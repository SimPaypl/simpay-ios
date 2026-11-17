import Foundation
import Testing
@testable import SimPayCheckoutCore

@MainActor
@Suite("CheckoutEngine: BLIK Level 0")
struct BlikFlowTests {

    private func blikEngine(_ transport: FlowTransport, maximumRejections: Int = BlikLevel0.maximumRejections) async -> CheckoutEngine {
        transport.script(.channels, Flow.channels(Flow.blikRedirect, Flow.blikLevel0, Flow.mbank))
        let engine = Flow.engine(transport, maximumBlikRejections: maximumRejections)
        await engine.loadChannels()
        await engine.selectChannel(id: "blik-level0")
        return engine
    }

    @Test("Happy path: transaction created on submit, code sent, bank confirmation awaited, paid only by status")
    func happyPath() async {
        let transport = FlowTransport()
        transport.script(.create, Flow.created())
        transport.script(.blik, Flow.blikAccepted)
        transport.script(.status, Flow.status("transaction_paid"))
        let statusGate = Gate()
        transport.hold(.status, with: statusGate)
        let engine = await blikEngine(transport)
        let recorder = StateRecorder(engine)

        #expect(await engine.submitBlikCode("482913"))

        #expect(engine.state == .awaitingBankConfirmation(Sample.transactionID))
        #expect(engine.result == nil)                         // 204 is not a payment
        #expect(transport.count(.create) == 1)
        #expect(transport.count(.blik) == 1)
        #expect(transport.sentBodies(.create).first?.contains(#""directChannel":"blik-level0""#) == true)
        #expect(transport.sentBodies(.blik) == [#"{"ticket":{"T6":"482913"}}"#])

        // Polling started on its own; only the status read can finish the checkout.
        #expect(await eventually { transport.count(.status) == 1 })
        #expect(engine.result == nil)
        await statusGate.open()
        #expect(await eventually { engine.result == .succeeded(transactionID: Sample.transactionID, status: .paid) })
        #expect(await eventually {
            recorder.names == ["enteringBlikCode", "creatingTransaction", "submittingBlikCode", "awaitingBankConfirmation", "finished"]
        })
    }

    @Test("The bank prompt stays while the status is still processing")
    func promptStays() async {
        let transport = FlowTransport()
        transport.script(.create, Flow.created())
        transport.script(.blik, Flow.blikAccepted)
        transport.script(.status, Flow.status("transaction_confirmed"))
        let engine = await blikEngine(transport)

        await engine.submitBlikCode("482913")
        #expect(await eventually { engine.lastStatus == .confirmed })

        #expect(engine.state == .awaitingBankConfirmation(Sample.transactionID))
        #expect(engine.isPolling)
    }

    @Test("An invalid code is refused locally and reaches no API", arguments: ["", "12345", "1234567", "12a456", " 123456"])
    func invalidCode(_ code: String) async {
        let transport = FlowTransport()
        let engine = await blikEngine(transport)

        #expect(await engine.submitBlikCode(code) == false)
        #expect(engine.state.blikEntry?.problem == .invalidFormat)
        #expect(transport.count(.create) == 0)
        #expect(transport.count(.blik) == 0)
    }

    @Test("A rejected code closes its transaction; the next code creates a new one", arguments: [400, 409, 422])
    func rejectedCode(_ status: Int) async {
        let transport = FlowTransport()
        transport.script(.create, Flow.created(), Flow.created(Flow.secondID.rawValue))
        transport.script(.blik, Flow.http(status), Flow.blikAccepted)
        let engine = await blikEngine(transport)

        await engine.submitBlikCode("111111")
        #expect(engine.state.blikEntry == BlikEntry(transactionID: nil, problem: .codeRejected, remainingAttempts: 4))
        #expect(engine.activeTransactionID == nil)
        #expect(engine.lastRejectedTransactionID == Sample.transactionID)

        await engine.submitBlikCode("222222")
        #expect(engine.state == .awaitingBankConfirmation(Flow.secondID))
        #expect(transport.count(.create) == 2)
        #expect(transport.count(.blik) == 2)
    }

    @Test("Rejections stop at the limit, which matches the Android code (5)")
    func rejectionLimit() async {
        let transport = FlowTransport()
        transport.script(.create, Flow.created())
        transport.script(.blik, Flow.http(409))
        let engine = await blikEngine(transport)

        for attempt in 1...BlikLevel0.maximumRejections {
            #expect(await engine.submitBlikCode("123456"), "attempt \(attempt)")
        }

        guard case .finished(.failed(let error, let id, _)) = engine.state else {
            Issue.record("unexpected state \(engine.state)")
            return
        }
        #expect(BlikLevel0.maximumRejections == 5)
        #expect(error.code == .blikRejected)
        #expect(id == Sample.transactionID)
        #expect(transport.count(.create) == 5)
        #expect(await engine.submitBlikCode("123456") == false)
        #expect(transport.count(.create) == 5)
    }

    @Test("A submission refused without effect keeps the transaction; the next code reuses it", arguments: [401, 429])
    func refusedWithoutEffect(_ status: Int) async {
        let transport = FlowTransport()
        transport.script(.create, Flow.created())
        transport.script(.blik, Flow.http(status), Flow.blikAccepted)
        let engine = await blikEngine(transport)

        await engine.submitBlikCode("111111")
        #expect(engine.state.blikEntry?.transactionID == Sample.transactionID)
        if case .submissionFailed = engine.state.blikEntry?.problem {} else { Issue.record("expected submissionFailed") }
        #expect(await engine.backToChannels() == false)          // the transaction must not be orphaned

        await engine.submitBlikCode("222222")
        #expect(engine.state == .awaitingBankConfirmation(Sample.transactionID))
        #expect(transport.count(.create) == 1)
        #expect(engine.blikRejections == 0)
    }

    @Test("An unclear BLIK submission keeps the transaction and is never repeated", arguments: [500, 504])
    func ambiguousSubmission(_ status: Int) async {
        let transport = FlowTransport()
        transport.script(.create, Flow.created())
        transport.script(.blik, Flow.http(status))
        let engine = await blikEngine(transport)

        await engine.submitBlikCode("111111")

        #expect(engine.state == .checkingStatus(Sample.transactionID, lastStatus: nil))
        #expect(engine.activeTransactionID == Sample.transactionID)
        #expect(await engine.submitBlikCode("222222") == false)
        #expect(transport.count(.blik) == 1)
        #expect(transport.count(.create) == 1)
    }

    @Test("A BLIK timeout keeps the transaction id for verification")
    func blikTimeout() async {
        let transport = FlowTransport()
        transport.script(.create, Flow.created())
        transport.script(.blik, .failure(URLError(.timedOut)))
        let engine = await blikEngine(transport)

        await engine.submitBlikCode("111111")

        #expect(engine.state == .checkingStatus(Sample.transactionID, lastStatus: nil))
        #expect(await engine.close() == .pending(transactionID: Sample.transactionID, status: nil, reason: .statusUnavailable))
    }

    @Test("A timeout while creating the BLIK transaction ends with outcomeUnknown and sends no code")
    func blikCreateTimeout() async {
        let transport = FlowTransport()
        transport.script(.create, .failure(URLError(.networkConnectionLost)))
        let engine = await blikEngine(transport)

        await engine.submitBlikCode("111111")

        if case .outcomeUnknown = engine.result {} else { Issue.record("expected outcomeUnknown") }
        #expect(transport.count(.blik) == 0)
        #expect(await engine.submitBlikCode("222222") == false)
        #expect(transport.count(.create) == 1)
    }

    @Test("Going back from BLIK entry is allowed while no transaction is active")
    func backFromBlik() async {
        let transport = FlowTransport()
        let engine = await blikEngine(transport)

        #expect(await engine.backToChannels())
        #expect(engine.state.name == "channels")
    }
}
