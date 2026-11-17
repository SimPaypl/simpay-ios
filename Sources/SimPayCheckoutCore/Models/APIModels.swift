import Foundation

/// Payment channel returned by `GET /payment/{serviceId}/mobile-sdk/channels`.
package struct PaymentChannel: Sendable, Hashable {

    /// Channel identifier, also used as `directChannel` when creating a transaction.
    /// Numeric identifiers sent by the API are kept as text.
    package let id: String
    /// Display name; falls back to `id` when the API sends none.
    package let name: String
    package let type: String?
    /// Logo address. Only `https` URLs are kept.
    package let imageURL: URL?
    package let currencies: [String]
    /// Amount limits, parsed from the API text without binary floating point.
    package let minimumAmount: Decimal?
    package let maximumAmount: Decimal?

    package init(
        id: String,
        name: String,
        type: String? = nil,
        imageURL: URL? = nil,
        currencies: [String] = [],
        minimumAmount: Decimal? = nil,
        maximumAmount: Decimal? = nil
    ) {
        self.id = id
        self.name = name
        self.type = type
        self.imageURL = imageURL
        self.currencies = currencies
        self.minimumAmount = minimumAmount
        self.maximumAmount = maximumAmount
    }
}

/// Everything needed for `POST /payment/{serviceId}/transactions`.
///
/// Every channel offered by the SDK is created as a direct channel, so the API requires
/// the payer context (`customer.email`, `customer.ip`, `customer.countryCode`) and
/// `antifraud.useragent`. All of it is checked here, before anything is sent.
package struct CreateTransactionRequest: Sendable {

    package let order: SimPayOrder
    package let directChannel: String
    package let payerIP: String
    package let userAgent: String

    /// - Parameters:
    ///   - payerIP: public IP from the session, or the order override. Never a device
    ///     interface address; the SDK does not invent one.
    package init(
        order: SimPayOrder,
        directChannel: String,
        payerIP: String?,
        userAgent: String
    ) throws(SimPayCheckoutError) {
        guard !directChannel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SimPayCheckoutError(.internal, message: "directChannel must not be blank")
        }
        guard let payerIP, !payerIP.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SimPayCheckoutError(
                .missingPayerIP,
                message: "The session provider did not supply the payer IP required for direct channels"
            )
        }
        guard !userAgent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SimPayCheckoutError(.internal, message: "antifraud.useragent must not be blank")
        }

        self.order = order
        self.directChannel = directChannel
        self.payerIP = payerIP
        self.userAgent = userAgent
    }
}

extension CreateTransactionRequest: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {

    package var description: String {
        "CreateTransactionRequest(order: \(order), directChannel: \(directChannel), payerIP: <redacted>)"
    }

    package var debugDescription: String { description }

    package var customMirror: Mirror {
        Mirror(self, children: ["order": order, "directChannel": directChannel], displayStyle: .struct)
    }
}

/// Result of a successful `POST /payment/{serviceId}/transactions`.
package struct CreatedTransaction: Sendable, Hashable {

    package let transactionID: TransactionID

    /// Payment page for redirect channels. `nil` when the API sent no usable `https`
    /// address; the transaction still exists and must be tracked by its id.
    package let redirectURL: URL?
}

/// Status snapshot returned by `GET /payment/{serviceId}/mobile-sdk/transactions/{id}`.
package struct TransactionSnapshot: Sendable, Hashable {
    package let transactionID: TransactionID
    package let status: TransactionStatus
}
