import Foundation
@testable import SimPayCheckoutCore

/// Clock whose wall time and monotonic uptime are moved by hand.
final class ManualClock: @unchecked Sendable {

    private let lock = NSLock()
    private var wall = Date(timeIntervalSince1970: 1_800_000_000)
    private var elapsed: Duration = .zero

    var now: Date { lock.withLock { wall } }

    /// Lets time pass: both clocks move.
    func advance(by duration: Duration) {
        lock.withLock {
            elapsed += duration
            wall += TimeInterval(duration.components.seconds)
        }
    }

    /// Changes only the system clock, as a user or NTP would.
    func setWallClock(_ date: Date) {
        lock.withLock { wall = date }
    }

    var sessionClock: SDKClock {
        SDKClock(
            wallNow: { self.lock.withLock { self.wall } },
            uptime: { self.lock.withLock { self.elapsed } },
            sleep: { try await Task.sleep(for: $0) }
        )
    }
}

/// A gate that suspends callers until opened.
actor Gate {
    private var isOpen = false
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiting.append($0) }
    }

    func open() {
        isOpen = true
        waiting.forEach { $0.resume() }
        waiting.removeAll()
    }
}

/// Provider issuing `mobsdk_test_1`, `mobsdk_test_2`, ... and counting calls.
final class ScriptedProvider: SimPaySessionProvider, @unchecked Sendable {

    private let lock = NSLock()
    private var count = 0
    private var failures: [Int: any Error & Sendable] = [:]
    private let gate: Gate?
    private let lifetime: TimeInterval?
    private let clock: ManualClock?
    private let payerIP: String?

    /// - Parameters:
    ///   - lifetime: `expiresAt` = clock.now + lifetime; `nil` reports no expiry.
    ///   - gate: when set, every call waits until the gate opens.
    init(clock: ManualClock? = nil, lifetime: TimeInterval? = nil, payerIP: String? = Sample.ip, gate: Gate? = nil) {
        self.clock = clock
        self.lifetime = lifetime
        self.payerIP = payerIP
        self.gate = gate
    }

    var calls: Int { lock.withLock { count } }

    /// Makes call number `call` (1-based) throw `error`.
    func fail(call: Int, with error: any Error & Sendable) {
        lock.withLock { failures[call] = error }
    }

    func provideSession() async throws -> SimPaySession {
        let (number, failure) = lock.withLock { () -> (Int, (any Error)?) in
            count += 1
            return (count, failures[count])
        }
        if let gate { await gate.wait() }
        if let failure { throw failure }

        let expiry = lifetime.map { (clock?.now ?? Date()).addingTimeInterval($0) }
        return try SimPaySession(token: Self.token(number), expiresAt: expiry, payerIP: payerIP)
    }

    static func token(_ number: Int) -> String { "mobsdk_test_\(number)" }
}

/// Transport answering through a closure and recording every request.
final class ScriptedTransport: HTTPTransport, @unchecked Sendable {

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let handler: @Sendable (URLRequest) throws -> HTTPResponse

    init(_ handler: @escaping @Sendable (URLRequest) throws -> HTTPResponse) {
        self.handler = handler
    }

    /// Answers 401 to every token except the accepted ones; otherwise `success`.
    static func accepting(_ tokens: Set<String>, success: HTTPResponse) -> ScriptedTransport {
        ScriptedTransport { request in
            let header = request.value(forHTTPHeaderField: "Authorization") ?? ""
            return tokens.contains(String(header.dropFirst("Bearer ".count))) ? success : HTTPResponse(statusCode: 401)
        }
    }

    var requests: [URLRequest] { lock.withLock { recorded } }
    var callCount: Int { requests.count }
    var tokensUsed: [String] {
        requests.map { String(($0.value(forHTTPHeaderField: "Authorization") ?? "").dropFirst("Bearer ".count)) }
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock { recorded.append(request) }
        return try handler(request)
    }
}

/// Polls `condition` until it holds, failing after about one second.
func eventually(isolation: isolated (any Actor)? = #isolation, _ condition: () async -> Bool) async -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return await condition()
}

struct ProviderBoom: Error, CustomStringConvertible, Sendable {
    // Simulates a careless provider error that quotes the token.
    var description: String { "backend said: token \(Sample.token) rejected" }
}
