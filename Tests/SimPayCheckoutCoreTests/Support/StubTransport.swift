import Foundation
@testable import SimPayCheckoutCore

/// Scripted transport that records every request it receives.
final class StubTransport: HTTPTransport, @unchecked Sendable {

    enum Reply: Sendable {
        case response(HTTPResponse)
        case failure(any Error & Sendable)
    }

    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    private let reply: Reply
    private let delay: Duration?

    init(_ reply: Reply, delay: Duration? = nil) {
        self.reply = reply
        self.delay = delay
    }

    convenience init(status: Int, json: String = "", headers: [String: String] = [:]) {
        self.init(.response(HTTPResponse(statusCode: status, headers: headers, body: Data(json.utf8))))
    }

    var requests: [URLRequest] { lock.withLock { recorded } }
    var callCount: Int { requests.count }

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        lock.withLock { recorded.append(request) }
        if let delay {
            // Honours cancellation, like URLSession does for read requests.
            try await Task.sleep(for: delay)
        }
        switch reply {
        case .response(let response): return response
        case .failure(let error): throw error
        }
    }
}

extension Sample {
    static let serviceID = "a1b2c3d4"
    static let environment = APIEnvironment(serviceID: serviceID)!
    static let session = try! SimPaySession(token: token, payerIP: ip)
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15"
    static let blikCode = BlikCode("482913")!

    static func client(_ transport: StubTransport) -> SimPayAPIClient {
        SimPayAPIClient(environment: environment, transport: transport)
    }

    static func order(amount: String = "100.00", returns: Bool = false) -> SimPayOrder {
        try! SimPayOrder(
            amount: Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX"))!,
            currency: "PLN",
            transactionDescription: "Wireless headphones",
            control: "Order 12345",
            customerEmail: email,
            returnURLs: returns
                ? SimPayReturnURLs(
                    success: URL(string: "myapp://payment-return?result=success")!,
                    failure: URL(string: "myapp://payment-return?result=failure")!
                )
                : nil
        )
    }

    static func createRequest(amount: String = "100.00", returns: Bool = false) -> CreateTransactionRequest {
        try! CreateTransactionRequest(order: order(amount: amount, returns: returns), directChannel: "blik-level0", payerIP: ip, userAgent: userAgent)
    }

    static let createdJSON = #"{"success":true,"data":{"transactionId":"3f2504e0-4f89-41d3-9a0c-0305e82c3301","redirectUrl":"https://secure.simpay.pl/pay/abc"}}"#
}

/// Runs `body` and returns the `APIFailure` it throws, or `nil`.
func apiFailure(_ body: () async throws -> Void) async -> APIFailure? {
    do {
        try await body()
        return nil
    } catch let failure as APIFailure {
        return failure
    } catch {
        return nil
    }
}

extension URLRequest {
    var bodyText: String? { httpBody.flatMap { String(data: $0, encoding: .utf8) } }
}
