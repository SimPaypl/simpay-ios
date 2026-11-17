import Testing
@testable import SimPayCheckoutCore

@Suite("Package configuration")
struct PackageConfigurationTests {

    @Test("SDK version follows Semantic Versioning (MAJOR.MINOR.PATCH with an optional pre-release)")
    func versionIsSemantic() {
        let pattern = #"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z-]+(\.[0-9A-Za-z-]+)*)?$"#
        #expect(SDKInfo.version.range(of: pattern, options: .regularExpression) != nil)
    }
}
