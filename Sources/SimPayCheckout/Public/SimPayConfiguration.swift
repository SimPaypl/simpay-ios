import Foundation
import SimPayCheckoutCore

/// Configuration of the SimPay checkout.
///
/// Holds no secret: the merchant API key never belongs in the app. Access tokens are
/// supplied by a ``SimPaySessionProvider`` backed by the merchant backend.
public struct SimPayConfiguration: Sendable, Hashable {

    /// Short service identifier from the SimPay panel (`:uuid_short`).
    public let serviceID: String
    /// Name shown to the payer as the recipient of the payment.
    public let merchantDisplayName: String

    package let environment: APIEnvironment

    /// Returns `nil` when `serviceID` is not a valid service identifier. Requests always
    /// go to the production SimPay API.
    public init?(serviceID: String, merchantDisplayName: String) {
        guard let environment = APIEnvironment(serviceID: serviceID) else { return nil }
        self.init(merchantDisplayName: merchantDisplayName, environment: environment)
    }

    /// A different base URL, for SDK tests and the debug-only demo configuration.
    package init(merchantDisplayName: String, environment: APIEnvironment) {
        self.serviceID = environment.serviceID
        self.merchantDisplayName = merchantDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.environment = environment
    }
}
