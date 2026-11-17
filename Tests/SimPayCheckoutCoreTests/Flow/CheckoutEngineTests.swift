import Foundation
import Testing
@testable import SimPayCheckoutCore

@MainActor
@Suite("CheckoutEngine: channels and redirect transactions")
struct CheckoutEngineTests {

    private func loadedEngine(_ transport: FlowTransport, channels: StubTransport.Reply = Flow.channels(Flow.blikRedirect, Flow.mbank, Flow.blikLevel0, Flow.euroOnly)) async -> CheckoutEngine {
        transport.script(.channels, channels)
        let engine = Flow.engine(transport)
        await engine.loadChannels()
        return engine
    }

    // MARK: Channels

    @Test("Loads channels, collapses BLIK and puts it first")
    func loadsChannels() async throws {
        let transport = FlowTransport()
        let engine = await loadedEngine(transport)

        guard case .channels(let options) = engine.state else {
            Issue.record("unexpected state \(engine.state)")
            return
        }
        #expect(options.map(\.id) == ["blik-level0", "mbank", "sepa"])
        #expect(options.map(\.isAvailable) == [true, true, false])
        #expect(transport.count(.channels) == 1)
    }

    @Test("A channel load failure can be retried")
    func channelsFailureRetry() async {
        let transport = FlowTransport()
        transport.script(.channels, Flow.http(500), Flow.channels(Flow.mbank))
        let engine = Flow.engine(transport)

        #expect(await engine.loadChannels() == false)
        #expect(engine.state == .failed(SimPayCheckoutError(.channelsFailed, message: "Server error"), canRetry: true))

        #expect(await engine.backToChannels())
        #expect(engine.state.name == "channels")
        #expect(transport.count(.channels) == 2)
    }

    @Test("Loading again while channels are shown is ignored")
    func noReloadWhenLoaded() async {
        let transport = FlowTransport()
        let engine = await loadedEngine(transport)
        #expect(await engine.loadChannels() == false)
        #expect(transport.count(.channels) == 1)
    }

    // MARK: Selection

    @Test("Unavailable or unknown channels cannot be selected and send nothing", arguments: ["sepa", "does-not-exist"])
    func unavailableSelection(_ id: String) async {
        let transport = FlowTransport()
        let engine = await loadedEngine(transport)

        #expect(await engine.selectChannel(id: id) == false)
        #expect(engine.state.name == "channels")
        #expect(transport.count(.create) == 0)
    }

    @Test("Selecting BLIK asks for the code and creates nothing")
    func selectBlik() async {
        let transport = FlowTransport()
        let engine = await loadedEngine(transport)

        #expect(await engine.selectChannel(id: "blik-level0"))
        #expect(engine.state.blikEntry == BlikEntry(transactionID: nil, problem: nil, remainingAttempts: 5))
        #expect(transport.count(.create) == 0)
    }

    @Test("Selecting a bank creates exactly one transaction and prepares the redirect")
    func redirectTransaction() async throws {
        let transport = FlowTransport()
        transport.script(.create, Flow.created())
        let engine = await loadedEngine(transport)
        let recorder = StateRecorder(engine)

        #expect(await engine.selectChannel(id: "mbank"))

        #expect(engine.state == .redirecting(Sample.transactionID, URL(string: "https://secure.simpay.pl/pay/abc")!))
        #expect(engine.activeTransactionID == Sample.transactionID)
        #expect(transport.count(.create) == 1)
        #expect(transport.sentBodies(.create).first?.contains(#""directChannel":"mbank""#) == true)
        #expect(await eventually { recorder.names == ["channels", "creatingTransaction", "redirecting"] })
    }

    @Test("A created transaction without a usable redirect goes to status verification")
    func createdWithoutRedirect() async {
        let transport = FlowTransport()
        transport.script(.create, Flow.created(redirect: nil))
        let engine = await loadedEngine(transport)

        await engine.selectChannel(id: "mbank")

        #expect(engine.state == .checkingStatus(Sample.transactionID, lastStatus: nil))
    }

    @Test("onTransactionCreated reports the id as soon as it is known")
    func transactionCreatedCallback() async {
        let transport = FlowTransport()
        transport.script(.channels, Flow.channels(Flow.mbank))
        transport.script(.create, Flow.created())
        let reported = Box<[TransactionID]>([])
        let engine = Flow.engine(transport) { reported.value.append($0) }

        await engine.loadChannels()
        await engine.selectChannel(id: "mbank")

        #expect(reported.value == [Sample.transactionID])
    }

    // MARK: Single transaction

    @Test("A double tap creates one transaction")
    func doubleTap() async {
        let transport = FlowTransport()
        transport.script(.create, Flow.created())
        let engine = await loadedEngine(transport)

        let first = await engine.selectChannel(id: "mbank")
        let second = await engine.selectChannel(id: "mbank")

        #expect(first && !second)
        #expect(transport.count(.create) == 1)
    }

