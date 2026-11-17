import Foundation

/// Mobile SDK access session issued by the merchant backend.
///
/// The backend obtains it from `POST /payment/{serviceId}/mobile-sdk/session` using the
/// merchant API key, which must never be shipped in the app. The token is short lived
/// (about 15 minutes) and is kept in memory only.
///
/// The token and the payer IP are never exposed through `description`,
/// `debugDescription` or reflection.
public struct SimPaySession: Sendable {

    /// Full token as issued by the API, including the `mobsdk_` prefix.
    package let token: String

    /// Expiry reported by the backend, used to refresh the session ahead of time.
    public let expiresAt: Date?

    /// Public IP of the payer as observed by the merchant backend; required by direct
    /// channels. `nil` when not supplied or blank.
    package let payerIP: String?

    /// - Throws: ``SimPayCheckoutError/Code-swift.struct/sessionFailed`` when the token is
    ///   empty or contains whitespace or control characters, which could never form a
    ///   valid `Authorization` header.
    public init(token: String, expiresAt: Date? = nil, payerIP: String? = nil) throws(SimPayCheckoutError) {
        guard !token.isEmpty else {
            throw SimPayCheckoutError(.sessionFailed, message: "token must not be empty")
        }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard !token.unicodeScalars.contains(where: forbidden.contains) else {
            throw SimPayCheckoutError(.sessionFailed, message: "token must not contain whitespace or control characters")
        }

        self.token = token
        self.expiresAt = expiresAt
        // A blank IP is treated as missing, as on Android.
        self.payerIP = payerIP.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    /// `Authorization` header value. The scheme is always `Bearer`.
    package var authorizationHeaderValue: String { "Bearer \(token)" }
}

extension SimPaySession: CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {

    public var description: String {
        "SimPaySession(token: <redacted>, expiresAt: \(expiresAt.map { "\($0)" } ?? "nil"), "
            + "payerIP: \(payerIP == nil ? "nil" : "<redacted>"))"
    }

    public var debugDescription: String { description }

    public var customMirror: Mirror {
        Mirror(self, children: ["expiresAt": expiresAt as Any], displayStyle: .struct)
    }
}
