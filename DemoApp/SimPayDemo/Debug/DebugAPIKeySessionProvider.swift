#if DEBUG
import Foundation
import SimPayCheckout

/// DEBUG BUILDS ONLY. Counterpart of `DebugApiKeySessionProvider` in the Android demo.
///
/// Creates a mobile SDK session straight from the app with the merchant API key, so the
/// real SimPay API can be exercised without a merchant backend. The whole file is
/// compiled out of Release builds and is intentionally not part of the SDK.
///
/// Shipping a merchant API key in an application exposes it to anyone who inspects the
/// app. Production apps must obtain the `mobsdk_*` token from the merchant backend
/// (see `INTEGRATION.md`).
///
/// Nothing here is logged or put into error messages: neither the API key, the issued
/// token nor the response body.
struct DebugAPIKeySessionProvider: SimPaySessionProvider {
    /// Same production host the SDK talks to. Not configurable on purpose.
    static let productionBaseURL = URL(string: "https://api.simpay.pl")!

    let configuration: DebugAPIKeyConfiguration
    let baseURL: URL
    let session: URLSession

    init(
        configuration: DebugAPIKeyConfiguration,
        baseURL: URL = DebugAPIKeySessionProvider.productionBaseURL,
        sessionConfiguration: URLSessionConfiguration = .ephemeral
    ) {
        self.configuration = configuration
        self.baseURL = baseURL
        sessionConfiguration.urlCache = nil
        sessionConfiguration.httpCookieStorage = nil
        sessionConfiguration.urlCredentialStorage = nil
        sessionConfiguration.timeoutIntervalForRequest = 20
        sessionConfiguration.timeoutIntervalForResource = 30
        self.session = URLSession(
            configuration: sessionConfiguration,
            delegate: RedirectRefuser(),
            delegateQueue: nil
        )
    }

    /// `POST {base}/payment/{serviceId}/mobile-sdk/session` with `Bearer <api key>`.
    func makeRequest() -> URLRequest {
        let url = baseURL
            .appendingPathComponent("payment")
            .appendingPathComponent(configuration.serviceID)
            .appendingPathComponent("mobile-sdk")
            .appendingPathComponent("session")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("SimPayCheckoutiOS-demo", forHTTPHeaderField: "User-Agent")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        request.httpBody = Data("{}".utf8)
        return request
    }

