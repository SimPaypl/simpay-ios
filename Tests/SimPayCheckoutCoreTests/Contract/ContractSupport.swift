import Foundation
@_spi(SimPayBridge) @testable import SimPayCheckoutCore

/// Untyped access to the language independent contract files.
///
/// Contract files are read with `JSONSerialization` on purpose: the conformance runner
/// must see exactly what a Kotlin, Dart or TypeScript reader sees, including numbers
/// where strings are expected.
enum Contract {

    static func object(_ name: String) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Fixture.data(named: name)) as? [String: Any] else {
            throw CocoaError(.fileReadCorruptFile, userInfo: [NSFilePathErrorKey: name])
        }
        return object
    }

    static func list(_ name: String, _ key: String) throws -> [[String: Any]] {
        (try object(name)[key] as? [[String: Any]]) ?? []
    }

    /// Names of the scenario files, for parameterized tests.
    static let scenarioNames: [String] = (try? Fixture.files(in: "scenarios")) ?? []

    static func error(_ value: SimPayCheckoutError?) -> String {
        value?.code.rawValue ?? "valid"
    }

    /// Two JSON values are equal the way JSON defines it (numbers by value, key order ignored).
    static func equal(_ lhs: Any?, _ rhs: Any?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case (let l?, let r?): return (l as AnyObject).isEqual(r as AnyObject)
        default: return false
        }
    }
}

extension String {
    /// Every match of a regular expression.
    func matches(of pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(startIndex..., in: self)
        return regex.matches(in: self, range: range).compactMap { Range($0.range, in: self).map { String(self[$0]) } }
    }
}

// MARK: Scenario runner

/// Transport answering from a scenario's `api` section.
final class ScenarioTransport: HTTPTransport, @unchecked Sendable {

    /// Endpoint names used by the contract.
    enum Endpoint: String, CaseIterable, Sendable {
        case channels, createTransaction = "create_transaction", submitBlikCode = "submit_blik_code", transactionStatus = "transaction_status"
    }

    enum Reply: @unchecked Sendable {
        case response(HTTPResponse)
        case failure(any Error)
    }

    /// A failure that is not a `URLError`: the `unknown` transport failure of the contract.
    struct OpaqueFailure: Error {}

    private let lock = NSLock()
    private var replies: [Endpoint: [Reply]]
    private var calls: [Endpoint: Int] = [:]

    init(api: [String: Any]) throws {
        var replies: [Endpoint: [Reply]] = [:]
        for (name, value) in api {
            guard let endpoint = Endpoint(rawValue: name), let list = value as? [[String: Any]] else {
                throw ScenarioError("unknown endpoint \(name)")
            }
            replies[endpoint] = try list.map(Self.reply)
        }
        self.replies = replies
    }

    func count(_ endpoint: Endpoint) -> Int { lock.withLock { calls[endpoint, default: 0] } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let endpoint = Self.endpoint(of: request)
        let reply = lock.withLock { () -> Reply? in
            calls[endpoint, default: 0] += 1
            var queue = replies[endpoint, default: []]
            let next = queue.count > 1 ? queue.removeFirst() : queue.first
            replies[endpoint] = queue
            return next
        }
        switch reply {
        case .response(let response): return response
        case .failure(let error): throw error
        // No scripted reply: the request provably did not leave the device.
        case nil: throw URLError(.cannotConnectToHost)
        }
    }

    private static func endpoint(of request: URLRequest) -> Endpoint {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/mobile-sdk/channels") { return .channels }
        if path.contains("/blik/level0/") { return .submitBlikCode }
        if path.contains("/mobile-sdk/transactions/") { return .transactionStatus }
        return .createTransaction
    }

    private static func reply(_ object: [String: Any]) throws -> Reply {
        if let failure = object["transportFailure"] as? String {
            return .failure(try transportError(failure))
        }
        guard let status = object["status"] as? Int else { throw ScenarioError("reply without status") }
        let body = try object["json"].map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        let headers = object["headers"] as? [String: String] ?? [:]
        return .response(HTTPResponse(statusCode: status, headers: headers, body: body))
    }

    /// Native error raised for a platform neutral failure name of
    /// `api/transport-error-mapping.json`.
    static func transportError(_ name: String) throws -> any Error {
        switch name {
        case "not_connected": return URLError(.notConnectedToInternet)
        case "dns_failure": return URLError(.dnsLookupFailed)
        case "connection_refused": return URLError(.cannotConnectToHost)
        case "certificate_rejected": return URLError(.serverCertificateUntrusted)
        case "timeout": return URLError(.timedOut)
        case "connection_lost": return URLError(.networkConnectionLost)
        case "tls_failure": return URLError(.secureConnectionFailed)
        case "unknown": return OpaqueFailure()
        default: throw ScenarioError("unknown transport failure \(name)")
        }
    }
}

