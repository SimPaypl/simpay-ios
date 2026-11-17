#if os(iOS)
import Foundation
import SimPayCheckoutCore
import UIKit

/// Entry point of the SimPay checkout on iOS.
///
/// ```swift
/// let checkout = SimPayCheckout(configuration: configuration, sessionProvider: provider)
/// let result = await checkout.present(order, from: viewController)
/// ```
///
/// - Every `present` call reports exactly one ``SimPayCheckoutResult``.
/// - Only one payment sheet can be shown at a time in the app; another `present` call
///   immediately reports `.failed` with `already_presented`.
/// - Closing the sheet never reports `.cancelled` once a transaction may exist; a request
///   in flight is always settled first.
/// - No result is proof of payment: the merchant backend must confirm the payment from the
///   SimPay webhook before releasing goods.
@MainActor
public final class SimPayCheckout {

    public let configuration: SimPayConfiguration

    private let sessionProvider: any SimPaySessionProvider
    private let dependencies: CheckoutDependencies
    private let notificationCenter: NotificationCenter
    private var presentation: Presentation?

    /// One sheet at a time for the whole app, across `SimPayCheckout` instances.
    private static var isSheetPresented = false
    /// The instance showing the sheet, for the static return URL entry points.
    private static weak var activeCheckout: SimPayCheckout?

    public convenience init(configuration: SimPayConfiguration, sessionProvider: any SimPaySessionProvider) {
        self.init(configuration: configuration, sessionProvider: sessionProvider, dependencies: CheckoutDependencies())
    }

    /// `notificationCenter` delivers the app lifecycle notifications; tests post to their own.
    package init(
        configuration: SimPayConfiguration,
        sessionProvider: any SimPaySessionProvider,
        dependencies: CheckoutDependencies,
        notificationCenter: NotificationCenter = .default
    ) {
        self.configuration = configuration
        self.sessionProvider = sessionProvider
        self.dependencies = dependencies
        self.notificationCenter = notificationCenter
    }

    /// Whether this instance is showing the payment sheet.
    public var isPresenting: Bool { presentation != nil }

    /// Shows the payment sheet and returns its result when the sheet is gone.
    ///
    /// Cancelling the calling task does not close the sheet: a payment may be in progress,
    /// so the result is still awaited.
    ///
    /// - Parameters:
    ///   - viewController: a controller in a window; the sheet is presented from the
    ///     topmost controller above it.
    ///   - onTransactionCreated: called as soon as a transaction id is known. Store it to
    ///     check the status later (``transactionStatus(of:)``) if the app is terminated.
    public func present(
        _ order: SimPayOrder,
        from viewController: UIViewController,
        onTransactionCreated: (@MainActor @Sendable (TransactionID) -> Void)? = nil
    ) async -> SimPayCheckoutResult {
        await withCheckedContinuation { continuation in
            present(order, from: viewController, onTransactionCreated: onTransactionCreated) { result in
                continuation.resume(returning: result)
            }
        }
    }

    /// Completion based variant, for UIKit code and cross-platform bridges. `completion`
    /// is called exactly once, on the main actor.
    public func present(
        _ order: SimPayOrder,
        from viewController: UIViewController,
        onTransactionCreated: (@MainActor @Sendable (TransactionID) -> Void)? = nil,
        completion: @escaping @MainActor (SimPayCheckoutResult) -> Void
    ) {
        guard presentation == nil, !Self.isSheetPresented else {
            completion(.failed(SimPayCheckoutError(.alreadyPresented, message: "A payment sheet is already presented"), transactionID: nil, status: nil))
            return
        }
        let presenter = dependencies.presenter
        guard let host = presenter.presentationHost(from: viewController) else {
            completion(.failed(
                SimPayCheckoutError(.presentationFailed, message: "The view controller is not in a window or is being dismissed"),
                transactionID: nil,
                status: nil
            ))
            return
        }

        let sessions = SessionStore(provider: sessionProvider, clock: dependencies.clock)
        let engine = CheckoutEngine(
            api: AuthorizedAPIClient(
                client: SimPayAPIClient(environment: configuration.environment, transport: dependencies.transport),
                sessions: sessions
            ),
            order: order,
            userAgent: DeviceUserAgent.current(),
            pollingClock: dependencies.clock,
            onTransactionCreated: onTransactionCreated
        )
        let model = PaymentSheetModel(
            engine: engine,
            order: order,
            merchantName: configuration.merchantDisplayName
        )
        let controller = PaymentSheetController(model: model, strings: dependencies.strings, browser: dependencies.makeBrowser())
        let lifecycle = AppLifecycleObserver(center: notificationCenter) { [weak model] event in
            model?.handle(event)
        }

        let presentation = Presentation(controller: controller, lifecycle: lifecycle, sessions: sessions, completion: completion)
        self.presentation = presentation
        Self.isSheetPresented = true
        Self.activeCheckout = self

        // Strong `self`: the checkout stays alive while its sheet is shown, even when the
        // caller keeps no reference (completion API, bridges). The cycle ends with the sheet.
        model.onFinish = { [weak presentation] result in
            guard let presentation else { return }
            self.end(presentation, with: result)
        }
        guard presenter.present(controller, from: host) else {
            lifecycle.stop()
            self.presentation = nil
            Self.isSheetPresented = false
            Self.activeCheckout = nil
            completion(.failed(
                SimPayCheckoutError(.presentationFailed, message: "UIKit refused to present the payment sheet"),
                transactionID: nil,
                status: nil
            ))
            return
        }
        model.start()
    }

