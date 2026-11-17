import Foundation
import Testing
@testable import SimPayCheckoutCore

@MainActor
@Suite("CheckoutEngine: status polling and app lifecycle")
struct PollingFlowTests {

    private let id = Sample.transactionID

    /// Engine waiting for the bank after an accepted BLIK code.
    private func blikAwaiting(
        _ transport: FlowTransport,
        clock: TestClock,
        provider: ScriptedProvider = ScriptedProvider(),
        policy: PollingPolicy = .default
    ) async -> CheckoutEngine {
        transport.script(.channels, Flow.channels(Flow.blikLevel0, Flow.mbank))
        transport.script(.create, Flow.created())
        transport.script(.blik, Flow.blikAccepted)
        let engine = Flow.engine(transport, provider: provider, clock: clock, pollingPolicy: policy)
        await engine.loadChannels()
        await engine.selectChannel(id: "blik-level0")
        await engine.submitBlikCode("482913")
        return engine
    }

    /// Engine with a bank transfer transaction whose payment page is ready.
    private func redirecting(_ transport: FlowTransport, clock: TestClock) async -> CheckoutEngine {
        transport.script(.channels, Flow.channels(Flow.mbank))
        transport.script(.create, Flow.created())
        let engine = Flow.engine(transport, clock: clock)
        await engine.loadChannels()
        await engine.selectChannel(id: "mbank")
        return engine
    }

    /// Waits until the engine's poller sleeps, then skips sleeps until the engine finishes.
    private func runToEnd(_ engine: CheckoutEngine, _ clock: TestClock) async {
        for _ in 0..<200 {
            guard await eventually({ clock.pendingSleeps > 0 || engine.result != nil }), engine.result == nil else { return }
            clock.advanceToNextDeadline()
            _ = await eventually { clock.pendingSleeps == 0 }
        }
    }

    // MARK: Automatic start

    @Test("Polling starts by itself after the bank accepted a BLIK code")
    func startsAfterBlik() async {
        let transport = FlowTransport()
        let clock = TestClock()
        transport.script(.status, Flow.status("transaction_new"), Flow.status("transaction_paid"))
        let engine = await blikAwaiting(transport, clock: clock)

        await runToEnd(engine, clock)

        #expect(engine.result == .succeeded(transactionID: id, status: .paid))
        #expect(transport.count(.status) == 2)
        #expect(transport.count(.create) == 1)
        #expect(transport.count(.blik) == 1)
    }

    @Test("An unclear BLIK submission is verified by polling, never by repeating it")
    func startsAfterUnclearBlik() async {
        let transport = FlowTransport()
        let clock = TestClock()
        transport.script(.channels, Flow.channels(Flow.blikLevel0))
        transport.script(.create, Flow.created())
        transport.script(.blik, .failure(URLError(.timedOut)))
        transport.script(.status, Flow.status("transaction_paid"))
        let engine = Flow.engine(transport, clock: clock)
        await engine.loadChannels()
        await engine.selectChannel(id: "blik-level0")
        await engine.submitBlikCode("482913")

        #expect(await eventually { engine.result != nil })
        #expect(engine.result == .succeeded(transactionID: id, status: .paid))
        #expect(transport.count(.blik) == 1)
        #expect(transport.count(.create) == 1)
    }

    @Test("Definitive failure status ends the checkout as failed with the transaction id")
    func definitiveFailure() async {
        let transport = FlowTransport()
        let clock = TestClock()
        transport.script(.status, Flow.status("transaction_failure"))
        let engine = await blikAwaiting(transport, clock: clock)

        #expect(await eventually { engine.result != nil })
        guard case .failed(let error, let transactionID, let status) = engine.result else {
            Issue.record("unexpected result \(String(describing: engine.result))")
            return
        }
        #expect(error.code == .transactionFailed)
        #expect(transactionID == id)
        #expect(status == .failure)
    }

    @Test("Fraud possibility ends as pending verification")
    func verification() async {
        let transport = FlowTransport()
        let clock = TestClock()
        transport.script(.status, Flow.status("transaction_fraud_possibility"))
        let engine = await blikAwaiting(transport, clock: clock)

        #expect(await eventually { engine.result != nil })
        #expect(engine.result == .pending(transactionID: id, status: .fraudPossibility, reason: .verificationRequired))
    }

    // MARK: Redirect

    @Test("No polling while the payment page is open; a return reads the status but is not a payment")
    func returnFromBank() async {
        let transport = FlowTransport()
        let clock = TestClock()
        transport.script(.status, Flow.status("transaction_new"))
        let engine = await redirecting(transport, clock: clock)

        try? await Task.sleep(for: .milliseconds(20))
        #expect(transport.count(.status) == 0)
        #expect(engine.isPolling == false)

        engine.handle(.returnedFromRedirect)
        #expect(await eventually { engine.lastStatus == .new })
        #expect(engine.state == .checkingStatus(id, lastStatus: .new))
        #expect(engine.result == nil)
        #expect(engine.isPolling)
        _ = await engine.close()
    }

