# Security policy

`SimPayCheckout` handles payments, so security reports get priority.

## Reporting a vulnerability

Email **security@simpay.pl**. Please do not open a public issue, pull request or
discussion for a vulnerability.

Include, if you can:

- the SDK version (`SimPayCheckoutSDK.version`) and iOS version;
- what an attacker can do and the conditions needed;
- steps or code to reproduce it.

Never send real API keys, session tokens, BLIK codes or payer data; use test values.

## Supported versions

Security fixes are released for the latest version only.

## Scope

In scope: this repository (the SDK, `DemoApp` and `IntegrationHost`). Issues in the SimPay
API or the merchant backend that issues sessions should still be sent to the address above;
they will be forwarded to the right team.