    func provideSession() async throws -> SimPaySession {
        let body: Data
        let response: URLResponse
        do {
            (body, response) = try await session.data(for: makeRequest())
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .cancelled {
            throw CancellationError()
        } catch {
            // The underlying error is dropped on purpose: it may quote the request.
            throw SimPayCheckoutError(.sessionFailed, message: "Debug session request did not complete.")
        }
        return try Self.parse(body: body, response: response, payerIP: configuration.payerIP)
    }

    /// Converts the endpoint response into the SDK session. The `mobsdk_*` token goes
    /// straight into `SimPaySession`; the SDK then owns refreshing and authorization.
    static func parse(body: Data, response: URLResponse, payerIP: String?) throws -> SimPaySession {
        let issued = try decode(body: body, response: response, payerIP: payerIP)
        do {
            return try SimPaySession(token: issued.token, expiresAt: issued.expiresAt, payerIP: issued.payerIP)
        } catch {
            throw SimPayCheckoutError(.invalidResponse, message: "Session response contains an unusable token.")
        }
    }

    /// Maps the session endpoint response. Accepts `{"data": {...}}` (the shape read by the
    /// Android demo) and a bare object; `token` is required, `expires_at`/`expiresAt` and
    /// `payer_ip`/`payerIp` are optional. The locally configured payer IP is the fallback.
    static func decode(body: Data, response: URLResponse, payerIP: String?) throws -> IssuedSession {
        guard let http = response as? HTTPURLResponse else {
            throw SimPayCheckoutError(.invalidResponse, message: "Debug session response is not HTTP.")
        }
        switch http.statusCode {
        case 200...299:
            break
        case 401, 403:
            throw SimPayCheckoutError(.unauthorized, message: "Session endpoint rejected the API key (HTTP \(http.statusCode)).")
        default:
            throw SimPayCheckoutError(.sessionFailed, message: "Session endpoint responded with HTTP \(http.statusCode).")
        }

        guard let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else {
            throw SimPayCheckoutError(.invalidResponse, message: "Session response is not a JSON object.")
        }
        if let success = root["success"] as? Bool, success == false {
            throw SimPayCheckoutError(.sessionFailed, message: "Session endpoint reported success=false.")
        }
        let data = (root["data"] as? [String: Any]) ?? root
        guard let token = data["token"] as? String, token.hasPrefix("mobsdk_"),
              !token.unicodeScalars.contains(where: { $0.properties.isWhitespace || $0.value < 0x20 }) else {
            throw SimPayCheckoutError(.invalidResponse, message: "Session response is missing a usable mobsdk_* token.")
        }
        let responseIP = ((data["payer_ip"] ?? data["payerIp"]) as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return IssuedSession(
            token: token,
            expiresAt: parseDate(data["expires_at"] ?? data["expiresAt"]),
            payerIP: (responseIP?.isEmpty == false) ? responseIP : payerIP
        )
    }

    /// Decoded session before it is handed to the SDK. Redacted in every textual form.
    struct IssuedSession: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
        let token: String
        let expiresAt: Date?
        let payerIP: String?
        var description: String { "IssuedSession(token: <redacted>, expiresAt: \(String(describing: expiresAt)))" }
        var debugDescription: String { description }
        var customMirror: Mirror { Mirror(self, children: ["token": "<redacted>"], displayStyle: .struct) }
    }

    /// ISO 8601 (with or without fractional seconds) or epoch seconds. Anything else is
    /// treated as unknown: the SDK then keeps the session until the first HTTP 401.
    static func parseDate(_ value: Any?) -> Date? {
        if let seconds = value as? Double { return Date(timeIntervalSince1970: seconds) }
        if let seconds = value as? Int { return Date(timeIntervalSince1970: TimeInterval(seconds)) }
        guard let text = value as? String, !text.isEmpty else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }

    /// Never follow redirects: the `Authorization` header must not reach another host.
    private final class RedirectRefuser: NSObject, URLSessionTaskDelegate, Sendable {
        func urlSession(
            _ session: URLSession,
            task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest
        ) async -> URLRequest? {
            nil
        }
    }
}

/// Values for the API-key mode. Read from the git-ignored `Config/SimPayDebug.local.xcconfig`
/// (injected into the Debug Info.plist only) or typed in on the tester panel.
struct DebugAPIKeyConfiguration: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let serviceID: String
    let apiKey: String
    let payerIP: String?

    static let serviceIDKey = "SimPayDebugServiceID"
    static let apiKeyKey = "SimPayDebugAPIKey"
    static let payerIPKey = "SimPayDebugPayerIP"

    /// Returns `nil` unless the service ID is valid and the key is non-empty and contains
    /// no whitespace or control characters (it goes verbatim into an HTTP header).
    init?(serviceID: String, apiKey: String, payerIP: String?) {
        let service = serviceID.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard SimPayConfiguration(serviceID: service, merchantDisplayName: "x") != nil,
              !key.isEmpty,
              key.unicodeScalars.allSatisfy({ $0.isASCII && $0.value > 0x20 && $0.value < 0x7F })
        else { return nil }
        self.serviceID = service
        self.apiKey = key
        let ip = payerIP?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.payerIP = (ip?.isEmpty ?? true) ? nil : ip
    }

    /// Raw values found in the Info.plist. Unset build settings expand to an empty string;
    /// a literal `$(...)` means the settings were never defined. Both count as missing.
    static func storedValues(in info: [String: Any]?) -> (serviceID: String, apiKey: String, payerIP: String) {
        func value(_ key: String) -> String {
            let raw = (info?[key] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return raw.hasPrefix("$(") ? "" : raw
        }
        return (value(serviceIDKey), value(apiKeyKey), value(payerIPKey))
    }

    var description: String {
        "DebugAPIKeyConfiguration(serviceID: \(serviceID), apiKey: <redacted>, payerIP: \(payerIP == nil ? "nil" : "<redacted>"))"
    }

    var debugDescription: String { description }
}

extension DebugAPIKeyConfiguration: CustomReflectable {
    /// Keeps the key out of `dump()` and debugger summaries as well.
    var customMirror: Mirror {
        Mirror(self, children: ["serviceID": serviceID, "apiKey": "<redacted>"], displayStyle: .struct)
    }
}
#endif
