#if os(iOS)
import SafariServices
import UIKit

/// Shows the payment page of a transaction. Replaced in tests.
@MainActor
package protocol PaymentPageBrowser: AnyObject {
    var isOpen: Bool { get }
    /// Shows `url` above `host`. Returns `false` when it cannot be shown. `onClose` runs
    /// once, when the payer closes the page themselves.
    func open(_ url: URL, from host: UIViewController, onClose: @escaping @MainActor () -> Void) -> Bool
    /// Closes the page without calling `onClose` (a return URL arrived, or the checkout
    /// ended).
    func close()
}

/// `SFSafariViewController`, the iOS counterpart of the Custom Tab used by the Android SDK.
///
/// Why this browser:
/// - it stays inside the app, so the checkout and its polling stay alive and closing the
///   browser is reported (`safariViewControllerDidFinish`), which a switch to Safari
///   cannot do;
/// - links of banks that open their app (Universal Links, custom schemes) are handed to
///   iOS like in Safari;
/// - it is a payment page, not a sign-in: `ASWebAuthenticationSession` would show the
///   system "wants to use … to sign in" prompt and ends only on a callback URL.
/// Behaviour with real bank apps must still be verified on a physical device.
package final class SafariPaymentPageBrowser: NSObject, PaymentPageBrowser, SFSafariViewControllerDelegate,
    UIAdaptivePresentationControllerDelegate {

    private var controller: SFSafariViewController?
    private var onClose: (@MainActor () -> Void)?

    override package init() {}

    package var isOpen: Bool { controller != nil }

    package func open(_ url: URL, from host: UIViewController, onClose: @escaping @MainActor () -> Void) -> Bool {
        // SFSafariViewController raises an exception for anything other than http(s).
        guard controller == nil, RedirectURLPolicy.isAllowed(url),
              host.viewIfLoaded?.window != nil, host.presentedViewController == nil else {
            return false
        }
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        configuration.barCollapsingEnabled = true

        let safari = SFSafariViewController(url: url, configuration: configuration)
        safari.dismissButtonStyle = .close
        safari.preferredControlTintColor = UIColor(hex: 0x00A63F)
        safari.modalPresentationStyle = .pageSheet
        safari.delegate = self
        // A swipe down dismisses the sheet without `safariViewControllerDidFinish`.
        safari.presentationController?.delegate = self
        host.present(safari, animated: true)
        // UIKit ignores the call (only logging it) when the host cannot present now.
        guard safari.presentingViewController != nil else { return false }
        controller = safari
        self.onClose = onClose
        return true
    }

    package func close() {
        guard let controller else { return }
        self.controller = nil
        onClose = nil
        if controller.presentingViewController != nil {
            controller.dismiss(animated: true)
        }
    }

    // MARK: Closed by the payer

    nonisolated package func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        MainActor.assumeIsolated { closedByPayer(controller) }
    }

    nonisolated package func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        MainActor.assumeIsolated { closedByPayer(presentationController.presentedViewController) }
    }

    private func closedByPayer(_ closed: UIViewController) {
        guard closed === controller else { return }
        controller = nil
        let onClose = self.onClose
        self.onClose = nil
        onClose?()
    }
}
#endif
