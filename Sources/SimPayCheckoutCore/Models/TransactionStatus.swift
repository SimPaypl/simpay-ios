/// Transaction status as reported by the SimPay API.
///
/// The raw API value is always preserved, so a status unknown to this SDK version can be
/// diagnosed and is never silently treated as success. Modelled as an extensible struct
/// so that statuses added by the API later do not break integrators' `switch` statements.
public struct TransactionStatus: RawRepresentable, Sendable, Hashable, CustomStringConvertible {

    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }

    public static let new = TransactionStatus(rawValue: "transaction_new")
    public static let generated = TransactionStatus(rawValue: "transaction_generated")
    public static let confirmed = TransactionStatus(rawValue: "transaction_confirmed")
    public static let paid = TransactionStatus(rawValue: "transaction_paid")
    public static let failure = TransactionStatus(rawValue: "transaction_failure")
    public static let fraud = TransactionStatus(rawValue: "transaction_fraud")
    public static let fraudPossibility = TransactionStatus(rawValue: "transaction_fraud_possibility")
    public static let expired = TransactionStatus(rawValue: "transaction_expired")
    public static let refunded = TransactionStatus(rawValue: "transaction_refunded")

    /// Whether this SDK version recognises the status.
    public var isRecognized: Bool { phase != .unrecognized }
}

extension TransactionStatus {

    /// Meaning of a status for the checkout flow.
    ///
    /// Matching is exact and case sensitive, mirroring `TransactionStatus.fromRaw` of the
    /// Android SDK: any other spelling is `unrecognized`, which never means success.
    package enum Phase: String, Sendable, CaseIterable {
        /// The payment is still being processed; keep checking.
        case processing
        /// `transaction_fraud_possibility`: neither a success nor a failure.
        case verification
        case paid
        case failed
        case expired
        case refunded
        case fraud
        case unrecognized
    }

    package var phase: Phase {
        switch rawValue {
        case Self.new.rawValue, Self.generated.rawValue, Self.confirmed.rawValue:
            return .processing
        case Self.fraudPossibility.rawValue:
            return .verification
        case Self.paid.rawValue:
            return .paid
        case Self.failure.rawValue:
            return .failed
        case Self.expired.rawValue:
            return .expired
        case Self.refunded.rawValue:
            return .refunded
        case Self.fraud.rawValue:
            return .fraud
        default:
            return .unrecognized
        }
    }
}
