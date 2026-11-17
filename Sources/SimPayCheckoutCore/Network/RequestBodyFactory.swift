import Foundation

/// Builds the JSON request bodies.
///
/// Text values are escaped with `JSONEncoder`. The amount is written as a JSON number
/// literal taken from `Decimal.description`, so it never passes through `Double` and
/// does not depend on how a given OS version of `JSONEncoder` serialises `Decimal`.
/// Keys are written in a fixed order so bodies are byte-for-byte reproducible in tests.
package enum RequestBodyFactory {

    /// Body of `POST /payment/{serviceId}/transactions`.
    package static func createTransaction(_ request: CreateTransactionRequest) throws(SimPayCheckoutError) -> Data {
        let order = request.order

        let customer: [(String, JSONToken)] = [
            ("email", .string(order.customerEmail)),
            ("ip", .string(request.payerIP)),
            ("countryCode", .string(order.resolvedCountryCode)),
        ]

        var fields: [(String, JSONToken)] = [
            ("amount", .number(try numberLiteral(order.amount))),
            ("currency", .string(order.currency)),
        ]
        if let description = order.transactionDescription {
            fields.append(("description", .string(description)))
        }
        if let control = order.control {
            fields.append(("control", .string(control)))
        }
        fields.append(("directChannel", .string(request.directChannel)))
        fields.append(("customer", .object(customer)))
        // Lowercase "useragent", exactly as the API requires.
        fields.append(("antifraud", .object([("useragent", .string(request.userAgent))])))
        if let returns = order.returnURLs {
            fields.append((
                "returns",
                .object([
                    ("success", .string(returns.success.absoluteString)),
                    ("failure", .string(returns.failure.absoluteString)),
                ])
            ))
        }

        return try JSONToken.object(fields).encoded()
    }

    /// Body of `POST /payment/{serviceId}/blik/level0/{transactionId}`.
    /// The key casing is significant: the API rejects a lowercase `t6`.
    package static func blikLevel0(_ code: BlikCode) throws(SimPayCheckoutError) -> Data {
        try JSONToken.object([("ticket", .object([("T6", .string(code.digits))]))]).encoded()
    }

    /// Plain decimal literal: optional minus, digits, optional fraction. Anything else
    /// (exponent, locale separators, NaN) is refused rather than sent.
    package static func numberLiteral(_ value: Decimal) throws(SimPayCheckoutError) -> String {
        let text = value.description
        var bytes = Substring(text).utf8[...]
        if bytes.first == UInt8(ascii: "-") { bytes = bytes.dropFirst() }
        let parts = bytes.split(separator: UInt8(ascii: "."), omittingEmptySubsequences: false)
        let isPlain = !value.isNaN
            && (1...2).contains(parts.count)
            && parts.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") } }
        guard isPlain else {
            throw SimPayCheckoutError(.internal, message: "amount cannot be written as a plain JSON number")
        }
        return text
    }
}

/// Minimal ordered JSON writer for request bodies.
enum JSONToken {
    case string(String)
    /// A validated number literal.
    case number(String)
    case object([(String, JSONToken)])

    func encoded() throws(SimPayCheckoutError) -> Data {
        var output = ""
        try write(into: &output)
        return Data(output.utf8)
    }

    private func write(into output: inout String) throws(SimPayCheckoutError) {
        switch self {
        case .string(let value):
            output += try Self.quoted(value)
        case .number(let literal):
            output += literal
        case .object(let members):
            output += "{"
            for (index, member) in members.enumerated() {
                if index > 0 { output += "," }
                output += try Self.quoted(member.0)
                output += ":"
                try member.1.write(into: &output)
            }
            output += "}"
        }
    }

    private static func quoted(_ value: String) throws(SimPayCheckoutError) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        guard let data = try? encoder.encode(value), let text = String(data: data, encoding: .utf8) else {
            throw SimPayCheckoutError(.internal, message: "Request body could not be encoded")
        }
        return text
    }
}
