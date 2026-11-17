import Foundation

/// The checkout flow, independent of any UI.
///
/// Responsibilities: loading channels, creating at most one active transaction, BLIK
/// Level 0 submission, status polling, reacting to app lifecycle events, and producing
/// exactly one ``SimPayCheckoutResult``. Opening the payment page is left to the platform
/// layer, which reports the payer's return through ``handle(_:)``.
///
/// Polling starts automatically once a transaction id is known and the transaction needs
/// confirmation: after the bank accepted a BLIK code, after an unclear BLIK submission,
/// after a transaction without a usable redirect, and when the payer returns from the
/// payment page. It pauses in the background and resumes in the foreground with the
/// budget that was left (see ``PollingPolicy``).
///
/// Rules that protect money:
/// - A transaction is created only from the channel list or the BLIK entry, never while
///   another mutating request runs, and never while a transaction is active.
/// - A new transaction after a BLIK code is allowed only when the previous one was
///   explicitly rejected (HTTP 400, 409 or 422 on the BLIK endpoint).
/// - An unclear create outcome ends the checkout with `.outcomeUnknown`; nothing is
///   repeated and no transaction id is guessed.
/// - Mutating requests run in engine-owned tasks: closing the checkout or cancelling the
///   caller never abandons them; `close()` waits for them and settles their outcome.
/// - Only a status read from the API can produce `.succeeded`.
@MainActor
package final class CheckoutEngine {

    // MARK: Observable state

    package private(set) var state: CheckoutState = .idle {
        didSet { broadcast(state) }
    }

    /// Set once, when the checkout ends.
    package private(set) var result: SimPayCheckoutResult?

    /// The transaction the checkout is working on.
    package private(set) var activeTransactionID: TransactionID?

    /// The last transaction closed by an explicit BLIK rejection.
    package private(set) var lastRejectedTransactionID: TransactionID?

    package private(set) var blikRejections = 0

    /// Last status read from the API for the active transaction.
    package private(set) var lastStatus: TransactionStatus?

    // MARK: Dependencies

    private let api: AuthorizedAPIClient
    private let order: SimPayOrder
    private let userAgent: String
    private let maximumBlikRejections: Int
    private let pollingPolicy: PollingPolicy
    private let pollingClock: SDKClock
    private let onTransactionCreated: (@MainActor @Sendable (TransactionID) -> Void)?

    // MARK: Flow bookkeeping

    private var channels: [ChannelOption] = []
    private var selectedChannel: ChannelOption?
    private var mutation: Task<Void, Never>?
    private var cancelRead: (() -> Void)?
    private var closeRequested = false
    private var observers: [UUID: AsyncStream<CheckoutState>.Continuation] = [:]

    /// The single status poller of the active transaction.
    private var poller: StatusPoller?
    private var isInBackground = false
    /// The payment page was handed to the payer and they have not come back from it yet.
    private var isPaymentPageOpen = false
    /// The app went to the background while the payment page was open, so the payer
    /// may have paid outside the app.
    private var leftDuringRedirect = false

    /// - Parameters:
    ///   - userAgent: sent as `antifraud.useragent`; supplied by the platform layer.
    ///   - pollingPolicy: intervals and budget of status polling.
    ///   - pollingClock: time source of polling; injected by tests.
    ///   - onTransactionCreated: called as soon as a transaction id is known, so the app
    ///     or backend can track it even if the process is killed later.
    package init(
        api: AuthorizedAPIClient,
        order: SimPayOrder,
        userAgent: String,
        maximumBlikRejections: Int = BlikLevel0.maximumRejections,
        pollingPolicy: PollingPolicy = .default,
        pollingClock: SDKClock = .system,
        onTransactionCreated: (@MainActor @Sendable (TransactionID) -> Void)? = nil
    ) {
        self.api = api
        self.order = order
        self.userAgent = userAgent
        self.maximumBlikRejections = max(1, maximumBlikRejections)
        self.pollingPolicy = pollingPolicy
        self.pollingClock = pollingClock
        self.onTransactionCreated = onTransactionCreated
    }

    /// Whether status polling is currently reading or waiting for its next read.
    package var isPolling: Bool { poller?.phase == .running }

    /// Polling budget left for the active transaction, excluding the run in progress.
    package var remainingPollingBudget: Duration? { poller?.remainingBudget }

    /// Emits the current state immediately, then every change; ends with `.finished`.
    package func stateUpdates() -> AsyncStream<CheckoutState> {
        let (stream, continuation) = AsyncStream<CheckoutState>.makeStream()
        continuation.yield(state)
        if case .finished = state {
            continuation.finish()
            return stream
        }
        let id = UUID()
        observers[id] = continuation
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.observers.removeValue(forKey: id) }
        }
        return stream
    }

    // MARK: Channels

    /// Loads the channel list. Allowed initially and after a failure before any
    /// transaction exists.
    @discardableResult
    package func loadChannels() async -> Bool {
        guard isOpen, mutation == nil, activeTransactionID == nil else { return false }
        switch state {
        case .idle, .failed(_, canRetry: true): break
        default: return false
        }

        state = .loadingChannels
        let api = self.api
        let task = Task { try await api.fetchChannels() }
        cancelRead = { task.cancel() }
        let outcome = await task.result
        cancelRead = nil

        guard isOpen else { return false }
        switch outcome {
        case .success(let list):
            channels = ChannelOption.prepare(list, for: order)
            state = .channels(channels)
            return true
        case .failure(let error):
            state = .failed(Self.checkoutError(error), canRetry: true)
            return false
        }
    }

    /// Returns to the channel list after a failure before any transaction exists, or from
    /// the BLIK entry while no transaction is active.
    @discardableResult
    package func backToChannels() async -> Bool {
        guard isOpen, mutation == nil, activeTransactionID == nil else { return false }
        switch state {
        case .failed(_, canRetry: true), .enteringBlikCode:
            if channels.isEmpty {
                // Only reachable from a failed channel load: load them again.
                return await loadChannels()
            }
            selectedChannel = nil
            state = .channels(channels)
            return true
        default:
            return false
        }
    }

    // MARK: Payment

    /// Selects a channel. BLIK asks for the code first; any other channel creates its
    /// transaction immediately. Repeated or concurrent calls are ignored.
    @discardableResult
    package func selectChannel(id: String) async -> Bool {
        guard canStartTransaction, case .channels = state,
              let option = channels.first(where: { $0.id == id }), option.isAvailable else {
            return false
        }
        selectedChannel = option

        if option.isBlik {
            state = .enteringBlikCode(BlikEntry(transactionID: nil, problem: nil, remainingAttempts: remainingBlikAttempts))
            return true
        }

        state = .creatingTransaction(channelID: option.id)
        await runMutation { engine in await engine.createRedirectTransaction(channelID: option.id) }
        return true
    }

    /// Submits a BLIK code. Creates the transaction first when none is active.
    @discardableResult
    package func submitBlikCode(_ rawCode: String) async -> Bool {
        guard isOpen, mutation == nil, case .enteringBlikCode(let entry) = state, let channel = selectedChannel else {
            return false
        }
        guard let code = BlikCode(rawCode) else {
            state = .enteringBlikCode(BlikEntry(transactionID: entry.transactionID, problem: .invalidFormat, remainingAttempts: entry.remainingAttempts))
            return false
        }

        if let transactionID = activeTransactionID {
            state = .submittingBlikCode(transactionID)
            await runMutation { engine in await engine.sendBlik(code, transactionID: transactionID) }
        } else {
            state = .creatingTransaction(channelID: channel.id)
            await runMutation { engine in await engine.createBlikTransaction(code) }
        }
        return true
    }

    /// Reads the status of the active transaction now, through the single poller, and
    /// waits for that read. Concurrent calls share one request. Returns whether a status
    /// was read. Starts polling if it has not started yet (for example from the payment
    /// page). Success can only come from a status read.
    @discardableResult
    package func checkStatus() async -> Bool {
        guard isOpen, mutation == nil, !isInBackground, let transactionID = activeTransactionID else { return false }
        switch state {
        case .awaitingBankConfirmation, .redirecting, .checkingStatus: break
        default: return false
        }
        if poller == nil {
            trackStatus(of: transactionID)
        }
        guard let poller, poller.transactionID == transactionID else { return false }
        return await poller.checkNow()
    }

    // MARK: Lifecycle

    /// Reacts to an application event reported by the platform layer.
    ///
    /// Never creates a transaction and never treats a return as a payment.
    package func handle(_ event: AppLifecycleEvent) {
        switch event {
        case .didEnterBackground:
            isInBackground = true
            if isPaymentPageOpen { leftDuringRedirect = true }
            // The transaction id stays in memory; no unbounded background work.
            poller?.pause()

        case .willEnterForeground:
            guard isInBackground else { return }
            isInBackground = false
            guard isOpen, let transactionID = activeTransactionID else { return }
            if let poller, poller.transactionID == transactionID {
                // Immediate read, then polling with the budget that was left.
                poller.start()
            } else if isPaymentPageOpen, leftDuringRedirect {
                trackStatus(of: transactionID)
            }

        case .returnedFromRedirect:
            guard isOpen, !isInBackground, let transactionID = activeTransactionID else { return }
            let wasOnPaymentPage = isPaymentPageOpen
            isPaymentPageOpen = false
            if let poller, poller.transactionID == transactionID {
                if !poller.start() { poller.wake() }
            } else if wasOnPaymentPage {
                trackStatus(of: transactionID)
            }
        }
    }

    /// Ends the checkout and returns its result, exactly once.
    ///
    /// A mutating request in flight is awaited first, so its outcome is settled instead
    /// of lost. A mutation still waiting for a session is cancelled: nothing has been sent
    /// yet, and a hung session provider must not block the checkout. An existing
    /// transaction is never reported as `.cancelled`.
    package func close() async -> SimPayCheckoutResult {
        if let result { return result }
        closeRequested = true
        cancelRead?()
        poller?.stop()

        if let mutation {
            // A request already handed to the transport is not affected (see SimPayAPIClient).
            mutation.cancel()
            await mutation.value
        }
        if let result { return result }

        let result = resultForClose()
        finish(result)
        return result
    }

    // MARK: Mutations

    private func createRedirectTransaction(channelID: String) async {
        guard let created = await createTransaction(directChannel: channelID) else { return }

        transactionCreated(created.transactionID)
        if let url = created.redirectURL {
            isPaymentPageOpen = true
            state = .redirecting(created.transactionID, url)
        } else {
            // The transaction exists but cannot be opened; only its status can tell more.
            state = .checkingStatus(created.transactionID, lastStatus: nil)
            trackStatus(of: created.transactionID)
        }
    }

    private func createBlikTransaction(_ code: BlikCode) async {
        guard let created = await createTransaction(directChannel: BlikLevel0.directChannel) else { return }

        let transactionID = created.transactionID
        transactionCreated(transactionID)

        if closeRequested {
            // The payer left while the transaction was being created: never push a code
            // to the banking app after that. The transaction is reported as pending.
            state = .checkingStatus(transactionID, lastStatus: nil)
            return
        }

        state = .submittingBlikCode(transactionID)
        await sendBlik(code, transactionID: transactionID)
    }

    private func sendBlik(_ code: BlikCode, transactionID: TransactionID) async {
        do {
            try await api.submitBlikCode(code, transactionID: transactionID)
            // The bank was asked to confirm; this is not a payment.
            state = .awaitingBankConfirmation(transactionID)
            trackStatus(of: transactionID)
        } catch let failure as APIFailure {
            handleBlikFailure(failure, transactionID: transactionID)
        } catch {
            // Should not happen; never assume the code was refused.
            state = .checkingStatus(transactionID, lastStatus: nil)
            trackStatus(of: transactionID)
        }
    }

    private func handleBlikFailure(_ failure: APIFailure, transactionID: TransactionID) {
        switch (failure.kind, failure.error.code) {
        case (.outcomeUnknown, _):
            // The code may have reached the bank: keep the transaction and verify it.
            state = .checkingStatus(transactionID, lastStatus: nil)
            trackStatus(of: transactionID)

        case (.rejected, .blikRejected):
            // An explicit rejection closes the transaction on the SimPay side, so the next
            // code needs a new one. This is the only place a transaction is abandoned.
            poller?.stop()
            poller = nil
            activeTransactionID = nil
            lastStatus = nil
            lastRejectedTransactionID = transactionID
            blikRejections += 1

            if blikRejections >= maximumBlikRejections {
                finish(.failed(
                    SimPayCheckoutError(.blikRejected, message: "The BLIK code was rejected too many times"),
                    transactionID: transactionID,
                    status: nil
                ))
            } else {
                state = .enteringBlikCode(BlikEntry(transactionID: nil, problem: .codeRejected, remainingAttempts: remainingBlikAttempts))
            }

        case (.rejected, .transactionNotFound):
            finish(.failed(failure.error, transactionID: transactionID, status: nil))

        default:
            // Refused without effect (401, 403, 429, no connection): the transaction is
            // kept and the next code is sent for it; nothing new is created.
            state = .enteringBlikCode(BlikEntry(
                transactionID: transactionID,
                problem: .submissionFailed(failure.error),
                remainingAttempts: remainingBlikAttempts
            ))
        }
    }

    /// Creates the transaction, or settles the failure and returns `nil`.
    private func createTransaction(directChannel: String) async -> CreatedTransaction? {
        do {
            return try await api.createTransaction(order: order, directChannel: directChannel, userAgent: userAgent)
        } catch {
            handleCreateFailure(error)
            return nil
        }
    }

    private func handleCreateFailure(_ error: any Error) {
        if closeRequested, error is CancellationError {
            // Closed while waiting for a session: nothing was sent.
            return
        }
        let checkoutError = Self.checkoutError(error)
        if let failure = error as? APIFailure, failure.kind == .outcomeUnknown {
            // A transaction may exist; its id is unknown and must not be guessed.
            finish(.outcomeUnknown(checkoutError))
            return
        }
        // Provably no transaction: the request was refused or never sent.
        let canRetry = ![.missingPayerIP, .internal].contains(checkoutError.code)
        state = .failed(checkoutError, canRetry: canRetry)
    }

    private func transactionCreated(_ transactionID: TransactionID) {
        activeTransactionID = transactionID
        lastStatus = nil
        onTransactionCreated?(transactionID)
    }

    // MARK: Status polling

    /// Starts verifying the active transaction. At most one poller exists; a poller for a
    /// different transaction is stopped first. In the background the poller is created
    /// but starts only when the app returns to the foreground.
    private func trackStatus(of transactionID: TransactionID) {
        guard isOpen, activeTransactionID == transactionID else { return }
        if let poller, poller.transactionID != transactionID {
            poller.stop()
            self.poller = nil
        }
        if poller == nil {
            let api = self.api
            poller = StatusPoller(
                transactionID: transactionID,
                policy: pollingPolicy,
                clock: pollingClock,
                read: { id in try await api.transactionStatus(id) },
                onStatus: { [weak self] status in self?.pollerRead(status, for: transactionID) },
                onOutcome: { [weak self] outcome in self?.pollerEnded(outcome, for: transactionID) }
            )
        }
        publishChecking(transactionID, lastStatus: lastStatus)
        if !isInBackground { poller?.start() }
    }

    private func pollerRead(_ status: TransactionStatus, for transactionID: TransactionID) {
        // A poller of an abandoned transaction can never change the current state.
        guard isOpen, activeTransactionID == transactionID else { return }
        lastStatus = status
        publishChecking(transactionID, lastStatus: status)
    }

    private func pollerEnded(_ outcome: StatusPoller.Outcome, for transactionID: TransactionID) {
        guard isOpen, activeTransactionID == transactionID else { return }
        switch outcome {
        case .resolved(let result):
            lastStatus = poller?.lastStatus
            finish(result)
        case .budgetExhausted(let last):
            // Still open: never a failure.
            lastStatus = last
            if isPaymentPageOpen {
                // The payer is still on the payment page: never end the checkout under
                // them. The status is read again when they come back.
                poller = nil
                return
            }
            finish(.pending(transactionID: transactionID, status: last, reason: .init(lastStatus: last)))
        case .statusUnavailable(_, let last):
            // The status cannot be read; this says nothing about the payment itself.
            lastStatus = last
            finish(.pending(transactionID: transactionID, status: last, reason: .statusUnavailable))
        }
    }

    /// The BLIK prompt must stay visible while the payer decides in the bank (BLIK
    /// certification); every other waiting state shows status verification.
    private func publishChecking(_ transactionID: TransactionID, lastStatus: TransactionStatus?) {
        if case .awaitingBankConfirmation(transactionID) = state { return }
        let next = CheckoutState.checkingStatus(transactionID, lastStatus: lastStatus)
        if state != next { state = next }
    }

    // MARK: Helpers

    private var isOpen: Bool { result == nil && !closeRequested }

    private var canStartTransaction: Bool {
        isOpen && mutation == nil && activeTransactionID == nil
    }

    private var remainingBlikAttempts: Int {
        max(0, maximumBlikRejections - blikRejections)
    }

    /// Runs a mutating operation in an engine-owned task: cancelling the caller does not
    /// cancel it, and `close()` can wait for it.
    private func runMutation(_ body: @escaping @MainActor @Sendable (CheckoutEngine) async -> Void) async {
        let task = Task { @MainActor in await body(self) }
        mutation = task
        await task.value
        mutation = nil
    }

    private func resultForClose() -> SimPayCheckoutResult {
        if let transactionID = activeTransactionID {
            return .pending(transactionID: transactionID, status: lastStatus, reason: .init(lastStatus: lastStatus))
        }
        if case .failed(let error, _) = state {
            return .failed(error, transactionID: nil, status: nil)
        }
        if let rejected = lastRejectedTransactionID {
            // The last transaction was closed by a rejected code; no payment happened.
            return .failed(
                SimPayCheckoutError(.blikRejected, message: "The payer left after a rejected BLIK code"),
                transactionID: rejected,
                status: nil
            )
        }
        return .cancelled
    }

    private func finish(_ result: SimPayCheckoutResult) {
        guard self.result == nil else { return }
        self.result = result
        cancelRead?()
        poller?.stop()
        state = .finished(result)
        for observer in observers.values { observer.finish() }
        observers.removeAll()
    }

    private func broadcast(_ state: CheckoutState) {
        for observer in observers.values { observer.yield(state) }
    }

    private static func checkoutError(_ error: any Error) -> SimPayCheckoutError {
        switch error {
        case let failure as APIFailure: return failure.error
        case let error as SimPayCheckoutError: return error
        case is CancellationError: return SimPayCheckoutError(.internal, message: "Operation was cancelled")
        default: return SimPayCheckoutError(.internal, message: "Unexpected failure (\(type(of: error)))")
        }
    }
}
