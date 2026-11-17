# SimPay Checkout iOS SDK

[![iOS](https://img.shields.io/badge/iOS-16.0+-blue.svg?logo=apple)](https://shields.io/)
[![Swift](https://img.shields.io/badge/Swift-6.0+-orange.svg?logo=swift)](https://shields.io/)
[![Xcode](https://img.shields.io/badge/Xcode-16+-informational.svg?logo=xcode)](https://shields.io/)
[![SPM](https://img.shields.io/badge/SPM-compatible-brightgreen.svg?logo=swift)](https://www.swift.org/documentation/package-manager/)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/license/mit)

Native [SimPay](https://simpay.pl) payment sheet for iOS apps: **BLIK Level 0** and **bank
transfers**, for SwiftUI and UIKit. No third-party dependencies. Texts in English and
Polish.

## How it works

```
App ──present(order)──▶ SimPayCheckout ──▶ payment sheet (channels, BLIK, bank page)
 ▲                            │
 │                            ├─ SimPaySessionProvider ──▶ your backend ──▶ SimPay session API
 │                            └─ SimPay API (channels, transaction, BLIK, status)
 └──── SimPayCheckoutResult ◀─┘          your backend ◀── SimPay webhook (proof of payment)
```

- Your **backend** keeps the SimPay API key and issues a short-lived `mobsdk_` session.
  The key never goes into the app.
- One `present` = one result. The SDK never repeats a request whose effect is unknown.
- Release goods **only after your backend verified the SimPay webhook**.

## Installation

Xcode: **File → Add Package Dependencies…** → `https://github.com/SimPaypl/simpay-ios.git`
→ *Up to Next Major Version* from `1.0.0` → add **SimPayCheckout** to your app target.

Or in `Package.swift`:

```swift
.package(url: "https://github.com/SimPaypl/simpay-ios.git", from: "1.0.0"),
// target dependency:
.product(name: "SimPayCheckout", package: "simpay-ios"),
```

## Quick start

```swift
import SimPayCheckout
import SwiftUI

let checkout = SimPayCheckout(
    configuration: SimPayConfiguration(serviceID: "a1b2c3d4", merchantDisplayName: "My Shop")!,
    sessionProvider: BackendSessionProvider()   // asks your backend for a session
)

struct PayButton: View {
    let order: SimPayOrder                      // try SimPayOrder(amount:customerEmail:...)
    @State private var isPaying = false

    var body: some View {
        Button("Pay") { isPaying = true }
            .simPayCheckout(isPresented: $isPaying, checkout: checkout, order: order) { result in
                print(result)                   // exactly one result per payment
            }
    }
}
```

Before the first payment, enable the mobile SDK and register your URL scheme in the
SimPay merchant panel. Everything else (session provider, UIKit, return URLs, results,
errors, recovery) is in the **[integration guide](INTEGRATION.md)**.

## Demo app

[`DemoApp/`](DemoApp/README.md) is a sample shop that runs offline with a simulated API,
or against SimPay with a test service.

## Development

```bash
swift test       # needs Xcode, not only the Command Line Tools
xcodebuild test -scheme SimPayCheckout -destination 'platform=iOS Simulator,name=iPhone 16'
scripts/release-checks.sh
```

`Contract/` holds test data shared with the [Android SDK](https://github.com/SimPaypl/simpay-android);
`api/` holds the public interface, regenerated on API changes:

```bash
xcodebuild build -scheme SimPayCheckout -configuration Release -destination 'generic/platform=iOS' \
  -derivedDataPath .build/api BUILD_LIBRARY_FOR_DISTRIBUTION=YES
for m in SimPayCheckout SimPayCheckoutCore; do
  cp .build/api/Build/Products/Release-iphoneos/$m.swiftmodule/arm64-apple-ios.swiftinterface api/$m.swiftinterface
done
```

## Security

Report vulnerabilities to **security@simpay.pl**, not through public issues. See
[SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
