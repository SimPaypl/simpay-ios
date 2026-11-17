import Foundation
import Testing
@testable import SimPayCheckoutCore

@Suite("SimPayTransactionStatusChecker")
struct TransactionStatusCheckerTests {

    private let id = Sample.transactionID

    private func checker(_ transport: StubTransport, provider: ScriptedProvider = ScriptedProvider()) -> SimPayTransactionStatusChecker {
        SimPayTransactionStatusChecker(api: AuthorizedAPIClient(
            client: Sample.client(transport),
            sessions: SessionStore(provider: provider, clock: ManualClock().sessionClock)
        ))
    }

    private static func statusJSON(_ raw: String) -> String {
        #"{"success":true,"data":{"status":"\#(raw)"}}"#
    }

    @Test("Maps the current status with one request and no polling")
    func mapping() async throws {
        let cases: [(String, SimPayCheckoutResult)] = [
            ("transaction_paid", .succeeded(transactionID: id, status: .paid)),
            ("transaction_new", .pending(transactionID: id, status: .new, reason: .inProgress)),
            ("transaction_confirmed", .pending(transactionID: id, status: .confirmed, reason: .inProgress)),
            ("transaction_fraud_possibility", .pending(transactionID: id, status: .fraudPossibility, reason: .verificationRequired)),
            ("transaction_whatever", .pending(transactionID: id, status: TransactionStatus(rawValue: "transaction_whatever"), reason: .unrecognizedStatus)),
        ]
        for (raw, expected) in cases {
            let transport = StubTransport(status: 200, json: Self.statusJSON(raw))
            #expect(try await checker(transport).status(of: id) == expected, "\(raw)")
            #expect(transport.callCount == 1)
            #expect(transport.requests.first?.url?.path == "/payment/\(Sample.serviceID)/mobile-sdk/transactions/\(id.rawValue)")
            #expect(transport.requests.first?.httpMethod == "GET")
        }
    }

    @Test("A definitive failure status is failed with the transaction id")
    func failed() async throws {
        let transport = StubTransport(status: 200, json: Self.statusJSON("transaction_expired"))
        let result = try await checker(transport).status(of: id)
        guard case .failed(let error, let transactionID, let status) = result else {
            Issue.record("unexpected \(result)")
            return
        }
        #expect(error.code == .transactionFailed)
        #expect(transactionID == id)
        #expect(status == .expired)
    }

    @Test("Read failures are thrown as typed errors and are never a payment failure", arguments: [
        (404, SimPayCheckoutError.Code.transactionNotFound),
        (503, .serviceUnavailable),
        (429, .rateLimited),
        (403, .unauthorized),
    ])
    func readFailure(_ status: Int, _ code: SimPayCheckoutError.Code) async {
        let transport = StubTransport(status: status)
        do {
            _ = try await checker(transport).status(of: id)
            Issue.record("expected an error")
        } catch let error as SimPayCheckoutError {
            #expect(error.code == code)
        } catch {
            Issue.record("unexpected error \(error)")
        }
        #expect(transport.callCount == 1)                        // no retry
    }

    @Test("No connection is reported as no_internet")
    func offline() async {
        let transport = StubTransport(.failure(URLError(.notConnectedToInternet)))
        do {
            _ = try await checker(transport).status(of: id)
            Issue.record("expected an error")
        } catch {
            #expect((error as? SimPayCheckoutError)?.code == .noInternet)
        }
    }

    @Test("HTTP 401 refreshes the session once, through the shared session handling")
    func refresh() async throws {
        let provider = ScriptedProvider()
        let transport = ScriptedTransport.accepting(
            [ScriptedProvider.token(2)],
            success: HTTPResponse(statusCode: 200, body: Data(Self.statusJSON("transaction_paid").utf8))
        )
        let checker = SimPayTransactionStatusChecker(api: AuthorizedAPIClient(
            client: SimPayAPIClient(environment: Sample.environment, transport: transport),
            sessions: SessionStore(provider: provider, clock: ManualClock().sessionClock)
        ))
        #expect(try await checker.status(of: id) == .succeeded(transactionID: id, status: .paid))
        #expect(provider.calls == 2)
        #expect(transport.callCount == 2)
    }

    @Test("An invalid service id is refused at creation")
    func invalidServiceID() {
        #expect(SimPayTransactionStatusChecker(serviceID: "../x", sessionProvider: ScriptedProvider()) == nil)
        #expect(SimPayTransactionStatusChecker(serviceID: "", sessionProvider: ScriptedProvider()) == nil)
        #expect(SimPayTransactionStatusChecker(serviceID: Sample.serviceID, sessionProvider: ScriptedProvider()) != nil)
    }
}
