# Integration guide

From zero to a working payment sheet. Requirements: iOS 16+, Xcode 16+, a SimPay service
and a backend you control.

1. [Prepare the merchant panel](#1-prepare-the-merchant-panel)
2. [Install the package](#2-install-the-package)
3. [Issue sessions from your backend](#3-issue-sessions-from-your-backend)
4. [Implement `SimPaySessionProvider`](#4-implement-simpaysessionprovider)
5. [Create the checkout and an order](#5-create-the-checkout-and-an-order)
6. [Present the sheet](#6-present-the-sheet)
7. [Handle return URLs](#7-handle-return-urls)
8. [Handle the result](#8-handle-the-result)
9. [Recover after the app was terminated](#9-recover-after-the-app-was-terminated)
10. [Checklist](#10-checklist)

## 1. Prepare the merchant panel

Nothing works until the service is set up in the SimPay merchant panel:

- **Turn on mobile SDK support.** Without it no session is issued and the sheet fails
  before showing any payment method.
- **Register your URL scheme**, identical in all three places:

```
merchant panel        Info.plist (URL Types)          SimPayReturnURLs
--------------        ----------------------          ----------------
scheme: myshop   ↔    CFBundleURLSchemes: myshop  ↔   "myshop://payment-return?..."
```

If the panel does not know the scheme, the API refuses the transaction with
`validation_failed`. If Info.plist and `returnURLs` differ, there is no error at all: the
payer simply never returns to the app. Pick a specific scheme (for example
`pl.example.shop`), because any app can declare the same one.

## 2. Install the package

Xcode: **File → Add Package Dependencies…** → `https://github.com/SimPaypl/simpay-ios.git`
→ *Up to Next Major Version* from `1.0.0` → add **SimPayCheckout** to your app target.

`import SimPayCheckout` is all you need; it includes every public model.

## 3. Issue sessions from your backend

The SimPay API key **must never be in the app**. Your backend exchanges it for a
short-lived (about 15 minutes) `mobsdk_` token:

```
POST https://api.simpay.pl/payment/{serviceId}/mobile-sdk/session
Authorization: Bearer <merchant API key>
```

Expose your own endpoint to the app, behind your user authentication and rate-limited:

```
POST https://shop.example.com/api/simpay/session
→ 200 {"token": "mobsdk_…", "expiresAt": "2026-11-06T12:15:00Z", "payerIp": "198.51.100.7"}
```

- `payerIp`: the payer's public IP as seen by your backend. Required by SimPay; if you
  cannot provide it, set `payerIPOverride` on the order.
- `expiresAt` (optional): the SDK refreshes the session 60 s before it expires.

## 4. Implement `SimPaySessionProvider`

```swift
import Foundation
import SimPayCheckout

struct BackendSessionProvider: SimPaySessionProvider {
    let endpoint = URL(string: "https://shop.example.com/api/simpay/session")!

    func provideSession() async throws -> SimPaySession {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("Bearer \(UserSession.current.accessToken)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw SimPayCheckoutError(.sessionFailed)
        }
        struct Payload: Decodable { let token: String; let expiresAt: Date?; let payerIp: String? }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let payload = try decoder.decode(Payload.self, from: data)
        return try SimPaySession(token: payload.token, expiresAt: payload.expiresAt, payerIP: payload.payerIp)
    }
}
```

- The SDK calls it when it needs a session (first request, before expiry, once after
  HTTP 401), never twice at the same time. Always return a fresh session.
- Throw a `SimPayCheckoutError` (for example `.noInternet`) to choose what the payer sees;
  any other error becomes `session_failed`.

## 5. Create the checkout and an order

```swift
let checkout = SimPayCheckout(
    configuration: SimPayConfiguration(serviceID: "a1b2c3d4", merchantDisplayName: "My Shop")!,
    sessionProvider: BackendSessionProvider()
)

let order = try SimPayOrder(
    amount: Decimal(string: "149.99")!,          // from text, never from a Double
    currency: "PLN",
    transactionDescription: "Order #1042",       // up to 64 characters
    control: "order-1042",                       // your order id, sent back in the webhook
    customerEmail: "payer@example.com",
    returnURLs: SimPayReturnURLs(
        success: URL(string: "myshop://payment-return?result=success")!,
        failure: URL(string: "myshop://payment-return?result=failure")!
    )
)
```

- Create `SimPayCheckout` once (for example in your app model) and reuse it. It runs on
  the main actor. `SimPayConfiguration` is `nil` for a malformed service id.
- `SimPayOrder` validates everything up front and throws `invalid_order`, or
  `missing_country_code` for a currency without a default country (for example EUR
  without `customerCountryCode`).
- Always set a unique `control`: your backend matches webhooks with it.

## 6. Present the sheet

**SwiftUI**

```swift
struct CheckoutView: View {
    let checkout: SimPayCheckout
    let order: SimPayOrder
    @State private var isPaying = false

    var body: some View {
        Button("Pay 149,99 zł") { isPaying = true }
            .simPayCheckout(
                isPresented: $isPaying,
                checkout: checkout,
                order: order,
                onTransactionCreated: { id in PendingPayments.store(id) }
            ) { result in
                handle(result)
            }
    }
}
```

**UIKit**

```swift
@objc func payTapped() {
    Task {
        let result = await checkout.present(order, from: self) { id in PendingPayments.store(id) }
        handle(result)
    }
}
```

A completion handler variant is available too:
`checkout.present(order, from: self, onTransactionCreated: nil) { result in … }`.

- The result arrives **exactly once**; with SwiftUI, `isPresented` goes back to `false`.
- The sheet cannot be closed while a payment request is being sent. Setting
  `isPresented = false` does not close it either.
- A second `present` while a sheet is shown returns `.failed(already_presented)`.

## 7. Handle return URLs

Bank transfers open the bank's payment page in an in-app browser. When the payer comes
back through your return URL, pass it to the SDK. The SDK then reads the payment status
from the API: **a return URL is never a payment confirmation**, and its query is ignored.

Register the scheme in `Info.plist` (Xcode: target → Info → URL Types):

```xml
<key>CFBundleURLTypes</key>
<array>
  <dict>
    <key>CFBundleURLSchemes</key>
    <array><string>myshop</string></array>
  </dict>
</array>
```

Forward opened URLs. `handleReturnURL` returns `false` for URLs that are not for the SDK:

```swift
// SwiftUI
WindowGroup {
    RootView()
        .onOpenURL { url in
            if SimPayCheckout.handleReturnURL(url) { return }
            router.open(url)                                  // your own links
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
            _ = SimPayCheckout.handleUserActivity(activity)   // Universal Links
        }
}

// UIKit (scene delegate)
func scene(_ scene: UIScene, openURLContexts contexts: Set<UIOpenURLContext>) {
    for context in contexts where !SimPayCheckout.handleReturnURL(context.url) {
        router.open(context.url)
    }
}
```

Without scenes, call the same methods from `application(_:open:options:)` and
`application(_:continue:restorationHandler:)`.

| Situation | What the SDK does |
|---|---|
| Payer comes back through the return URL | closes the page and reads the status |
| Payer closes the page | reads the status; the payer can open the same page again |
| Payer pays in a banking app and returns by hand | reads the status when the app is active again |
| The bank never sends the payer back | result `pending` with the transaction id |

**Universal Links** (`https://…`) work the same way but need the Associated Domains
capability and an `apple-app-site-association` file on your domain.

**Polish texts**: iOS shows the sheet in Polish only if your app declares Polish
(`CFBundleLocalizations` with `en` and `pl`, or a Polish localization in the project).

## 8. Handle the result

```swift
func handle(_ result: SimPayCheckoutResult) {
    switch result {
    case .succeeded(let id, _):
        // The API reported the payment as paid. Release goods after your backend's webhook.
        showSuccess(id)
    case .pending(let id, _, _):
        // Not final yet; it may still complete. Never treat it as a failure.
        showPending(id)
    case .failed(let error, _, _):
        // Definitely not paid; the payer may try again.
        showFailure(error.code)
    case .outcomeUnknown:
        // It is unknown whether a transaction exists. Do NOT offer to pay again
        // until your backend has checked the order by `control`.
        showCheckOrderStatus()
    case .cancelled:
        // Closed before any transaction was created. Nothing was charged.
        break
    }
}
```

| Result | Can the payer pay again right away? |
|---|---|
| `succeeded` | no |
| `pending` | no, wait for the webhook |
| `failed` | yes |
| `outcomeUnknown` | **no**, check the order first |
| `cancelled` | yes |

`error.code` is a stable string, the same as in the Android SDK. Most common codes:

| Code | Cause |
|---|---|
| `no_internet`, `timeout`, `service_unavailable`, `rate_limited` | network or API; the payer can retry later |
| `session_failed`, `unauthorized` | your session endpoint or token |
| `channels_failed` | wrong service id, or mobile SDK disabled in the panel |
| `validation_failed`, `invalid_order`, `missing_payer_ip`, `missing_country_code` | order data, or a URL scheme unknown to the panel |
| `blik_rejected` | the BLIK code was rejected too many times |
| `already_presented`, `presentation_failed` | the sheet was presented twice, or from a hidden screen |

`error.message` is a developer diagnostic in English. Do not show it to payers. New codes
may be added, so keep a `default` branch when switching on codes.

**The result in the app is information for the payer. Only the SimPay webhook, verified by
your backend (signature, amount, currency, `control`, status `transaction_paid`), proves
a payment.**

## 9. Recover after the app was terminated

iOS may terminate the app while the payer is in the banking app; the result is then never
delivered. Store the id from `onTransactionCreated`, and on the next launch:

```swift
if let id = PendingPayments.storedID {                 // TransactionID("…") from a string
    let result = try await checkout.transactionStatus(of: id)
    handle(result)
}
```

## 10. Checklist

- [ ] Mobile SDK support turned on in the merchant panel.
- [ ] The same URL scheme in the panel, Info.plist and `returnURLs`; `handleReturnURL`
      wired.
- [ ] No SimPay API key in the app or its repository.
- [ ] Session endpoint requires a logged-in user and is rate-limited.
- [ ] Unique `control` per order.
- [ ] Transaction id from `onTransactionCreated` stored; status checked on next launch.
- [ ] `outcomeUnknown` does not offer an immediate second payment.
- [ ] Goods released only after the verified webhook.

Questions or problems: open an issue on
[GitHub](https://github.com/SimPaypl/simpay-ios/issues). Security issues: see
[SECURITY.md](SECURITY.md).
