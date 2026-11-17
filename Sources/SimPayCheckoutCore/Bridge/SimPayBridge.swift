import Foundation

/// Platform-neutral payload format `bridge-v1`, shared with the Android SDK and used by
/// the Flutter and React Native adapters. The format is specified in
/// `Contract/schema/bridge-v1.schema.json` (examples in `Contract/bridge/`).
///
/// Available only through `@_spi(SimPayBridge) import SimPayCheckout`. Regular Swift
/// integrations use the typed API instead. Adapters must use this codec rather than
/// mapping fields themselves, so every platform produces identical payloads.
///
/// Rules of the format:
/// - payloads are JSON-compatible dictionaries (`NSDictionary` from Flutter and React Native);
/// - amounts are strings with a strict grammar, never numbers, so no value passes
///   through a binary floating point type in Dart or JavaScript;
/// - unknown keys are ignored, so a newer adapter can talk to an older SDK;
/// - error messages name the offending field but never echo its value;
/// - session tokens are accepted, never produced, and never appear in any output.
@_spi(SimPayBridge)
public enum SimPayBridge {

    /// Major version of the payload format. Incremented only for incompatible changes.
    public static let version = 1

    // MARK: Requests (adapter -> SDK)

    /// Data needed to present the checkout, decoded from a `present` request.
    public struct PresentRequest: Sendable {
        public let serviceID: String
        public let merchantDisplayName: String
        public let order: SimPayOrder
    }

    /// Decodes `{ "version": 1, "configuration": {...}, "order": {...} }`.
    ///
    /// Configuration values are only checked for presence here; the SDK entry point
    /// validates them and reports `invalid_configuration`.
    public static func presentRequest(from object: [String: Any]) throws(SimPayCheckoutError) -> PresentRequest {
        try checkVersion(object)
        guard let configuration = object["configuration"] as? [String: Any] else {
            throw configurationError("configuration must be an object")
        }
        guard let serviceID = configuration["serviceId"] as? String else {
            throw configurationError("configuration.serviceId must be a string")
        }
        guard let merchantDisplayName = configuration["merchantDisplayName"] as? String else {
            throw configurationError("configuration.merchantDisplayName must be a string")
        }
        guard let order = object["order"] as? [String: Any] else {
            throw orderError("order must be an object")
        }
        return PresentRequest(serviceID: serviceID, merchantDisplayName: merchantDisplayName, order: try self.order(from: order))
    }

    /// Decodes an order. Field names follow the SimPay API (`description`, `control`).
    public static func order(from object: [String: Any]) throws(SimPayCheckoutError) -> SimPayOrder {
        guard let amountText = object["amount"] as? String else {
            throw orderError("amount must be a decimal string, for example \"49.99\"")
        }
        guard let amount = amount(from: amountText) else {
            throw orderError("amount must match ^(0|[1-9][0-9]*)(\\.[0-9]{1,2})?$")
        }

        let currency = try optionalString(object, "currency", error: orderError) ?? "PLN"
        let description = try optionalString(object, "description", error: orderError)
        let control = try optionalString(object, "control", error: orderError)
        guard let email = object["customerEmail"] as? String else {
            throw orderError("customerEmail must be a string")
        }
        let country = try optionalString(object, "customerCountryCode", error: orderError)
        let payerIP = try optionalString(object, "payerIpOverride", error: orderError)

        var returnURLs: SimPayReturnURLs?
        if let value = object["returnUrls"], !(value is NSNull) {
            guard let returns = value as? [String: Any],
                  let success = (returns["success"] as? String).flatMap(URL.init(string:)),
                  let failure = (returns["failure"] as? String).flatMap(URL.init(string:)) else {
                throw orderError("returnUrls must contain success and failure URLs")
            }
            returnURLs = SimPayReturnURLs(success: success, failure: failure)
        }

        return try SimPayOrder(
            amount: amount,
            currency: currency,
            transactionDescription: description,
            control: control,
            customerEmail: email,
            customerCountryCode: country,
            returnURLs: returnURLs,
            payerIPOverride: payerIP
        )
    }

    /// Decodes a session delivered by the merchant backend through the adapter.
    /// `expiresAt` is an ISO 8601 date with a time zone, for example
    /// `2026-11-05T12:15:00Z` or `2026-11-05T12:15:00.000+01:00`.
    public static func session(from object: [String: Any]) throws(SimPayCheckoutError) -> SimPaySession {
        guard let token = object["token"] as? String else {
            throw SimPayCheckoutError(.sessionFailed, message: "token must be a string")
        }
        var expiresAt: Date?
        if let value = object["expiresAt"], !(value is NSNull) {
            guard let text = value as? String, let date = date(from: text) else {
                throw SimPayCheckoutError(.sessionFailed, message: "expiresAt must be an ISO 8601 date with a time zone")
            }
            expiresAt = date
        }
        let payerIP = try optionalString(object, "payerIp") { SimPayCheckoutError(.sessionFailed, message: $0) }
        return try SimPaySession(token: token, expiresAt: expiresAt, payerIP: payerIP)
    }

