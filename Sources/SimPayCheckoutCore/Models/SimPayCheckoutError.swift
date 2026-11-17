/// Error reported by the SimPay Checkout SDK.
///
/// `code` is a stable, platform independent identifier. The same values are used by the
/// Android SDK and by the Flutter and React Native adapters, so integrators can branch on
/// it safely. `message` is an English diagnostic for developers: it is never shown to the
/// payer and never contains tokens, BLIK codes or other personal data.
public struct SimPayCheckoutError: Error, Sendable, Hashable, CustomStringConvertible {

    public let code: Code
    public let message: String?

    public init(_ code: Code, message: String? = nil) {
        self.code = code
        self.message = message
    }

    public var description: String {
        guard let message else { return "SimPayCheckoutError(\(code.rawValue))" }
        return "SimPayCheckoutError(\(code.rawValue)): \(message)"
    }
}

extension SimPayCheckoutError {

    /// Stable error identifier.
    ///
    /// Modelled as an extensible struct rather than an enum, so new codes can be added
    /// in a minor release without breaking exhaustive `switch` statements of integrators.
    /// Raw values are `snake_case` and must never change once released.
    public struct Code: RawRepresentable, Sendable, Hashable, CustomStringConvertible {

        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        // MARK: Connectivity

        /// The request never reached the server, so repeating it is safe.
        public static let noInternet = Code(rawValue: "no_internet")
        /// A read-only request timed out.
        public static let timeout = Code(rawValue: "timeout")
        /// Too many requests; the caller must wait before retrying.
        public static let rateLimited = Code(rawValue: "rate_limited")
        /// The TLS connection could not be established or the certificate was rejected.
        public static let secureConnectionFailed = Code(rawValue: "secure_connection_failed")
        /// The SimPay API answered with a server error (5xx) to a read-only request.
        public static let serviceUnavailable = Code(rawValue: "service_unavailable")

        // MARK: Session and API

        /// The session provider failed or returned an unusable session.
        public static let sessionFailed = Code(rawValue: "session_failed")
        /// The access token was rejected.
        public static let unauthorized = Code(rawValue: "unauthorized")
        /// Payment channels could not be loaded.
        public static let channelsFailed = Code(rawValue: "channels_failed")
        /// The API response could not be understood.
        public static let invalidResponse = Code(rawValue: "invalid_response")
        /// The API rejected the request payload.
        public static let validationFailed = Code(rawValue: "validation_failed")
        /// The transaction is unknown to the API.
        public static let transactionNotFound = Code(rawValue: "transaction_not_found")

        // MARK: Payment outcome

        /// The transaction was rejected or did not complete.
        public static let transactionFailed = Code(rawValue: "transaction_failed")
        /// The BLIK code was rejected or is no longer usable.
        public static let blikRejected = Code(rawValue: "blik_rejected")
        /// The outcome of a request that may have changed state is unknown, for example
        /// no response after creating a transaction. Never repeated automatically.
        public static let outcomeUnknown = Code(rawValue: "outcome_unknown")

        // MARK: Integration

        /// The order failed local validation; nothing was sent to the API.
        public static let invalidOrder = Code(rawValue: "invalid_order")
        /// Direct channels need the payer's public IP, but none was supplied.
        public static let missingPayerIP = Code(rawValue: "missing_payer_ip")
        /// Direct channels need a country code and none could be determined.
        public static let missingCountryCode = Code(rawValue: "missing_country_code")
        /// A checkout is already being presented.
        public static let alreadyPresented = Code(rawValue: "already_presented")
        /// The payment sheet could not be shown, for example because the given view
        /// controller is not in a window. No transaction was attempted.
        public static let presentationFailed = Code(rawValue: "presentation_failed")
        /// The checkout configuration is invalid, for example a malformed service id or an
        /// unsupported bridge payload version. No request was sent.
        public static let invalidConfiguration = Code(rawValue: "invalid_configuration")
        /// No browser is available to open the payment page (Android only today).
        public static let browserUnavailable = Code(rawValue: "browser_unavailable")
        /// Unexpected internal failure.
        public static let `internal` = Code(rawValue: "internal")
    }
}

extension SimPayCheckoutError.Code {

    /// Every code defined by this SDK version. Used by contract tests.
    package static let allKnown: [SimPayCheckoutError.Code] = [
        .noInternet, .timeout, .rateLimited, .secureConnectionFailed, .serviceUnavailable,
        .sessionFailed, .unauthorized, .channelsFailed, .invalidResponse,
        .validationFailed, .transactionNotFound,
        .transactionFailed, .blikRejected, .outcomeUnknown,
        .invalidOrder, .missingPayerIP, .missingCountryCode, .alreadyPresented,
        .presentationFailed, .invalidConfiguration, .browserUnavailable, .internal,
    ]
}
