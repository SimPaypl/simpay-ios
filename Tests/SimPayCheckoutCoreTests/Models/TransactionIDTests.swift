import Testing
@testable import SimPayCheckoutCore

@Suite("TransactionID")
struct TransactionIDTests {

    @Test("Accepts canonical UUIDs in any letter case", arguments: [
        "3f2504e0-4f89-41d3-9a0c-0305e82c3301",
        "3F2504E0-4F89-41D3-9A0C-0305E82C3301",
        "00000000-0000-0000-0000-000000000000",
    ])
    func acceptsCanonicalUUID(_ raw: String) throws {
        let id = try #require(TransactionID(raw))
        // The value is sent back to the API unchanged.
        #expect(id.rawValue == raw)
        #expect(id.description == raw)
    }

    @Test("Rejects anything that is not a canonical UUID", arguments: [
        "",
        "not-a-uuid",
        "3f2504e04f8941d39a0c0305e82c3301",          // no hyphens
        "{3f2504e0-4f89-41d3-9a0c-0305e82c3301}",    // braces
        " 3f2504e0-4f89-41d3-9a0c-0305e82c3301",     // leading space
        "3f2504e0-4f89-41d3-9a0c-0305e82c330",       // too short
        "3f2504e0-4f89-41d3-9a0c-0305e82c33011",     // too long
        "3g2504e0-4f89-41d3-9a0c-0305e82c3301",      // non-hex digit
        "3f2504e0_4f89-41d3-9a0c-0305e82c3301",      // wrong separator
        "３f2504e0-4f89-41d3-9a0c-0305e82c3301",     // full-width digit
    ])
    func rejectsMalformedValue(_ raw: String) {
        #expect(TransactionID(raw) == nil)
    }

    @Test("Comparison is exact")
    func comparisonIsExact() {
        #expect(TransactionID("3f2504e0-4f89-41d3-9a0c-0305e82c3301") == Sample.transactionID)
        #expect(TransactionID("3F2504E0-4F89-41D3-9A0C-0305E82C3301") != Sample.transactionID)
    }
}