    @Test("Leaving for a banking app from the payment page and coming back starts polling")
    func redirectThroughBackground() async {
        let transport = FlowTransport()
        let clock = TestClock()
        transport.script(.status, Flow.status("transaction_paid"))
        let engine = await redirecting(transport, clock: clock)

        engine.handle(.didEnterBackground)
        engine.handle(.willEnterForeground)

        #expect(await eventually { engine.result != nil })
        #expect(engine.result == .succeeded(transactionID: id, status: .paid))
        #expect(transport.count(.create) == 1)
    }

    @Test("A foreground event without a background stay starts nothing on the payment page")
    func foregroundWithoutBackground() async {
        let transport = FlowTransport()
        let clock = TestClock()
        let engine = await redirecting(transport, clock: clock)

        engine.handle(.willEnterForeground)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(transport.count(.status) == 0)
    }

    // MARK: Lifecycle

    @Test("Background pauses polling and keeps the id; foreground reads at once without resetting the budget")
    func backgroundAndForeground() async {
        let transport = FlowTransport()
        let clock = TestClock()
        transport.script(.status, Flow.status("transaction_new"))
        let engine = await blikAwaiting(transport, clock: clock, policy: Polling.shortPolicy)
        #expect(await eventually { clock.pendingSleeps == 1 })
        clock.advanceToNextDeadline()                            // second read at 2 s
        #expect(await eventually { transport.count(.status) == 2 && clock.pendingSleeps == 1 })

        engine.handle(.didEnterBackground)
        #expect(engine.isPolling == false)
        #expect(engine.activeTransactionID == id)
        #expect(engine.remainingPollingBudget == .seconds(8))

        clock.advance(by: .seconds(900))                         // payer in the banking app
        engine.handle(.returnedFromRedirect)                     // ignored in the background
        #expect(await engine.checkStatus() == false)
        #expect(transport.count(.status) == 2)

        engine.handle(.willEnterForeground)
        #expect(await eventually { transport.count(.status) == 3 })
        #expect(engine.state == .awaitingBankConfirmation(id))
        await runToEnd(engine, clock)

        #expect(engine.result == .pending(transactionID: id, status: .new, reason: .inProgress))
        #expect(clock.now == .seconds(2 + 900 + 8))              // only foreground time used the budget
        #expect(transport.count(.create) == 1)
        #expect(transport.count(.blik) == 1)
    }

    @Test("A code accepted while the app is in the background is verified on return")
    func acceptedInBackground() async {
        let transport = FlowTransport()
        let clock = TestClock()
        let gate = Gate()
        transport.script(.channels, Flow.channels(Flow.blikLevel0))
        transport.script(.create, Flow.created())
        transport.script(.blik, Flow.blikAccepted)
        transport.hold(.blik, with: gate)
        transport.script(.status, Flow.status("transaction_paid"))
        let engine = Flow.engine(transport, clock: clock)
        await engine.loadChannels()
        await engine.selectChannel(id: "blik-level0")

        let submitting = Task { await engine.submitBlikCode("482913") }
        #expect(await eventually { transport.count(.blik) == 1 })
        engine.handle(.didEnterBackground)
        await gate.open()
        _ = await submitting.value

        #expect(engine.state == .awaitingBankConfirmation(id))
        try? await Task.sleep(for: .milliseconds(20))
        #expect(transport.count(.status) == 0)

        engine.handle(.willEnterForeground)
        #expect(await eventually { engine.result == .succeeded(transactionID: id, status: .paid) })
    }

    // MARK: Network

    @Test("Temporary failures while polling never fail the payment; the budget ends as pending")
    func temporaryFailuresEndPending() async {
        let transport = FlowTransport()
        let clock = TestClock()
        transport.script(.status, .failure(URLError(.notConnectedToInternet)), .failure(URLError(.timedOut)), Flow.http(503), Flow.http(429))
        let engine = await blikAwaiting(transport, clock: clock, policy: Polling.shortPolicy)

        await runToEnd(engine, clock)

        #expect(engine.result == .pending(transactionID: id, status: nil, reason: .statusUnavailable))
        #expect(transport.count(.create) == 1)
        #expect(transport.count(.blik) == 1)
    }

