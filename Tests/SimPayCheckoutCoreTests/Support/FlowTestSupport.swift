import Foundation
@testable import SimPayCheckoutCore

/// Transport that answers each endpoint from its own script and counts calls per route.
final class FlowTransport: HTTPTransport, @unchecked Sendable {

    enum Route: String, CaseIterable, Sendable {
        case channels, create, blik, status
    }

    private let lock = NSLock()
    private var scripts: [Route: [StubTransport.Reply]] = [:]
    private var gates: [Route: Gate] = [:]
    private var calls: [Route: Int] = [:]
    private var bodies: [Route: [Data]] = [:]

    /// Queues replies for a route; the last one repeats.
    func script(_ route: Route, _ replies: StubTransport.Reply...) {
        lock.withLock { scripts[route] = replies }
    }

    /// Makes every call to `route` wait until the gate opens.
    func hold(_ route: Route, with gate: Gate) {
        lock.withLock { gates[route] = gate }
    }

    func count(_ route: Route) -> Int { lock.withLock { calls[route, default: 0] } }
    func sentBodies(_ route: Route) -> [String] {
        lock.withLock { bodies[route, default: []].map { String(decoding: $0, as: UTF8.self) } }
    }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let route = Self.route(of: request)
        let (reply, gate) = lock.withLock { () -> (StubTransport.Reply?, Gate?) in
            calls[route, default: 0] += 1
            if let body = request.httpBody { bodies[route, default: []].append(body) }
            var queue = scripts[route, default: []]
            let next = queue.count > 1 ? queue.removeFirst() : queue.first
            scripts[route] = queue
            return (next, gates[route])
        }
        if let gate { await gate.wait() }

        switch reply {
        case .response(let response): return response
        case .failure(let error): throw error
        case nil: throw URLError(.unsupportedURL)
        }
    }

    private static func route(of request: URLRequest) -> Route {
        let path = request.url?.path ?? ""
        if path.hasSuffix("/mobile-sdk/channels") { return .channels }
        if path.contains("/blik/level0/") { return .blik }
        if path.contains("/mobile-sdk/transactions/") { return .status }
        return .create
    }
}

enum Flow {
    static let blikRedirect = #"{"id":"blik","name":"BLIK","type":"blik","currencies":["PLN"],"amount":{"min":"1.00","max":"20000.00"}}"#
    static let blikLevel0 = #"{"id":"blik-level0","name":"BLIK Level 0","type":"blik","currencies":["PLN"],"amount":{"min":"1.00","max":"20000.00"}}"#
    static let mbank = #"{"id":"mbank","name":"mBank","type":"transfer","currencies":["PLN"],"amount":{"min":"1.00","max":"50000.00"}}"#
    static let euroOnly = #"{"id":"sepa","name":"SEPA","type":"transfer","currencies":["EUR"]}"#
    static let tooSmall = #"{"id":"premium","name":"Premium","type":"transfer","currencies":["PLN"],"amount":{"min":"500.00"}}"#

    static func channels(_ items: String...) -> StubTransport.Reply {
        ok(#"{"success":true,"data":[\#(items.joined(separator: ","))]}"#)
    }

    static func created(_ id: String = "3f2504e0-4f89-41d3-9a0c-0305e82c3301", redirect: String? = "https://secure.simpay.pl/pay/abc") -> StubTransport.Reply {
        let redirectField = redirect.map { #","redirectUrl":"\#($0)""# } ?? ""
        return .response(HTTPResponse(statusCode: 201, body: Data(#"{"success":true,"data":{"transactionId":"\#(id)"\#(redirectField)}}"#.utf8)))
    }

    static func status(_ raw: String) -> StubTransport.Reply {
        ok(#"{"success":true,"data":{"status":"\#(raw)"}}"#)
    }

    static func http(_ status: Int) -> StubTransport.Reply {
        .response(HTTPResponse(statusCode: status))
    }

    static let blikAccepted = http(204)

    static func ok(_ json: String) -> StubTransport.Reply {
        .response(HTTPResponse(statusCode: 200, body: Data(json.utf8)))
    }

    static let secondID = TransactionID("aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!

    @MainActor
    static func engine(
        _ transport: FlowTransport,
        provider: ScriptedProvider = ScriptedProvider(),
        order: SimPayOrder = Sample.order(),
        maximumBlikRejections: Int = BlikLevel0.maximumRejections,
        clock: TestClock = TestClock(),
        pollingPolicy: PollingPolicy = .default,
        onTransactionCreated: (@MainActor @Sendable (TransactionID) -> Void)? = nil
    ) -> CheckoutEngine {
        CheckoutEngine(
            api: AuthorizedAPIClient(
                client: SimPayAPIClient(environment: Sample.environment, transport: transport),
                sessions: SessionStore(provider: provider, clock: ManualClock().sessionClock)
            ),
            order: order,
            userAgent: Sample.userAgent,
            maximumBlikRejections: maximumBlikRejections,
            pollingPolicy: pollingPolicy,
            pollingClock: clock.pollingClock,
            onTransactionCreated: onTransactionCreated
        )
    }
}

/// Collects every state an engine publishes.
@MainActor
final class StateRecorder {
    private(set) var states: [CheckoutState] = []
    private var task: Task<Void, Never>?

    init(_ engine: CheckoutEngine) {
        let stream = engine.stateUpdates()
        task = Task { @MainActor [weak self] in
            for await state in stream { self?.states.append(state) }
        }
    }

    /// Short names of the recorded states, for readable assertions.
    var names: [String] { states.map(\.name) }
}

extension CheckoutState {
    var name: String {
        switch self {
        case .idle: return "idle"
        case .loadingChannels: return "loadingChannels"
        case .channels: return "channels"
        case .creatingTransaction: return "creatingTransaction"
        case .enteringBlikCode: return "enteringBlikCode"
        case .submittingBlikCode: return "submittingBlikCode"
        case .awaitingBankConfirmation: return "awaitingBankConfirmation"
        case .redirecting: return "redirecting"
        case .checkingStatus: return "checkingStatus"
        case .failed: return "failed"
        case .finished: return "finished"
        }
    }

    var blikEntry: BlikEntry? {
        if case .enteringBlikCode(let entry) = self { return entry }
        return nil
    }
}
