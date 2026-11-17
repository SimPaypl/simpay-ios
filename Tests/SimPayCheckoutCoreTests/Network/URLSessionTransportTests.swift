import Foundation
import Testing
@testable import SimPayCheckoutCore

/// Serves canned responses to a real `URLSession`, without any network access.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {

    struct Captured: Sendable {
        let request: URLRequest
        let body: Data?
    }

    typealias Handler = @Sendable (URLRequest) -> Result<(Int, [String: String], Data), URLError>

    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: Handler?
    nonisolated(unsafe) private static var captured: [Captured] = []

    static func install(_ handler: @escaping Handler) {
        lock.withLock {
            self.handler = handler
            captured = []
        }
    }

    static var requests: [Captured] { lock.withLock { captured } }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let body = request.httpBody ?? request.httpBodyStream.map(Self.read)
        let handler = Self.lock.withLock {
            Self.captured.append(Captured(request: request, body: body))
            return Self.handler
        }

        switch handler?(request) ?? .failure(URLError(.unknown)) {
        case .success(let (status, headers, data)):
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        case .failure(let error):
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func read(_ stream: InputStream) -> Data {
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count <= 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }
}

@Suite("URLSessionTransport", .serialized)
struct URLSessionTransportTests {

    private func makeTransport() -> URLSessionTransport {
        let configuration = URLSessionTransport.makeConfiguration()
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSessionTransport(configuration: configuration)
    }

    @Test("Default configuration is ephemeral, without cache, cookies or stored credentials")
    func configuration() {
        let configuration = URLSessionTransport.makeConfiguration()

        #expect(configuration.urlCache == nil)
        #expect(configuration.httpCookieStorage == nil)
        #expect(configuration.httpShouldSetCookies == false)
        #expect(configuration.httpCookieAcceptPolicy == .never)
        #expect(configuration.urlCredentialStorage == nil)
        #expect(configuration.requestCachePolicy == .reloadIgnoringLocalCacheData)
        #expect(configuration.timeoutIntervalForRequest == 20)
        #expect(configuration.timeoutIntervalForResource == 30)
        #expect(configuration.waitsForConnectivity == false)
        #expect(configuration.tlsMinimumSupportedProtocolVersion == .TLSv12)
    }

    @Test("Redirects are refused so the Authorization header never leaves the API host")
    func redirectsAreRefused() async {
        let url = URL(string: "https://api.simpay.pl/payment/a1b2c3d4/transactions")!
        let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": "https://evil.example"])!
        let next = URLRequest(url: URL(string: "https://evil.example")!)
        let session = URLSession(configuration: .ephemeral)
        let task = session.dataTask(with: url)

        let decision = await RedirectBlocker().urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: next)
        #expect(decision == nil)
        session.invalidateAndCancel()
    }

    @Test("Sends method, headers and body unchanged through a real URLSession")
    func roundTrip() async throws {
        StubURLProtocol.install { _ in .success((201, ["Content-Type": "application/json", "X-Request-Id": "abc"], Data(Sample.createdJSON.utf8))) }
        let client = SimPayAPIClient(environment: Sample.environment, transport: makeTransport())

        let created = try await client.createTransaction(Sample.createRequest(amount: "49.99"), session: Sample.session)

        #expect(created.transactionID == Sample.transactionID)
        let captured = try #require(StubURLProtocol.requests.first)
        #expect(StubURLProtocol.requests.count == 1)
        #expect(captured.request.httpMethod == "POST")
        #expect(captured.request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Sample.token)")
        #expect(captured.request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(captured.request.value(forHTTPHeaderField: "Cookie") == nil)
        let body = String(decoding: try #require(captured.body), as: UTF8.self)
        #expect(body.hasPrefix(#"{"amount":49.99,"#))
    }

    @Test("Response headers are exposed with lower-cased names")
    func responseHeaders() async throws {
        StubURLProtocol.install { _ in .success((429, ["Retry-After": "30"], Data())) }

        let request = URLRequest(url: URL(string: "https://api.simpay.pl/x")!)
        let response = try await makeTransport().send(request)

        #expect(response.statusCode == 429)
        #expect(response.headers["retry-after"] == "30")
    }

    @Test("A transport timeout on POST reaches the caller as outcome_unknown")
    func timeoutThroughURLSession() async {
        StubURLProtocol.install { _ in .failure(URLError(.timedOut)) }
        let client = SimPayAPIClient(environment: Sample.environment, transport: makeTransport())

        let failure = await apiFailure { _ = try await client.createTransaction(Sample.createRequest(), session: Sample.session) }

        #expect(failure?.kind == .outcomeUnknown)
        #expect(StubURLProtocol.requests.count == 1)
    }

    @Test("A connection failure on POST reaches the caller as not_delivered")
    func cannotConnectThroughURLSession() async {
        StubURLProtocol.install { _ in .failure(URLError(.cannotConnectToHost)) }
        let client = SimPayAPIClient(environment: Sample.environment, transport: makeTransport())

        let failure = await apiFailure { _ = try await client.createTransaction(Sample.createRequest(), session: Sample.session) }

        #expect(failure?.kind == .notDelivered)
        #expect(failure?.error.code == .noInternet)
    }
}
