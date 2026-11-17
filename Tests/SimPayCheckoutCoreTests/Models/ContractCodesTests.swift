import Testing
@_spi(SimPayBridge) @testable import SimPayCheckoutCore

@Suite("Result and error contract")
struct ContractCodesTests {

    private struct CodesFile: Decodable {
        struct ErrorCode: Decodable { let code: String; let category: String; let meaning: String; let since: String }
        struct Reason: Decodable { let reason: String }
        struct ResultType: Decodable { let type: String; let transactionId: String }
        let errorCodes: [ErrorCode]
        let pendingReasons: [Reason]
        let resultTypes: [ResultType]
    }

    private func contract() throws -> CodesFile {
        try Fixture.load(CodesFile.self, named: "codes/codes")
    }

    @Test("Error codes match the contract exactly, in order")
    func errorCodesMatchContract() throws {
        #expect(SimPayCheckoutError.Code.allKnown.map(\.rawValue) == (try contract().errorCodes.map(\.code)))
    }

    @Test("Every error code has a category, a meaning and a contract version")
    func errorCodesAreDocumented() throws {
        let categories: Set = ["connectivity", "session", "api", "payment", "integration", "internal"]
        for entry in try contract().errorCodes {
            #expect(categories.contains(entry.category), "\(entry.code)")
            #expect(!entry.meaning.isEmpty, "\(entry.code)")
            #expect(entry.since.split(separator: ".").count == 3, "\(entry.code)")
        }
    }

    @Test("Pending reasons match the contract exactly, in order")
    func pendingReasonsMatchContract() throws {
        #expect(SimPayCheckoutResult.PendingReason.allKnown.map(\.rawValue) == (try contract().pendingReasons.map(\.reason)))
    }

    @Test("Result types and transaction id rules match the bridge")
    func resultTypesMatchContract() throws {
        let types = try contract().resultTypes
        #expect(types.map(\.type) == SimPayBridge.ResultType.all)
        let rules = Dictionary(uniqueKeysWithValues: types.map { ($0.type, $0.transactionId) })
        #expect(rules == [
            "succeeded": "required", "pending": "required", "failed": "optional",
            "outcome_unknown": "forbidden", "cancelled": "forbidden",
        ])
    }

    @Test("Identifiers are unique snake_case strings")
    func identifiersAreSnakeCase() {
        let values = SimPayCheckoutError.Code.allKnown.map(\.rawValue)
            + SimPayCheckoutResult.PendingReason.allKnown.map(\.rawValue)

        #expect(Set(SimPayCheckoutError.Code.allKnown).count == SimPayCheckoutError.Code.allKnown.count)
        for value in values {
            let isSnakeCase = !value.isEmpty
                && value.first != "_" && value.last != "_"
                && value.utf8.allSatisfy { ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z")) || $0 == UInt8(ascii: "_") }
            #expect(isSnakeCase, "\(value) is not snake_case")
        }
    }

    @Test("A code received from another platform round-trips through its raw value")
    func codesRoundTrip() {
        #expect(SimPayCheckoutError.Code(rawValue: "outcome_unknown") == .outcomeUnknown)
        // A code introduced by a newer contract is kept rather than rejected.
        #expect(SimPayCheckoutError.Code(rawValue: "future_code").rawValue == "future_code")
    }

    @Test("Error description carries the code and the message")
    func errorDescription() {
        #expect(SimPayCheckoutError(.timeout).description == "SimPayCheckoutError(timeout)")
        #expect(
            SimPayCheckoutError(.invalidOrder, message: "amount must be at least 1").description
                == "SimPayCheckoutError(invalid_order): amount must be at least 1"
        )
    }

    @Test("outcomeUnknown is distinct from pending and carries no transaction id")
    func outcomeUnknownIsDistinct() {
        let unknown = SimPayCheckoutResult.outcomeUnknown(SimPayCheckoutError(.outcomeUnknown))
        let pending = SimPayCheckoutResult.pending(
            transactionID: Sample.transactionID, status: nil, reason: .statusUnavailable
        )

        #expect(unknown != pending)
        #expect(unknown.transactionID == nil)
        #expect(pending.transactionID == Sample.transactionID)
        #expect(SimPayCheckoutResult.cancelled.transactionID == nil)
    }

    @Test("A failure before any transaction carries no id; a failed transaction carries its id")
    func failureTransactionID() {
        let local = SimPayCheckoutResult.failed(SimPayCheckoutError(.missingPayerIP), transactionID: nil, status: nil)
        let rejected = SimPayCheckoutResult.failed(
            SimPayCheckoutError(.transactionFailed), transactionID: Sample.transactionID, status: .failure
        )

        #expect(local.transactionID == nil)
        #expect(rejected.transactionID == Sample.transactionID)
    }
}
