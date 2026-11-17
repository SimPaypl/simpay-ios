/// Static information about the SDK build.
///
/// Kept in the core target so networking can later identify the SDK (for example in
/// the `User-Agent` header) without depending on the iOS integration layer.
package enum SDKInfo {

    /// Semantic version of the SDK. Must match the released git tag.
    package static let version = "1.0.0"

    /// Name used to identify the SDK towards the SimPay API.
    package static let name = "SimPayCheckoutiOS"
}
