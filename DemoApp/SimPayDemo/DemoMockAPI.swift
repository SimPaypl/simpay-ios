#if DEBUG
import Foundation
@_spi(Testing) import SimPayCheckout

/// Local test scenarios. All payment API calls are answered in memory.
enum DemoScenario: String, CaseIterable, Identifiable, Sendable {
    case blikPaid
    case blikRejectedThenPaid
    case blikPending
    case redirectPaidAfterReturn
    case redirectPending
    case createTimeout
    case sessionExpiredThenPaid
    case statusOffline
    case statusFailed
    case verificationRequired
    case channelsError

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blikPaid: "BLIK — sukces"
        case .blikRejectedThenPaid: "BLIK — zły kod, potem sukces"
        case .blikPending: "BLIK — oczekiwanie"
        case .redirectPaidAfterReturn: "Bank — sukces po powrocie"
        case .redirectPending: "Bank — oczekiwanie"
        case .createTimeout: "Tworzenie — nieznany wynik"
        case .sessionExpiredThenPaid: "Sesja — 401 i odświeżenie"
        case .statusOffline: "Status — brak sieci"
        case .statusFailed: "Status — płatność odrzucona"
        case .verificationRequired: "Status — weryfikacja"
        case .channelsError: "Kanały — błąd 503"
        }
    }

    var explanation: String {
        switch self {
        case .blikPaid: "Po kodzie BLIK status zmienia się na opłacony."
        case .blikRejectedThenPaid: "Pierwszy kod zostaje odrzucony, drugi przechodzi."
        case .blikPending: "Transakcja pozostaje w trakcie przetwarzania."
        case .redirectPaidAfterReturn: "Po powrocie z przeglądarki API zgłasza sukces."
        case .redirectPending: "Zamknięcie przeglądarki nie oznacza sukcesu."
        case .createTimeout: "POST mógł dotrzeć do serwera — bez ponowienia."
        case .sessionExpiredThenPaid: "Pierwszy odczyt statusu zwraca HTTP 401, SDK odświeża sesję."
        case .statusOffline: "Błąd sieci przy pollingu nie oznacza niepowodzenia (wynik po ok. 2 min)."
        case .statusFailed: "API zgłasza transaction_failure — jednoznaczne niepowodzenie."
        case .verificationRequired: "API zgłasza transaction_fraud_possibility — płatność oczekuje."
        case .channelsError: "Nie można pobrać dostępnych metod płatności."
        }
    }

    static var launchArgument: DemoScenario {
        let arguments = ProcessInfo.processInfo.arguments
        if let index = arguments.firstIndex(of: "-scenario"), arguments.indices.contains(index + 1) {
            return DemoScenario(rawValue: arguments[index + 1]) ?? .blikPaid
        }
        return .blikPaid
    }
}

/// Test-only API transport. It never sends a payment request to SimPay.
/// Redirect pages use https://example.com/ and may load that public page in Safari.
actor DemoMockAPI: SimPayTestTransport {
    static let sampleTransactionID = "3f2504e0-4f89-41d3-9a0c-0305e82c3301"

    let scenario: DemoScenario
    private var returned = false
    private var statusReads = 0
    private var blikSubmissions = 0

    init(scenario: DemoScenario) { self.scenario = scenario }

    func markReturned() { returned = true }

    /// Answers whether the payer came back from the (fake) bank. Only the dedicated
    /// return path counts, so an unrelated deep link never "completes" a payment.
    static func isBankReturn(_ url: URL?) -> Bool {
        url?.scheme?.lowercased() == "simpay-demo" && url?.host?.lowercased() == "payment-return"
    }

    func respond(to request: URLRequest) async throws -> (statusCode: Int, headers: [String: String], body: Data) {
        let path = request.url?.path ?? ""
        try await Task.sleep(for: .milliseconds(300))

        if path.hasSuffix("/mobile-sdk/channels") {
            if scenario == .channelsError { return (503, [:], Data()) }
            return json(200, #"""
            {"success":true,"data":[
              {"id":"blik-level0","name":"BLIK Level 0","type":"blik","currencies":["PLN"]},
              {"id":"mbank","name":"mBank","type":"transfer","currencies":["PLN"]},
              {"id":"ing","name":"ING Bank Śląski","type":"transfer","currencies":["PLN"]},
              {"id":"pekao","name":"Pekao24","type":"transfer","currencies":["PLN"]}
            ]}
            """#)
        }
        if path.contains("/blik/level0/") {
            blikSubmissions += 1
            if scenario == .blikRejectedThenPaid, blikSubmissions == 1 { return (409, [:], Data()) }
            return (204, [:], Data())
        }
        if path.contains("/mobile-sdk/transactions/") {
            statusReads += 1
            return try statusAnswer()
        }
        if scenario == .createTimeout { throw URLError(.timedOut) }
        return json(201, #"{"success":true,"data":{"transactionId":"\#(Self.sampleTransactionID)","redirectUrl":"https://example.com/"}}"#)
    }

    private func statusAnswer() throws -> (statusCode: Int, headers: [String: String], body: Data) {
        switch scenario {
        case .blikPaid, .blikRejectedThenPaid:
            return status(statusReads >= 2 ? "transaction_paid" : "transaction_new")
        case .redirectPaidAfterReturn:
            return status(returned ? "transaction_paid" : "transaction_new")
        case .sessionExpiredThenPaid:
            // The first read is refused; the SDK refreshes the session once and reads again.
            if statusReads == 1 { return (401, [:], Data()) }
            return status("transaction_paid")
        case .statusFailed:
            return status("transaction_failure")
        case .verificationRequired:
            return status("transaction_fraud_possibility")
        case .statusOffline:
            throw URLError(.notConnectedToInternet)
        default:
            return status("transaction_new")
        }
    }

    private func status(_ status: String) -> (statusCode: Int, headers: [String: String], body: Data) {
        json(200, #"{"success":true,"data":{"transactionId":"\#(Self.sampleTransactionID)","status":"\#(status)"}}"#)
    }

    private func json(_ code: Int, _ body: String) -> (statusCode: Int, headers: [String: String], body: Data) {
        (code, ["Content-Type": "application/json"], Data(body.utf8))
    }
}

struct DemoMockSessionProvider: SimPaySessionProvider {
    func provideSession() async throws -> SimPaySession {
        try SimPaySession(token: "mobsdk_demo_only", payerIP: "203.0.113.7")
    }
}
#endif
