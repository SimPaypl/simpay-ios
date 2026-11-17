import Foundation
import Testing
@testable import SimPayCheckoutCore

@Suite("Endpoints and request headers")
struct EndpointTests {

    private let id = Sample.transactionID

    @Test("Builds the documented URLs, identical to MobileSdkEndpoints on Android")
    func documentedURLs() {
        let env = Sample.environment
        #expect(APIEndpoint.channels.url(in: env).absoluteString == "https://api.simpay.pl/payment/a1b2c3d4/mobile-sdk/channels")
        #expect(APIEndpoint.createTransaction.url(in: env).absoluteString == "https://api.simpay.pl/payment/a1b2c3d4/transactions")
        #expect(
            APIEndpoint.submitBlikCode(id).url(in: env).absoluteString
                == "https://api.simpay.pl/payment/a1b2c3d4/blik/level0/3f2504e0-4f89-41d3-9a0c-0305e82c3301"
        )
        #expect(
            APIEndpoint.transactionStatus(id).url(in: env).absoluteString
                == "https://api.simpay.pl/payment/a1b2c3d4/mobile-sdk/transactions/3f2504e0-4f89-41d3-9a0c-0305e82c3301"
        )
    }

    @Test("Uses the documented HTTP methods; only POST endpoints are mutating")
    func methods() {
        #expect(APIEndpoint.channels.method == "GET")
        #expect(APIEndpoint.transactionStatus(id).method == "GET")
        #expect(APIEndpoint.createTransaction.method == "POST")
        #expect(APIEndpoint.submitBlikCode(id).method == "POST")
        #expect(!APIEndpoint.channels.isMutating && !APIEndpoint.transactionStatus(id).isMutating)
        #expect(APIEndpoint.createTransaction.isMutating && APIEndpoint.submitBlikCode(id).isMutating)
    }

    @Test("Production is the default and the only https host")
    func productionDefault() {
        #expect(Sample.environment.baseURL.absoluteString == "https://api.simpay.pl")
    }

    @Test("A trailing slash in a base URL does not produce a double slash")
    func trailingSlash() {
        let env = APIEnvironment(serviceID: "a1b2c3d4", baseURL: URL(string: "https://staging.example.com/")!)!
        #expect(APIEndpoint.channels.url(in: env).absoluteString == "https://staging.example.com/payment/a1b2c3d4/mobile-sdk/channels")
    }

    @Test("Refuses insecure base URLs")
    func refusesInsecureBaseURL() {
        #expect(APIEnvironment(serviceID: "a1b2c3d4", baseURL: URL(string: "http://api.simpay.pl")!) == nil)
        #expect(APIEnvironment(serviceID: "a1b2c3d4", baseURL: URL(string: "file:///tmp")!) == nil)
    }

    @Test("Refuses service ids that are not safe path segments", arguments: [
        "", "../admin", "a1b2/c3d4", "a1b2 c3d4", "a1b2?x=1", "a1b2#x", "a1b2%2F", "ąęść", String(repeating: "a", count: 65),
    ])
    func refusesUnsafeServiceID(_ serviceID: String) {
        #expect(APIEnvironment(serviceID: serviceID) == nil)
    }

    @Test("GET requests carry the bearer token and no body")
    func getHeaders() async throws {
        let transport = StubTransport(status: 200, json: #"{"success":true,"data":[]}"#)
        _ = try await Sample.client(transport).fetchChannels(session: Sample.session)

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "GET")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Sample.token)")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.value(forHTTPHeaderField: "User-Agent") == "SimPayCheckoutiOS/\(SDKInfo.version)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(request.value(forHTTPHeaderField: "Cookie") == nil)
        #expect(request.httpBody == nil)
        #expect(request.httpShouldHandleCookies == false)
        #expect(request.cachePolicy == .reloadIgnoringLocalCacheData)
        #expect(request.timeoutInterval == URLSessionTransport.requestTimeout)
    }

    @Test("POST requests carry the bearer token and a JSON body")
    func postHeaders() async throws {
        let transport = StubTransport(status: 200, json: Sample.createdJSON)
        _ = try await Sample.client(transport).createTransaction(Sample.createRequest(), session: Sample.session)

        let request = try #require(transport.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url == APIEndpoint.createTransaction.url(in: Sample.environment))
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer \(Sample.token)")
        #expect(request.value(forHTTPHeaderField: "Content-Type") == "application/json")
        #expect(request.value(forHTTPHeaderField: "Accept") == "application/json")
        #expect(request.httpBody?.isEmpty == false)
    }
}
