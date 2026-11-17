/// Application events the checkout reacts to, independent of UIKit and SwiftUI.
///
/// The platform layer translates its own notifications into these events (for example
/// `UIApplication.didEnterBackgroundNotification`, `scenePhase`, the dismissal of the
/// in-app browser or an opened return URL) and passes them to
/// ``CheckoutEngine/handle(_:)``. Bridges for Flutter and React Native rely on the same
/// native observer, so they need no lifecycle logic of their own.
///
/// No event is ever a payment confirmation: returning from the bank only triggers a
/// status read.
package enum AppLifecycleEvent: Sendable, Hashable {
    /// The app moved to the background. Polling pauses; the transaction id stays in memory.
    case didEnterBackground
    /// The app is back in the foreground. The status is read at once and polling resumes
    /// with the budget that was left.
    case willEnterForeground
    /// The payer came back from the payment page or the bank, for example the in-app
    /// browser was closed or a return URL was opened. Triggers a status read.
    case returnedFromRedirect
}
