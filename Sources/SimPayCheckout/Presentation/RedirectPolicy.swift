import Foundation

/// Checks applied before a payment page is opened.
///
/// The API client already keeps only `https` redirect URLs; this is the last check before
/// the URL reaches a browser, so it is repeated here with stricter rules.
package enum RedirectURLPolicy {

    package static let maximumLength = 4096

    /// `https`, a host, no embedded credentials, a reasonable length.
    package static func isAllowed(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https",
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil,
              url.absoluteString.utf8.count <= maximumLength else {
            return false
        }
        return true
    }
}

/// Decides whether a URL opened in the app is the return from this checkout.
///
/// A return URL is a signal only: it tells the SDK that the payer came back, so the
/// status of the known transaction is read from the API. Its query and fragment (for
/// example `?result=success`) are never trusted and never inspected.
///
/// A URL matches when scheme, host, port and path equal one of the order's return URLs
/// (scheme and host case-insensitively). Web schemes other than `https` and schemes that
/// can carry code or local content are always refused.
package struct ReturnURLMatcher: Sendable {

    private static let refusedSchemes: Set<String> = ["http", "javascript", "data", "file", "about", "blob", "vbscript"]

    private let expected: [URL]

    package init(returnURLs: SimPayReturnURLs?) {
        expected = returnURLs.map { [$0.success, $0.failure] } ?? []
    }

    package func matches(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), !Self.refusedSchemes.contains(scheme),
              url.user == nil, url.password == nil else {
            return false
        }
        return expected.contains { Self.sameTarget($0, url) }
    }

    private static func sameTarget(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && (lhs.host ?? "").lowercased() == (rhs.host ?? "").lowercased()
            && lhs.port == rhs.port
            && normalizedPath(lhs) == normalizedPath(rhs)
    }

    private static func normalizedPath(_ url: URL) -> String {
        let path = url.path
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : (path.isEmpty ? "/" : path)
    }
}
