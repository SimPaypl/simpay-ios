# SimPay Demo Shop

A sample SwiftUI shop with one product and a **Pay** button that opens the real SDK
payment sheet. It is not part of the SDK.

## Run

1. Open `DemoApp/SimPayDemo.xcodeproj` (keep it inside the `simpay-ios` folder: it uses
   the package from the parent directory).
2. Scheme **SimPayDemo**, an iPhone simulator, **⌘R**.
3. Choose a mode (and a scenario in FAKE), tap **Zapłać przez SimPay**; the result appears
   below the button.

If Xcode reports `Missing package product SimPayCheckout`: **File → Packages → Reset
Package Caches**.

## Modes

| Mode | API | What you need |
|---|---|---|
| **FAKE** | simulated on the device, nothing is sent to SimPay | nothing |
| **API KEY** | real SimPay API; the app creates the session with an API key | a **test** service and `Config/SimPayDebug.local.xcconfig` |

Both modes exist only in Debug builds. In a real app the session comes from your backend
(see the [integration guide](../INTEGRATION.md)); an API key never belongs in an app.

**API KEY** needs the SimPay merchant panel prepared: mobile SDK enabled and the
URL scheme **`simpay-demo`** registered. Without the scheme the API refuses the
transaction with `validation_failed`.

### API KEY setup

Copy `Config/SimPayDebug.local.xcconfig.example` to `Config/SimPayDebug.local.xcconfig`
(git-ignored; do not edit the `.example`) and fill in:

```
SIMPAY_DEBUG_SERVICE_ID = <service id>
SIMPAY_DEBUG_API_KEY    = <test API key>
SIMPAY_DEBUG_PAYER_IP   = <public IP of the test device>
```

Then **Product → Clean Build Folder** and run again. Use only a test key: anyone with a
Debug build can extract it. Release builds do not contain this mode.

## FAKE scenarios

| Scenario | Expected result |
|---|---|
| `blikPaid` | success |
| `blikRejectedThenPaid` | first code rejected, second succeeds |
| `blikPending` | pending; closing the sheet returns `pending` |
| `redirectPaidAfterReturn` | bank page, then success after the return URL |
| `redirectPending` | bank page, stays pending |
| `createTimeout` | `outcomeUnknown`, no second transaction |
| `sessionExpiredThenPaid` | session refreshed after HTTP 401, then success |
| `statusOffline` | pending after the 120 s polling budget, never failed |
| `statusFailed` | failed with the transaction id |
| `verificationRequired` | pending, never success |
| `channelsError` | error with a retry button |

Any six digits work as a BLIK code. To simulate the bank sending the payer back, while the
payment page is open run:

```bash
xcrun simctl openurl booted 'simpay-demo://payment-return?result=success'
```

## Tests

```bash
xcodebuild test -project DemoApp/SimPayDemo.xcodeproj -scheme SimPayDemo \
  -destination 'platform=iOS Simulator,name=iPhone 16'
```

A success shown by the demo is only a UI result: a real shop releases goods after its
backend verified the SimPay webhook.
