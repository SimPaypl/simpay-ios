/// Six digit BLIK code entered by the payer.
///
/// The code is a one-time payment credential. It is never printed, logged or exposed
/// through reflection: `description`, `debugDescription` and `dump()` show a mask only.
/// Only the networking layer reads the digits, through `package` access.
package struct BlikCode: Sendable {

    package static let length = 6

    /// The digits, for the request body only. Never log this value.
    package let digits: String

    /// Returns `nil` unless `raw` consists of exactly six ASCII digits.
    /// No trimming is performed; the UI is responsible for sanitising input.
    package init?(_ raw: String) {
        guard Self.isValid(raw) else { return nil }
        self.digits = raw
    }

    /// Validation without creating a value, for enabling the "Pay" button while typing.
    package static func isValid(_ raw: String) -> Bool {
        let bytes = raw.utf8
        return bytes.count == length
            && bytes.allSatisfy { $0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9") }
    }
}

extension BlikCode: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {

    package var description: String { "BlikCode(******)" }

    package var debugDescription: String { description }

    package var customMirror: Mirror { Mirror(self, children: [], displayStyle: .struct) }
}
