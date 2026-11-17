// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SimPayCheckout",
    // Strings of the payment sheet are English by default, with a Polish translation.
    defaultLocalization: "en",
    platforms: [
        .iOS(.v16),
        // macOS is declared only so the platform independent code can be built and
        // tested with `swift test` on a Mac host. The SDK is not offered for macOS apps.
        .macOS(.v13),
    ],
    products: [
        // The only public product. Public domain models live in SimPayCheckoutCore and
        // are re-exported by SimPayCheckout; internals are shared through `package` access.
        .library(
            name: "SimPayCheckout",
            targets: ["SimPayCheckout"]
        ),
    ],
    targets: [
        // Payment logic with no UIKit or SwiftUI dependency.
        .target(
            name: "SimPayCheckoutCore"
        ),
        // Public iOS integration layer: entry point, payment sheet and platform glue.
        .target(
            name: "SimPayCheckout",
            dependencies: ["SimPayCheckoutCore"],
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "SimPayCheckoutCoreTests",
            dependencies: ["SimPayCheckoutCore"]
            // Contract data is read from the repository's `Contract/` directory at test
            // time (see `Fixture`), so there is exactly one copy to keep in sync.
        ),
        // Payment sheet, public facade and localization. UIKit tests run on the iOS
        // simulator only; the rest also runs with `swift test` on macOS.
        .testTarget(
            name: "SimPayCheckoutTests",
            dependencies: ["SimPayCheckout", "SimPayCheckoutCore"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
