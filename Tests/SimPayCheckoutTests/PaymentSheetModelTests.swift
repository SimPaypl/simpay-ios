import Foundation
import Testing
@testable import SimPayCheckout
@testable import SimPayCheckoutCore

@MainActor
@Suite("Payment sheet model")
struct PaymentSheetModelTests {

    private func loaded(_ transport: SheetTransport) async -> (PaymentSheetModel, CheckoutEngine, Box<[SimPayCheckoutResult]>) {
        let (model, engine, results) = Sheet.model(transport)
        model.start()
        _ = await eventually { if case .channels = model.screen { return true } else { return false } }
        return (model, engine, results)
    }

    private func blikEntry(_ transport: SheetTransport) async -> (PaymentSheetModel, CheckoutEngine, Box<[SimPayCheckoutResult]>) {
        transport.script(.channels, Sheet.channels(Sheet.mbank, Sheet.blik))
        let tuple = await loaded(transport)
        tuple.0.selectChannel(id: "blik-level0")
        _ = await eventually { if case .blikEntry = tuple.0.screen { return true } else { return false } }
        return tuple
    }

    // MARK: Channels

    @Test("Loads channels with BLIK first; payment page channels are selectable")
    func channels() async {
        let transport = SheetTransport()
        transport.script(.channels, Sheet.channels(Sheet.mbank, Sheet.blik, Sheet.euro))
        let (model, _, _) = await loaded(transport)

        guard case .channels(let list) = model.screen else {
            Issue.record("unexpected \(model.screen)")
            return
        }
        #expect(list.blik?.id == "blik-level0")
        #expect(list.blik?.isSelectable == true)
        #expect(list.others.map(\.id) == ["mbank", "sepa"])
        #expect(list.others.map(\.unavailability) == [nil, .currencyNotSupported])
        #expect(model.isDismissLocked == false)
    }

    @Test("A channel that cannot be continued never creates a transaction")
    func unavailableChannel() async {
        let transport = SheetTransport()
        transport.script(.channels, Sheet.channels(Sheet.blik, Sheet.euro))
        let (model, _, _) = await loaded(transport)

        model.selectChannel(id: "sepa")
        try? await Task.sleep(for: .milliseconds(30))

        #expect(transport.count(.create) == 0)
        if case .channels = model.screen {} else { Issue.record("left the channel list: \(model.screen)") }
    }

    @Test("A channel load failure can be retried")
    func channelFailure() async {
        let transport = SheetTransport()
        transport.script(.channels, Sheet.http(503), Sheet.channels(Sheet.blik))
        let (model, _, _) = Sheet.model(transport)
        model.start()

        #expect(await eventually { model.screen == .failure(SimPayCheckoutError(.channelsFailed, message: "Server error"), canRetry: true) })
        model.retry()
        #expect(await eventually { if case .channels = model.screen { return true } else { return false } })
        #expect(transport.count(.channels) == 2)
    }

    @Test("No channels shows the empty state")
    func emptyChannels() async {
        let transport = SheetTransport()
        transport.script(.channels, Sheet.channels())
        let (model, _, _) = Sheet.model(transport)
        model.start()
        #expect(await eventually { model.screen == .emptyChannels })
    }

    // MARK: BLIK

    @Test("Selecting BLIK opens code entry without contacting the API")
    func selectBlik() async {
        let transport = SheetTransport()
        let (model, _, _) = await blikEntry(transport)

        guard case .blikEntry(let entry, let canChange) = model.screen else { Issue.record("unexpected \(model.screen)"); return }
        #expect(entry.transactionID == nil)
        #expect(canChange)
        #expect(transport.count(.create) == 0)
    }

    @Test("The code field keeps six ASCII digits only", arguments: [
        ("123456", "123456"), ("12 34 56", "123456"), ("1234567", "123456"),
        ("12a3b4", "1234"), ("١٢٣٤٥٦", ""), ("", ""),
    ])
    func sanitizing(_ input: String, _ expected: String) async {
        let (model, _, _) = Sheet.model(SheetTransport())
        model.updateBlikCode(input)
        #expect(model.blikCode == expected)
    }

    @Test("Pay is enabled only with six digits")
    func validation() async {
        let transport = SheetTransport()
        let (model, _, _) = await blikEntry(transport)

        model.updateBlikCode("12345")
        #expect(model.canSubmitBlikCode == false)
        model.submitBlikCode()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(transport.count(.create) == 0)

        model.updateBlikCode("123456")
        #expect(model.canSubmitBlikCode)
    }

    @Test("Submitting twice sends one code; the code is cleared at once; the bank prompt follows")
    func singleSubmission() async {
        let transport = SheetTransport()
        transport.script(.create, Sheet.created)
        transport.script(.blik, Sheet.blikAccepted)
        let (model, _, _) = await blikEntry(transport)

        model.updateBlikCode("482913")
        model.submitBlikCode()
        #expect(model.blikCode.isEmpty)
        model.submitBlikCode()
        model.updateBlikCode("482913")
        model.submitBlikCode()

        #expect(await eventually { model.screen == .awaitingBank })
        #expect(transport.count(.create) == 1)
        #expect(transport.count(.blik) == 1)
        #expect(model.isDismissLocked == false)
    }

