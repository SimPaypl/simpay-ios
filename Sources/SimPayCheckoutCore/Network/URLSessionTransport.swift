import Foundation

/// `URLSession` based transport.
///
/// - Ephemeral session: no disk cache, no cookies, no credential storage.
/// - Redirects are never followed, so the `Authorization` header cannot travel to
///   another host; a 3xx response is returned as is.
/// - TLS 1.2 or newer.
/// - No automatic retries and no logging of headers or bodies.
package final class URLSessionTransport: HTTPTransport {

    package static let requestTimeout: TimeInterval = 20
    package static let resourceTimeout: TimeInterval = 30

    private let session: URLSession

    package init(configuration: URLSessionConfiguration = URLSessionTransport.makeConfiguration()) {
        session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
    }

    deinit {
        session.finishTasksAndInvalidate()
    }

    /// The configuration used by default; exposed so tests can add a stub protocol.
    package static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = resourceTimeout
        configuration.waitsForConnectivity = false
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.tlsMinimumSupportedProtocolVersion = .TLSv12
        return configuration
    }

    package func send(_ request: URLRequest) async throws -> HTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw URLError(.badServerResponse)
        }

        var headers: [String: String] = [:]
        for (name, value) in http.allHeaderFields {
            if let name = name as? String, let value = value as? String {
                headers[name] = value
            }
        }
        return HTTPResponse(statusCode: http.statusCode, headers: headers, body: data)
    }
}

/// Refuses every HTTP redirect, so the original 3xx response is delivered instead.
package final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {

    package func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest
    ) async -> URLRequest? {
        nil
    }
}
