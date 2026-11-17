import Foundation

/// Localized texts and money formatting of the payment sheet.
///
/// The sheet resolves strings from the SDK bundle (`Bundle.module`). Tests and previews
/// can pin a language with ``init(language:)``; the app's preferred language is used
/// otherwise. API messages are never shown: every text comes from this table.
package struct SheetStrings {

    package let bundle: Bundle
    package let locale: Locale

    package init(bundle: Bundle, locale: Locale) {
        self.bundle = bundle
        self.locale = locale
    }

    /// Strings in the language iOS picked for the app, money in the user's locale.
    package static var system: SheetStrings {
        SheetStrings(bundle: .module, locale: .autoupdatingCurrent)
    }

    /// Strings and money formatting pinned to `language` (`"en"` or `"pl"`).
    package init(language: String) {
        let path = Bundle.module.path(forResource: language, ofType: "lproj")
        self.bundle = path.flatMap(Bundle.init(path:)) ?? .module
        self.locale = Locale(identifier: language == "pl" ? "pl_PL" : "en_US")
    }

    package func text(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: nil, table: nil)
    }

    package func text(_ key: String, _ arguments: any CVarArg...) -> String {
        String(format: text(key), locale: locale, arguments: arguments)
    }

    /// Formats a payment amount without ever hiding a digit the order carries, like
    /// `AmountFormatter` of the Android SDK. Unknown currency codes are shown verbatim.
    package func amount(_ amount: Decimal, currency: String) -> String {
        let code = currency.uppercased()
        guard Locale.commonISOCurrencyCodes.contains(code) else {
            return "\(amount) \(code)"
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.locale = locale
        formatter.currencyCode = code
        let digits = max(formatter.maximumFractionDigits, Self.scale(of: amount))
        formatter.minimumFractionDigits = digits
        formatter.maximumFractionDigits = digits
        return formatter.string(from: amount as NSDecimalNumber) ?? "\(amount) \(code)"
    }

    private static func scale(of amount: Decimal) -> Int {
        let text = amount.description
        guard let dot = text.firstIndex(of: ".") else { return 0 }
        return text.distance(from: text.index(after: dot), to: text.endIndex)
    }
}

/// Keys of the texts shown for errors and results. Kept apart from the views so the
/// mapping can be tested on every platform.
package enum SheetCopy {

    package enum Tone: Sendable, Hashable {
        case success, pending, failure, unknown, neutral
    }

    package struct Outcome: Sendable, Hashable {
        package let tone: Tone
        package let titleKey: String
        package let detailKey: String?
    }

    /// The text explaining an error to the payer. Never the API message.
    package static func errorKey(_ code: SimPayCheckoutError.Code) -> String {
        switch code {
        case .noInternet: return "error.no_internet"
        case .timeout: return "error.timeout"
        case .rateLimited: return "error.rate_limited"
        case .missingPayerIP: return "error.missing_payer_ip"
        case .missingCountryCode: return "error.missing_country"
        case .transactionNotFound: return "error.transaction_not_found"
        case .blikRejected: return "error.blik_rejected"
        case .outcomeUnknown: return "result.unknown_detail"
        // The payer did nothing wrong: the session or the channel list is unavailable.
        case .sessionFailed, .unauthorized, .channelsFailed, .serviceUnavailable,
             .secureConnectionFailed, .invalidResponse:
            return "error.unavailable"
        default: return "error.generic"
        }
    }

    /// Title, detail and tone of a final result.
    package static func outcome(_ result: SimPayCheckoutResult) -> Outcome {
        switch result {
        case .succeeded:
            return Outcome(tone: .success, titleKey: "result.success_title", detailKey: "result.success_detail")

        case .pending(_, _, let reason):
            switch reason {
            case .verificationRequired:
                return Outcome(tone: .pending, titleKey: "result.verification_title", detailKey: "result.verification_detail")
            case .statusUnavailable:
                return Outcome(tone: .pending, titleKey: "result.pending_title", detailKey: "result.status_unavailable_detail")
            default:
                return Outcome(tone: .pending, titleKey: "result.pending_title", detailKey: "result.pending_detail")
            }

        case .failed(let error, _, let status):
            switch status {
            case .some(.expired):
                return Outcome(tone: .failure, titleKey: "result.expired_title", detailKey: "result.expired_detail")
            case .some(.refunded):
                return Outcome(tone: .neutral, titleKey: "result.refunded_title", detailKey: nil)
            case .some:
                return Outcome(tone: .failure, titleKey: "result.failure_title", detailKey: "result.declined_detail")
            case .none:
                return Outcome(tone: .failure, titleKey: "result.failure_title", detailKey: errorKey(error.code))
            }

        case .outcomeUnknown:
            // Must never read as a failed payment: the payment may exist.
            return Outcome(tone: .unknown, titleKey: "result.unknown_title", detailKey: "result.unknown_detail")

        case .cancelled:
            return Outcome(tone: .neutral, titleKey: "result.cancelled_title", detailKey: "result.cancelled_detail")
        }
    }

    /// Every key the sheet can show, for localization tests.
    package static let allKeys: [String] = [
        "sheet.recipient", "sheet.amount_due", "sheet.secure_note", "sheet.close", "sheet.processing_hint",
        "channels.loading", "channels.empty", "channels.choose", "channels.blik_name", "channels.blik_subtitle",
        "channels.other", "channels.unavailable_currency", "channels.unavailable_amount",
        "blik.title", "blik.hint", "blik.field_label", "blik.field_value", "blik.invalid_code", "blik.rejected_code",
        "blik.new_payment", "blik.submission_failed", "blik.attempts_left", "blik.change_method",
        "progress.preparing", "progress.sending_code", "progress.awaiting_bank", "progress.awaiting_bank_detail",
        "progress.checking_status", "progress.checking_status_detail",
        "redirect.opening", "redirect.detail", "redirect.reopen",
        "result.success_title", "result.success_detail", "result.pending_title", "result.pending_detail",
        "result.status_unavailable_detail", "result.verification_title", "result.verification_detail",
        "result.expired_title", "result.expired_detail", "result.refunded_title", "result.failure_title",
        "result.declined_detail", "result.unknown_title", "result.unknown_detail", "result.cancelled_title",
        "result.cancelled_detail",
        "error.no_internet", "error.timeout", "error.rate_limited", "error.missing_payer_ip", "error.missing_country",
        "error.transaction_not_found", "error.unavailable", "error.blik_rejected", "error.generic",
        "action.pay", "action.pay_amount", "action.cancel", "action.close", "action.done", "action.try_again",
        "a11y.simpay", "a11y.recommended", "a11y.unavailable",
    ]
}
