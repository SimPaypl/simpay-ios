import Foundation
import Testing
@testable import SimPayCheckoutCore

/// Provider whose first call succeeds and every later call hangs, like an integrator's
/// backend request that never returns.
private final class HangingAfterFirstProvider: SimPaySessionProvider, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let never = Gate()

    var calls: Int { lock.withLock { count } }

    func provideSession() async throws -> SimPaySession {
        let number = lock.withLock { () -> Int in
            count += 1
            return count
        }
        if number > 1 { await never.wait() }
        return try SimPaySession(token: ScriptedProvider.token(number), payerIP: Sample.ip)
    }
}

@MainActor
@Suite("CheckoutEngine: edge cases")
struct CheckoutEdgeCaseTests {

    private let id = Sample.transactionID

    private func makeEngine(_ transport: FlowTransport, provider: any SimPaySessionProvider, clock: TestClock = TestClock(), policy: PollingPolicy = .default) -> CheckoutEngine {
        CheckoutEngine(
            api: AuthorizedAPIClient(
                client: SimPayAPIClient(environment: Sample.environment, transport: transport),
                sessions: SessionStore(provider: provider, clock: ManualClock().sessionClock)
            ),
            order: Sample.order(),
            userAgent: Sample.userAgent,
            pollingPolicy: policy,
            pollingClock: clock.pollingClock
        )
    }

    // MARK: Closing while a session is being fetched

    @Test("Closing while the next BLIK code waits for a session never sends it and does not hang")
    func closeWhileBlikWaitsForSession() async {
        let transport = FlowTransport()
        transport.script(.channels, Flow.channels(Flow.blikLevel0))
        transport.script(.create, Flow.created())
        // The first code meets a 401: the session is dropped and the transaction kept.
        transport.script(.blik, Flow.http(401), Flow.blikAccepted)
        let provider = HangingAfterFirstProvider()
        let engine = makeEngine(transport, provider: provider)

        await engine.loadChannels()
        await engine.selectChannel(id: "blik-level0")
        await engine.submitBlikCode("482913")
        #expect(engine.state.blikEntry?.transactionID == id)

        let submit = Task { await engine.submitBlikCode("111222") }
        #expect(await eventually { provider.calls == 2 })

        let result = await engine.close()
        _ = await submit.value

        #expect(result == .pending(transactionID: id, status: nil, reason: .statusUnavailable))
        #expect(transport.count(.blik) == 1)
    }

    @Test("Closing while a transaction waits for a session reports cancelled and creates nothing")
    func closeWhileCreateWaitsForSession() async {
        let transport = FlowTransport()
        transport.script(.channels, Flow.channels(Flow.mbank))
        // 401 drops the session, so the next attempt needs a new one.
        transport.script(.create, Flow.http(401), Flow.created())
        let provider = HangingAfterFirstProvider()
        let engine = makeEngine(transport, provider: provider)

        await engine.loadChannels()
        await engine.selectChannel(id: "mbank")
        await engine.backToChannels()

        let select = Task { await engine.selectChannel(id: "mbank") }
        #expect(await eventually { provider.calls == 2 })

        let result = await engine.close()
        _ = await select.value

        #expect(result == .cancelled)
        #expect(transport.count(.create) == 1)
    }

    // MARK: Payment page

    @Test("The polling budget never ends the checkout while the payer is on the payment page")
    func budgetDoesNotEndOpenPaymentPage() async {
        let transport = FlowTransport()
        let clock = TestClock()
        transport.script(.channels, Flow.channels(Flow.mbank))
        transport.script(.create, Flow.created())
        transport.script(.status, Flow.status("transaction_new"))
        let engine = makeEngine(transport, provider: ScriptedProvider(), clock: clock, policy: Polling.shortPolicy)

        await engine.loadChannels()
        await engine.selectChannel(id: "mbank")
        // A trip to another app (for example for an SMS code) starts polling.
        engine.handle(.didEnterBackground)
        engine.handle(.willEnterForeground)

        for _ in 0..<50 {
            guard await eventually({ clock.pendingSleeps > 0 || !engine.isPolling }), engine.isPolling else { break }
            clock.advanceToNextDeadline()
        }
        #expect(await eventually { !engine.isPolling })
        #expect(engine.result == nil)
        let readsBeforeReturn = transport.count(.status)

        // The payer comes back from the page: the status is read again.
        transport.script(.status, Flow.status("transaction_paid"))
        engine.handle(.returnedFromRedirect)

        #expect(await eventually { engine.result != nil })
        #expect(engine.result == .succeeded(transactionID: id, status: .paid))
        #expect(transport.count(.status) > readsBeforeReturn)
    }

    // MARK: BLIK endpoint

    @Test("Other 4xx answers to a BLIK code keep the transaction and count no rejection", arguments: [405, 408, 413, 415])
    func otherClientErrorsKeepTransaction(status: Int) async {
        let failure = ErrorClassifier.classify(statusCode: status, body: Data(), endpoint: .submitBlikCode(id))
        #expect(failure.error.code == .validationFailed)
        #expect(failure.kind == .rejected)

        let transport = FlowTransport()
        transport.script(.channels, Flow.channels(Flow.blikLevel0))
        transport.script(.create, Flow.created())
        transport.script(.blik, Flow.http(status))
        let engine = makeEngine(transport, provider: ScriptedProvider())

        await engine.loadChannels()
        await engine.selectChannel(id: "blik-level0")
        await engine.submitBlikCode("482913")

        #expect(engine.state.blikEntry?.transactionID == id)
        #expect(engine.blikRejections == 0)
        #expect(transport.count(.create) == 1)
        _ = await engine.close()
    }
}
