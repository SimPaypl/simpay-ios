import Testing
@testable import SimPayCheckoutCore

@Suite("Transaction status mapping")
struct TransactionStatusTests {

    private struct MappingFile: Decodable {
        let cases: [Case]
    }

    private struct Case: Decodable, CustomTestStringConvertible {
        let raw: String
        let outcome: String
        let errorCode: String?
        let pendingReason: String?

        var testDescription: String { raw.isEmpty ? "<empty>" : raw }
    }

    private static let mapping: [Case] = (try? Fixture.load(MappingFile.self, named: "api/status-mapping").cases) ?? []

    @Test("The mapping fixture is loaded")
    func fixtureIsLoaded() {
        #expect(Self.mapping.count >= 10)
    }

    @Test("Every status maps to the contract outcome", arguments: mapping)
    private func mapsToContractOutcome(_ expected: Case) throws {
        let status = TransactionStatus(rawValue: expected.raw)
        let result = status.finalResult(for: Sample.transactionID)

        switch (expected.outcome, result) {
        case ("keep_checking", nil):
            break

        case ("succeeded", .succeeded(let id, let reported)?):
            #expect(id == Sample.transactionID)
            #expect(reported.rawValue == expected.raw)

        case ("failed", .failed(let error, let id, let reported)?):
            #expect(error.code.rawValue == expected.errorCode)
            #expect(id == Sample.transactionID)
            #expect(reported?.rawValue == expected.raw)

        case ("pending", .pending(let id, let reported, let reason)?):
            #expect(reason.rawValue == expected.pendingReason)
            #expect(id == Sample.transactionID)
            #expect(reported?.rawValue == expected.raw)

        default:
            Issue.record("\(expected.raw) resolved to \(String(describing: result)), contract expects \(expected.outcome)")
        }
    }

    @Test("Only transaction_paid is a success")
    func onlyPaidSucceeds() {
        for raw in Self.mapping.map(\.raw) where raw != "transaction_paid" {
            if case .succeeded? = TransactionStatus(rawValue: raw).finalResult(for: Sample.transactionID) {
                Issue.record("\(raw) must never be a success")
            }
        }
    }

    @Test("Every known constant is recognised and covered by the fixture")
    func knownConstantsAreCovered() {
        let known: [TransactionStatus] = [
            .new, .generated, .confirmed, .paid, .failure, .fraud, .fraudPossibility, .expired, .refunded,
        ]
        let fixtureRaws = Set(Self.mapping.map(\.raw))

        for status in known {
            #expect(status.isRecognized)
            #expect(fixtureRaws.contains(status.rawValue), "\(status) missing from status-mapping.json")
        }
        #expect(Set(known.map(\.phase)) == Set(TransactionStatus.Phase.allCases).subtracting([.unrecognized]))
    }

    @Test("Unknown statuses keep their raw value and are not recognised")
    func unknownStatusKeepsRawValue() {
        let status = TransactionStatus(rawValue: "transaction_something_new")
        #expect(!status.isRecognized)
        #expect(status.rawValue == "transaction_something_new")
        #expect(status.description == "transaction_something_new")
    }
}
