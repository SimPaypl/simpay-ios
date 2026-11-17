import Testing
@testable import SimPayCheckoutCore

@Suite("BlikCode")
struct BlikCodeTests {

    @Test("Accepts exactly six ASCII digits", arguments: ["123456", "000000", "999999"])
    func acceptsSixDigits(_ raw: String) throws {
        let code = try #require(BlikCode(raw))
        #expect(code.digits == raw)
        #expect(BlikCode.isValid(raw))
    }

    @Test("Rejects malformed codes", arguments: [
        "",
        "12345",        // too short
        "1234567",      // too long
        "12345a",       // letter
        "123 456",      // inner space
        " 123456",      // leading space, not trimmed by the model
        "123456\n",     // trailing newline
        "-12345",       // sign
        "١٢٣٤٥٦",       // Arabic-Indic digits are not ASCII digits
        "１２３４５６",  // full-width digits
    ])
    func rejectsMalformedCode(_ raw: String) {
        #expect(BlikCode(raw) == nil)
        #expect(!BlikCode.isValid(raw))
    }

    @Test("The code never appears in description, debug output or dump")
    func codeIsMasked() throws {
        let code = try #require(BlikCode("482913"))

        let text = everyTextualForm(of: code)
        #expect(!text.contains("482913"))
        #expect(code.description == "BlikCode(******)")
        #expect("\(code)" == "BlikCode(******)")
    }

    @Test("The code is masked when nested in other values")
    func codeIsMaskedWhenNested() throws {
        let code = try #require(BlikCode("482913"))

        #expect(!everyTextualForm(of: [code]).contains("482913"))
        #expect(!everyTextualForm(of: (label: "blik", value: code)).contains("482913"))
    }
}
