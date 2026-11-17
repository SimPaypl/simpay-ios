#if DEBUG && os(iOS)
import Foundation
import SimPayCheckoutCore

/// Test hook for integration hosts: answers SDK requests without any network.
///
/// Available only through `@_spi(Testing) import SimPayCheckout` and only in DEBUG builds
/// of the package: release builds do not contain this code, so a simulated API can never
/// replace the production one in a shipped app.
@_spi(Testing)
public protocol SimPayTestTransport: Sendable {
    /// Answers one request. Throwing a `URLError` simulates a network failure.
    func respond(to request: URLRequest) async throws -> (statusCode: Int, headers: [String: String], body: Data)
}

@_spi(Testing)
extension SimPayCheckout {

    /// A checkout whose requests are answered by `testTransport` instead of the SimPay API.
    public convenience init(
        configuration: SimPayConfiguration,
        sessionProvider: any SimPaySessionProvider,
        testTransport: any SimPayTestTransport
    ) {
        var dependencies = CheckoutDependencies()
        dependencies.transport = TestTransportAdapter(base: testTransport)
        self.init(configuration: configuration, sessionProvider: sessionProvider, dependencies: dependencies)
    }
}

private struct TestTransportAdapter: HTTPTransport {
    let base: any SimPayTestTransport

    func send(_ request: URLRequest) async throws -> HTTPResponse {
        let answer = try await base.respond(to: request)
        let headers = Dictionary(answer.headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { _, last in last })
        return HTTPResponse(statusCode: answer.statusCode, headers: headers, body: answer.body)
    }
}
#endif
