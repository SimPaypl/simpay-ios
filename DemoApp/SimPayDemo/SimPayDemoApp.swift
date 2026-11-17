import SwiftUI
import SimPayCheckout

/// A standalone integration example. The demo depends on the local Swift package,
/// but none of its UI or fake responses are included in the SDK product.
@main
struct SimPayDemoApp: App {
    @StateObject private var state = DemoState()

    var body: some Scene {
        WindowGroup {
            DemoStoreView(state: state)
                .onOpenURL { url in
                    state.handleIncoming(url) { SimPayCheckout.handleReturnURL(url) }
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    state.handleIncoming(activity.webpageURL) { SimPayCheckout.handleUserActivity(activity) }
                }
        }
    }
}
