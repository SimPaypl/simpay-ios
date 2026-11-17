/// Final outcome reported to the integrating application.
///
/// No value is proof of payment. The merchant backend must confirm the payment from the
/// SimPay webhook (status, amount, currency, `control`, service id) before releasing
/// goods. These cases only tell the app what to show the payer.
public enum SimPayCheckoutResult: Sendable, Hashable {

    /// The API reported `transaction_paid`.
    case succeeded(transactionID: TransactionID, status: TransactionStatus)

    /// A transaction exists, but its final outcome is not known yet. It may still
    /// complete; never treat this as a failure, and never as a payment.
    case pending(transactionID: TransactionID, status: TransactionStatus?, reason: PendingReason)

    /// The payment definitely did not succeed, or the checkout failed before any
    /// transaction could have been created.
    case failed(SimPayCheckoutError, transactionID: TransactionID?, status: TransactionStatus?)

    /// The SDK cannot tell whether a transaction was created, for example when a create
    /// request was sent but no usable response arrived. No transaction id is known.
    /// The SDK never repeats such a request; the merchant backend must reconcile the
    /// order (by `control`) from webhooks.
    case outcomeUnknown(SimPayCheckoutError)

    /// The payer closed the checkout before any transaction was requested.
    case cancelled

    /// Transaction identifier, when one is known.
    public var transactionID: TransactionID? {
        switch self {
        case .succeeded(let id, _), .pending(let id, _, _):
            return id
        case .failed(_, let id, _):
            return id
        case .outcomeUnknown, .cancelled:
            return nil
        }
    }
}

extension SimPayCheckoutResult {

    /// Why a transaction is reported as pending.
    ///
    /// An extensible struct with stable `snake_case` raw values, shared with the Android
    /// SDK and the cross-platform adapters.
    public struct PendingReason: RawRepresentable, Sendable, Hashable, CustomStringConvertible {

        public let rawValue: String

        public init(rawValue: String) {
            self.rawValue = rawValue
        }

        public var description: String { rawValue }

        /// The last known status is still in progress (new, generated or confirmed).
        public static let inProgress = PendingReason(rawValue: "in_progress")
        /// `transaction_fraud_possibility`: the transaction is under verification.
        public static let verificationRequired = PendingReason(rawValue: "verification_required")
        /// The API returned a status this SDK version does not recognise.
        public static let unrecognizedStatus = PendingReason(rawValue: "unrecognized_status")
        /// The status could not be read, or was not checked before the checkout closed.
        public static let statusUnavailable = PendingReason(rawValue: "status_unavailable")
    }
}

extension SimPayCheckoutResult.PendingReason {

    /// Every reason defined by this SDK version. Used by contract tests.
    package static let allKnown: [SimPayCheckoutResult.PendingReason] = [
        .inProgress, .verificationRequired, .unrecognizedStatus, .statusUnavailable,
    ]
}
