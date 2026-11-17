import Foundation

/// Time sources of the SDK, injectable so tests never wait for real.
///
/// `wallNow` is used once, when a session arrives, to turn the backend's `expiresAt` into
/// a remaining lifetime. From then on only `uptime` (a monotonic clock that keeps running
/// while the device sleeps) is used, both for session expiry and the polling budget, so
/// changing the system clock cannot extend or shorten either.
package struct SDKClock: Sendable {

    package let wallNow: @Sendable () -> Date
    /// Monotonic time since an arbitrary origin; unaffected by changes of the system clock.
    package let uptime: @Sendable () -> Duration
    /// Suspends for the given duration; throws `CancellationError` when cancelled.
    package let sleep: @Sendable (Duration) async throws -> Void

    package init(
        wallNow: @escaping @Sendable () -> Date,
        uptime: @escaping @Sendable () -> Duration,
        sleep: @escaping @Sendable (Duration) async throws -> Void
    ) {
        self.wallNow = wallNow
        self.uptime = uptime
        self.sleep = sleep
    }

    package static let system: SDKClock = {
        let clock = ContinuousClock()
        let origin = clock.now
        return SDKClock(wallNow: { Date() }, uptime: { clock.now - origin }, sleep: { try await clock.sleep(for: $0) })
    }()
}
