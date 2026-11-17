import SwiftUI
@_spi(Testing) import SimPayCheckout

/// Minimal host for SDK integration tests. Not a demo app and never part of the SDK.
///
/// Return URLs are forwarded exactly as an integrator would:
/// - custom scheme `simpayhost://payment-return` through `onOpenURL`;
/// - Universal Links through `onContinueUserActivity` (requires an Associated Domains
///   entitlement and an `apple-app-site-association` file on a real domain).
@main
struct SimPayIntegrationHostApp: App {

    @StateObject private var host = HostState()

    var body: some Scene {
        WindowGroup {
            ContentView(host: host)
                .onOpenURL { url in
                    host.received(url: url, handled: SimPayCheckout.handleReturnURL(url))
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    let handled = SimPayCheckout.handleUserActivity(activity)
                    host.received(url: activity.webpageURL, handled: handled)
                }
        }
    }
}

@MainActor
final class HostState: ObservableObject {

    @Published var scenario: Scenario = .fromLaunchArguments
    @Published var results: [String] = []
    @Published var createdTransactions: [String] = []
    @Published var returnLog: [String] = []
    @Published var isPaying = false

    let api = MockSimPayAPI(scenario: .fromLaunchArguments)
    let checkout: SimPayCheckout

    init() {
        checkout = SimPayCheckout(
            configuration: SimPayConfiguration(serviceID: "a1b2c3d4", merchantDisplayName: "Sklep Testowy")!,
            sessionProvider: MockSessionProvider(),
            testTransport: api
        )
    }

    var order: SimPayOrder {
        try! SimPayOrder(
            amount: Decimal(string: "149.99", locale: Locale(identifier: "en_US_POSIX"))!,
            currency: "PLN",
            transactionDescription: "Integration test order",
            control: "host-order-1",
            customerEmail: "jan.kowalski@example.com",
            returnURLs: SimPayReturnURLs(
                success: URL(string: "simpayhost://payment-return?result=success")!,
                failure: URL(string: "simpayhost://payment-return?result=failure")!
            )
        )
    }

    func select(_ scenario: Scenario) {
        self.scenario = scenario
        results = []
        createdTransactions = []
        returnLog = []
        let api = self.api
        Task { await api.reset(scenario) }
    }

    func transactionCreated(_ id: TransactionID) {
        createdTransactions.append(id.rawValue)
    }

    func finished(_ result: SimPayCheckoutResult) {
        results.append(Self.describe(result))
    }

    func received(url: URL?, handled: Bool) {
        // The simulated bank finishes the payment once the payer is sent back.
        if handled {
            let api = self.api
            Task { await api.markReturned() }
        }
        returnLog.append("\(handled ? "handled" : "ignored"): \(url?.absoluteString ?? "-")")
    }

    static func describe(_ result: SimPayCheckoutResult) -> String {
        switch result {
        case .succeeded: return "succeeded"
        case .pending(_, _, let reason): return "pending(\(reason.rawValue))"
        case .failed(let error, _, _): return "failed(\(error.code.rawValue))"
        case .outcomeUnknown: return "outcomeUnknown"
        case .cancelled: return "cancelled"
        }
    }
}
