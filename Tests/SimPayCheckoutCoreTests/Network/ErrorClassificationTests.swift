import Foundation
import Testing
@testable import SimPayCheckoutCore

@Suite("Error classification")
struct ErrorClassificationTests {

    private struct MappingFile: Decodable { let cases: [Case] }

    struct Case: Decodable, CustomTestStringConvertible {
        let endpoint: String
        let status: Int
        let code: String
        let kind: String
        var testDescription: String { "\(endpoint) HTTP \(status)" }
    }

    private static let mapping: [Case] = (try? Fixture.load(MappingFile.self, named: "api/http-error-mapping").cases) ?? []

    private static func endpoint(_ name: String) -> APIEndpoint? {
        switch name {
        case "channels": return .channels
        case "create_transaction": return .createTransaction
        case "submit_blik_code": return .submitBlikCode(Sample.transactionID)
        case "transaction_status": return .transactionStatus(Sample.transactionID)
        default: return nil
        }
    }

    private static func kindName(_ kind: FailureKind) -> String {
        switch kind {
        case .notDelivered: return "not_delivered"
        case .rejected: return "rejected"
        case .transient: return "transient"
        case .outcomeUnknown: return "outcome_unknown"
        }
    }

    @Test("The HTTP mapping fixture covers every endpoint")
    func fixtureCoversEndpoints() {
        #expect(Set(Self.mapping.map(\.endpoint)) == ["channels", "create_transaction", "submit_blik_code", "transaction_status"])
    }

    @Test("HTTP statuses map per endpoint as the contract states", arguments: mapping)
    func statusMapping(_ expected: Case) throws {
        let endpoint = try #require(Self.endpoint(expected.endpoint))
        let failure = ErrorClassifier.classify(statusCode: expected.status, body: Data(), endpoint: endpoint)

        #expect(failure.error.code.rawValue == expected.code)
        #expect(Self.kindName(failure.kind) == expected.kind)
        #expect(failure.httpStatus == expected.status)
    }

    @Test("The same HTTP status means different things on different endpoints")
    func endpointContext() {
        let id = Sample.transactionID
        // 404: Android maps it globally to TransactionNotFound.
        #expect(ErrorClassifier.classify(statusCode: 404, body: Data(), endpoint: .channels).error.code == .channelsFailed)
        #expect(ErrorClassifier.classify(statusCode: 404, body: Data(), endpoint: .transactionStatus(id)).error.code == .transactionNotFound)
        // 409: Android maps it globally to BlikRejected.
        #expect(ErrorClassifier.classify(statusCode: 409, body: Data(), endpoint: .createTransaction).kind == .outcomeUnknown)
        #expect(ErrorClassifier.classify(statusCode: 409, body: Data(), endpoint: .submitBlikCode(id)).error.code == .blikRejected)
        // 500: harmless for reads, unknown state for writes.
        #expect(ErrorClassifier.classify(statusCode: 500, body: Data(), endpoint: .transactionStatus(id)).kind != .outcomeUnknown)
        #expect(ErrorClassifier.classify(statusCode: 500, body: Data(), endpoint: .createTransaction).kind == .outcomeUnknown)
    }

    // MARK: Transport errors

    static let notDelivered: [URLError.Code] = [.notConnectedToInternet, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed]
    static let certificate: [URLError.Code] = [.serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .clientCertificateRejected]
    static let ambiguous: [URLError.Code] = [
        .timedOut, .networkConnectionLost, .secureConnectionFailed, .cancelled,
        .badServerResponse, .cannotParseResponse, .zeroByteResource, .resourceUnavailable, .unknown,
    ]

    @Test("Errors before a connection exists are not_delivered for every endpoint", arguments: notDelivered)
    func notDeliveredErrors(_ code: URLError.Code) {
        for endpoint in [APIEndpoint.channels, .createTransaction, .submitBlikCode(Sample.transactionID)] {
            let failure = ErrorClassifier.classify(transportError: URLError(code), endpoint: endpoint)
            #expect(failure.kind == .notDelivered)
            #expect(failure.error.code == .noInternet)
        }
    }

