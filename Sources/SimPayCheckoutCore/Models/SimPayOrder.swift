import Foundation

/// Order data passed to the checkout.
///
/// Every value is validated on creation, so an invalid order fails with
/// ``SimPayCheckoutError/Code-swift.struct/invalidOrder`` (or `missingCountryCode`)
/// before anything is sent to the API.
///
/// - Important: These values are only what the application claims. The SimPay API does
///   not bind the amount or currency to the session token, so the merchant backend must
///   verify the webhook against its own order record before releasing goods.
public struct SimPayOrder: Sendable {

    /// Amount to pay, at least 1, with at most two fractional digits.
    ///
    /// Create it from text, for example `Decimal(string: "49.99")`, never from `Double`.
    public let amount: Decimal

    /// ISO 4217 code, normalised to upper case. Defaults to `PLN`.
    public let currency: String

    /// Text shown on the SimPay gateway (API field `description`). Max 64 characters.
    public let transactionDescription: String?

    /// Merchant reference, typically the order id (API field `control`). Max 255
    /// characters. Used by the backend to reconcile webhooks, including after an
    /// ``SimPayCheckoutResult/outcomeUnknown(_:)`` result.
    public let control: String?

    /// Payer e-mail, required because every channel is created as a direct channel.
    public let customerEmail: String

    /// Payer country as ISO 3166-1 alpha-2 (upper case), as supplied by the integrator.
    public let customerCountryCode: String?

    /// Return URLs used by the payment gateway after a redirect payment.
    public let returnURLs: SimPayReturnURLs?

    /// Payer public IP fallback, used only when the session carries none. Must be the
    /// address observed by the merchant backend, never a device interface address.
    public let payerIPOverride: String?

    /// Country sent as `customer.countryCode`: the explicit one, otherwise derived from
    /// the currency. Always present, because the initializer fails otherwise.
    package let resolvedCountryCode: String

    package static let minimumAmount: Decimal = 1
    package static let maximumFractionDigits = 2
    package static let maximumDescriptionLength = 64
    package static let maximumControlLength = 255

    public init(
        amount: Decimal,
        currency: String = "PLN",
        transactionDescription: String? = nil,
        control: String? = nil,
        customerEmail: String,
        customerCountryCode: String? = nil,
        returnURLs: SimPayReturnURLs? = nil,
        payerIPOverride: String? = nil
    ) throws(SimPayCheckoutError) {
        guard !amount.isNaN, amount >= Self.minimumAmount else {
            throw Self.invalid("amount must be at least 1")
        }
        guard Self.hasAtMostFractionDigits(amount, Self.maximumFractionDigits) else {
            throw Self.invalid("amount must have at most 2 fractional digits")
        }

        let normalizedCurrency = currency.trimmingCharacters(in: .whitespaces).uppercased()
        guard Self.isUppercaseASCIILetters(normalizedCurrency, count: 3) else {
            throw Self.invalid("currency must be a three letter ISO 4217 code")
        }

        // Length is counted in UTF-16 units, exactly like Kotlin `String.length`, which
        // is never smaller than the character count the API may apply.
        if let transactionDescription, transactionDescription.utf16.count > Self.maximumDescriptionLength {
            throw Self.invalid("transactionDescription max length is 64")
        }
        if let control, control.utf16.count > Self.maximumControlLength {
            throw Self.invalid("control max length is 255")
        }

        guard !customerEmail.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Self.invalid("customerEmail must not be blank")
        }

        if let customerCountryCode, !Self.isUppercaseASCIILetters(customerCountryCode, count: 2) {
            throw Self.invalid("customerCountryCode must be two uppercase letters (ISO 3166-1 alpha-2)")
        }
        guard let country = customerCountryCode ?? PayerCountry.forCurrency(normalizedCurrency) else {
            throw SimPayCheckoutError(
                .missingCountryCode,
                message: "\(normalizedCurrency) is used by several countries; set customerCountryCode"
            )
        }

        self.amount = amount
        self.currency = normalizedCurrency
        self.transactionDescription = transactionDescription
        self.control = control
        self.customerEmail = customerEmail
        self.customerCountryCode = customerCountryCode
        self.returnURLs = returnURLs
        // A blank override is treated as missing, as on Android.
        self.payerIPOverride = payerIPOverride.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        self.resolvedCountryCode = country
    }

    private static func invalid(_ message: String) -> SimPayCheckoutError {
        SimPayCheckoutError(.invalidOrder, message: message)
    }

    private static func hasAtMostFractionDigits(_ value: Decimal, _ digits: Int) -> Bool {
        var input = value
        var rounded = Decimal()
        NSDecimalRound(&rounded, &input, digits, .plain)
        return rounded == value
    }

    private static func isUppercaseASCIILetters(_ value: String, count: Int) -> Bool {
        let bytes = value.utf8
        return bytes.count == count
            && bytes.allSatisfy { $0 >= UInt8(ascii: "A") && $0 <= UInt8(ascii: "Z") }
    }
}

extension SimPayOrder: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {

    /// Payer e-mail and IP are personal data and are never printed.
    public var description: String {
        "SimPayOrder(amount: \(amount) \(currency), control: \(control ?? "nil"), "
            + "customerEmail: <redacted>, payerIPOverride: \(payerIPOverride == nil ? "nil" : "<redacted>"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(
            self,
            children: [
                "amount": amount,
                "currency": currency,
                "control": control as Any,
                "customerCountryCode": customerCountryCode as Any,
            ],
            displayStyle: .struct
        )
    }
}

/// Return URLs used by the payment gateway.
///
/// The URL scheme (or Universal Link domain) must be registered identically in the
/// SimPay merchant panel and in the application; otherwise the payer stays in the
/// browser after paying, without any error.
public struct SimPayReturnURLs: Sendable, Hashable {

    public let success: URL
    public let failure: URL

    public init(success: URL, failure: URL) {
        self.success = success
        self.failure = failure
    }
}
