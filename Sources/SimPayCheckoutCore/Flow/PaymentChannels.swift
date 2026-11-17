import Foundation

/// BLIK Level 0 rules, identical to `BlikLevel0` of the Android SDK.
///
/// BLIK Level 0 is the only method completed inside the sheet; every other channel is
/// completed on the SimPay gateway after a redirect.
package enum BlikLevel0 {

    /// Value sent as `directChannel` for BLIK. Deliberately separate from the channel
    /// ids: the channels endpoint lists BLIK under its own id.
    package static let directChannel = "blik-level0"

    /// Number of explicitly rejected codes after which the checkout stops.
    ///
    /// Matches `MAX_BLIK_REJECTIONS` of the Android SDK. Every rejection creates a new
    /// transaction, so the limit protects the merchant account.
    package static let maximumRejections = 5

    /// Ids and types under which the channels endpoint reports BLIK.
    private static let blikIdentifiers: Set<String> = ["blik", "blik-level0", "blik_level_0"]

    /// Ids of the in-app variant, preferred when the API lists BLIK more than once.
    private static let level0Identifiers: Set<String> = ["blik-level0", "blik_level_0", "bliklevel0"]

    package static func supports(_ channel: PaymentChannel) -> Bool {
        blikIdentifiers.contains(normalized(channel.id))
            || channel.type.map { blikIdentifiers.contains(normalized($0)) } == true
    }

    private static func isLevel0(_ channel: PaymentChannel) -> Bool {
        level0Identifiers.contains(normalized(channel.id))
    }

    /// Reduces the BLIK entries to one. The API reports BLIK twice (redirect and Level 0);
    /// Level 0 wins, otherwise the first entry is kept. BLIK stays at the index of its
    /// first occurrence and every other channel keeps its order.
    package static func collapseDuplicates(_ channels: [PaymentChannel]) -> [PaymentChannel] {
        let blikEntries = channels.filter(supports)
        guard blikEntries.count > 1, let firstIndex = channels.firstIndex(where: supports) else {
            return channels
        }
        let preferred = blikEntries.first(where: isLevel0) ?? blikEntries[0]

        return channels.enumerated().compactMap { index, channel in
            guard supports(channel) else { return channel }
            return index == firstIndex ? preferred : nil
        }
    }

    private static func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

/// A channel prepared for presentation, with its availability for the current order.
package struct ChannelOption: Sendable, Hashable, Identifiable {

    package enum Unavailability: Sendable, Hashable {
        /// The channel lists currencies and the order currency is not one of them.
        case currencyNotSupported
        /// The order amount is outside the channel's limits.
        case amountOutOfRange
    }

    package let channel: PaymentChannel
    package let isBlik: Bool
    /// `nil` when the channel can be used for the order.
    package let unavailability: Unavailability?

    package var id: String { channel.id }
    package var isAvailable: Bool { unavailability == nil }

    /// Evaluates a channel against the order.
    ///
    /// Only data the API actually sent is used: an empty currency list or a missing
    /// limit never makes a channel unavailable.
    package init(channel: PaymentChannel, order: SimPayOrder) {
        self.channel = channel
        self.isBlik = BlikLevel0.supports(channel)

        let currencies = channel.currencies.map { $0.uppercased() }
        if !currencies.isEmpty, !currencies.contains(order.currency) {
            unavailability = .currencyNotSupported
        } else if let minimum = channel.minimumAmount, order.amount < minimum {
            unavailability = .amountOutOfRange
        } else if let maximum = channel.maximumAmount, order.amount > maximum {
            unavailability = .amountOutOfRange
        } else {
            unavailability = nil
        }
    }

    /// Collapses duplicate BLIK entries and puts BLIK first, as the Android sheet does.
    package static func prepare(_ channels: [PaymentChannel], for order: SimPayOrder) -> [ChannelOption] {
        let options = BlikLevel0.collapseDuplicates(channels).map { ChannelOption(channel: $0, order: order) }
        return options.filter(\.isBlik) + options.filter { !$0.isBlik }
    }
}