    @Test("Certificate failures are TLS errors before sending", arguments: certificate)
    func certificateErrors(_ code: URLError.Code) {
        let failure = ErrorClassifier.classify(transportError: URLError(code), endpoint: .createTransaction)
        #expect(failure.kind == .notDelivered)
        #expect(failure.error.code == .secureConnectionFailed)
    }

    @Test("Ambiguous network errors after a POST are outcome_unknown", arguments: ambiguous)
    func ambiguousMutating(_ code: URLError.Code) {
        for endpoint in [APIEndpoint.createTransaction, .submitBlikCode(Sample.transactionID)] {
            let failure = ErrorClassifier.classify(transportError: URLError(code), endpoint: endpoint)
            #expect(failure.kind == .outcomeUnknown)
            #expect(failure.error.code == .outcomeUnknown)
        }
    }

    @Test("The same ambiguous errors are transient for reads", arguments: ambiguous)
    func ambiguousRead(_ code: URLError.Code) {
        let failure = ErrorClassifier.classify(transportError: URLError(code), endpoint: .transactionStatus(Sample.transactionID))
        #expect(failure.kind == .transient)
    }

    @Test("A read timeout is timeout; a TLS failure is secure_connection_failed")
    func readCodes() {
        #expect(ErrorClassifier.classify(transportError: URLError(.timedOut), endpoint: .channels).error.code == .timeout)
        #expect(ErrorClassifier.classify(transportError: URLError(.secureConnectionFailed), endpoint: .channels).error.code == .secureConnectionFailed)
    }

    @Test("A non-URLError failure is outcome_unknown for writes")
    func foreignError() {
        struct Boom: Error {}
        #expect(ErrorClassifier.classify(transportError: Boom(), endpoint: .createTransaction).kind == .outcomeUnknown)
        #expect(ErrorClassifier.classify(transportError: Boom(), endpoint: .channels).kind == .transient)
    }

    // MARK: Through the client

    @Test("Client surfaces a timeout on POST as outcome_unknown")
    func clientTimeoutOnCreate() async {
        let failure = await apiFailure {
            _ = try await Sample.client(StubTransport(.failure(URLError(.timedOut)))).createTransaction(Sample.createRequest(), session: Sample.session)
        }
        #expect(failure?.error.code == .outcomeUnknown)
    }

    @Test("Client surfaces 429 and 5xx on reads as safe to repeat", arguments: [429, 500, 502, 503])
    func clientReadServerErrors(_ status: Int) async {
        let failure = await apiFailure {
            _ = try await Sample.client(StubTransport(status: status)).transactionStatus(Sample.transactionID, session: Sample.session)
        }
        #expect(failure?.kind == .transient)
        #expect(failure?.httpStatus == status)
    }

    @Test("API error bodies are summarised by field names and message only")
    func errorSummary() {
        let body = Data(#"{"message":"The given data was invalid.","errors":{"customer.email":["The email jan.kowalski@example.com is invalid."],"customer.ip":["203.0.113.10 is private"]}}"#.utf8)
        let failure = ErrorClassifier.classify(statusCode: 422, body: body, endpoint: .createTransaction)

        #expect(failure.error.message == "The given data was invalid.; fields: customer.email, customer.ip")
        #expect(!(failure.error.message ?? "").contains(Sample.email))
        #expect(!(failure.error.message ?? "").contains(Sample.ip))
    }

    @Test("Long or missing API messages are handled")
    func errorSummaryEdges() {
        let long = Data(#"{"message":"\#(String(repeating: "x", count: 500))"}"#.utf8)
        #expect(APIErrorSummary.make(from: long)?.count == 120)
        #expect(APIErrorSummary.make(from: Data()) == nil)
        #expect(APIErrorSummary.make(from: Data("<html>502</html>".utf8)) == nil)
        #expect(ErrorClassifier.classify(statusCode: 502, body: Data("<html>".utf8), endpoint: .channels).error.message == "Server error")
    }
}
