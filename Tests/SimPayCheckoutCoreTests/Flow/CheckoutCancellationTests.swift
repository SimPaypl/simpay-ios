import Foundation
import Testing
@testable import SimPayCheckoutCore

@MainActor
@Suite("CheckoutEngine: closing and cancellation")
struct CheckoutCancellationTests {

    private func engine(_ transport: FlowTransport) async -> CheckoutEngine {
        transport.script(.channels, Flow.channels(Flow.blikLevel0, Flow.mbank))
        let engine = Flow.engine(transport)
        await engine.loadChannels()
        return engine
    }

    @Test("Closing before any transaction is cancelled")
    func closeBeforeTransaction() async {
        let engine = await engine(FlowTransport())
        #expect(await engine.close() == .cancelled)
        #expect(engine.state == .finished(.cancelled))
    }

    @Test("Closing on the BLIK entry before a transaction is cancelled")
    func closeOnBlikEntry() async {
        let engine = await engine(FlowTransport())
        await engine.selectChannel(id: "blik-level0")
        #expect(await engine.close() == .cancelled)
    }

    @Test("Closing while channels load cancels the read and reports cancelled")
    func closeWhileLoading() async {
        let gate = Gate()
        let transport = FlowTransport()
        transport.script(.channels, Flow.channels(Flow.mbank))
        transport.hold(.channels, with: gate)
        let engine = Flow.engine(transport)

        let loading = Task { await engine.loadChannels() }
        #expect(await eventually { transport.count(.channels) == 1 })
        #expect(await engine.close() == .cancelled)
        await gate.open()
        #expect(await loading.value == false)
        #expect(engine.state == .finished(.cancelled))
    }

    @Test("Closing while the transaction is being created waits for it and reports it as pending")
    func closeDuringCreate() async {
        let gate = Gate()
        let transport = FlowTransport()
        transport.script(.create, Flow.created())
        transport.hold(.create, with: gate)
        let engine = await engine(transport)

        let selecting = Task { await engine.selectChannel(id: "mbank") }
        #expect(await eventually { transport.count(.create) == 1 })

        let closing = Task { await engine.close() }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(engine.result == nil)                 // still waiting for the POST
        await gate.open()

        #expect(await closing.value == .pending(transactionID: Sample.transactionID, status: nil, reason: .statusUnavailable))
        #expect(await selecting.value)
        #expect(transport.count(.create) == 1)
    }

    @Test("Closing during an unclear create reports outcomeUnknown, never cancelled")
    func closeDuringAmbiguousCreate() async {
        let gate = Gate()
        let transport = FlowTransport()
        transport.script(.create, .failure(URLError(.timedOut)))
        transport.hold(.create, with: gate)
        let engine = await engine(transport)

        let selecting = Task { await engine.selectChannel(id: "mbank") }
        #expect(await eventually { transport.count(.create) == 1 })
        let closing = Task { await engine.close() }
        await gate.open()

        if case .outcomeUnknown = await closing.value {} else { Issue.record("expected outcomeUnknown") }
        _ = await selecting.value
    }

    @Test("Closing during a refused create reports the failure, not a transaction")
    func closeDuringRefusedCreate() async {
        let gate = Gate()
        let transport = FlowTransport()
        transport.script(.create, Flow.http(422))
        transport.hold(.create, with: gate)
        let engine = await engine(transport)

        let selecting = Task { await engine.selectChannel(id: "mbank") }
        #expect(await eventually { transport.count(.create) == 1 })
        let closing = Task { await engine.close() }
        await gate.open()

        let result = await closing.value
        #expect(result.transactionID == nil)
        if case .failed(let error, _, _) = result { #expect(error.code == .validationFailed) } else { Issue.record("expected failed") }
        _ = await selecting.value
    }

    @Test("Closing while the BLIK transaction is created never pushes the code to the bank")
    func closeDuringBlikCreate() async {
        let gate = Gate()
        let transport = FlowTransport()
        transport.script(.create, Flow.created())
        transport.script(.blik, Flow.blikAccepted)
        transport.hold(.create, with: gate)
        let engine = await engine(transport)
        await engine.selectChannel(id: "blik-level0")

        let submitting = Task { await engine.submitBlikCode("482913") }
        #expect(await eventually { transport.count(.create) == 1 })
        let closing = Task { await engine.close() }
        await gate.open()

        #expect(await closing.value == .pending(transactionID: Sample.transactionID, status: nil, reason: .statusUnavailable))
        #expect(transport.count(.blik) == 0)
        _ = await submitting.value
    }

    @Test("Closing while the BLIK code is in flight waits and reports pending")
    func closeDuringBlikSubmit() async {
        let gate = Gate()
        let transport = FlowTransport()
        transport.script(.create, Flow.created())
        transport.script(.blik, Flow.blikAccepted)
        transport.hold(.blik, with: gate)
        let engine = await engine(transport)
        await engine.selectChannel(id: "blik-level0")

        let submitting = Task { await engine.submitBlikCode("482913") }
        #expect(await eventually { transport.count(.blik) == 1 })
        let closing = Task { await engine.close() }
        await gate.open()

        #expect(await closing.value == .pending(transactionID: Sample.transactionID, status: nil, reason: .statusUnavailable))
        #expect(transport.count(.blik) == 1)
        _ = await submitting.value
    }

    @Test("Closing after a transaction exists is pending with the last known status")
    func closeAfterTransaction() async {
        let transport = FlowTransport()
        transport.script(.create, Flow.created())
        transport.script(.status, Flow.status("transaction_generated"))
        let engine = await engine(transport)
        await engine.selectChannel(id: "mbank")
        await engine.checkStatus()

        #expect(await engine.close() == .pending(transactionID: Sample.transactionID, status: .generated, reason: .inProgress))
    }

    @Test("Closing after a rejected code reports the rejected transaction, not cancelled")
    func closeAfterRejection() async {
        let transport = FlowTransport()
        transport.script(.create, Flow.created())
        transport.script(.blik, Flow.http(409))
        let engine = await engine(transport)
        await engine.selectChannel(id: "blik-level0")
        await engine.submitBlikCode("111111")

        let result = await engine.close()
        guard case .failed(let error, let id, _) = result else {
            Issue.record("unexpected \(result)")
            return
        }
        #expect(error.code == .blikRejected)
        #expect(id == Sample.transactionID)
    }

    @Test("Cancelling the caller's task does not abandon the create request")
    func callerCancellation() async {
        let gate = Gate()
        let transport = FlowTransport()
        transport.script(.create, Flow.created())
        transport.hold(.create, with: gate)
        let engine = await engine(transport)

        let selecting = Task { await engine.selectChannel(id: "mbank") }
        #expect(await eventually { transport.count(.create) == 1 })
        selecting.cancel()
        await gate.open()
        _ = await selecting.value

        #expect(engine.activeTransactionID == Sample.transactionID)
        #expect(engine.state.name == "redirecting")
    }

    @Test("The result is produced once; later actions are ignored")
    func singleResult() async {
        let transport = FlowTransport()
        let engine = await engine(transport)

        let first = await engine.close()
        let second = await engine.close()

        #expect(first == .cancelled && second == .cancelled)
        #expect(await engine.selectChannel(id: "mbank") == false)
        #expect(await engine.loadChannels() == false)
        #expect(transport.count(.create) == 0)
    }

    @Test("State updates end with the finished state")
    func streamEnds() async {
        let engine = await engine(FlowTransport())
        let stream = engine.stateUpdates()
        _ = await engine.close()

        var names: [String] = []
        for await state in stream { names.append(state.name) }
        #expect(names == ["channels", "finished"])
    }
}