    /// Decodes a transaction id received from Dart or TypeScript.
    public static func transactionID(from text: String) throws(SimPayCheckoutError) -> TransactionID {
        guard let id = TransactionID(text) else {
            throw SimPayCheckoutError(.invalidOrder, message: "transactionId must be a canonical UUID")
        }
        return id
    }

    // MARK: Payloads (SDK -> adapter)

    /// Encodes the final result of `present` or of a status check.
    public static func payload(for result: SimPayCheckoutResult) -> [String: Any] {
        var payload: [String: Any] = ["version": version]
        switch result {
        case .succeeded(let id, let status):
            payload["type"] = ResultType.succeeded
            payload["transactionId"] = id.rawValue
            payload["status"] = status.rawValue
        case .pending(let id, let status, let reason):
            payload["type"] = ResultType.pending
            payload["transactionId"] = id.rawValue
            payload["status"] = status?.rawValue
            payload["pendingReason"] = reason.rawValue
        case .failed(let error, let id, let status):
            payload["type"] = ResultType.failed
            payload["error"] = self.payload(for: error)
            payload["transactionId"] = id?.rawValue
            payload["status"] = status?.rawValue
        case .outcomeUnknown(let error):
            payload["type"] = ResultType.outcomeUnknown
            payload["error"] = self.payload(for: error)
        case .cancelled:
            payload["type"] = ResultType.cancelled
        }
        return payload
    }

    /// Encodes an error. The message is an English diagnostic free of personal data.
    public static func payload(for error: SimPayCheckoutError) -> [String: Any] {
        var payload: [String: Any] = ["code": error.code.rawValue]
        payload["message"] = error.message
        return payload
    }

    /// Event emitted as soon as a transaction id is known.
    public static func transactionCreatedEvent(_ transactionID: TransactionID) -> [String: Any] {
        ["version": version, "type": "transaction_created", "transactionId": transactionID.rawValue]
    }

    /// Values of the `type` field of a result payload.
    public enum ResultType {
        public static let succeeded = "succeeded"
        public static let pending = "pending"
        public static let failed = "failed"
        public static let outcomeUnknown = "outcome_unknown"
        public static let cancelled = "cancelled"

        package static let all = [succeeded, pending, failed, outcomeUnknown, cancelled]
    }

    // MARK: Amount

    /// Parses an amount with the strict contract grammar `^(0|[1-9][0-9]*)(\.[0-9]{1,2})?$`.
    ///
    /// `Decimal(string:)` alone is not used for validation because it accepts prefixes,
    /// exponents and whitespace (`"12abc"` becomes 12, `"1,5"` becomes 1).
    public static func amount(from text: String) -> Decimal? {
        let bytes = Array(text.utf8)
        let parts = bytes.split(separator: UInt8(ascii: "."), maxSplits: 1, omittingEmptySubsequences: false)
        guard let integer = parts.first, !integer.isEmpty, integer.allSatisfy(isDigit) else { return nil }
        if integer.count > 1, integer.first == UInt8(ascii: "0") { return nil }
        if parts.count == 2 {
            let fraction = parts[1]
            guard (1...2).contains(fraction.count), fraction.allSatisfy(isDigit) else { return nil }
        }
        return Decimal(string: text, locale: Locale(identifier: "en_US_POSIX"))
    }

    // MARK: Helpers

    private static func checkVersion(_ object: [String: Any]) throws(SimPayCheckoutError) {
        guard let value = object["version"] as? Int, value == version else {
            throw SimPayCheckoutError(.invalidConfiguration, message: "version must be \(version)")
        }
    }

    private static func optionalString(
        _ object: [String: Any],
        _ key: String,
        error: (String) -> SimPayCheckoutError
    ) throws(SimPayCheckoutError) -> String? {
        guard let value = object[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw error("\(key) must be a string or null") }
        return text
    }

    private static func orderError(_ message: String) -> SimPayCheckoutError {
        SimPayCheckoutError(.invalidOrder, message: message)
    }

    private static func configurationError(_ message: String) -> SimPayCheckoutError {
        SimPayCheckoutError(.invalidConfiguration, message: message)
    }

    private static func isDigit(_ byte: UInt8) -> Bool {
        byte >= UInt8(ascii: "0") && byte <= UInt8(ascii: "9")
    }

    private static func date(from text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: text)
    }
}
