import Foundation
import Testing
@testable import SimPayCheckout
@testable import SimPayCheckoutCore

/// Parts of the shared contract implemented by the iOS layer: return URLs, payment page
/// checks and amount display.
@Suite("Contract: return URLs and amount display")
struct ContractPresentationTests {

    /// `Contract/` of this repository, read in place (one copy of the contract).
    private static let contractDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SimPayCheckoutTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repository root
        .appendingPathComponent("Contract", isDirectory: true)

    private func object(_ name: String) throws -> [String: Any] {
        let data = try Data(contentsOf: Self.contractDirectory.appendingPathComponent(name + ".json"))
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @Test("Only safe payment page URLs are opened")
    func paymentPage() throws {
        for entry in try object("policy/return-urls")["paymentPage"] as? [[String: Any]] ?? [] {
            let text = try #require(entry["url"] as? String)
            let url = try #require(URL(string: text))
            #expect(RedirectURLPolicy.isAllowed(url) == entry["allowed"] as? Bool, "\(text)")
        }
    }

    @Test("Return URLs match the order's return addresses exactly as the contract states")
    func returnURLs() throws {
        let file = try object("policy/return-urls")
        let declared = try #require(file["orderReturnUrls"] as? [String: String])
        let matcher = ReturnURLMatcher(returnURLs: SimPayReturnURLs(
            success: try #require(URL(string: declared["success"] ?? "")),
            failure: try #require(URL(string: declared["failure"] ?? ""))
        ))
        for entry in file["returns"] as? [[String: Any]] ?? [] {
            let text = try #require(entry["url"] as? String)
            let url = try #require(URL(string: text))
            #expect(matcher.matches(url) == entry["matches"] as? Bool, "\(text)")
        }
        // Without declared return URLs nothing is ever a return.
        #expect(!ReturnURLMatcher(returnURLs: nil).matches(try #require(URL(string: declared["success"] ?? ""))))
    }

    @Test("Amounts are displayed without losing a digit")
    func amountDisplay() throws {
        for entry in try object("validation/amounts")["display"] as? [[String: Any]] ?? [] {
            let amount = try #require(Decimal(string: entry["amount"] as? String ?? "", locale: Locale(identifier: "en_US_POSIX")))
            let text = SheetStrings(language: entry["language"] as? String ?? "en").amount(amount, currency: entry["currency"] as? String ?? "")
            for part in entry["mustContain"] as? [String] ?? [] {
                #expect(text.contains(part), "\(text) should contain \(part)")
            }
        }
    }
}
