import Foundation

/// A session handed out by ``SessionStore`` together with the generation it belongs to.
///
/// The generation lets the store tell whether an HTTP 401 refers to the current session
/// or to one that has already been replaced, so a late failure can never discard a newer
/// session.
package struct SessionLease: Sendable {
    package let session: SimPaySession
    package let generation: UInt64
}

/// Owns the mobile SDK session of one checkout, in memory only.
///
/// - Single flight: however many callers need a new session at the same time, the
///   provider is called once and every caller receives the same session.
/// - Each waiting caller can be cancelled on its own; the shared fetch keeps running for
///   the others.
/// - Proactive refresh: when `expiresAt` is known, the session is replaced
///   `refreshMargin` before it expires, measured on a monotonic clock.
/// - Failures are never cached: the next caller triggers a new provider call.
/// - Nothing is persisted, logged or exposed; ``clear()`` drops the session.
package actor SessionStore {

    /// Default margin before `expiresAt` at which the session is replaced.
    package static let defaultRefreshMargin: Duration = .seconds(60)

    /// A session is always reused for at least this long, even when its reported expiry
    /// is already past on the device clock (clock skew). This keeps a wrong device clock
    /// from turning every request into a provider call; the API answers 401 if the token
    /// is really expired.
    package static let minimumReuse: Duration = .seconds(10)

    private struct Entry {
        let session: SimPaySession
        let generation: UInt64
        /// Monotonic uptime after which the session must be replaced; `nil` when the
        /// backend reported no expiry (the session is then replaced only after a 401).
        let refreshAt: Duration?
    }

    private let provider: any SimPaySessionProvider
    private let clock: SDKClock
    private let refreshMargin: Duration

    private var current: Entry?
    private var generation: UInt64 = 0
    /// Bumped by `clear()`, so a fetch that started before it is not cached.
    private var epoch: UInt64 = 0

    private var fetchInFlight = false
    private var waiters: [UInt64: CheckedContinuation<SessionLease, any Error>] = [:]
    private var nextWaiterID: UInt64 = 0

    package init(
        provider: any SimPaySessionProvider,
        clock: SDKClock = .system,
        refreshMargin: Duration = SessionStore.defaultRefreshMargin
    ) {
        self.provider = provider
        self.clock = clock
        self.refreshMargin = refreshMargin
    }

    // MARK: Public operations

    /// Returns a session that is not about to expire, fetching one if needed.
    ///
    /// - Throws: `SimPayCheckoutError` (`.sessionFailed` unless the provider threw a
    ///   `SimPayCheckoutError` itself) or `CancellationError`.
    package func validSession() async throws -> SessionLease {
        try Task.checkCancellation()
        if let current, isFresh(current) {
            return SessionLease(session: current.session, generation: current.generation)
        }
        return try await awaitRefresh()
    }

    /// Called after the API answered HTTP 401 to a request made with `lease`.
    ///
    /// If the session has already been replaced since `lease` was issued, the newer one
    /// is returned without another provider call. Otherwise the rejected session is
    /// dropped and a new one is fetched.
    package func sessionReplacing(_ lease: SessionLease) async throws -> SessionLease {
        try Task.checkCancellation()
        if let current, current.generation > lease.generation {
            return SessionLease(session: current.session, generation: current.generation)
        }
        invalidate(lease)
        return try await awaitRefresh()
    }

    /// Drops the session if it is still the one in `lease`. A stale lease is ignored, so
    /// a late 401 can never remove a newer session.
    package func invalidate(_ lease: SessionLease) {
        if current?.generation == lease.generation {
            current = nil
        }
    }

    /// Drops the session, for example when the checkout ends. A fetch already running
    /// still answers its waiters but its result is not kept.
    package func clear() {
        current = nil
        epoch &+= 1
    }

    // MARK: Diagnostics for tests

    package var hasSession: Bool { current != nil }
    package var waitingCallers: Int { waiters.count }

    // MARK: Single-flight refresh

    private func isFresh(_ entry: Entry) -> Bool {
        guard let refreshAt = entry.refreshAt else { return true }
        return clock.uptime() < refreshAt
    }

    private func awaitRefresh() async throws -> SessionLease {
        let id = nextWaiterID
        nextWaiterID &+= 1

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<SessionLease, any Error>) in
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                waiters[id] = continuation
                startFetchIfNeeded()
            }
        } onCancel: {
            Task { await self.cancelWaiter(id) }
        }
    }

    private func cancelWaiter(_ id: UInt64) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func startFetchIfNeeded() {
        guard !fetchInFlight else { return }
        fetchInFlight = true

        let provider = self.provider
        let startedEpoch = epoch
        let receivedAt = clock.uptime
        let wallNow = clock.wallNow

        Task {
            let outcome: Result<(SimPaySession, Duration, Date), SimPayCheckoutError>
            do {
                let session = try await provider.provideSession()
                outcome = .success((session, receivedAt(), wallNow()))
            } catch {
                outcome = .failure(Self.mapProviderError(error))
            }
            self.finishFetch(outcome, startedEpoch: startedEpoch)
        }
    }

    private func finishFetch(_ outcome: Result<(SimPaySession, Duration, Date), SimPayCheckoutError>, startedEpoch: UInt64) {
        fetchInFlight = false
        let pending = waiters
        waiters.removeAll()

        switch outcome {
        case .success(let (session, receivedAt, wallNow)):
            generation &+= 1
            let entry = Entry(
                session: session,
                generation: generation,
                refreshAt: refreshDeadline(for: session, receivedAt: receivedAt, wallNow: wallNow)
            )
            // A single fetch runs at a time, so this is always the newest session; it is
            // only discarded when the store was cleared meanwhile.
            if startedEpoch == epoch {
                current = entry
            }
            let lease = SessionLease(session: session, generation: entry.generation)
            for continuation in pending.values { continuation.resume(returning: lease) }

        case .failure(let error):
            for continuation in pending.values { continuation.resume(throwing: error) }
        }
    }

    /// Converts the wall-clock `expiresAt` into a monotonic deadline once, on arrival.
    private func refreshDeadline(for session: SimPaySession, receivedAt: Duration, wallNow: Date) -> Duration? {
        guard let expiresAt = session.expiresAt else { return nil }
        let remaining = Duration.seconds(expiresAt.timeIntervalSince(wallNow))
        return receivedAt + max(remaining - refreshMargin, Self.minimumReuse)
    }

    /// Provider errors never leak their description: it may contain backend details or
    /// even the token. A `SimPayCheckoutError` is passed through as the integrator chose it.
    private static func mapProviderError(_ error: any Error) -> SimPayCheckoutError {
        if let error = error as? SimPayCheckoutError {
            return error
        }
        if error is CancellationError {
            return SimPayCheckoutError(.sessionFailed, message: "Session provider was cancelled")
        }
        return SimPayCheckoutError(.sessionFailed, message: "Session provider failed (\(type(of: error)))")
    }
}