    @Test("Concurrent selections while the request is in flight create one transaction")
    func concurrentSelections() async {
        let gate = Gate()
        let transport = FlowTransport()
        transport.script(.create, Flow.created())
        transport.hold(.create, with: gate)
        let engine = await loadedEngine(transport)

        let first = Task { await engine.selectChannel(id: "mbank") }
        #expect(await eventually { transport.count(.create) == 1 })
        let others = await [engine.selectChannel(id: "mbank"), engine.selectChannel(id: "blik-level0"), engine.submitBlikCode("123456")]
        await gate.open()

        #expect(await first.value)
        #expect(others == [false, false, false])
        #expect(transport.count(.create) == 1)
    }

    @Test("No second transaction once one is active")
    func noSecondTransaction() async {
        let transport = FlowTransport()
        transport.script(.create, Flow.created())
        let engine = await loadedEngine(transport)

        await engine.selectChannel(id: "mbank")
        #expect(await engine.backToChannels() == false)
        #expect(await engine.loadChannels() == false)
        #expect(await engine.selectChannel(id: "mbank") == false)
        #expect(transport.count(.create) == 1)
        #expect(engine.activeTransactionID == Sample.transactionID)
    }

    // MARK: Create failures

    @Test("A timeout while creating ends with outcomeUnknown, no id, no repetition")
    func createTimeout() async {
        let transport = FlowTransport()
        transport.script(.create, .failure(URLError(.timedOut)))
        let engine = await loadedEngine(transport)

        await engine.selectChannel(id: "mbank")

        guard case .finished(.outcomeUnknown(let error)) = engine.state else {
            Issue.record("unexpected state \(engine.state)")
            return
        }
        #expect(error.code == .outcomeUnknown)
        #expect(engine.result?.transactionID == nil)
        #expect(engine.activeTransactionID == nil)
        #expect(transport.count(.create) == 1)
        #expect(await engine.selectChannel(id: "mbank") == false)
        #expect(await engine.close() == engine.result)
        #expect(transport.count(.create) == 1)
    }

    @Test("Ambiguous POST outcomes all end as outcomeUnknown", arguments: [500, 502, 504, 409])
    func createAmbiguous(_ status: Int) async {
        let transport = FlowTransport()
        transport.script(.create, Flow.http(status))
        let engine = await loadedEngine(transport)

        await engine.selectChannel(id: "mbank")

        #expect(engine.state.name == "finished")
        if case .outcomeUnknown = engine.result {} else { Issue.record("expected outcomeUnknown, got \(String(describing: engine.result))") }
        #expect(transport.count(.create) == 1)
    }

    @Test("A definitive refusal leaves no transaction and allows going back")
    func createRejected() async {
        let transport = FlowTransport()
        transport.script(.create, Flow.http(422), Flow.created())
        let engine = await loadedEngine(transport)

        await engine.selectChannel(id: "mbank")
        guard case .failed(let error, canRetry: true) = engine.state else {
            Issue.record("unexpected state \(engine.state)")
            return
        }
        #expect(error.code == .validationFailed)
        #expect(engine.activeTransactionID == nil)

        #expect(await engine.backToChannels())
        #expect(await engine.selectChannel(id: "mbank"))
        #expect(transport.count(.create) == 2)
    }

    @Test("A missing payer IP fails before anything is sent and cannot be retried")
    func missingPayerIP() async {
        let transport = FlowTransport()
        transport.script(.channels, Flow.channels(Flow.mbank))
        let engine = Flow.engine(transport, provider: ScriptedProvider(payerIP: nil))

        await engine.loadChannels()
        await engine.selectChannel(id: "mbank")

        #expect(engine.state == .failed(SimPayCheckoutError(.missingPayerIP, message: "The session provider did not supply the payer IP required for direct channels"), canRetry: false))
        #expect(transport.count(.create) == 0)
    }

    // MARK: Status

    @Test("Success comes only from the status endpoint")
    func successFromStatusOnly() async {
        let transport = FlowTransport()
        transport.script(.create, Flow.created())
        transport.script(.status, Flow.status("transaction_new"), Flow.status("transaction_paid"))
        let engine = await loadedEngine(transport)

        await engine.selectChannel(id: "mbank")
        #expect(engine.result == nil)

        await engine.checkStatus()
        #expect(engine.state == .checkingStatus(Sample.transactionID, lastStatus: .new))
        await engine.checkStatus()
        #expect(engine.result == .succeeded(transactionID: Sample.transactionID, status: .paid))
    }

    @Test("A failed status read leaves the transaction untouched")
    func statusUnavailable() async {
        let transport = FlowTransport()
        transport.script(.create, Flow.created())
        transport.script(.status, Flow.http(503))
        let engine = await loadedEngine(transport)

        await engine.selectChannel(id: "mbank")
        #expect(await engine.checkStatus() == false)
        #expect(engine.result == nil)
        #expect(engine.activeTransactionID == Sample.transactionID)
    }
}

/// Mutable reference for collecting values from `@Sendable` callbacks on the main actor.
@MainActor
final class Box<Value> {
    var value: Value
    init(_ value: Value) { self.value = value }
}
