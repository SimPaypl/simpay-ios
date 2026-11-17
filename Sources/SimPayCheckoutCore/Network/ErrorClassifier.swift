import Foundation

/// Maps transport errors, HTTP statuses and unusable bodies to an ``APIFailure``.
///
/// The meaning of a failure depends on the endpoint: for a read-only request every
/// failure is harmless, while for `POST /transactions` and `POST /blik/level0/{id}` any
/// failure that may follow the request reaching the server is `outcomeUnknown`.
/// A network exception is never assumed to mean "not sent" unless the error code
/// proves no connection was established.
package enum ErrorClassifier {

    // MARK: Transport errors

    /// Errors raised before any byte of the request could reach the server.
    private static let notDeliveredCodes: Set<URLError.Code> = [
        .notConnectedToInternet,
        .cannotFindHost,
        .cannotConnectToHost,
        .dnsLookupFailed,
        .internationalRoamingOff,
        .dataNotAllowed,
        .callIsActive,
        .badURL,
        .unsupportedURL,
        .appTransportSecurityRequiresSecureConnection,
    ]

    /// Certificate failures happen during the TLS handshake, before the HTTP request is
    /// sent. The generic `secureConnectionFailed` is deliberately not listed: it does not
    /// prove at which point the connection broke.
    private static let certificateCodes: Set<URLError.Code> = [
        .serverCertificateUntrusted,
        .serverCertificateHasBadDate,
        .serverCertificateNotYetValid,
        .serverCertificateHasUnknownRoot,
        .clientCertificateRejected,
        .clientCertificateRequired,
    ]

    package static func classify(transportError: any Error, endpoint: APIEndpoint) -> APIFailure {
        guard let urlError = transportError as? URLError else {
            // Unknown failure: the request may or may not have left the device.
            return endpoint.isMutating
                ? APIFailure(.outcomeUnknown, kind: .outcomeUnknown, endpoint: endpoint, message: "Request outcome is unknown")
                : APIFailure(.internal, kind: .transient, endpoint: endpoint, message: "Request failed")
        }

        if notDeliveredCodes.contains(urlError.code) {
            return APIFailure(.noInternet, kind: .notDelivered, endpoint: endpoint, message: "No connection to the server")
        }
        if certificateCodes.contains(urlError.code) {
            return APIFailure(.secureConnectionFailed, kind: .notDelivered, endpoint: endpoint, message: "The server certificate was rejected")
        }

        if endpoint.isMutating {
            // Timeout, lost connection, generic TLS failure, cancellation, unreadable
            // response: the server may have accepted the request.
            return APIFailure(
                .outcomeUnknown,
                kind: .outcomeUnknown,
                endpoint: endpoint,
                message: "Request outcome is unknown (URLError \(urlError.code.rawValue))"
            )
        }

        switch urlError.code {
        case .timedOut:
            return APIFailure(.timeout, kind: .transient, endpoint: endpoint, message: "Request timed out")
        case .secureConnectionFailed:
            return APIFailure(.secureConnectionFailed, kind: .transient, endpoint: endpoint, message: "Secure connection failed")
        default:
            return APIFailure(.noInternet, kind: .transient, endpoint: endpoint, message: "Network failure (URLError \(urlError.code.rawValue))")
        }
    }

    // MARK: HTTP statuses

    /// Classifies a response whose status is outside 200...299.
    package static func classify(statusCode: Int, body: Data, headers: [String: String] = [:], endpoint: APIEndpoint) -> APIFailure {
        let summary = APIErrorSummary.make(from: body)
        let retryAfter = (statusCode == 429 || statusCode == 503) ? Self.retryAfter(from: headers) : nil
        func failure(_ code: SimPayCheckoutError.Code, _ kind: FailureKind, _ fallback: String) -> APIFailure {
            APIFailure(code, kind: kind, endpoint: endpoint, httpStatus: statusCode, message: summary ?? fallback, retryAfter: retryAfter)
        }

        switch endpoint {
        case .channels:
            switch statusCode {
            case 401, 403: return failure(.unauthorized, .rejected, "Access token rejected")
            case 429: return failure(.rateLimited, .transient, "Too many requests")
            case 500...599: return failure(.channelsFailed, .transient, "Server error")
            case 404: return failure(.channelsFailed, .rejected, "Service not found; check serviceId and mobile SDK support")
            default: return failure(.channelsFailed, statusCode >= 400 && statusCode < 500 ? .rejected : .transient, "Unexpected HTTP status")
            }

        case .transactionStatus:
            switch statusCode {
            case 401, 403: return failure(.unauthorized, .rejected, "Access token rejected")
            case 404: return failure(.transactionNotFound, .rejected, "Transaction not found")
            case 429: return failure(.rateLimited, .transient, "Too many requests")
            case 500...599: return failure(.serviceUnavailable, .transient, "Server error")
            default: return failure(.invalidResponse, statusCode >= 400 && statusCode < 500 ? .rejected : .transient, "Unexpected HTTP status")
            }

        case .createTransaction:
            switch statusCode {
            case 400, 422: return failure(.validationFailed, .rejected, "Transaction request rejected")
            case 401, 403: return failure(.unauthorized, .rejected, "Access token rejected")
            case 404: return failure(.transactionFailed, .rejected, "Endpoint not found; check serviceId")
            case 429: return failure(.rateLimited, .rejected, "Too many requests")
            // A conflict may mean the transaction already exists.
            case 409: return failure(.outcomeUnknown, .outcomeUnknown, "Conflict; transaction state unknown")
            // Gateways and proxies answer 5xx after the request may have been processed;
            // a 3xx is not part of the contract and proves nothing either.
            case 500...599, 300...399: return failure(.outcomeUnknown, .outcomeUnknown, "Server error; transaction state unknown")
            case 400...499: return failure(.transactionFailed, .rejected, "Transaction request rejected")
            default: return failure(.outcomeUnknown, .outcomeUnknown, "Unexpected HTTP status; transaction state unknown")
            }

        case .submitBlikCode:
            switch statusCode {
            // Same as the Android SDK: an explicit rejection of the ticket.
            case 400, 409, 422: return failure(.blikRejected, .rejected, "BLIK code rejected")
            case 401, 403: return failure(.unauthorized, .rejected, "Access token rejected")
            case 404: return failure(.transactionNotFound, .rejected, "Transaction not found")
            case 429: return failure(.rateLimited, .rejected, "Too many requests")
            case 500...599, 300...399: return failure(.outcomeUnknown, .outcomeUnknown, "Server error; BLIK submission state unknown")
            // Not a rejection of the code (405, 408, 413, ...): the transaction is kept and the
            // next code is sent for it, so no second transaction is created.
            case 400...499: return failure(.validationFailed, .rejected, "BLIK submission refused")
            default: return failure(.outcomeUnknown, .outcomeUnknown, "Unexpected HTTP status; BLIK submission state unknown")
            }
        }
    }

    // MARK: Retry-After

    /// Longest server-requested delay that is honoured; anything above is capped.
    package static let maximumRetryAfter: Duration = .seconds(3600)

    /// Parses `Retry-After` as delta-seconds or an HTTP date (RFC 9110). Invalid values
    /// are ignored; negative delays become zero.
    package static func retryAfter(from headers: [String: String], now: Date = Date()) -> Duration? {
        guard let raw = headers["retry-after"]?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }

        if raw.utf8.allSatisfy({ $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }) {
            guard let seconds = Int64(raw) else { return maximumRetryAfter }
            return min(.seconds(seconds), maximumRetryAfter)
        }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        let seconds = max(0, date.timeIntervalSince(now))
        return min(.milliseconds(Int64(seconds * 1000)), maximumRetryAfter)
    }

    // MARK: Unusable 2xx bodies

    /// Classifies a 2xx response whose body cannot be used: malformed JSON, missing
    /// fields or `success: false`. After a mutating request the server reported success
    /// at the HTTP level, so the state is unknown rather than failed. A read-only request
    /// fails with `readCode` and may simply be repeated.
    package static func unusableSuccessBody(
        statusCode: Int,
        endpoint: APIEndpoint,
        readCode: SimPayCheckoutError.Code = .invalidResponse,
        reason: String
    ) -> APIFailure {
        if endpoint.isMutating {
            return APIFailure(.outcomeUnknown, kind: .outcomeUnknown, endpoint: endpoint, httpStatus: statusCode, message: reason)
        }
        return APIFailure(readCode, kind: .transient, endpoint: endpoint, httpStatus: statusCode, message: reason)
    }
}

/// Builds a short diagnostic from an API error body without echoing submitted values.
///
/// Only field names from `errors` and a truncated top-level `message` are kept. Per-field
/// messages are dropped because APIs often quote the rejected value (e-mail, IP).
package enum APIErrorSummary {

    private static let maximumMessageLength = 120

    package static func make(from body: Data) -> String? {
        guard !body.isEmpty, let decoded = try? JSONDecoder().decode(APIErrorBodyDTO.self, from: body) else {
            return nil
        }

        var parts: [String] = []
        if let message = decoded.message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty {
            parts.append(String(message.prefix(maximumMessageLength)))
        }
        if !decoded.fieldNames.isEmpty {
            parts.append("fields: " + decoded.fieldNames.sorted().joined(separator: ", "))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "; ")
    }
}
