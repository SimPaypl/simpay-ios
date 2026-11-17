# SimPay Integration Host (test only)

A minimal iOS app used to test the SDK end to end on the simulator or a device. It is
**not** the demo app and is not part of the `SimPayCheckout` product: it lives outside
`Package.swift` and references the package locally.

- All API answers come from `MockSimPayAPI` through the DEBUG-only
  `@_spi(Testing) SimPayCheckout(configuration:sessionProvider:testTransport:)`. No request
  leaves the device and no payment can happen. Release builds of the SDK do not contain
  this hook.
- Return URL scheme: `simpayhost://payment-return`.
- Scenarios: `-scenario blikPaid | blikRejectedThenPaid | blikPending | redirectPaidAfterReturn |
  redirectPending | createTimeout | sessionExpiredThenPaid | statusOffline | channelsError`.

```bash
cd IntegrationHost
TEST_RUNNER_SIMPAY_SCREENSHOT_DIR=/tmp/simpay-host-shots \
xcodebuild test -project SimPayIntegrationHost.xcodeproj -scheme SimPayIntegrationHost \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro'
```

Simulate a bank return while the payment page is open:

```bash
xcrun simctl openurl booted 'simpayhost://payment-return?result=success'
```
