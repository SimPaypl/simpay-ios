import Foundation

/// Minimal HTTP response.
package struct HTTPResponse: Sendable {
    package let statusCode: Int
    /// Header fields with lower-cased names.
    package let headers: [String: String]
    package let body: Data

    package init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = Dictionary(headers.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { first, _ in first })
        self.body = body
    }
}

/// Sends a single HTTP request.
///
/// Implementations must not retry, must not follow redirects and must not log request
/// or response bodies or headers. Network failures are thrown unchanged (normally as
/// `URLError`) so that `ErrorClassifier` can decide what they mean for each endpoint.
package protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> HTTPResponse
}
