#if DEBUG
import Foundation
import Testing
import SimPayCheckout
@testable import SimPayDemo

/// Synthetic values only. The key below is not a real SimPay credential.
private enum Fixture {
    static let serviceID = "a1b2c3d4"
    static let apiKey = "test-api-key-DO-NOT-USE-7f3a9c"
    static let token = "mobsdk_test_session_token"
    static let payerIP = "203.0.113.10"

    static func configuration(payerIP: String? = Fixture.payerIP) -> DebugAPIKeyConfiguration {
        DebugAPIKeyConfiguration(serviceID: serviceID, apiKey: apiKey, payerIP: payerIP)!
    }

    static func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.simpay.pl/")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }

    static func json(_ object: Any) -> Data { try! JSONSerialization.data(withJSONObject: object) }
}

/// Serves canned responses to the provider's URLSession and records requests.
final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    struct Reply: Sendable { var status: Int; var body: Data; var headers: [String: String] = [:]; var failure: URLError? = nil }
    nonisolated(unsafe) static var reply = Reply(status: 200, body: Data())
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var bodies: [Data] = []
    static let lock = NSLock()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        Self.requests.append(request)
        Self.bodies.append(request.httpBody ?? request.httpBodyStream.map(Self.read) ?? Data())
        let reply = Self.reply
        Self.lock.unlock()
        if let failure = reply.failure {
            client?.urlProtocol(self, didFailWithError: failure)
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers)!
        if (300...399).contains(reply.status), let location = reply.headers["Location"], let target = URL(string: location) {
            client?.urlProtocol(self, wasRedirectedTo: URLRequest(url: target), redirectResponse: response)
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    static func read(_ stream: InputStream) -> Data {
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(buffer, count: n) }
        return data
    }

    static func install(_ reply: Reply) -> URLSessionConfiguration {
        lock.lock(); self.reply = reply; requests = []; bodies = []; lock.unlock()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return configuration
    }
}

@Suite("Debug API-key session provider", .serialized)
struct DebugAPIKeySessionProviderTests {

    @Test func requestMatchesTheSessionEndpointContract() throws {
        let request = DebugAPIKeySessionProvider(configuration: Fixture.configuration()).makeRequest()
        #expect(request.httpMethod == "POST")
        #expect(request.url?.absoluteString == "https://api.simpay.pl/payment/a1b2c3d4/mobile-sdk/session")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixture.apiKey)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.httpBody == Data("{}".utf8))
    }

    @Test func issuedTokenIsHandedToTheSDKSession() async throws {
        let configuration = StubURLProtocol.install(.init(status: 200, body: Fixture.json([
            "success": true,
            "data": ["token": Fixture.token, "expires_at": "2030-01-01T10:00:00Z"],
        ])))
        let provider = DebugAPIKeySessionProvider(configuration: Fixture.configuration(), sessionConfiguration: configuration)
        let session = try await provider.provideSession()
        #expect(session.expiresAt == ISO8601DateFormatter().date(from: "2030-01-01T10:00:00Z"))
        #expect(!String(reflecting: session).contains(Fixture.token), "the SDK session redacts the token")

        let issued = try DebugAPIKeySessionProvider.decode(
            body: Fixture.json(["success": true, "data": ["token": Fixture.token]]),
            response: Fixture.response(200), payerIP: Fixture.payerIP
        )
        #expect(issued.token == Fixture.token, "the mobsdk_* token is passed on unchanged")
        #expect(issued.payerIP == Fixture.payerIP, "falls back to the locally configured payer IP")
        #expect(!String(describing: issued).contains(Fixture.token))
        #expect(StubURLProtocol.requests.count == 1, "exactly one request, no retries")
        #expect(StubURLProtocol.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer \(Fixture.apiKey)")
        #expect(StubURLProtocol.bodies.first == Data("{}".utf8))
    }

    @Test func payerIPFromTheResponseWins() throws {
        let issued = try DebugAPIKeySessionProvider.decode(
            body: Fixture.json(["data": ["token": Fixture.token, "payer_ip": "198.51.100.7"]]),
            response: Fixture.response(200), payerIP: Fixture.payerIP
        )
        #expect(issued.payerIP == "198.51.100.7")
    }

    @Test func bareObjectAndOptionalFieldsAreAccepted() throws {
        let issued = try DebugAPIKeySessionProvider.decode(
            body: Fixture.json(["token": Fixture.token, "expiresAt": 1_900_000_000]),
            response: Fixture.response(201), payerIP: nil
        )
        #expect(issued.expiresAt == Date(timeIntervalSince1970: 1_900_000_000))
        #expect(issued.payerIP == nil)
    }

    @Test(arguments: [
        (401, SimPayCheckoutError.Code.unauthorized),
        (403, .unauthorized),
        (400, .sessionFailed),
        (429, .sessionFailed),
        (500, .sessionFailed),
    ])
    func httpErrorsAreMapped(status: Int, code: SimPayCheckoutError.Code) throws {
        let error = #expect(throws: SimPayCheckoutError.self) {
            try DebugAPIKeySessionProvider.parse(
                body: Data(#"{"message":"bad key test-api-key-DO-NOT-USE-7f3a9c"}"#.utf8),
                response: Fixture.response(status), payerIP: nil
            )
        }
        #expect(error?.code == code)
        Self.expectNoSecrets(error)
    }

