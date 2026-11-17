extension TransactionStatus {

    /// Maps a status of a known transaction to the result that ends the flow, or `nil`
    /// while the transaction is still being processed and should be checked again.
    ///
    /// Mirrors `terminalStateFor` and `currentResult` of the Android SDK:
    /// - `transaction_paid` is the only success;
    /// - failure, fraud, expired and refunded are definitive failures;
    /// - `transaction_fraud_possibility` and unrecognised statuses are pending,
    ///   because neither proves anything.
    package func finalResult(for transactionID: TransactionID) -> SimPayCheckoutResult? {
        switch phase {
        case .processing:
            return nil
        case .paid:
            return .succeeded(transactionID: transactionID, status: self)
        case .verification:
            return .pending(transactionID: transactionID, status: self, reason: .verificationRequired)
        case .unrecognized:
            return .pending(transactionID: transactionID, status: self, reason: .unrecognizedStatus)
        case .failed:
            return failure(transactionID, message: "Payment was not completed")
        case .fraud:
            return failure(transactionID, message: "Transaction was rejected")
        case .expired:
            return failure(transactionID, message: "Transaction expired")
        case .refunded:
            return failure(transactionID, message: "Transaction refunded")
        }
    }

    private func failure(_ transactionID: TransactionID, message: String) -> SimPayCheckoutResult {
        .failed(
            SimPayCheckoutError(.transactionFailed, message: message),
            transactionID: transactionID,
            status: self
        )
    }
}

extension SimPayCheckoutResult.PendingReason {

    /// Why a transaction is still pending when the flow ends without a final status:
    /// `.inProgress` if the last status read says so, `.statusUnavailable` otherwise.
    package init(lastStatus: TransactionStatus?) {
        self = lastStatus?.phase == .processing ? .inProgress : .statusUnavailable
    }
}
