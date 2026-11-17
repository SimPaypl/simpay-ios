#if os(iOS)
import UIKit

/// The User-Agent sent as `antifraud.useragent`.
///
/// Mirrors `DeviceUserAgent` of the Android SDK, which uses the WebView default agent:
/// the payment is continued in a browser or a banking app, and antifraud systems compare
/// the declared agent with that client. This is the format Mobile Safari reports on the
/// device. It carries no account or device identifier, only the OS version and family.
enum DeviceUserAgent {

    @MainActor
    static func current() -> String {
        let device = UIDevice.current
        return make(systemVersion: device.systemVersion, isPad: device.userInterfaceIdiom == .pad)
    }

    static func make(systemVersion: String, isPad: Bool) -> String {
        let parts = systemVersion.split(separator: ".").prefix(3).map(String.init)
        let underscored = parts.joined(separator: "_")
        let short = parts.prefix(2).joined(separator: ".")
        let platform = isPad ? "iPad; CPU OS \(underscored) like Mac OS X" : "iPhone; CPU iPhone OS \(underscored) like Mac OS X"
        return "Mozilla/5.0 (\(platform)) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/\(short) Mobile/15E148 Safari/604.1"
    }
}

/// Translates application notifications into ``AppLifecycleEvent`` for the engine.
///
/// `UIApplication` notifications are posted to SwiftUI and UIKit apps alike, with or
/// without scenes, so one observer covers both. The observer lives exactly as long as the
/// sheet; ``stop()`` removes it.
@MainActor
final class AppLifecycleObserver {

    private let center: NotificationCenter
    private var tokens: [any NSObjectProtocol] = []

    init(center: NotificationCenter = .default, onEvent: @escaping @MainActor @Sendable (AppLifecycleEvent) -> Void) {
        self.center = center
        let mapping: [(Notification.Name, AppLifecycleEvent)] = [
            (UIApplication.didEnterBackgroundNotification, .didEnterBackground),
            (UIApplication.willEnterForegroundNotification, .willEnterForeground),
        ]
        tokens = mapping.map { name, event in
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { onEvent(event) }
            }
        }
    }

    func stop() {
        tokens.forEach(center.removeObserver)
        tokens.removeAll()
    }
}

/// Presents and dismisses the sheet. Replaced in tests, where no application exists.
@MainActor
package protocol SheetPresenter {
    /// The controller to present from, or `nil` when presenting is impossible.
    func presentationHost(from viewController: UIViewController) -> UIViewController?
    /// Returns `false` when UIKit refused to present, for example because `host` started
    /// presenting something else in the same run loop.
    func present(_ sheet: UIViewController, from host: UIViewController) -> Bool
    /// Dismisses the sheet if it is still presented; `completion` runs exactly once.
    func dismiss(_ sheet: UIViewController, completion: @escaping @MainActor () -> Void)
}

package struct UIKitSheetPresenter: SheetPresenter {

    package init() {}

    /// The topmost controller above `viewController`, so adapters may pass the root view
    /// controller. Refuses a controller outside a window or one being dismissed.
    package func presentationHost(from viewController: UIViewController) -> UIViewController? {
        guard viewController.viewIfLoaded?.window != nil else { return nil }
        var top = viewController
        while let presented = top.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        return top.isBeingDismissed ? nil : top
    }

    package func present(_ sheet: UIViewController, from host: UIViewController) -> Bool {
        host.present(sheet, animated: true)
        // A refused presentation is only logged by UIKit; this is the one way to notice it.
        return sheet.presentingViewController != nil
    }

    package func dismiss(_ sheet: UIViewController, completion: @escaping @MainActor () -> Void) {
        guard sheet.presentingViewController != nil, !sheet.isBeingDismissed else {
            completion()
            return
        }
        sheet.dismiss(animated: true) { MainActor.assumeIsolated { completion() } }
    }
}
#endif
