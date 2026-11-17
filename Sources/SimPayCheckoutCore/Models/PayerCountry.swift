import Foundation

/// Derives `customer.countryCode` from the transaction currency.
///
/// Direct channels require a country code matching the currency. Only currencies with
/// exactly one issuing country are mapped; shared currencies such as EUR resolve to
/// `nil`, so the integrator must state the country instead of the SDK guessing one.
/// The table is identical to `PayerCountry` of the Android SDK.
package enum PayerCountry {

    private static let byCurrency: [String: String] = [
        "PLN": "PL",
        "CZK": "CZ",
        "HUF": "HU",
        "RON": "RO",
        "BGN": "BG",
        "GBP": "GB",
        "USD": "US",
        "SEK": "SE",
        "NOK": "NO",
        "DKK": "DK",
        "CHF": "CH",
        "UAH": "UA",
    ]

    package static func forCurrency(_ currency: String) -> String? {
        byCurrency[currency.trimmingCharacters(in: .whitespaces).uppercased()]
    }
}