    /// Reads the current status of a transaction, for example one reported through
    /// `onTransactionCreated` before the app was terminated. One request, no polling.
    public func transactionStatus(of transactionID: TransactionID) async throws -> SimPayCheckoutResult {
        let checker = SimPayTransactionStatusChecker(api: AuthorizedAPIClient(
            client: SimPayAPIClient(environment: configuration.environment, transport: dependencies.transport),
            sessions: SessionStore(provider: sessionProvider, clock: dependencies.clock)
        ))
        return try await checker.status(of: transactionID)
    }

    // MARK: Returning from the payment page

    /// Passes a URL opened in the app (custom URL scheme or Universal Link) to the
    /// checkout shown by this instance.
    ///
    /// Returns `true` when the URL is a return URL of the current order
    /// (``SimPayOrder/returnURLs``, compared by scheme, host, port and path). The payment
    /// page is then closed and the transaction status is read from the API. The URL's
    /// parameters are never trusted: a return is never a payment confirmation. Returns
    /// `false` for unrelated URLs and when no checkout is shown, so the app can handle
    /// them itself. Calling it again for the same return only reads the status again.
    @discardableResult
    public func handleReturnURL(_ url: URL) -> Bool {
        presentation?.controller.model.handleReturnURL(url) ?? false
    }

    /// Same as the instance method, for the checkout currently shown anywhere in the app.
    /// Convenient in `onOpenURL`, `scene(_:openURLContexts:)` and
    /// `application(_:open:options:)`.
    @discardableResult
    public static func handleReturnURL(_ url: URL) -> Bool {
        activeCheckout?.handleReturnURL(url) ?? false
    }

    /// Universal Link variant: accepts the `NSUserActivityTypeBrowsingWeb` activity from
    /// `onContinueUserActivity`, `scene(_:continue:)` or
    /// `application(_:continue:restorationHandler:)`.
    @discardableResult
    public static func handleUserActivity(_ userActivity: NSUserActivity) -> Bool {
        guard userActivity.activityType == NSUserActivityTypeBrowsingWeb, let url = userActivity.webpageURL else {
            return false
        }
        return handleReturnURL(url)
    }

    // MARK: Ending

    private func end(_ presentation: Presentation, with result: SimPayCheckoutResult) {
        presentation.lifecycle.stop()
        dependencies.presenter.dismiss(presentation.controller) {
            self.deliver(result, for: presentation)
        }
    }

    private func deliver(_ result: SimPayCheckoutResult, for presentation: Presentation) {
        guard !presentation.isDelivered else { return }
        presentation.isDelivered = true
        if self.presentation === presentation {
            self.presentation = nil
            Self.isSheetPresented = false
            if Self.activeCheckout === self { Self.activeCheckout = nil }
        }
        let sessions = presentation.sessions
        Task { await sessions.clear() }
        presentation.completion(result)
    }

    /// Everything that belongs to one `present` call.
    private final class Presentation {
        let controller: PaymentSheetController
        let lifecycle: AppLifecycleObserver
        let sessions: SessionStore
        let completion: @MainActor (SimPayCheckoutResult) -> Void
        var isDelivered = false

        init(controller: PaymentSheetController, lifecycle: AppLifecycleObserver, sessions: SessionStore, completion: @escaping @MainActor (SimPayCheckoutResult) -> Void) {
            self.controller = controller
            self.lifecycle = lifecycle
            self.sessions = sessions
            self.completion = completion
        }
    }
}

/// Replaceable collaborators of ``SimPayCheckout``. Production values by default; tests
/// replace the transport, clock and presenter so no real payment or window is involved.
@MainActor
package struct CheckoutDependencies {
    package var transport: any HTTPTransport = URLSessionTransport()
    package var clock: SDKClock = .system
    package var presenter: any SheetPresenter = UIKitSheetPresenter()
    package var strings: SheetStrings = .system
    package var makeBrowser: @MainActor () -> any PaymentPageBrowser = { SafariPaymentPageBrowser() }

    package init() {}
}
#endif
