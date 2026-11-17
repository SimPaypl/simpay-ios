import Foundation

/// Internal state of the checkout flow, observed by the payment sheet and the bridges.
///
/// Distinct from ``SimPayCheckoutResult``: states describe what is happening now, the
/// result is reported once when the checkout ends.
package enum CheckoutState: Sendable, Hashable {

    /// Created, nothing loaded yet.
    case idle
    case loadingChannels
    /// Channels to choose from, BLIK first, with availability for the order.
    case channels([ChannelOption])
    /// `POST /transactions` is in flight. Closing waits for it to finish.
    case creatingTransaction(channelID: String)
    /// The payer types a BLIK code. No transaction exists yet, unless a previous
    /// submission for an existing transaction was refused without effect.
    case enteringBlikCode(BlikEntry)
    /// `POST /blik/level0/{id}` is in flight. Closing waits for it to finish.
    case submittingBlikCode(TransactionID)
    /// The bank was asked to confirm. Not a payment yet.
    case awaitingBankConfirmation(TransactionID)
    /// The payment page is ready to be opened by the platform layer. Polling starts when
    /// the payer returns (see `AppLifecycleEvent`).
    case redirecting(TransactionID, URL)
    /// The transaction exists and its status is being verified by polling.
    case checkingStatus(TransactionID, lastStatus: TransactionStatus?)
    /// The checkout failed before any transaction exists. `canRetry` tells whether going
    /// back to the channel list makes sense.
    case failed(SimPayCheckoutError, canRetry: Bool)
    /// The checkout ended; the same result is returned by `close()`.
    case finished(SimPayCheckoutResult)
}

/// What the BLIK entry screen shows.
package struct BlikEntry: Sendable, Hashable {

    package enum Problem: Sendable, Hashable {
        /// The input is not six digits; nothing was sent.
        case invalidFormat
        /// The bank rejected the code. The rejected transaction is closed, so the next
        /// code starts a new payment.
        case codeRejected
        /// The submission was refused without effect (for example 401 or 429); the next
        /// code is sent for the same transaction.
        case submissionFailed(SimPayCheckoutError)
    }

    /// Transaction the next code will be sent for; `nil` means a new one is created.
    package let transactionID: TransactionID?
    package let problem: Problem?
    /// Rejections still allowed before the checkout stops.
    package let remainingAttempts: Int
}
