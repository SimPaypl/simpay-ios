import Foundation
@_spi(Testing) import SimPayCheckout

/// Scenarios of the mocked SimPay API, chosen with `-scenario <name>` or in the UI.
enum Scenario: String, CaseIterable, Identifiable, Sendable {
    case blikPaid
    case blikRejectedThenPaid
    case blikPending
    case redirectPaidAfterReturn
    case redirectPending
    case createTimeout
    case sessionExpiredThenPaid
    case statusOffline
    case channelsError

    var id: String { rawValue }

    static var fromLaunchArguments: Scenario {
        let value = UserDefaults.standard.string(forKey: "scenario") ?? ""
        return Scenario(rawValue: value) ?? .blikPaid
    }
}

/// Simulated SimPay API for the integration host. Every answer is produced in memory;
/// nothing leaves the device and no payment can happen.
///
/// Redirect scenarios simulate the bank: the transaction is reported paid only after the
/// app received a return URL (`markReturned()`), like a real payer finishing in the bank.
actor MockSimPayAPI: SimPayTestTransport {

    static let paymentPage = "https://example.com/"
    private static let transactionID = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"

    private(set) var scenario: Scenario
    private(set) var counts: [String: Int] = [:]
    private var returned = false
    private var statusReads = 0
    private var blikSubmissions = 0

    init(scenario: Scenario) {
        self.scenario = scenario
    }

    func reset(_ scenario: Scenario) {
        self.scenario = scenario
        counts = [:]
        returned = false
        statusReads = 0
        blikSubmissions = 0
    }

    func markReturned() { returned = true }

    func count(_ route: String) -> Int { counts[route, default: 0] }

    func respond(to request: URLRequest) async throws -> (statusCode: Int, headers: [String: String], body: Data) {
        let path = request.url?.path ?? ""
        try await Task.sleep(for: .milliseconds(450))

        if path.hasSuffix("/mobile-sdk/channels") {
            counts["channels", default: 0] += 1
            if scenario == .channelsError { return (503, [:], Data()) }
            return json(200, #"""
            {"success":true,"data":[
              {"id":"blik-level0","name":"BLIK Level 0","type":"blik","currencies":["PLN"]},
              {"id":"mbank","name":"mBank","type":"transfer","currencies":["PLN"]},
              {"id":"ing","name":"ING Bank Śląski","type":"transfer","currencies":["PLN"]},
              {"id":"pekao","name":"Pekao24","type":"transfer","currencies":["PLN"]},
              {"id":"sepa","name":"SEPA","type":"transfer","currencies":["EUR"]}
            ]}
            """#)
        }
        if path.contains("/blik/level0/") {
            counts["blik", default: 0] += 1
            blikSubmissions += 1
            if scenario == .blikRejectedThenPaid, blikSubmissions == 1 { return (409, [:], Data()) }
            return (204, [:], Data())
        }
        if path.contains("/mobile-sdk/transactions/") {
            counts["status", default: 0] += 1
            statusReads += 1
            return try statusAnswer()
        }
        counts["create", default: 0] += 1
        if scenario == .createTimeout { throw URLError(.timedOut) }
        return json(201, #"{"success":true,"data":{"transactionId":"\#(Self.transactionID)","redirectUrl":"\#(Self.paymentPage)"}}"#)
    }

    private func statusAnswer() throws -> (statusCode: Int, headers: [String: String], body: Data) {
        switch scenario {
        case .blikPaid, .blikRejectedThenPaid:
            return status(statusReads >= 2 ? "transaction_paid" : "transaction_new")
        case .redirectPaidAfterReturn:
            return status(returned ? "transaction_paid" : "transaction_new")
        case .sessionExpiredThenPaid:
            if statusReads == 1 { return (401, [:], Data()) }
            return status(returned ? "transaction_paid" : "transaction_new")
        case .statusOffline:
            throw URLError(.notConnectedToInternet)
        default:
            return status("transaction_new")
        }
    }

    private func status(_ raw: String) -> (statusCode: Int, headers: [String: String], body: Data) {
        json(200, #"{"success":true,"data":{"transactionId":"\#(Self.transactionID)","status":"\#(raw)"}}"#)
    }

    private func json(_ code: Int, _ text: String) -> (statusCode: Int, headers: [String: String], body: Data) {
        (code, ["Content-Type": "application/json"], Data(text.utf8))
    }
}

/// Stands in for the merchant backend that would call the SimPay session endpoint.
struct MockSessionProvider: SimPaySessionProvider {
    func provideSession() async throws -> SimPaySession {
        try SimPaySession(token: "mobsdk_integration_host", payerIP: "203.0.113.7")
    }
}
