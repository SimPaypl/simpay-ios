/// How a failed request may be treated by the caller.
package enum FailureKind: String, Sendable, Hashable {

    /// The request provably never reached the server (no connection, DNS failure, TLS
    /// certificate rejected). Repeating it is safe, even for a mutating request.
    case notDelivered

    /// The server answered with a definitive refusal (for example 400, 401, 403, 404,
    /// 422, 429). For a mutating request this is assumed to have caused no side effect;
    /// repeating the same request is pointless until the cause is fixed.
    case rejected

    /// A read-only request failed temporarily (timeout, lost connection, 5xx, 429,
    /// unusable body). Repeating it is safe because it changes nothing on the server.
    case transient

    /// A mutating request may or may not have taken effect: it could have reached the
    /// server, but no trustworthy answer arrived. It must never be repeated automatically.
    case outcomeUnknown
}

/// A failed API call, classified for the endpoint it targeted.
///
/// Carries no token, BLIK code, e-mail, IP or request body; `error.message` contains at
/// most API field names and a short API message.
package struct APIFailure: Error, Sendable, Hashable, CustomStringConvertible {

    package let error: SimPayCheckoutError
    package let kind: FailureKind
    package let endpoint: APIEndpoint
    /// HTTP status when the server answered, otherwise `nil`.
    package let httpStatus: Int?
    /// Delay requested by the server through `Retry-After` (HTTP 429 or 503), if any.
    package let retryAfter: Duration?
    /// The session provider failed, so no request was sent. Counted by the poller whatever
    /// code the integrator chose, so the merchant backend is never called without bound.
    package let isSessionFailure: Bool

    package init(
        _ code: SimPayCheckoutError.Code,
        kind: FailureKind,
        endpoint: APIEndpoint,
        httpStatus: Int? = nil,
        message: String? = nil,
        retryAfter: Duration? = nil,
        isSessionFailure: Bool = false
    ) {
        self.error = SimPayCheckoutError(code, message: message)
        self.kind = kind
        self.endpoint = endpoint
        self.httpStatus = httpStatus
        self.retryAfter = retryAfter
        self.isSessionFailure = isSessionFailure
    }

    package var description: String {
        let status = httpStatus.map { ", HTTP \($0)" } ?? ""
        return "APIFailure(\(endpoint.operationName), \(kind.rawValue), \(error.code.rawValue)\(status))"
    }
}
