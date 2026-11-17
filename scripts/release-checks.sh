#!/bin/bash
# Release safety checks for the SimPayCheckout SDK sources.
#
# Usage: scripts/release-checks.sh [path-to-release-build-products]
#
# Static checks always run. When a directory with Release build products is given, the
# compiled objects are also checked for test-only symbols. Exits non-zero on any finding.
set -euo pipefail

cd "$(dirname "$0")/.."
failed=0

fail() {
    echo "::error::$1"
    failed=1
}

echo "== No logging in SDK sources (tokens, BLIK codes and payer data must never be printed)"
if grep -rnE '\b(print|debugPrint|NSLog|os_log)\(|\bLogger\(' Sources | grep -vE '^\S+:[0-9]+:\s*///'; then
    fail "Logging call found in Sources/"
fi

echo "== No merchant API keys or real-looking session tokens"
if grep -rniE 'SIMPAY_API_KEY|api[_-]?key\s*[:=]\s*"[A-Za-z0-9_-]{16,}"' Sources DemoApp/SimPayDemo DemoApp/Config IntegrationHost/SimPayIntegrationHost; then
    fail "Possible API key in sources"
fi
# Only synthetic tokens are allowed: mobsdk_test_*, mobsdk_demo_only, mobsdk_integration_host.
if grep -rnoE 'mobsdk_[A-Za-z0-9_]{6,}' Sources Tests Contract DemoApp IntegrationHost \
    | grep -vE 'mobsdk_(test_[A-Za-z0-9_]*|demo_only|integration_host)$'; then
    fail "Non-synthetic mobsdk_ token found"
fi

echo "== Test hooks are compiled only in DEBUG"
testing_file=Sources/SimPayCheckout/Public/SimPayCheckout+Testing.swift
if [ "$(head -1 "$testing_file")" != "#if DEBUG && os(iOS)" ]; then
    fail "$testing_file must start with '#if DEBUG && os(iOS)'"
fi
if grep -rln '@_spi(Testing)' Sources | grep -v "$testing_file"; then
    fail "@_spi(Testing) used outside $testing_file"
fi

echo "== Production API address is fixed"
if ! grep -q 'https://api.simpay.pl' Sources/SimPayCheckoutCore/Network/APIEndpoint.swift; then
    fail "Production base URL not found in APIEndpoint.swift"
fi

echo "== Package manifest"
grep -q 'swift-tools-version: 6.0' Package.swift || fail "swift-tools-version must stay 6.0"
grep -q '.iOS(.v16)' Package.swift || fail "Minimum iOS must stay 16"
if grep -q '\.package(' Package.swift; then
    fail "The SDK must not have package dependencies"
fi

version=$(sed -nE 's/.*static let version = "([^"]+)".*/\1/p' Sources/SimPayCheckoutCore/Support/SDKInfo.swift)

echo "== Contract JSON is well formed"
while IFS= read -r file; do
    python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$file" || fail "Invalid JSON: $file"
done < <(find Contract -name '*.json')

if [ $# -ge 1 ]; then
    echo "== Release build products contain no test-only symbols"
    products="$1"
    if [ ! -d "$products" ]; then
        fail "Build products directory not found: $products"
    else
        found=$(find "$products" \( -name '*.o' -o -name '*.a' -o -perm -111 -type f \) -print0 \
            | xargs -0 grep -l -E 'SimPayTestTransport|DemoMockAPI|MockSimPayAPI' 2>/dev/null || true)
        if [ -n "$found" ]; then
            echo "$found"
            fail "Test-only symbols found in Release products"
        fi
    fi
fi

if [ $failed -ne 0 ]; then
    echo "Release checks FAILED"
    exit 1
fi
echo "Release checks passed (SDK version $version)"
