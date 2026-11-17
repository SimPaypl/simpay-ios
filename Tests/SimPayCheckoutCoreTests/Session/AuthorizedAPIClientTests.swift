import Foundation
import Testing
@testable import SimPayCheckoutCore

@Suite("Authorized API client")
struct AuthorizedAPIClientTests {

    private static let channelsOK = HTTPResponse(statusCode: 200, body: Data(#"{"success":true,"data":[{"id":"blik"}]}"#.utf8))
    private static let statusOK = HTTPResponse(statusCode: 200, body: Data(#"{"success":true,"data":{"status":"transaction_paid"}}"#.utf8))
    private static let createdOK = HTTPResponse(statusCode: 201, body: Data(Sample.createdJSON.utf8))

    /// Answers GET with the channel list and POST with a created transaction.
    private static func routed(_ request: URLRequest) -> HTTPResponse {
        request.httpMethod == "POST" ? createdOK : channelsOK
    }

    private func make(_ transport: ScriptedTransport, _ provider: ScriptedProvider, clock: ManualClock = ManualClock()) -> AuthorizedAPIClient {
        AuthorizedAPIClient(
            client: SimPayAPIClient(environment: Sample.environment, transport: transport),
            sessions: SessionStore(provider: provider, clock: clock.sessionClock)
        )
    }

    private func create(_ api: AuthorizedAPIClient, order: SimPayOrder = Sample.order()) async throws -> CreatedTransaction {
        try await api.createTransaction(order: order, directChannel: "mbank", userAgent: "UA")
    }

    // MARK: Reads

    @Test("Every request carries the current session token")
    func usesSession() async throws {
        let transport = ScriptedTransport.accepting([ScriptedProvider.token(1)], success: Self.channelsOK)
        let api = make(transport, ScriptedProvider())

        _ = try await api.fetchChannels()
        _ = try await api.fetchChannels()

        #expect(transport.tokensUsed == [ScriptedProvider.token(1), ScriptedProvider.token(1)])
    }

    @Test("GET after 401: one refresh, one repetition, success with the new token")
    func readRefreshesOnce() async throws {
        let transport = ScriptedTransport.accepting([ScriptedProvider.token(2)], success: Self.statusOK)
        let provider = ScriptedProvider()
        let api = make(transport, provider)

        let snapshot = try await api.transactionStatus(Sample.transactionID)

        #expect(snapshot.status == .paid)
        #expect(provider.calls == 2)
        #expect(transport.tokensUsed == [ScriptedProvider.token(1), ScriptedProvider.token(2)])
    }

    @Test("GET with a second 401 stops after one refresh and drops the session")
    func readGivesUpAfterSecond401() async throws {
        let transport = ScriptedTransport.accepting([], success: Self.channelsOK)
        let provider = ScriptedProvider()
        let api = make(transport, provider)

        let failure = await apiFailure { _ = try await api.fetchChannels() }

        #expect(failure?.error.code == .unauthorized)
        #expect(failure?.httpStatus == 401)
        #expect(transport.callCount == 2)          // at most one repetition
        #expect(provider.calls == 2)               // at most one refresh
        #expect(await api.sessions.hasSession == false)
    }

    @Test("GET is not repeated for failures other than 401", arguments: [403, 404, 429, 500])
    func readNotRepeatedForOtherStatuses(_ status: Int) async {
        let transport = ScriptedTransport { _ in HTTPResponse(statusCode: status) }
        let provider = ScriptedProvider()
        let api = make(transport, provider)

        _ = await apiFailure { _ = try await api.transactionStatus(Sample.transactionID) }

        #expect(transport.callCount == 1)
        #expect(provider.calls == 1)
    }

    @Test("A session that cannot be obtained sends nothing and is not_delivered")
    func sessionFailureIsNotDelivered() async {
        let transport = ScriptedTransport { _ in Self.channelsOK }
        let provider = ScriptedProvider()
        provider.fail(call: 1, with: ProviderBoom())
        let api = make(transport, provider)

        let failure = await apiFailure { _ = try await api.fetchChannels() }

        #expect(failure?.error.code == .sessionFailed)
        #expect(failure?.kind == .notDelivered)
        #expect(failure?.isSessionFailure == true)
        #expect(transport.callCount == 0)
        #expect(failure.map { !everyTextualForm(of: $0).contains(Sample.token) } == true)
    }

    @Test("A provider error with its own code keeps that code and is marked as a session failure")
    func providerOwnCodeIsSessionFailure() async {
        let transport = ScriptedTransport { _ in Self.channelsOK }
        let provider = ScriptedProvider()
        provider.fail(call: 1, with: SimPayCheckoutError(.noInternet))
        let api = make(transport, provider)

        let failure = await apiFailure { _ = try await api.fetchChannels() }

        #expect(failure?.error.code == .noInternet)
        #expect(failure?.isSessionFailure == true)
        #expect(transport.callCount == 0)
    }

    @Test("A refresh failure after 401 on GET is reported, not retried")
    func refreshFailureAfter401() async {
        let transport = ScriptedTransport.accepting([], success: Self.channelsOK)
        let provider = ScriptedProvider()
        provider.fail(call: 2, with: ProviderBoom())
        let api = make(transport, provider)

        let failure = await apiFailure { _ = try await api.fetchChannels() }

        #expect(failure?.error.code == .sessionFailed)
        #expect(transport.callCount == 1)
        #expect(provider.calls == 2)
    }

    @Test("A proactively refreshed session is used before the old one expires")
    func proactiveRefreshBeforeRequest() async throws {
        let clock = ManualClock()
        let transport = ScriptedTransport { _ in Self.channelsOK }
        let provider = ScriptedProvider(clock: clock, lifetime: 15 * 60)
        let api = make(transport, provider, clock: clock)

        _ = try await api.fetchChannels()
        clock.advance(by: .seconds(14 * 60 + 30))
        _ = try await api.fetchChannels()

        #expect(transport.tokensUsed == [ScriptedProvider.token(1), ScriptedProvider.token(2)])
    }

    // MARK: Writes

    @Test("POST after 401 is never repeated; the session is dropped for the next operation")
    func createNotRepeatedAfter401() async throws {
        let accepted = "Bearer \(ScriptedProvider.token(2))"
        let transport = ScriptedTransport { request in
            request.value(forHTTPHeaderField: "Authorization") == accepted ? Self.routed(request) : HTTPResponse(statusCode: 401)
        }
        let provider = ScriptedProvider()
        let api = make(transport, provider)

        let failure = await apiFailure { _ = try await create(api) }

        #expect(failure?.error.code == .unauthorized)
        #expect(failure?.kind == .rejected)
        #expect(transport.callCount == 1)
        #expect(provider.calls == 1)
        #expect(await api.sessions.hasSession == false)

        // The next, separate operation starts with a fresh session.
        _ = try await api.fetchChannels()
        #expect(transport.tokensUsed.last == ScriptedProvider.token(2))
    }

    @Test("BLIK after 401 is never repeated")
    func blikNotRepeatedAfter401() async {
        let transport = ScriptedTransport.accepting([], success: HTTPResponse(statusCode: 204))
        let provider = ScriptedProvider()
        let api = make(transport, provider)

        let failure = await apiFailure { try await api.submitBlikCode(Sample.blikCode, transactionID: Sample.transactionID) }

        #expect(failure?.httpStatus == 401)
        #expect(transport.callCount == 1)
        #expect(provider.calls == 1)
    }

    @Test("POST with an unknown outcome is never repeated and keeps the session", arguments: [500, 504])
    func createOutcomeUnknown(_ status: Int) async {
        let transport = ScriptedTransport { _ in HTTPResponse(statusCode: status) }
        let api = make(transport, ScriptedProvider())

        let failure = await apiFailure { _ = try await create(api) }

        #expect(failure?.kind == .outcomeUnknown)
        #expect(transport.callCount == 1)
        #expect(await api.sessions.hasSession)
    }

    @Test("POST timeout is never repeated")
    func createTimeout() async {
        let transport = ScriptedTransport { _ in throw URLError(.timedOut) }
        let api = make(transport, ScriptedProvider())

        let failure = await apiFailure { _ = try await create(api) }

        #expect(failure?.kind == .outcomeUnknown)
        #expect(transport.callCount == 1)
    }

    @Test("POST fetches a valid session before sending")
    func createUsesFreshSession() async throws {
        let clock = ManualClock()
        let transport = ScriptedTransport { Self.routed($0) }
        let provider = ScriptedProvider(clock: clock, lifetime: 15 * 60)
        let api = make(transport, provider, clock: clock)

        _ = try await api.fetchChannels()
        clock.advance(by: .seconds(15 * 60))
        _ = try await create(api)

        #expect(transport.tokensUsed == [ScriptedProvider.token(1), ScriptedProvider.token(2)])
    }

    // MARK: Payer IP

    @Test("The payer IP comes from the session used for the request")
    func payerIPFromSession() async throws {
        let transport = ScriptedTransport { Self.routed($0) }
        let api = make(transport, ScriptedProvider(payerIP: "198.51.100.7"))

        _ = try await create(api)

        let body = try #require(transport.requests.first?.httpBody)
        let json = try #require(JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect((json["customer"] as? [String: Any])?["ip"] as? String == "198.51.100.7")
    }

    @Test("Without a payer IP nothing is sent and missing_payer_ip is reported")
    func missingPayerIP() async {
        let transport = ScriptedTransport { Self.routed($0) }
        let api = make(transport, ScriptedProvider(payerIP: nil))

        let failure = await apiFailure { _ = try await create(api) }

        #expect(failure?.error.code == .missingPayerIP)
        #expect(failure?.kind == .notDelivered)
        #expect(transport.callCount == 0)
    }

    @Test("The order override is used when the session carries no IP")
    func payerIPOverride() async throws {
        let transport = ScriptedTransport { Self.routed($0) }
        let api = make(transport, ScriptedProvider(payerIP: nil))
        let order = try SimPayOrder(amount: 10, customerEmail: Sample.email, payerIPOverride: "192.0.2.44")

        _ = try await create(api, order: order)

        #expect(transport.requests.first?.bodyText?.contains(#""ip":"192.0.2.44""#) == true)
    }

    // MARK: Masking

    @Test("Failures never contain the session token")
    func failuresAreMasked() async {
        let transport = ScriptedTransport.accepting([], success: Self.channelsOK)
        let api = make(transport, ScriptedProvider())

        let failures = [
            await apiFailure { _ = try await api.fetchChannels() },
            await apiFailure { _ = try await create(api) },
        ]
        #expect(failures.compactMap { $0 }.count == 2)
        for failure in failures.compactMap({ $0 }) {
            #expect(!everyTextualForm(of: failure).contains("mobsdk_test"))
        }
    }
}
