import Combine
import Foundation

/// State holder of the payment sheet. Presents ``CheckoutEngine`` and forwards actions.
///
/// It contains no payment rules. The engine decides which actions are allowed; this model
/// only adds what belongs to the interface:
/// - the BLIK digits being typed, kept in memory only and cleared as soon as they are
///   submitted, never logged or stored;
/// - the dismissal lock while a mutating request is in flight;
/// - the payment page browser: when to open it, at most once at a time, and what its
///   closing or a return URL means (only "read the status now");
/// - delivering the result exactly once through `onFinish`.
@MainActor
package final class PaymentSheetModel: ObservableObject {

    /// The payment page browser as the model wants it. The platform layer follows it:
    /// it opens the page for `.requested` and closes a page that is shown for `.closed`.
    package enum Browser: Sendable, Hashable {
        case closed
        /// Open `url`. `attempt` changes on every request, so the same URL can be opened
        /// again on purpose, while re-rendering never opens it twice.
        case requested(URL, attempt: Int)
        case open
    }

    @Published package private(set) var screen: PaymentSheetScreen = .loadingChannels
    /// Digits typed into the BLIK field: ASCII digits only, at most six.
    @Published package private(set) var blikCode = ""
    /// `true` while the sheet must not be dismissed: a mutating request is in flight, or
    /// a close is waiting for one to settle.
    @Published package private(set) var isDismissLocked = false
    @Published package private(set) var browser: Browser = .closed

    package let merchantName: String
    package let amount: Decimal
    package let currency: String

    /// Called once with the final result. Set by the presenting layer.
    package var onFinish: (@MainActor (SimPayCheckoutResult) -> Void)?

    private let engine: CheckoutEngine
    private let returnMatcher: ReturnURLMatcher
    private var observation: Task<Void, Never>?
    private var isClosing = false
    private var isFinished = false
    /// Payment page of the active transaction; kept so the payer can open it again.
    private var paymentPage: URL?
    private var browserAttempts = 0

    package init(engine: CheckoutEngine, order: SimPayOrder, merchantName: String) {
        self.engine = engine
        self.merchantName = merchantName
        self.amount = order.amount
        self.currency = order.currency
        self.returnMatcher = ReturnURLMatcher(returnURLs: order.returnURLs)
    }

    /// Starts observing the engine and loads the channels. Calling it again does nothing.
    package func start() {
        guard observation == nil, !isFinished else { return }
        let stream = engine.stateUpdates()
        observation = Task { [weak self] in
            for await state in stream {
                self?.apply(state)
            }
        }
        let engine = self.engine
        Task { await engine.loadChannels() }
    }

    /// Whether the payer can open the payment page again (after closing the browser).
    package var canReopenPaymentPage: Bool {
        guard !isFinished, !isClosing, paymentPage != nil, browser == .closed else { return false }
        switch screen {
        case .redirecting, .progress(.checkingStatus): return true
        default: return false
        }
    }

    // MARK: Actions

    /// Selects a channel. Ignored for rows that cannot be used; repeated taps are ignored
    /// by the engine.
    package func selectChannel(id: String) {
        guard !isClosing, case .channels(let list) = screen else { return }
        let rows = [list.blik].compactMap { $0 } + list.others
        guard let row = rows.first(where: { $0.id == id }), row.isSelectable else { return }
        let engine = self.engine
        Task { await engine.selectChannel(id: id) }
    }

    /// Keeps only ASCII digits, at most six.
    package func updateBlikCode(_ input: String) {
        let digits = input.unicodeScalars.filter { $0.isASCII && CharacterSet.decimalDigits.contains($0) }
        let sanitized = String(String.UnicodeScalarView(digits.prefix(6)))
        if sanitized != blikCode { blikCode = sanitized }
    }

    package var canSubmitBlikCode: Bool {
        guard !isClosing, case .blikEntry = screen else { return false }
        return blikCode.count == 6
    }

    /// Sends the typed code once. The field is cleared at once, so a second tap has
    /// nothing to send and the code does not stay in the interface.
    package func submitBlikCode() {
        guard canSubmitBlikCode else { return }
        let code = blikCode
        blikCode = ""
        let engine = self.engine
        Task { await engine.submitBlikCode(code) }
    }

    /// Back to the channel list; allowed by the engine only while no transaction is active.
    package func changePaymentMethod() {
        guard !isClosing else { return }
        let engine = self.engine
        Task { await engine.backToChannels() }
    }

    /// Retries after a failure that happened before any transaction existed.
    package func retry() {
        guard !isClosing, case .failure(_, canRetry: true) = screen else { return }
        let engine = self.engine
        Task { await engine.backToChannels() }
    }

    /// Opens the payment page of the existing transaction again. Never creates anything.
    package func reopenPaymentPage() {
        guard canReopenPaymentPage, let paymentPage else { return }
        requestBrowser(paymentPage)
    }

    /// Close button, cancel button or "Done". Refused while a mutating request is in
    /// flight. Returns whether the close was accepted.
    @discardableResult
    package func close() -> Bool {
        guard !isFinished, !isClosing else { return false }
        if case .result(let result) = screen {
            finish(result)
            return true
        }
        guard !screen.locksDismissal else { return false }
        settleAndFinish()
        return true
    }

    /// The sheet disappeared without the model asking for it: a swipe, or the host app
    /// dismissed it programmatically, possibly during a mutating request. The engine waits
    /// for that request and reports its real outcome; nothing is cancelled blindly.
    package func sheetWasDismissed() {
        guard !isFinished, !isClosing else { return }
        if case .result(let result) = screen {
            finish(result)
            return
        }
        settleAndFinish()
    }

    /// Shows a screen without driving the engine. For snapshot tests and previews only;
    /// it never starts a request and is not reachable from the public API.
    package func showForPreview(_ screen: PaymentSheetScreen, blikCode: String = "", paymentPage: URL? = nil) {
        self.screen = screen
        self.blikCode = blikCode
        self.paymentPage = paymentPage
        refreshLock()
    }

    package func handle(_ event: AppLifecycleEvent) {
        guard !isFinished else { return }
        engine.handle(event)
    }

    // MARK: Payment page

    /// The platform layer shows the page requested by `browser`.
    package func browserDidOpen() {
        guard case .requested = browser else { return }
        browser = .open
    }

    /// The page could not be shown. The transaction exists, so its status is checked;
    /// the payer can try to open the page again.
    package func browserFailedToOpen() {
        guard case .requested = browser else { return }
        browser = .closed
        engine.handle(.returnedFromRedirect)
    }

    /// The payer closed the browser. Says nothing about the payment: read the status.
    package func browserDidClose() {
        guard browser != .closed else { return }
        browser = .closed
        guard !isFinished else { return }
        engine.handle(.returnedFromRedirect)
    }

    /// A URL opened in the app (URL scheme or Universal Link). Returns `true` when it is
    /// a return URL of this checkout while its transaction exists; it then closes the
    /// browser and reads the status. Query parameters are never trusted. Repeated calls
    /// only read the status again.
    package func handleReturnURL(_ url: URL) -> Bool {
        guard !isFinished, engine.activeTransactionID != nil, returnMatcher.matches(url) else { return false }
        if browser != .closed { browser = .closed }
        engine.handle(.returnedFromRedirect)
        return true
    }

    // MARK: State

    private func apply(_ state: CheckoutState) {
        let next = PaymentSheetScreen(state)
        if case .blikEntry = next, case .blikEntry = screen {} else if case .blikEntry = next {
            // A fresh entry (first one, or after a rejection) always starts empty.
            blikCode = ""
        }
        if case .redirecting(_, let url) = state, paymentPage == nil {
            openPaymentPage(url)
        }
        if case .result = next, browser != .closed {
            // The API reported a final status: the page is no longer needed.
            browser = .closed
        }
        if next != screen { screen = next }
        refreshLock()
    }

    /// First opening of the payment page of a new transaction.
    private func openPaymentPage(_ url: URL) {
        guard RedirectURLPolicy.isAllowed(url) else {
            // Never hand an unsafe URL to a browser. The transaction exists: verify it.
            engine.handle(.returnedFromRedirect)
            return
        }
        paymentPage = url
        requestBrowser(url)
    }

    private func requestBrowser(_ url: URL) {
        guard browser == .closed else { return }
        browserAttempts += 1
        browser = .requested(url, attempt: browserAttempts)
    }

    private func settleAndFinish() {
        isClosing = true
        refreshLock()
        let engine = self.engine
        Task { [weak self] in
            let result = await engine.close()
            self?.finish(result)
        }
    }

    private func finish(_ result: SimPayCheckoutResult) {
        guard !isFinished else { return }
        isFinished = true
        blikCode = ""
        if browser != .closed { browser = .closed }
        observation?.cancel()
        observation = nil
        refreshLock()
        onFinish?(result)
        onFinish = nil
    }

    private func refreshLock() {
        let locked = !isFinished && (screen.locksDismissal || isClosing)
        if locked != isDismissLocked { isDismissLocked = locked }
    }
}
