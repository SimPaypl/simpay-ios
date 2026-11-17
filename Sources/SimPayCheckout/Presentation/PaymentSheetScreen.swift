import Foundation

/// What the payment sheet shows, derived only from ``CheckoutState``.
///
/// The sheet adds no payment logic: every screen is a projection of the engine state, and
/// every action is forwarded to the engine, which decides whether it is allowed.
package enum PaymentSheetScreen: Sendable, Hashable {

    package enum Progress: Sendable, Hashable {
        case preparingPayment
        case sendingCode
        case checkingStatus
    }

    case loadingChannels
    case channels(ChannelList)
    case emptyChannels
    /// `canChangeMethod` is `false` while a transaction is kept for the next code.
    case blikEntry(BlikEntry, canChangeMethod: Bool)
    case progress(Progress)
    /// The BLIK prompt stays for the whole time the payer decides in the bank.
    case awaitingBank
    /// The payment page of an existing transaction is shown, or about to be.
    case redirecting
    case failure(SimPayCheckoutError, canRetry: Bool)
    case result(SimPayCheckoutResult)

    /// Mutating requests are in flight: the sheet must not be dismissed.
    package var locksDismissal: Bool {
        switch self {
        case .progress(.preparingPayment), .progress(.sendingCode): return true
        default: return false
        }
    }

    package init(_ state: CheckoutState) {
        switch state {
        case .idle, .loadingChannels:
            self = .loadingChannels
        case .channels(let options):
            self = options.isEmpty
                ? .emptyChannels
                : .channels(ChannelList(options))
        case .creatingTransaction:
            self = .progress(.preparingPayment)
        case .enteringBlikCode(let entry):
            self = .blikEntry(entry, canChangeMethod: entry.transactionID == nil)
        case .submittingBlikCode:
            self = .progress(.sendingCode)
        case .awaitingBankConfirmation:
            self = .awaitingBank
        case .redirecting:
            self = .redirecting
        case .checkingStatus:
            self = .progress(.checkingStatus)
        case .failed(let error, let canRetry):
            self = .failure(error, canRetry: canRetry)
        case .finished(let result):
            self = .result(result)
        }
    }
}

/// The channel list as presented: BLIK on top, other channels below.
package struct ChannelList: Sendable, Hashable {

    package struct Row: Sendable, Hashable, Identifiable {
        package let id: String
        package let name: String
        package let imageURL: URL?
        package let isBlik: Bool
        /// `nil` when the channel can be used for the order.
        package let unavailability: ChannelOption.Unavailability?

        package var isSelectable: Bool { unavailability == nil }
    }

    package let blik: Row?
    package let others: [Row]

    package init(_ options: [ChannelOption]) {
        let rows = options.map { option in
            Row(
                id: option.id,
                name: option.channel.name,
                imageURL: option.channel.imageURL,
                isBlik: option.isBlik,
                unavailability: option.unavailability
            )
        }
        blik = rows.first(where: \.isBlik)
        others = rows.filter { !$0.isBlik }
    }
}