    @Test("HTTP 429 with Retry-After delays the next read")
    func retryAfter() async {
        let transport = FlowTransport()
        let clock = TestClock()
        transport.script(
            .status,
            .response(HTTPResponse(statusCode: 429, headers: ["retry-after": "12"])),
            Flow.status("transaction_paid")
        )
        let engine = await blikAwaiting(transport, clock: clock)

        #expect(await eventually { clock.pendingSleeps == 1 })
        #expect(clock.sleepRequests == [.seconds(12)])
        await runToEnd(engine, clock)
        #expect(engine.result == .succeeded(transactionID: id, status: .paid))
    }

    @Test("HTTP 401 while polling refreshes the session once through the session store")
    func unauthorizedRefresh() async {
        let transport = FlowTransport()
        let clock = TestClock()
        let provider = ScriptedProvider()
        transport.script(.status, Flow.http(401), Flow.status("transaction_paid"))
        let engine = await blikAwaiting(transport, clock: clock, provider: provider)

        #expect(await eventually { engine.result != nil })
        #expect(engine.result == .succeeded(transactionID: id, status: .paid))
        #expect(provider.calls == 2)
        #expect(transport.count(.status) == 2)
    }

    @Test("A status that cannot be read after a refresh ends as pending, never failed")
    func unauthorizedTwice() async {
        let transport = FlowTransport()
        let clock = TestClock()
        let provider = ScriptedProvider()
        transport.script(.status, Flow.status("transaction_new"), Flow.http(401))
        let engine = await blikAwaiting(transport, clock: clock, provider: provider)

        await runToEnd(engine, clock)

        #expect(engine.result == .pending(transactionID: id, status: .new, reason: .statusUnavailable))
        #expect(transport.count(.status) == 3)                   // read, 401, 401 after one refresh
        #expect(provider.calls == 2)
    }

    // MARK: Concurrency

    @Test("Concurrent status checks share one request")
    func concurrentChecks() async {
        let transport = FlowTransport()
        let clock = TestClock()
        transport.script(.status, Flow.status("transaction_new"))
        let engine = await blikAwaiting(transport, clock: clock)
        #expect(await eventually { clock.pendingSleeps == 1 })

        async let first = engine.checkStatus()
        async let second = engine.checkStatus()
        async let third = engine.checkStatus()
        #expect(await [first, second, third] == [true, true, true])
        #expect(transport.count(.status) == 2)
        _ = await engine.close()
    }

    @Test("Closing while polling reports pending once; a late answer cannot change it")
    func closeDuringRead() async {
        let transport = FlowTransport()
        let clock = TestClock()
        let gate = Gate()
        transport.hold(.status, with: gate)
        transport.script(.status, Flow.status("transaction_paid"))
        let engine = await blikAwaiting(transport, clock: clock)
        let recorder = StateRecorder(engine)
        #expect(await eventually { transport.count(.status) == 1 })

        let result = await engine.close()
        await gate.open()
        try? await Task.sleep(for: .milliseconds(30))

        #expect(result == .pending(transactionID: id, status: nil, reason: .statusUnavailable))
        #expect(engine.result == result)
        #expect(await engine.close() == result)
        #expect(recorder.names.filter { $0 == "finished" }.count == 1)
        #expect(engine.isPolling == false)
        #expect(transport.count(.status) == 1)
    }

    @Test("After the end no lifecycle event reads or creates anything")
    func eventsAfterEnd() async {
        let transport = FlowTransport()
        let clock = TestClock()
        transport.script(.status, Flow.status("transaction_paid"))
        let engine = await blikAwaiting(transport, clock: clock)
        #expect(await eventually { engine.result != nil })

        engine.handle(.didEnterBackground)
        engine.handle(.willEnterForeground)
        engine.handle(.returnedFromRedirect)
        #expect(await engine.checkStatus() == false)
        try? await Task.sleep(for: .milliseconds(20))

        #expect(transport.count(.status) == 1)
        #expect(transport.count(.create) == 1)
        #expect(transport.count(.blik) == 1)
    }

    @Test("A rejected BLIK code leaves no poller behind; the new transaction is polled")
    func rejectionThenNewTransaction() async {
        let transport = FlowTransport()
        let clock = TestClock()
        transport.script(.channels, Flow.channels(Flow.blikLevel0))
        transport.script(.create, Flow.created(), Flow.created(Flow.secondID.rawValue))
        transport.script(.blik, Flow.http(409), Flow.blikAccepted)
        transport.script(.status, Flow.status("transaction_paid"))
        let engine = Flow.engine(transport, clock: clock)
        await engine.loadChannels()
        await engine.selectChannel(id: "blik-level0")

        await engine.submitBlikCode("111111")
        #expect(engine.isPolling == false)
        await engine.submitBlikCode("222222")

        #expect(await eventually { engine.result != nil })
        #expect(engine.result == .succeeded(transactionID: Flow.secondID, status: .paid))
        #expect(transport.count(.status) == 1)
    }
}