struct ScenarioError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Outcome of one scenario run.
struct ScenarioRun {
    var result: SimPayCheckoutResult?
    var requests: [String: Int] = [:]
    var transactionCreatedEvents = 0
    var sessionRequests = 0
    /// Steps whose acceptance differed from the scenario.
    var stepMismatches: [String] = []
}

/// Plays a contract scenario against the real `CheckoutEngine`, with a scripted transport,
/// a counting session provider and a manual clock. Nothing waits for real time.
@MainActor
enum ScenarioRunner {

    static let defaultOrder: [String: Any] = ["amount": "49.99", "customerEmail": "payer@example.com"]

    static func run(_ scenario: [String: Any]) async throws -> ScenarioRun {
        let transport = try ScenarioTransport(api: scenario["api"] as? [String: Any] ?? [:])

        var payerIP: String? = Sample.ip
        if let session = scenario["session"] as? [String: Any], session.keys.contains("payerIp") {
            payerIP = session["payerIp"] as? String
        }
        let provider = ScriptedProvider(payerIP: payerIP)

        let orderFields = defaultOrder.merging(scenario["order"] as? [String: Any] ?? [:]) { $1 }
        let order = try SimPayBridge.order(from: orderFields)

        let clock = TestClock()
        let events = EventCounter()
        let engine = CheckoutEngine(
            api: AuthorizedAPIClient(
                client: SimPayAPIClient(environment: Sample.environment, transport: transport),
                sessions: SessionStore(provider: provider, clock: ManualClock().sessionClock)
            ),
            order: order,
            userAgent: Sample.userAgent,
            pollingClock: clock.pollingClock,
            onTransactionCreated: { _ in events.count += 1 }
        )

        var run = ScenarioRun()
        for (index, step) in (scenario["steps"] as? [[String: Any]] ?? []).enumerated() {
            let action = step["action"] as? String ?? ""
            let accepted: Bool?
            switch action {
            case "load_channels":
                accepted = await engine.loadChannels()
            case "select_channel":
                accepted = await engine.selectChannel(id: step["channelId"] as? String ?? "")
            case "submit_blik_code":
                accepted = await engine.submitBlikCode(step["code"] as? String ?? "")
            case "back_to_channels":
                accepted = await engine.backToChannels()
            case "lifecycle":
                engine.handle(try lifecycleEvent(step["event"] as? String))
                accepted = nil
            case "run_polling":
                await runPolling(engine, clock)
                accepted = nil
            case "close":
                _ = await engine.close()
                accepted = nil
            default:
                throw ScenarioError("unknown action \(action)")
            }
            if let accepted, accepted != (step["accepted"] as? Bool ?? true) {
                run.stepMismatches.append("step \(index + 1) \(action): accepted \(accepted)")
            }
            await settle(engine, clock)
        }

        run.result = engine.result
        for endpoint in ScenarioTransport.Endpoint.allCases {
            run.requests[endpoint.rawValue] = transport.count(endpoint)
        }
        run.transactionCreatedEvents = events.count
        run.sessionRequests = provider.calls
        return run
    }

    private static func lifecycleEvent(_ name: String?) throws -> AppLifecycleEvent {
        switch name {
        case "did_enter_background": return .didEnterBackground
        case "will_enter_foreground": return .willEnterForeground
        case "returned_from_redirect": return .returnedFromRedirect
        default: throw ScenarioError("unknown lifecycle event \(name ?? "nil")")
        }
    }

    /// Waits until nothing is in flight: the checkout finished, the poller sleeps, or no
    /// poller runs.
    private static func settle(_ engine: CheckoutEngine, _ clock: TestClock) async {
        _ = await eventually { engine.result != nil || clock.pendingSleeps > 0 || !engine.isPolling }
    }

    /// Skips every poll interval until the checkout finishes or the budget ends.
    private static func runPolling(_ engine: CheckoutEngine, _ clock: TestClock) async {
        for _ in 0..<500 {
            guard await eventually({ clock.pendingSleeps > 0 || engine.result != nil }), engine.result == nil else { return }
            clock.advanceToNextDeadline()
            _ = await eventually { clock.pendingSleeps == 0 }
        }
    }
}

@MainActor
private final class EventCounter {
    var count = 0
}
