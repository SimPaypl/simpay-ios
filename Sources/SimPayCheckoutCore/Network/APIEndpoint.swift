import Foundation

/// Where the SDK sends its requests.
///
/// Production is the only environment available to integrators. A different base URL
/// exists only for SDK tests and, later, a debug-only demo configuration.
package struct APIEnvironment: Sendable, Hashable {

    package static let productionBaseURL = URL(string: "https://api.simpay.pl")!

    package let baseURL: URL
    /// Short service identifier (`:uuid_short`), the first 8 characters of the service UUID.
    package let serviceID: String

    /// Returns `nil` when the base URL is not `https` or the service id is not a safe
    /// path segment, so no request can ever be built from untrusted text.
    package init?(serviceID: String, baseURL: URL = APIEnvironment.productionBaseURL) {
        guard baseURL.scheme?.lowercased() == "https", baseURL.host?.isEmpty == false else { return nil }
        guard Self.isSafePathSegment(serviceID) else { return nil }
        self.baseURL = baseURL
        self.serviceID = serviceID
    }

    /// Letters, digits, `-` and `_` only; 1 to 64 characters.
    private static func isSafePathSegment(_ value: String) -> Bool {
        let bytes = value.utf8
        guard (1...64).contains(bytes.count) else { return false }
        return bytes.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: "-") || byte == UInt8(ascii: "_")
        }
    }
}

/// The four endpoints used by the mobile SDK.
///
/// The session endpoint is absent on purpose: it requires the merchant API key and is
/// called by the merchant backend only.
package enum APIEndpoint: Sendable, Hashable {

    /// `GET /payment/{serviceId}/mobile-sdk/channels`
    case channels
    /// `POST /payment/{serviceId}/transactions`
    case createTransaction
    /// `POST /payment/{serviceId}/blik/level0/{transactionId}`
    case submitBlikCode(TransactionID)
    /// `GET /payment/{serviceId}/mobile-sdk/transactions/{transactionId}`
    case transactionStatus(TransactionID)

    package var method: String {
        isMutating ? "POST" : "GET"
    }

    /// Mutating requests may create state on the server. They are never repeated
    /// automatically and an unclear outcome is reported as `outcome_unknown`.
    package var isMutating: Bool {
        switch self {
        case .createTransaction, .submitBlikCode: return true
        case .channels, .transactionStatus: return false
        }
    }

    /// Short name for diagnostics; never contains identifiers or payload values.
    package var operationName: String {
        switch self {
        case .channels: return "GET channels"
        case .createTransaction: return "POST transactions"
        case .submitBlikCode: return "POST blik/level0"
        case .transactionStatus: return "GET transaction status"
        }
    }

    /// Path segments after the base URL. Both the service id and the transaction id are
    /// validated to contain only path-safe characters.
    package func pathSegments(serviceID: String) -> [String] {
        switch self {
        case .channels:
            return ["payment", serviceID, "mobile-sdk", "channels"]
        case .createTransaction:
            return ["payment", serviceID, "transactions"]
        case .submitBlikCode(let id):
            return ["payment", serviceID, "blik", "level0", id.rawValue]
        case .transactionStatus(let id):
            return ["payment", serviceID, "mobile-sdk", "transactions", id.rawValue]
        }
    }

    package func url(in environment: APIEnvironment) -> URL {
        var url = environment.baseURL
        for segment in pathSegments(serviceID: environment.serviceID) {
            url.appendPathComponent(segment, isDirectory: false)
        }
        return url
    }
}
