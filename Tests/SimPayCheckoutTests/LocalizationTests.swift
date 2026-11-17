import Foundation
import Testing
@testable import SimPayCheckout
@testable import SimPayCheckoutCore

@Suite("Localization and copy")
struct LocalizationTests {

    private static let languages = ["en", "pl"]

    private func table(_ language: String) -> [String: String] {
        guard let path = SheetStrings.system.bundle.path(forResource: language, ofType: "lproj"),
              let url = Bundle(path: path)?.url(forResource: "Localizable", withExtension: "strings"),
              let dictionary = NSDictionary(contentsOf: url) as? [String: String] else {
            return [:]
        }
        return dictionary
    }

    @Test("English and Polish define exactly the keys the sheet uses", arguments: languages)
    func completeTables(_ language: String) {
        let keys = Set(table(language).keys)
        #expect(!keys.isEmpty, "missing \(language).lproj/Localizable.strings")
        #expect(keys == Set(SheetCopy.allKeys))
    }

    @Test("Every key resolves to a real text in both languages", arguments: languages)
    func resolves(_ language: String) {
        let strings = SheetStrings(language: language)
        for key in SheetCopy.allKeys {
            let text = strings.text(key)
            #expect(text != key && !text.isEmpty, "\(language): \(key)")
        }
    }

    @Test("Polish differs from English except brand names")
    func translated() {
        let english = SheetStrings(language: "en")
        let polish = SheetStrings(language: "pl")
        let sameInBoth: Set = ["channels.blik_name", "a11y.simpay"]
        for key in SheetCopy.allKeys where !sameInBoth.contains(key) {
            #expect(english.text(key) != polish.text(key), "\(key) is not translated")
        }
        #expect(polish.text("action.pay") == "Zapłać")
        #expect(polish.text("progress.awaiting_bank") == "Potwierdź płatność w aplikacji swojego banku")
    }

    @Test("Format arguments are applied")
    func formatting() {
        #expect(SheetStrings(language: "pl").text("blik.attempts_left", 4) == "Pozostałe próby: 4")
        #expect(SheetStrings(language: "en").text("blik.field_value", 3) == "3 of 6 digits entered")
    }

    @Test("Amounts follow the language and never lose a digit")
    func amounts() {
        let polish = SheetStrings(language: "pl").amount(Decimal(string: "149.99")!, currency: "PLN")
        #expect(polish.contains("149,99") && polish.contains("zł"))
        let english = SheetStrings(language: "en").amount(Decimal(string: "1234.5")!, currency: "EUR")
        #expect(english.contains("1,234.50") && english.contains("€"))
        let precise = SheetStrings(language: "en").amount(Decimal(string: "10.125")!, currency: "PLN")
        #expect(precise.contains("10.125"))
        #expect(SheetStrings(language: "en").amount(Decimal(10), currency: "XYZ1") == "10 XYZ1")
    }

    @Test("Every error code maps to a payer text, never an API message")
    func errorTexts() {
        for code in SimPayCheckoutError.Code.allKnown {
            #expect(SheetCopy.allKeys.contains(SheetCopy.errorKey(code)), "\(code)")
        }
        #expect(SheetCopy.errorKey(SimPayCheckoutError.Code(rawValue: "future_code")) == "error.generic")
    }

    @Test("An unknown outcome never reads as a failed payment; pending never reads as paid")
    func outcomeSemantics() {
        let unknown = SheetCopy.outcome(.outcomeUnknown(SimPayCheckoutError(.outcomeUnknown)))
        #expect(unknown.tone == .unknown)
        #expect(unknown.titleKey == "result.unknown_title")

        let id = Sheet.transactionID
        for reason in SimPayCheckoutResult.PendingReason.allKnown {
            let pending = SheetCopy.outcome(.pending(transactionID: id, status: nil, reason: reason))
            #expect(pending.tone == .pending)
            #expect(pending.titleKey != "result.success_title")
        }
        #expect(SheetCopy.outcome(.succeeded(transactionID: id, status: .paid)).tone == .success)
        #expect(SheetCopy.outcome(.cancelled).tone == .neutral)
        #expect(SheetCopy.outcome(.failed(SimPayCheckoutError(.transactionFailed), transactionID: id, status: .expired)).titleKey == "result.expired_title")
        #expect(SheetCopy.outcome(.failed(SimPayCheckoutError(.blikRejected), transactionID: id, status: nil)).detailKey == "error.blik_rejected")

        let polish = SheetStrings(language: "pl")
        #expect(polish.text("result.unknown_detail").contains("Nie płać ponownie"))
    }

    @Test("Screens follow the engine state; only mutating requests lock dismissal")
    func screenMapping() {
        let id = Sheet.transactionID
        let cases: [(CheckoutState, PaymentSheetScreen, Bool)] = [
            (.idle, .loadingChannels, false),
            (.loadingChannels, .loadingChannels, false),
            (.channels([]), .emptyChannels, false),
            (.creatingTransaction(channelID: "blik-level0"), .progress(.preparingPayment), true),
            (.submittingBlikCode(id), .progress(.sendingCode), true),
            (.awaitingBankConfirmation(id), .awaitingBank, false),
            (.checkingStatus(id, lastStatus: nil), .progress(.checkingStatus), false),
            (.redirecting(id, URL(string: "https://secure.simpay.pl/x")!), .redirecting, false),
            (.finished(.cancelled), .result(.cancelled), false),
        ]
        for (state, screen, locks) in cases {
            let mapped = PaymentSheetScreen(state)
            #expect(mapped == screen, "\(state)")
            #expect(mapped.locksDismissal == locks, "\(state)")
        }
        let kept = BlikEntry(transactionID: id, problem: nil, remainingAttempts: 5)
        #expect(PaymentSheetScreen(.enteringBlikCode(kept)) == .blikEntry(kept, canChangeMethod: false))
    }
}
