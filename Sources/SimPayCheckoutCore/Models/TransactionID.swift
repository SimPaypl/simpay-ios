import Foundation

/// Identifier of a SimPay transaction: a UUID in its canonical 36 character form.
///
/// The original spelling is preserved because the value is sent back to the API
/// unchanged; comparison is therefore exact.
public struct TransactionID: Sendable, Hashable, CustomStringConvertible {

    public let rawValue: String

    /// Returns `nil` unless `rawValue` is a canonical UUID
    /// (`xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`, hexadecimal digits in either case).
    public init?(_ rawValue: String) {
        // The length check rules out the braced and unhyphenated forms some parsers accept.
        guard rawValue.utf8.count == 36, UUID(uuidString: rawValue) != nil else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}
