import Foundation
@testable import SimPayCheckoutCore

/// Monotonic test clock. Sleeps suspend until the test moves time past their deadline,
/// so polling tests never wait for real time.
final class TestClock: @unchecked Sendable {

    private struct Sleeper {
        let deadline: Duration
        let continuation: CheckedContinuation<Void, any Error>
    }

    private let lock = NSLock()
    private var elapsed: Duration = .zero
    private var sleepers: [UUID: Sleeper] = [:]
    private var cancelledEarly: Set<UUID> = []
    private var requested: [Duration] = []

    var now: Duration { lock.withLock { elapsed } }
    /// Sleeps currently suspended.
    var pendingSleeps: Int { lock.withLock { sleepers.count } }
    /// Every requested sleep duration, in order.
    var sleepRequests: [Duration] { lock.withLock { requested } }

    var pollingClock: SDKClock {
        SDKClock(wallNow: { Date() }, uptime: { self.now }, sleep: { try await self.sleep($0) })
    }

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                enum Action { case wait, resume, cancel }
                let action = lock.withLock { () -> Action in
                    requested.append(duration)
                    if cancelledEarly.remove(id) != nil { return .cancel }
                    if duration <= .zero { return .resume }
                    sleepers[id] = Sleeper(deadline: elapsed + duration, continuation: continuation)
                    return .wait
                }
                switch action {
                case .wait: break
                case .resume: continuation.resume()
                case .cancel: continuation.resume(throwing: CancellationError())
                }
            }
        } onCancel: {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, any Error>? in
                if let sleeper = sleepers.removeValue(forKey: id) { return sleeper.continuation }
                cancelledEarly.insert(id)
                return nil
            }
            continuation?.resume(throwing: CancellationError())
        }
    }

    /// Lets time pass and wakes every sleep whose deadline is reached.
    func advance(by duration: Duration) {
        let due = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            elapsed += duration
            let reached = sleepers.filter { $0.value.deadline <= elapsed }
            reached.keys.forEach { sleepers.removeValue(forKey: $0) }
            return reached.values.map(\.continuation)
        }
        due.forEach { $0.resume() }
    }

    /// Moves time to the earliest pending deadline, if any.
    @discardableResult
    func advanceToNextDeadline() -> Duration? {
        let step = lock.withLock { sleepers.values.map(\.deadline).min().map { $0 - elapsed } }
        if let step { advance(by: step) }
        return step
    }
}

/// Scripted status reads for `StatusPoller` unit tests.
final class StatusReaderStub: @unchecked Sendable {

    enum Step: Sendable {
        case status(String)
        case failure(APIFailure)
    }

    private let lock = NSLock()
    private var steps: [Step] = []
    private var gate: Gate?
    private var count = 0
    private var inFlight = 0
    private var peak = 0

    /// Queues answers; the last one repeats.
    func script(_ steps: Step...) { lock.withLock { self.steps = steps } }
    /// Every read waits until the gate opens, ignoring cancellation like a slow network.
    func hold(with gate: Gate?) { lock.withLock { self.gate = gate } }

    var calls: Int { lock.withLock { count } }
    var readsInFlight: Int { lock.withLock { inFlight } }
    var maximumConcurrentReads: Int { lock.withLock { peak } }

    func read(_ transactionID: TransactionID) async throws -> TransactionSnapshot {
        let (step, gate) = lock.withLock { () -> (Step?, Gate?) in
            count += 1
            inFlight += 1
            peak = max(peak, inFlight)
            let next = steps.count > 1 ? steps.removeFirst() : steps.first
            return (next, self.gate)
        }
        defer { lock.withLock { inFlight -= 1 } }
        if let gate { await gate.wait() }

        switch step {
        case .status(let raw): return TransactionSnapshot(transactionID: transactionID, status: TransactionStatus(rawValue: raw))
        case .failure(let failure): throw failure
        case nil: throw Polling.failure(.noInternet, .notDelivered)
        }
    }
}

enum Polling {
    /// Short budget so budget tests need few steps: reads at 0, 2, 6 and 10 seconds.
    static let shortPolicy = PollingPolicy(budget: .seconds(10))

    static func failure(
        _ code: SimPayCheckoutError.Code,
        _ kind: FailureKind,
        http: Int? = nil,
        retryAfter: Duration? = nil,
        session: Bool = false
    ) -> APIFailure {
        APIFailure(code, kind: kind, endpoint: .transactionStatus(Sample.transactionID), httpStatus: http, retryAfter: retryAfter, isSessionFailure: session)
    }

    static let offline = failure(.noInternet, .notDelivered)
    static let timeout = failure(.timeout, .transient)
    static let serverError = failure(.serviceUnavailable, .transient, http: 503)
    static let unreadable = failure(.invalidResponse, .transient, http: 200)
    static let unauthorized = failure(.unauthorized, .rejected, http: 401)
    static let notFound = failure(.transactionNotFound, .rejected, http: 404)
    static let sessionFailed = failure(.sessionFailed, .notDelivered, session: true)
    /// The provider threw its own code; still a session failure.
    static let providerOffline = failure(.noInternet, .notDelivered, session: true)

    static func rateLimited(retryAfter: Duration?) -> APIFailure {
        failure(.rateLimited, .transient, http: 429, retryAfter: retryAfter)
    }
}

/// A poller wired to a scripted reader and a test clock, recording its callbacks.
@MainActor
final class PollerHarness {
    let clock = TestClock()
    let reader = StatusReaderStub()
    let statuses = Box<[TransactionStatus]>([])
    let outcomes = Box<[StatusPoller.Outcome]>([])
    let poller: StatusPoller

    init(policy: PollingPolicy = .default) {
        let reader = self.reader
        let statuses = self.statuses
        let outcomes = self.outcomes
        poller = StatusPoller(
            transactionID: Sample.transactionID,
            policy: policy,
            clock: clock.pollingClock,
            read: { id in try await reader.read(id) },
            onStatus: { statuses.value.append($0) },
            onOutcome: { outcomes.value.append($0) }
        )
    }

    /// Waits until the poller sleeps or has ended.
    func settle() async -> Bool {
        await eventually { clock.pendingSleeps > 0 || poller.phase != .running }
    }

    /// Lets the poller run, skipping every sleep, until it ends.
    func runToEnd(maximumSteps: Int = 200) async {
        for _ in 0..<maximumSteps {
            guard await settle(), poller.phase == .running else { return }
            clock.advanceToNextDeadline()
            _ = await eventually { clock.pendingSleeps == 0 }
        }
    }
}