    @Test("A rejected code shows the problem and an empty field; a new payment follows")
    func rejectedCode() async {
        let transport = SheetTransport()
        transport.script(.create, Sheet.created)
        transport.script(.blik, Sheet.http(409))
        let (model, _, _) = await blikEntry(transport)

        model.updateBlikCode("111111")
        model.submitBlikCode()

        #expect(await eventually {
            if case .blikEntry(let entry, true) = model.screen { return entry.problem == .codeRejected } else { return false }
        })
        #expect(model.blikCode.isEmpty)
    }

    // MARK: Dismissal

    @Test("The sheet is locked while the transaction is being created; a close request is refused")
    func lockedDuringPost() async {
        let transport = SheetTransport()
        let gate = Gate()
        transport.script(.create, Sheet.created)
        transport.script(.blik, Sheet.blikAccepted)
        transport.hold(.create, with: gate)
        let (model, _, results) = await blikEntry(transport)

        model.updateBlikCode("482913")
        model.submitBlikCode()
        #expect(await eventually { model.screen == .progress(.preparingPayment) })
        #expect(model.isDismissLocked)
        #expect(model.close() == false)

        await gate.open()
        #expect(await eventually { model.screen == .awaitingBank })
        #expect(model.isDismissLocked == false)
        #expect(results.value.isEmpty)
    }

    @Test("A forced dismissal during POST waits for it; no code is sent and the result is not cancelled")
    func forcedDismissDuringPost() async {
        let transport = SheetTransport()
        let gate = Gate()
        transport.script(.create, Sheet.created)
        transport.hold(.create, with: gate)
        let (model, _, results) = await blikEntry(transport)
        model.updateBlikCode("482913")
        model.submitBlikCode()
        #expect(await eventually { transport.count(.create) == 1 })

        model.sheetWasDismissed()
        try? await Task.sleep(for: .milliseconds(20))
        #expect(results.value.isEmpty)                            // settled first

        await gate.open()
        #expect(await eventually { results.value.count == 1 })
        #expect(results.value == [.pending(transactionID: Sheet.transactionID, status: nil, reason: .statusUnavailable)])
        #expect(transport.count(.blik) == 0)
    }

    @Test("An unclear create outcome is reported as outcomeUnknown, never cancelled")
    func unclearCreate() async {
        let transport = SheetTransport()
        transport.script(.create, .failure(URLError(.timedOut)))
        let (model, _, results) = await blikEntry(transport)
        model.updateBlikCode("482913")
        model.submitBlikCode()

        #expect(await eventually { if case .result(.outcomeUnknown) = model.screen { return true } else { return false } })
        #expect(model.close())
        if case .outcomeUnknown = results.value.first {} else { Issue.record("unexpected \(results.value)") }
    }

    @Test("Closing before any transaction is cancelled")
    func closeBeforeTransaction() async {
        let transport = SheetTransport()
        let (model, _, results) = await blikEntry(transport)

        #expect(model.close())
        #expect(await eventually { results.value == [.cancelled] })
        #expect(transport.count(.create) == 0)
    }

    @Test("Closing while waiting for the bank is pending with the transaction id")
    func closeAfterTransaction() async {
        let transport = SheetTransport()
        transport.script(.create, Sheet.created)
        transport.script(.blik, Sheet.blikAccepted)
        let (model, _, results) = await blikEntry(transport)
        model.updateBlikCode("482913")
        model.submitBlikCode()
        #expect(await eventually { model.screen == .awaitingBank })

        #expect(model.close())
        #expect(await eventually { results.value.count == 1 })
        #expect(results.value.first?.transactionID == Sheet.transactionID)
        if case .pending = results.value.first {} else { Issue.record("unexpected \(results.value)") }
    }

    @Test("A result shown by the sheet is delivered once, on Done")
    func resultOnce() async {
        let transport = SheetTransport()
        transport.script(.create, Sheet.created)
        transport.script(.blik, Sheet.blikAccepted)
        transport.script(.status, Sheet.status("transaction_paid"))
        let (model, _, results) = await blikEntry(transport)
        model.updateBlikCode("482913")
        model.submitBlikCode()

        let paid = SimPayCheckoutResult.succeeded(transactionID: Sheet.transactionID, status: .paid)
        #expect(await eventually { model.screen == .result(paid) })
        #expect(results.value.isEmpty)                            // shown first, delivered on Done

        #expect(model.close())
        model.sheetWasDismissed()
        #expect(model.close() == false)
        #expect(results.value == [paid])
    }

    // MARK: Lifecycle

    @Test("Background pauses polling and foreground resumes it; nothing new is created")
    func lifecycle() async {
        let transport = SheetTransport()
        transport.script(.create, Sheet.created)
        transport.script(.blik, Sheet.blikAccepted)
        transport.script(.status, Sheet.status("transaction_new"))
        let (model, engine, _) = await blikEntry(transport)
        model.updateBlikCode("482913")
        model.submitBlikCode()
        #expect(await eventually { engine.isPolling && transport.count(.status) == 1 })

        model.handle(.didEnterBackground)
        #expect(engine.isPolling == false)
        model.handle(.willEnterForeground)
        #expect(await eventually { transport.count(.status) == 2 })
        #expect(engine.isPolling)
        #expect(model.screen == .awaitingBank)
        #expect(transport.count(.create) == 1)
        #expect(transport.count(.blik) == 1)
    }
}
