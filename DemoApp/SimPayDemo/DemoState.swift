import Foundation
import SwiftUI
import SimPayCheckout
#if DEBUG
@_spi(Testing) import SimPayCheckout
#endif

enum DemoMode: String, CaseIterable, Identifiable {
    /// Simulated API on the device; nothing is sent to SimPay.
    case fake = "FAKE"
    /// Real SimPay API, session created in the app with a test API key (Debug only).
    case apiKey = "API KEY"

    var id: String { rawValue }
}

/// State of the demo shop. Payments themselves are done entirely by the SDK.
@MainActor
final class DemoState: ObservableObject {

    enum Outcome { case success, pending, failure }

    @Published var isPresenting = false
    @Published private(set) var checkout: SimPayCheckout
    @Published private(set) var mode: DemoMode = .fake
    #if DEBUG
    @Published private(set) var scenario: DemoScenario = .launchArgument
    #endif
    @Published private(set) var resultText: String?
    @Published private(set) var resultDetail: String?
    @Published private(set) var outcome: Outcome?
    @Published private(set) var message: String?

    /// API KEY mode, prefilled from the git-ignored `SimPayDebug.local.xcconfig`. Kept in
    /// memory only, never persisted or logged.
    @Published var serviceID = ""
    @Published var apiKey = ""
    @Published var payerIP = ""

    let order: SimPayOrder = try! SimPayOrder(
        amount: Decimal(string: "1.00")!,
        transactionDescription: "Słuchawki bezprzewodowe — demo",
        customerEmail: "klient@example.com",
        customerCountryCode: "PL",
        returnURLs: SimPayReturnURLs(
            success: URL(string: "simpay-demo://payment-return?result=success")!,
            failure: URL(string: "simpay-demo://payment-return?result=failure")!
        )
    )

    #if DEBUG
    private var fakeAPI: DemoMockAPI?
    #endif

    init() {
        #if DEBUG
        let api = DemoMockAPI(scenario: .launchArgument)
        fakeAPI = api
        checkout = Self.fakeCheckout(api)
        let stored = DebugAPIKeyConfiguration.storedValues(in: Bundle.main.infoDictionary)
        serviceID = stored.serviceID
        apiKey = stored.apiKey
        payerIP = stored.payerIP
        #else
        // The demo pays only in Debug builds (simulated API or a test API key).
        checkout = SimPayCheckout(
            configuration: SimPayConfiguration(serviceID: "a1b2c3d4", merchantDisplayName: "SimPay Demo Shop")!,
            sessionProvider: UnavailableSessionProvider()
        )
        #endif
    }

    func changeMode(_ newMode: DemoMode) {
        guard !isPresenting else { return }
        mode = newMode
        clearResult()
    }

    #if DEBUG
    func changeScenario(_ newScenario: DemoScenario) {
        guard !isPresenting else { return }
        scenario = newScenario
        clearResult()
    }
    #endif

    func pay() {
        guard !isPresenting, !checkout.isPresenting else { return }
        clearResult()
        #if DEBUG
        switch mode {
        case .fake:
            let api = DemoMockAPI(scenario: scenario)
            fakeAPI = api
            checkout = Self.fakeCheckout(api)
        case .apiKey:
            guard let configuration = DebugAPIKeyConfiguration(serviceID: serviceID, apiKey: apiKey, payerIP: payerIP),
                  let checkoutConfiguration = SimPayConfiguration(serviceID: configuration.serviceID, merchantDisplayName: "SimPay Demo Shop") else {
                message = "Podaj Service ID i klucz API (albo uzupełnij SimPayDebug.local.xcconfig)."
                return
            }
            checkout = SimPayCheckout(
                configuration: checkoutConfiguration,
                sessionProvider: DebugAPIKeySessionProvider(configuration: configuration)
            )
        }
        #endif
        isPresenting = true
    }

    func paymentFinished(_ result: SimPayCheckoutResult) {
        switch result {
        case .succeeded:
            outcome = .success
            resultText = "Płatność zakończona — potwierdzona statusem z API."
        case .pending:
            outcome = .pending
            resultText = "Płatność w toku — ostateczny wynik potwierdzi webhook."
        case .failed(let error, _, _):
            outcome = .failure
            resultText = "Płatność nieudana (\(error.code.rawValue))."
            resultDetail = error.message
        case .outcomeUnknown(let error):
            outcome = .pending
            resultText = "Nie wiadomo, czy transakcja powstała — nie płać ponownie."
            resultDetail = error.message
        case .cancelled:
            outcome = nil
            resultText = "Płatność anulowana."
        }
    }

    /// URL schemes and Universal Links. In FAKE mode the simulated bank learns about the
    /// return first, so the status read triggered by the SDK already sees it.
    func handleIncoming(_ url: URL?, forward: @escaping @MainActor () -> Bool) {
        #if DEBUG
        if mode == .fake, DemoMockAPI.isBankReturn(url), let api = fakeAPI {
            Task {
                await api.markReturned()
                _ = forward()
            }
            return
        }
        #endif
        _ = forward()
    }

    private func clearResult() {
        resultText = nil
        resultDetail = nil
        outcome = nil
        message = nil
    }

    #if DEBUG
    private static func fakeCheckout(_ api: DemoMockAPI) -> SimPayCheckout {
        SimPayCheckout(
            configuration: SimPayConfiguration(serviceID: "a1b2c3d4", merchantDisplayName: "SimPay Demo Shop")!,
            sessionProvider: DemoMockSessionProvider(),
            testTransport: api
        )
    }
    #endif
}

#if !DEBUG
private struct UnavailableSessionProvider: SimPaySessionProvider {
    func provideSession() async throws -> SimPaySession {
        throw SimPayCheckoutError(.sessionFailed, message: "The demo pays only in Debug builds.")
    }
}
#endif