    @Test(arguments: [
        #"{"success":true,"data":{}}"#,
        #"{"success":false,"data":{"token":"mobsdk_test_session_token"}}"#,
        #"{"data":{"token":"not_a_mobsdk_token"}}"#,
        #"{"data":{"token":"mobsdk_with space"}}"#,
        "not json",
        "[]",
    ])
    func malformedResponsesAreRejected(body: String) {
        let error = #expect(throws: SimPayCheckoutError.self) {
            try DebugAPIKeySessionProvider.parse(body: Data(body.utf8), response: Fixture.response(200), payerIP: nil)
        }
        #expect(error?.code == .invalidResponse || error?.code == .sessionFailed)
        Self.expectNoSecrets(error)
    }

    @Test func transportFailureHidesTheUnderlyingError() async {
        let configuration = StubURLProtocol.install(.init(status: 0, body: Data(), failure: URLError(.notConnectedToInternet)))
        let provider = DebugAPIKeySessionProvider(configuration: Fixture.configuration(), sessionConfiguration: configuration)
        let error = await #expect(throws: SimPayCheckoutError.self) { try await provider.provideSession() }
        #expect(error?.code == .sessionFailed)
        Self.expectNoSecrets(error)
    }

    @Test func redirectsAreNotFollowed() async {
        let configuration = StubURLProtocol.install(.init(
            status: 302, body: Data(), headers: ["Location": "https://attacker.example.com/steal"]
        ))
        let provider = DebugAPIKeySessionProvider(configuration: Fixture.configuration(), sessionConfiguration: configuration)
        await #expect(throws: SimPayCheckoutError.self) { try await provider.provideSession() }
        #expect(StubURLProtocol.requests.allSatisfy { $0.url?.host == "api.simpay.pl" },
                "the API key must never be sent to the redirect target")
    }

    private static func expectNoSecrets(_ error: SimPayCheckoutError?, sourceLocation: SourceLocation = #_sourceLocation) {
        let text = "\(String(describing: error)) \(String(reflecting: error)) \(error?.message ?? "")"
        #expect(!text.contains(Fixture.apiKey), sourceLocation: sourceLocation)
        #expect(!text.contains(Fixture.token), sourceLocation: sourceLocation)
    }
}

@Suite("Debug API-key configuration")
struct DebugAPIKeyConfigurationTests {

    @Test func validValuesAreTrimmed() throws {
        let configuration = try #require(DebugAPIKeyConfiguration(serviceID: " a1b2c3d4 ", apiKey: " \(Fixture.apiKey)\n", payerIP: "  "))
        #expect(configuration.serviceID == "a1b2c3d4")
        #expect(configuration.apiKey == Fixture.apiKey)
        #expect(configuration.payerIP == nil)
    }

    @Test(arguments: [
        ("", Fixture.apiKey),
        ("bad/service", Fixture.apiKey),
        ("a1b2c3d4", ""),
        ("a1b2c3d4", "key with space"),
        ("a1b2c3d4", "key\r\nX-Injected: 1"),
        ("a1b2c3d4", "kluczżółć"),
    ])
    func invalidValuesAreRejected(serviceID: String, apiKey: String) {
        #expect(DebugAPIKeyConfiguration(serviceID: serviceID, apiKey: apiKey, payerIP: nil) == nil)
    }

    @Test func keyNeverAppearsInTextualRepresentations() {
        let configuration = Fixture.configuration()
        var dumped = ""
        dump(configuration, to: &dumped)
        for text in [String(describing: configuration), String(reflecting: configuration), dumped, "\(configuration)"] {
            #expect(!text.contains(Fixture.apiKey))
            #expect(!text.contains(Fixture.payerIP))
        }
    }

    @Test func unsetBuildSettingsCountAsMissing() {
        let unexpanded = DebugAPIKeyConfiguration.storedValues(in: [
            "SimPayDebugServiceID": "$(SIMPAY_DEBUG_SERVICE_ID)",
            "SimPayDebugAPIKey": "$(SIMPAY_DEBUG_API_KEY)",
        ])
        #expect(unexpanded.serviceID.isEmpty && unexpanded.apiKey.isEmpty && unexpanded.payerIP.isEmpty)

        let filled = DebugAPIKeyConfiguration.storedValues(in: [
            "SimPayDebugServiceID": "a1b2c3d4", "SimPayDebugAPIKey": Fixture.apiKey, "SimPayDebugPayerIP": Fixture.payerIP,
        ])
        #expect(filled.serviceID == "a1b2c3d4" && filled.apiKey == Fixture.apiKey && filled.payerIP == Fixture.payerIP)
        #expect(DebugAPIKeyConfiguration.storedValues(in: nil).apiKey.isEmpty)
    }

    @Test func dateFormats() {
        #expect(DebugAPIKeySessionProvider.parseDate("2030-01-01T10:00:00.250Z") != nil)
        #expect(DebugAPIKeySessionProvider.parseDate("2030-01-01T10:00:00+01:00") != nil)
        #expect(DebugAPIKeySessionProvider.parseDate("tomorrow") == nil)
        #expect(DebugAPIKeySessionProvider.parseDate(nil) == nil)
    }
}
#endif
