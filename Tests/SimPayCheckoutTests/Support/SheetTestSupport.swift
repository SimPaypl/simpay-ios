import Foundation
@testable import SimPayCheckout
@testable import SimPayCheckoutCore

/// Transport answering each endpoint from its own script; counts calls per route.
/// Never touches the network.
final class SheetTransport: HTTPTransport, @unchecked Sendable {

    enum Route: Sendable { case channels, create, blik, status }

    enum Reply: Sendable {
        case response(HTTPResponse)
        case failure(any Error & Sendable)
    }

    private let lock = NSLock()
    private var scripts: [Route: [Reply]] = [:]
    private var gates: [Route: Gate] = [:]
    private var calls: [Route: Int] = [:]

    /// Queues replies; the last one repeats.
    func script(_ route: Route, _ replies: Reply...) { lock.withLock { scripts[route] = replies } }
    func hold(_ route: Route, with gate: Gate) { lock.withLock { gates[route] = gate } }
    func count(_ route: Route) -> Int { lock.withLock { calls[route, default: 0] } }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let path = request.url?.path ?? ""
        let route: Route = path.hasSuffix("/mobile-sdk/channels") ? .channels
            : path.contains("/blik/level0/") ? .blik
            : path.contains("/mobile-sdk/transactions/") ? .status
            : .create
        let (reply, gate) = lock.withLock { () -> (Reply?, Gate?) in
            calls[route, default: 0] += 1
            var queue = scripts[route, default: []]
            let next = queue.count > 1 ? queue.removeFirst() : queue.first
            scripts[route] = queue
            return (next, gates[route])
        }
        if let gate { await gate.wait() }
        switch reply {
        case .response(let response): return response
        case .failure(let error): throw error
        case nil: throw URLError(.notConnectedToInternet)
        }
    }
}

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

struct TestSessionProvider: SimPaySessionProvider {
    func provideSession() async throws -> SimPaySession {
        try SimPaySession(token: "mobsdk_test_token", payerIP: "203.0.113.7")
    }
}

/// Issues a new token on every call and counts the calls.
final class CountingSessionProvider: SimPaySessionProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var calls: Int { lock.withLock { count } }

    func provideSession() async throws -> SimPaySession {
        let number = lock.withLock { () -> Int in count += 1; return count }
        return try SimPaySession(token: "mobsdk_test_\(number)", payerIP: "203.0.113.7")
    }
}

/// Polls `condition` until it holds, for about one second.
@MainActor
func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0..<200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}

enum Sheet {
    static let transactionID = TransactionID("3f2504e0-4f89-41d3-9a0c-0305e82c3301")!
    static let environment = APIEnvironment(serviceID: "a1b2c3d4")!

    static let blik = #"{"id":"blik-level0","name":"BLIK Level 0","type":"blik","currencies":["PLN"],"amount":{"min":"1.00","max":"20000.00"}}"#
    static let mbank = #"{"id":"mbank","name":"mBank","type":"transfer","currencies":["PLN"]}"#
    static let pekao = #"{"id":"pekao","name":"Pekao24","type":"transfer","currencies":["PLN"]}"#
    static let euro = #"{"id":"sepa","name":"SEPA","type":"transfer","currencies":["EUR"]}"#

    static func channels(_ items: String...) -> SheetTransport.Reply {
        ok(#"{"success":true,"data":[\#(items.joined(separator: ","))]}"#)
    }
    static let created = SheetTransport.Reply.response(HTTPResponse(
        statusCode: 201,
        body: Data(#"{"success":true,"data":{"transactionId":"3f2504e0-4f89-41d3-9a0c-0305e82c3301","redirectUrl":"https://secure.simpay.pl/pay/abc"}}"#.utf8)
    ))
    static func status(_ raw: String) -> SheetTransport.Reply { ok(#"{"success":true,"data":{"status":"\#(raw)"}}"#) }
    static func http(_ code: Int) -> SheetTransport.Reply { .response(HTTPResponse(statusCode: code)) }
    static let blikAccepted = http(204)

    static func ok(_ json: String) -> SheetTransport.Reply {
        .response(HTTPResponse(statusCode: 200, body: Data(json.utf8)))
    }

    static func order(amount: String = "149.99", currency: String = "PLN", returns: Bool = false) -> SimPayOrder {
        try! SimPayOrder(
            amount: Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX"))!,
            currency: currency,
            transactionDescription: "Wireless headphones",
            control: "order-12345",
            customerEmail: "jan.kowalski@example.com",
            customerCountryCode: currency == "PLN" ? nil : "PL",
            returnURLs: returns ? returnURLs : nil
        )
    }

    static let returnURLs = SimPayReturnURLs(
        success: URL(string: "simpayhost://payment-return?result=success")!,
        failure: URL(string: "simpayhost://payment-return?result=failure")!
    )
    static let paymentPage = URL(string: "https://secure.simpay.pl/pay/abc")!

    static func created(redirect: String) -> SheetTransport.Reply {
        .response(HTTPResponse(
            statusCode: 201,
            body: Data(#"{"success":true,"data":{"transactionId":"3f2504e0-4f89-41d3-9a0c-0305e82c3301","redirectUrl":"\#(redirect)"}}"#.utf8)
        ))
    }

    /// Polling never waits for real: sleeps last until the poller is stopped.
    static let idleClock = SDKClock(wallNow: { Date() }, uptime: { .zero }, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })

    @MainActor
    static func engine(
        _ transport: SheetTransport,
        order: SimPayOrder = Sheet.order(),
        provider: any SimPaySessionProvider = TestSessionProvider()
    ) -> CheckoutEngine {
        CheckoutEngine(
            api: AuthorizedAPIClient(
                client: SimPayAPIClient(environment: environment, transport: transport),
                sessions: SessionStore(provider: provider)
            ),
            order: order,
            userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)",
            pollingClock: idleClock
        )
    }

    @MainActor
    static func model(
        _ transport: SheetTransport,
        order: SimPayOrder = Sheet.order(),
        provider: any SimPaySessionProvider = TestSessionProvider()
    ) -> (PaymentSheetModel, CheckoutEngine, Box<[SimPayCheckoutResult]>) {
        let engine = engine(transport, order: order, provider: provider)
        let model = PaymentSheetModel(engine: engine, order: order, merchantName: "Sklep Testowy")
        let results = Box<[SimPayCheckoutResult]>([])
        model.onFinish = { results.value.append($0) }
        return (model, engine, results)
    }
}
