import Foundation

/// Timing of status polling. Defaults mirror `PollingConfig` of the Android SDK.
///
/// After every read that does not end the flow the interval doubles, up to
/// `maximumInterval` (2 s, 4 s, 5 s, 5 s, ...).
///
/// Budget policy: `budget` is the time spent polling while the app is in the foreground.
/// Time in the background (for example while the payer confirms in the banking app) is
/// not counted, because iOS suspends the app and no status can be read anyway. The budget
/// is never reset by a pause, a resume or a return from the bank.
package struct PollingPolicy: Sendable, Hashable {

    package let initialInterval: Duration
    package let maximumInterval: Duration
    package let budget: Duration

    package init(
        initialInterval: Duration = .seconds(2),
        maximumInterval: Duration = .seconds(5),
        budget: Duration = .seconds(120)
    ) {
        self.initialInterval = max(initialInterval, .milliseconds(1))
        self.maximumInterval = max(maximumInterval, self.initialInterval)
        self.budget = max(budget, .zero)
    }

    package static let `default` = PollingPolicy()

    package func interval(after current: Duration) -> Duration {
        min(current * 2, maximumInterval)
    }
}

/// Polls the status of one transaction until it is final, the budget runs out, or the
/// status cannot be read any more.
///
/// Guarantees:
/// - One run at a time and never two status requests in flight: a new run waits for the
///   previous one to end.
/// - The first read of every run happens immediately.
/// - Read failures that may be temporary (no connection, timeout, 429, 5xx, unusable
///   body) never end polling and never mean the payment failed. `Retry-After` is honoured.
/// - Answers from a paused or stopped run are discarded, so a late response can never
///   overwrite a newer state.
/// - Session refresh after HTTP 401 is done by ``AuthorizedAPIClient``; the poller has no
///   authorization logic of its own.
@MainActor
package final class StatusPoller {

    package enum Outcome: Sendable, Hashable {
        /// The API reported a status that ends the flow.
        case resolved(SimPayCheckoutResult)
        /// The budget ran out before a final status was read.
        case budgetExhausted(lastStatus: TransactionStatus?)
        /// The status cannot be read any more (for example the token was refused after a
        /// refresh, or the transaction is unknown to the API). Says nothing about payment.
        case statusUnavailable(SimPayCheckoutError, lastStatus: TransactionStatus?)
    }

    package enum Phase: Sendable, Hashable {
        case idle, running, paused, finished
    }

    package typealias StatusReader = @Sendable (TransactionID) async throws -> TransactionSnapshot

    /// Consecutive session failures after which polling stops. The provider usually calls
    /// the merchant backend, which is rate limited; it must not be called without bound.
    package static let maximumSessionFailures = 3

    package let transactionID: TransactionID
    package private(set) var phase: Phase = .idle
    package private(set) var lastStatus: TransactionStatus?
    /// Budget left, excluding the run in progress.
    package private(set) var remainingBudget: Duration

    private let policy: PollingPolicy
    private let clock: SDKClock
    private let read: StatusReader
    private let onStatus: @MainActor (TransactionStatus) -> Void
    private let onOutcome: @MainActor (Outcome) -> Void

    private var runStartedAt: Duration?
    private var interval: Duration
    private var generation: UInt64 = 0
    private var runTask: Task<Void, Never>?
    private var sleepTask: Task<Void, any Error>?
    /// The current sleep was requested by the server (`Retry-After`) and is not shortened.
    private var sleepIsMandatory = false
    private var wakeRequested = false
    private var sessionFailures = 0
    /// Callers waiting for a read that has not started yet.
    private var queuedWaiters: [CheckedContinuation<Bool, Never>] = []
    /// Callers waiting for the read in flight.
    private var readWaiters: [CheckedContinuation<Bool, Never>] = []

    /// - Parameters:
    ///   - onStatus: a non-final status was read.
    ///   - onOutcome: polling ended on its own; called at most once, never after `stop()`.
    package init(
        transactionID: TransactionID,
        policy: PollingPolicy = .default,
        clock: SDKClock = .system,
        read: @escaping StatusReader,
        onStatus: @escaping @MainActor (TransactionStatus) -> Void,
        onOutcome: @escaping @MainActor (Outcome) -> Void
    ) {
        self.transactionID = transactionID
        self.policy = policy
        self.clock = clock
        self.read = read
        self.onStatus = onStatus
        self.onOutcome = onOutcome
        self.remainingBudget = policy.budget
        self.interval = policy.initialInterval
    }

    // MARK: Control

    /// Starts, or resumes after a pause, with an immediate read. Ignored while running or
    /// after the end.
    @discardableResult
    package func start() -> Bool {
        switch phase {
        case .idle, .paused:
            beginRun()
            return true
        case .running, .finished:
            return false
        }
    }

    /// Stops reading and keeps the remaining budget, for example when the app goes to the
    /// background. A read in flight is cancelled and its answer discarded.
    package func pause() {
        guard phase == .running else { return }
        remainingBudget = budgetLeft()
        phase = .paused
        endRun()
    }

    /// Ends polling for good without reporting an outcome.
    package func stop() {
        guard phase != .finished else { return }
        if phase == .running { remainingBudget = budgetLeft() }
        phase = .finished
        endRun()
    }

    /// Asks for a read as soon as possible, for example after a return from the bank.
    /// A delay requested by the server is still respected.
    package func wake() {
        guard phase == .running else { return }
        wakeRequested = true
        if !sleepIsMandatory { sleepTask?.cancel() }
    }

    /// Reads now and waits for a read that starts after this call. Concurrent callers
    /// share one request. Returns whether a status was read.
    package func checkNow() async -> Bool {
        switch phase {
        case .finished:
            return false
        case .idle, .paused:
            beginRun()
        case .running:
            if !sleepIsMandatory { sleepTask?.cancel() }
        }
        return await withCheckedContinuation { queuedWaiters.append($0) }
    }

    // MARK: Run loop

    private func beginRun() {
        generation &+= 1
        let run = generation
        let previous = runTask
        phase = .running
        runStartedAt = clock.uptime()
        interval = policy.initialInterval
        runTask = Task { [weak self] in
            // Never two requests in flight: a cancelled read may still be finishing.
            await previous?.value
            await self?.loop(run)
        }
    }

    private func endRun() {
        generation &+= 1
        runStartedAt = nil
        runTask?.cancel()
        sleepTask?.cancel()
        resolveWaiters(&readWaiters, false)
        resolveWaiters(&queuedWaiters, false)
    }

    private func isCurrent(_ run: UInt64) -> Bool {
        generation == run && phase == .running && !Task.isCancelled
    }

    private func loop(_ run: UInt64) async {
        while isCurrent(run) {
            readWaiters.append(contentsOf: queuedWaiters)
            queuedWaiters.removeAll()
            wakeRequested = false

            let outcome: Result<TransactionSnapshot, any Error>
            do {
                outcome = .success(try await read(transactionID))
            } catch {
                outcome = .failure(error)
            }
            // Paused or stopped meanwhile: this answer belongs to an abandoned run.
            guard isCurrent(run) else { return }

            var serverDelay: Duration?
            switch outcome {
            case .success(let snapshot):
                lastStatus = snapshot.status
                sessionFailures = 0
                if let result = snapshot.status.finalResult(for: transactionID) {
                    resolveWaiters(&readWaiters, true)
                    finish(.resolved(result))
                    return
                }
                onStatus(snapshot.status)
                resolveWaiters(&readWaiters, true)

            case .failure(let error):
                let failure = readFailure(error)
                resolveWaiters(&readWaiters, false)
                if let final = finalFailure(failure) {
                    finish(.statusUnavailable(final, lastStatus: lastStatus))
                    return
                }
                serverDelay = failure.retryAfter
            }

            let left = budgetLeft()
            if left <= .zero {
                finish(.budgetExhausted(lastStatus: lastStatus))
                return
            }
            if let serverDelay, serverDelay >= left {
                // The server asks to wait past the budget; no further read is allowed.
                finish(.budgetExhausted(lastStatus: lastStatus))
                return
            }

            let delay = max(interval, serverDelay ?? .zero)
            interval = policy.interval(after: interval)
            if serverDelay == nil, wakeRequested || !queuedWaiters.isEmpty {
                continue
            }

            // The last sleep ends exactly at the budget, followed by one final read.
            let clock = self.clock
            let pauseFor = min(delay, left)
            let sleeper = Task { try await clock.sleep(pauseFor) }
            sleepTask = sleeper
            sleepIsMandatory = serverDelay != nil
            _ = await sleeper.result
            if generation == run {
                sleepTask = nil
                sleepIsMandatory = false
            }
        }
    }

    /// Returns the error that ends polling, or `nil` when the failure may be temporary.
    private func finalFailure(_ failure: APIFailure) -> SimPayCheckoutError? {
        if failure.isSessionFailure {
            sessionFailures += 1
            return sessionFailures >= Self.maximumSessionFailures ? failure.error : nil
        }
        sessionFailures = 0
        switch failure.kind {
        case .transient, .notDelivered:
            return nil
        case .rejected, .outcomeUnknown:
            // 401 after a session refresh, 403, 404: repeating cannot help.
            return failure.error
        }
    }

    private func finish(_ outcome: Outcome) {
        phase = .finished
        remainingBudget = budgetLeft()
        endRun()
        onOutcome(outcome)
    }

    private func budgetLeft() -> Duration {
        guard let runStartedAt else { return remainingBudget }
        return max(.zero, remainingBudget - (clock.uptime() - runStartedAt))
    }

    private func resolveWaiters(_ waiters: inout [CheckedContinuation<Bool, Never>], _ value: Bool) {
        let resolved = waiters
        waiters.removeAll()
        for waiter in resolved { waiter.resume(returning: value) }
    }

    private func readFailure(_ error: any Error) -> APIFailure {
        if let failure = error as? APIFailure { return failure }
        // Unexpected error type from a read: harmless, treated as temporary.
        return APIFailure(
            .internal,
            kind: .transient,
            endpoint: .transactionStatus(transactionID),
            message: "Status read failed (\(type(of: error)))"
        )
    }
}
