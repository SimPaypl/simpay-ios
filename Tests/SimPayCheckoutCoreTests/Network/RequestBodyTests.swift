import Foundation
import Testing
@testable import SimPayCheckoutCore

@Suite("Request bodies")
struct RequestBodyTests {

    @Test("Transaction body is byte-for-byte the expected JSON")
    func rawTransactionBody() throws {
        let body = try RequestBodyFactory.createTransaction(Sample.createRequest(amount: "49.99", returns: true))

        let expected = #"{"amount":49.99,"currency":"PLN","description":"Wireless headphones","control":"Order 12345","#
            + #""directChannel":"blik-level0","#
            + #""customer":{"email":"jan.kowalski@example.com","ip":"203.0.113.10","countryCode":"PL"},"#
            + #""antifraud":{"useragent":"Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15"},"#
            + #""returns":{"success":"myapp://payment-return?result=success","failure":"myapp://payment-return?result=failure"}}"#
        #expect(String(decoding: body, as: UTF8.self) == expected)
    }

    @Test("Carries every field required by direct channels, like DirectChannelRequestTest")
    func requiredDirectChannelFields() throws {
        let body = try RequestBodyFactory.createTransaction(Sample.createRequest())
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["currency"] as? String == "PLN")
        #expect(json["directChannel"] as? String == "blik-level0")
        #expect(json["control"] as? String == "Order 12345")
        let customer = try #require(json["customer"] as? [String: Any])
        #expect(customer["email"] as? String == Sample.email)
        #expect(customer["ip"] as? String == Sample.ip)
        #expect(customer["countryCode"] as? String == "PL")
        // Lowercase key, exactly as the API documents it.
        #expect((json["antifraud"] as? [String: Any])?["useragent"] as? String == Sample.userAgent)
        #expect(json["returns"] == nil)
    }

    @Test("Optional fields are omitted, not sent as null")
    func optionalFieldsOmitted() throws {
        let order = try SimPayOrder(amount: 10, customerEmail: Sample.email)
        let request = try CreateTransactionRequest(order: order, directChannel: "mbank", payerIP: Sample.ip, userAgent: "UA")
        let text = String(decoding: try RequestBodyFactory.createTransaction(request), as: UTF8.self)

        #expect(!text.contains("description"))
        #expect(!text.contains("control"))
        #expect(!text.contains("returns"))
        #expect(!text.contains("null"))
    }

    @Test("The amount is an exact JSON number literal", arguments: [
        ("100.00", "100"), ("49.99", "49.99"), ("1", "1"), ("1.5", "1.5"), ("0100.10", "100.1"),
        ("999999999.99", "999999999.99"), ("12345678901234567890.12", "12345678901234567890.12"),
    ])
    func exactAmountLiteral(_ input: String, _ literal: String) throws {
        let body = try RequestBodyFactory.createTransaction(Sample.createRequest(amount: input))
        let text = String(decoding: body, as: UTF8.self)

        #expect(text.hasPrefix(#"{"amount":\#(literal),"#))
        // Same check as Android: the literal parses back to the identical decimal value.
        let parsed = try #require(Decimal(string: literal, locale: Locale(identifier: "en_US_POSIX")))
        #expect(parsed == Decimal(string: input, locale: Locale(identifier: "en_US_POSIX"))!)
    }

    @Test("Text values are escaped correctly")
    func escaping() throws {
        let order = try SimPayOrder(
            amount: 10,
            transactionDescription: "Quote \" backslash \\ newline \n zażółć 😀",
            customerEmail: Sample.email
        )
        let request = try CreateTransactionRequest(order: order, directChannel: "mbank", payerIP: Sample.ip, userAgent: "UA")
        let body = try RequestBodyFactory.createTransaction(request)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])

        #expect(json["description"] as? String == "Quote \" backslash \\ newline \n zażółć 😀")
    }

    @Test("Refuses values that cannot be a plain JSON number")
    func numberLiteralGuard() {
        #expect(throws: SimPayCheckoutError.self) { try RequestBodyFactory.numberLiteral(.nan) }
        #expect((try? RequestBodyFactory.numberLiteral(Decimal(string: "-12.5")!)) == "-12.5")
    }

    @Test("BLIK body uses the uppercase T6 key")
    func blikBody() throws {
        let body = try RequestBodyFactory.blikLevel0(Sample.blikCode)
        #expect(String(decoding: body, as: UTF8.self) == #"{"ticket":{"T6":"482913"}}"#)
    }

    @Test("Direct channel requests require payer IP, channel and user agent")
    func requestValidation() {
        let order = Sample.order()
        func code(_ build: () throws(SimPayCheckoutError) -> CreateTransactionRequest) -> SimPayCheckoutError.Code? {
            caughtError(build)?.code
        }

        #expect(code { () throws(SimPayCheckoutError) in try CreateTransactionRequest(order: order, directChannel: "blik", payerIP: nil, userAgent: "UA") } == .missingPayerIP)
        #expect(code { () throws(SimPayCheckoutError) in try CreateTransactionRequest(order: order, directChannel: "blik", payerIP: " ", userAgent: "UA") } == .missingPayerIP)
        #expect(code { () throws(SimPayCheckoutError) in try CreateTransactionRequest(order: order, directChannel: " ", payerIP: Sample.ip, userAgent: "UA") } == .internal)
        #expect(code { () throws(SimPayCheckoutError) in try CreateTransactionRequest(order: order, directChannel: "blik", payerIP: Sample.ip, userAgent: "") } == .internal)
    }
}
