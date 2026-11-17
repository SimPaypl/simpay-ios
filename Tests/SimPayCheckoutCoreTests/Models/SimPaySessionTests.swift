import Foundation
import Testing
@testable import SimPayCheckoutCore

@Suite("SimPaySession")
struct SimPaySessionTests {

    @Test("Builds a Bearer header from the full token")
    func bearerHeader() throws {
        let session = try SimPaySession(token: Sample.token)
        #expect(session.authorizationHeaderValue == "Bearer \(Sample.token)")
    }

    @Test("Rejects tokens that cannot form a valid header", arguments: [
        "",
        " ",
        "mobsdk_abc def",
        "mobsdk_abc\n",
        "mobsdk_abc\r\nX-Injected: 1",
        "mobsdk_abc\t",
        "mobsdk_abc\u{0000}",
    ])
    func rejectsUnusableToken(_ token: String) {
        let error = caughtError { () throws(SimPayCheckoutError) in try SimPaySession(token: token) }
        #expect(error?.code == .sessionFailed)
    }

    @Test("A blank payer IP is treated as missing", arguments: [nil, "", "   "])
    func blankPayerIPIsMissing(_ ip: String?) throws {
        let session = try SimPaySession(token: Sample.token, payerIP: ip)
        #expect(session.payerIP == nil)
    }

    @Test("Keeps the payer IP and expiry")
    func keepsPayerIPAndExpiry() throws {
        let expiry = Date(timeIntervalSince1970: 1_800_000_000)
        let session = try SimPaySession(token: Sample.token, expiresAt: expiry, payerIP: Sample.ip)

        #expect(session.payerIP == Sample.ip)
        #expect(session.expiresAt == expiry)
    }

    @Test("Token and payer IP never appear in description, debug output or dump")
    func secretsAreMasked() throws {
        let session = try SimPaySession(token: Sample.token, payerIP: Sample.ip)

        let text = everyTextualForm(of: session)
        #expect(!text.contains("mobsdk_"))
        #expect(!text.contains("secret-payload"))
        #expect(!text.contains(Sample.ip))
        #expect(text.contains("<redacted>"))
    }

    @Test("Validation messages never echo the token")
    func errorDoesNotEchoToken() {
        let error = caughtError { () throws(SimPayCheckoutError) in
            try SimPaySession(token: "mobsdk_test_secret value")
        }
        #expect(error.map { !everyTextualForm(of: $0).contains("secret") } == true)
    }
}
