import Foundation
import Testing
@testable import SimPayCheckoutCore

@Suite("Sensitive data in the networking layer")
struct SensitiveDataTests {

    private let secrets = [Sample.token, "secret-payload", Sample.email, Sample.ip, "482913"]

    private func expectNoSecrets(in value: Any, sourceLocation: SourceLocation = #_sourceLocation) {
        let text = everyTextualForm(of: value)
        for secret in secrets {
            #expect(!text.contains(secret), "leaked \(secret)", sourceLocation: sourceLocation)
        }
    }

    @Test("Failures of every endpoint reveal no token, BLIK code, e-mail or IP")
    func failuresAreClean() async {
        let errorBody = #"{"message":"bad","errors":{"customer.email":["\#(Sample.email) invalid"],"ticket.T6":["482913 rejected"]}}"#
        let replies: [StubTransport.Reply] = [
            .response(HTTPResponse(statusCode: 422, body: Data(errorBody.utf8))),
            .response(HTTPResponse(statusCode: 500, body: Data(errorBody.utf8))),
            .failure(URLError(.timedOut)),
            .response(HTTPResponse(statusCode: 200, body: Data("{".utf8))),
        ]

        for reply in replies {
            let client = Sample.client(StubTransport(reply))
            let failures = [
                await apiFailure { _ = try await client.fetchChannels(session: Sample.session) },
                await apiFailure { _ = try await client.createTransaction(Sample.createRequest(), session: Sample.session) },
                await apiFailure { try await client.submitBlikCode(Sample.blikCode, transactionID: Sample.transactionID, session: Sample.session) },
                await apiFailure { _ = try await client.transactionStatus(Sample.transactionID, session: Sample.session) },
            ]
            for failure in failures {
                // A 2xx BLIK answer with an unreadable body is accepted (the API answers
                // 204 and the body is ignored), so that combination yields no failure.
                if let failure { expectNoSecrets(in: failure) }
            }
            #expect(failures.compactMap { $0 }.count >= 3)
        }
    }

    @Test("The create request description hides payer data")
    func createRequestIsMasked() {
        expectNoSecrets(in: Sample.createRequest())
    }

    @Test("The request itself is the only place carrying the secrets")
    func requestCarriesSecretsOnlyInHeaderAndBody() async throws {
        let transport = StubTransport(status: 204)
        try await Sample.client(transport).submitBlikCode(Sample.blikCode, transactionID: Sample.transactionID, session: Sample.session)

        let request = try #require(transport.requests.first)
        #expect(request.url?.absoluteString.contains("482913") == false)
        #expect(request.url?.absoluteString.contains(Sample.token) == false)
        #expect(request.bodyText?.contains("482913") == true)
    }
}
