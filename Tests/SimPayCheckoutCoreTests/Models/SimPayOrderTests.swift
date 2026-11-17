import Foundation
import Testing
@testable import SimPayCheckoutCore

@Suite("SimPayOrder")
struct SimPayOrderTests {

    private func order(
        amount: String = "100.00",
        currency: String = "PLN",
        transactionDescription: String? = nil,
        control: String? = nil,
        customerEmail: String = Sample.email,
        customerCountryCode: String? = nil,
        payerIPOverride: String? = nil
    ) throws(SimPayCheckoutError) -> SimPayOrder {
        try SimPayOrder(
            amount: Decimal(string: amount, locale: Locale(identifier: "en_US_POSIX"))!,
            currency: currency,
            transactionDescription: transactionDescription,
            control: control,
            customerEmail: customerEmail,
            customerCountryCode: customerCountryCode,
            payerIPOverride: payerIPOverride
        )
    }

    private func error(_ build: () throws(SimPayCheckoutError) -> SimPayOrder) -> SimPayCheckoutError.Code? {
        caughtError(build)?.code
    }

    // MARK: Amount

    @Test("Accepts amounts of at least 1 with up to two decimals", arguments: [
        "1", "1.00", "1.5", "49.99", "100.00", "20000.00", "999999999.99",
    ])
    func acceptsValidAmount(_ amount: String) throws {
        let order = try order(amount: amount)
        #expect(order.amount == Decimal(string: amount)!)
    }

    @Test("Rejects amounts below 1, like the Android SDK", arguments: ["0.99", "0", "-1", "-100.00"])
    func rejectsAmountBelowMinimum(_ amount: String) {
        #expect(error { () throws(SimPayCheckoutError) in try order(amount: amount) } == .invalidOrder)
    }

    @Test("Rejects amounts with more than two decimals", arguments: ["1.001", "49.999", "10.0000001"])
    func rejectsExcessPrecision(_ amount: String) {
        #expect(error { () throws(SimPayCheckoutError) in try order(amount: amount) } == .invalidOrder)
    }

    @Test("Rejects NaN")
    func rejectsNaN() {
        let failure = error { () throws(SimPayCheckoutError) in
            try SimPayOrder(amount: .nan, customerEmail: Sample.email)
        }
        #expect(failure == .invalidOrder)
    }

    @Test("Rejects an amount that picked up binary floating point noise")
    func rejectsDoubleNoise() {
        // What `Decimal(Double)` yields for 49.99 on platforms that convert through
        // binary floating point. Such a value must never reach the API.
        let noisy = Decimal(string: "49.99000000000000512")!
        let failure = error { () throws(SimPayCheckoutError) in
            try SimPayOrder(amount: noisy, customerEmail: Sample.email)
        }
        #expect(failure == .invalidOrder)
    }

    @Test("The amount keeps its exact decimal value", arguments: ["1.00", "49.99", "0100.10", "20000.00"])
    func amountRoundTripsExactly(_ amount: String) throws {
        let order = try order(amount: amount)
        // The textual form, which the networking layer will send as a JSON number,
        // parses back to the identical value; no Double is involved.
        let text = order.amount.description
        #expect(Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) == Decimal(string: amount)!)
        #expect(!text.contains("e") && !text.contains(","))
    }

    // MARK: Currency and country

    @Test("Normalises the currency code")
    func normalisesCurrency() throws {
        #expect(try order(currency: " pln ").currency == "PLN")
    }

    @Test("Rejects malformed currency codes", arguments: ["", "PL", "PLNN", "P1N", "złt"])
    func rejectsMalformedCurrency(_ currency: String) {
        #expect(error { () throws(SimPayCheckoutError) in try order(currency: currency) } == .invalidOrder)
    }

    @Test("Derives the country only for single-country currencies")
    func derivesCountryFromCurrency() throws {
        #expect(try order(currency: "PLN").resolvedCountryCode == "PL")
        #expect(try order(currency: "czk").resolvedCountryCode == "CZ")
        #expect(try order(currency: "GBP").resolvedCountryCode == "GB")
        #expect(PayerCountry.forCurrency(" GBP ") == "GB")
        #expect(PayerCountry.forCurrency("EUR") == nil)
        #expect(PayerCountry.forCurrency("XYZ") == nil)
    }

    @Test("Never guesses a country for EUR or unknown currencies", arguments: ["EUR", "XYZ"])
    func refusesToGuessCountry(_ currency: String) {
        let failure = error { () throws(SimPayCheckoutError) in try order(currency: currency) }
        #expect(failure == .missingCountryCode)
    }

    @Test("An explicit country wins over the derived one and enables EUR")
    func explicitCountryWins() throws {
        #expect(try order(currency: "PLN", customerCountryCode: "DE").resolvedCountryCode == "DE")
        #expect(try order(currency: "EUR", customerCountryCode: "DE").resolvedCountryCode == "DE")
    }

    @Test("Rejects malformed country codes, like the Android SDK", arguments: ["pl", "POL", "P", "", "P1", "Pl"])
    func rejectsMalformedCountry(_ country: String) {
        let failure = error { () throws(SimPayCheckoutError) in try order(customerCountryCode: country) }
        #expect(failure == .invalidOrder)
    }

    // MARK: Text limits

    @Test("Description is limited to 64 characters")
    func descriptionLimit() {
        #expect(throws: Never.self) { try order(transactionDescription: String(repeating: "a", count: 64)) }
        #expect(error { () throws(SimPayCheckoutError) in
            try order(transactionDescription: String(repeating: "a", count: 65))
        } == .invalidOrder)
    }

    @Test("Control is limited to 255 characters")
    func controlLimit() {
        #expect(throws: Never.self) { try order(control: String(repeating: "x", count: 255)) }
        #expect(error { () throws(SimPayCheckoutError) in
            try order(control: String(repeating: "x", count: 256))
        } == .invalidOrder)
    }

    @Test("Limits count UTF-16 units, like Kotlin String.length")
    func limitsCountUTF16Units() {
        // 32 emoji are 32 characters but 64 UTF-16 units: accepted on Android, accepted here.
        #expect(throws: Never.self) { try order(transactionDescription: String(repeating: "😀", count: 32)) }
        // 33 emoji are 66 UTF-16 units: rejected on Android, rejected here.
        #expect(error { () throws(SimPayCheckoutError) in
            try order(transactionDescription: String(repeating: "😀", count: 33))
        } == .invalidOrder)
    }

    // MARK: Payer data

    @Test("Customer e-mail is required", arguments: ["", "   ", "\n"])
    func emailIsRequired(_ email: String) {
        #expect(error { () throws(SimPayCheckoutError) in try order(customerEmail: email) } == .invalidOrder)
    }

    @Test("A blank payer IP override is treated as missing", arguments: [nil, "", "  "])
    func blankPayerIPOverrideIsMissing(_ ip: String?) throws {
        #expect(try order(payerIPOverride: ip).payerIPOverride == nil)
    }

    @Test("Personal data never appears in description, debug output or dump")
    func personalDataIsMasked() throws {
        let order = try order(control: "order-2451", payerIPOverride: Sample.ip)

        let text = everyTextualForm(of: order)
        #expect(!text.contains(Sample.email))
        #expect(!text.contains(Sample.ip))
        #expect(text.contains("order-2451"))
    }

    @Test("Validation messages never echo submitted values")
    func errorsDoNotEchoValues() {
        let failure = caughtError { () throws(SimPayCheckoutError) in
            try order(customerEmail: Sample.email, customerCountryCode: "secret")
        }
        #expect(failure.map { !everyTextualForm(of: $0).contains("secret") } == true)
    }
}
