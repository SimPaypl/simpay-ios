import Foundation
import Testing
@testable import SimPayCheckout
@testable import SimPayCheckoutCore

@Suite("Redirect and return URL policies")
struct RedirectPolicyTests {

    @Test("Payment pages must be https with a host and no credentials", arguments: [
        ("https://secure.simpay.pl/pay/abc", true),
        ("https://bank.example/pay?token=1#x", true),
        ("http://secure.simpay.pl/pay", false),
        ("javascript:alert(1)", false),
        ("simpayhost://payment-return", false),
        ("ftp://secure.simpay.pl/pay", false),
        ("https://user:secret@secure.simpay.pl/pay", false),
        ("https:///no-host", false),
    ])
    func paymentPage(_ raw: String, _ allowed: Bool) {
        guard let url = URL(string: raw) else {
            #expect(allowed == false)
            return
        }
        #expect(RedirectURLPolicy.isAllowed(url) == allowed)
    }

    @Test("Overlong payment page URLs are refused")
    func overlong() {
        let url = URL(string: "https://secure.simpay.pl/" + String(repeating: "a", count: 5000))!
        #expect(RedirectURLPolicy.isAllowed(url) == false)
    }

    @Test("Return URLs match by scheme, host, port and path; parameters are ignored", arguments: [
        ("simpayhost://payment-return?result=success", true),
        ("simpayhost://payment-return?result=failure", true),
        ("simpayhost://payment-return?result=paid&amount=0", true),
        ("SIMPAYHOST://Payment-Return", true),
        ("simpayhost://payment-return/", true),
        ("simpayhost://other", false),
        ("simpayhost://payment-return/extra", false),
        ("otherapp://payment-return", false),
        ("https://payment-return", false),
        ("javascript://payment-return", false),
        ("simpayhost://user:pw@payment-return", false),
    ])
    func returnURL(_ raw: String, _ matches: Bool) {
        let matcher = ReturnURLMatcher(returnURLs: Sheet.returnURLs)
        #expect(matcher.matches(URL(string: raw)!) == matches, "\(raw)")
    }

    @Test("Universal Link return URLs match their https path only")
    func universalLink() {
        let matcher = ReturnURLMatcher(returnURLs: SimPayReturnURLs(
            success: URL(string: "https://shop.example/pay/return?ok=1")!,
            failure: URL(string: "https://shop.example/pay/return?ok=0")!
        ))
        #expect(matcher.matches(URL(string: "https://shop.example/pay/return?anything")!))
        #expect(matcher.matches(URL(string: "https://SHOP.example/pay/return")!))
        #expect(!matcher.matches(URL(string: "https://evil.example/pay/return")!))
        #expect(!matcher.matches(URL(string: "http://shop.example/pay/return")!))
        #expect(!matcher.matches(URL(string: "https://shop.example:8443/pay/return")!))
    }

    @Test("Without return URLs in the order nothing matches")
    func noReturnURLs() {
        let matcher = ReturnURLMatcher(returnURLs: nil)
        #expect(!matcher.matches(URL(string: "simpayhost://payment-return")!))
    }
}

@MainActor
@Suite("Payment sheet: redirect flow")
struct RedirectFlowTests {

    private let id = Sheet.transactionID

    /// A bank transfer transaction whose payment page was requested.
    private func redirected(
        _ transport: SheetTransport,
        redirect: String = Sheet.paymentPage.absoluteString,
        provider: any SimPaySessionProvider = TestSessionProvider()
    ) async -> (PaymentSheetModel, CheckoutEngine, Box<[SimPayCheckoutResult]>) {
        transport.script(.channels, Sheet.channels(Sheet.blik, Sheet.mbank))
        transport.script(.create, Sheet.created(redirect: redirect))
        let (model, engine, results) = Sheet.model(transport, order: Sheet.order(returns: true), provider: provider)
        model.start()
        _ = await eventually { if case .channels = model.screen { return true } else { return false } }
        model.selectChannel(id: "mbank")
        _ = await eventually { model.screen == .redirecting }
        return (model, engine, results)
    }

    @Test("A bank channel creates one transaction and requests its page once; no polling yet")
    func opensPage() async {
        let transport = SheetTransport()
        let (model, engine, _) = await redirected(transport)

        #expect(model.browser == .requested(Sheet.paymentPage, attempt: 1))
        model.browserDidOpen()
        #expect(model.browser == .open)
        model.selectChannel(id: "mbank")
        try? await Task.sleep(for: .milliseconds(20))

        #expect(model.browser == .open)                          // no second request
        #expect(transport.count(.create) == 1)
        #expect(transport.count(.status) == 0)
        #expect(engine.isPolling == false)
        #expect(engine.activeTransactionID == id)
    }

    @Test("An unsafe payment page is never opened; the transaction is verified instead")
    func unsafePage() async {
        let transport = SheetTransport()
        transport.script(.status, Sheet.status("transaction_new"))
        let (model, engine, _) = await redirected(transport, redirect: "https://user:pw@secure.simpay.pl/pay")

        #expect(model.browser == .closed)
        #expect(await eventually { transport.count(.status) == 1 })
        #expect(engine.isPolling)
        #expect(model.canReopenPaymentPage == false)
    }

    @Test("Closing the browser reads the status; the page can be opened again without a new transaction")
    func closeBrowser() async {
        let transport = SheetTransport()
        transport.script(.status, Sheet.status("transaction_new"))
        let (model, engine, _) = await redirected(transport)
        model.browserDidOpen()

        model.browserDidClose()
        #expect(await eventually { model.screen == .progress(.checkingStatus) && transport.count(.status) == 1 })
        #expect(engine.isPolling)
        #expect(model.canReopenPaymentPage)

        model.reopenPaymentPage()
        #expect(model.browser == .requested(Sheet.paymentPage, attempt: 2))
        #expect(transport.count(.create) == 1)
        #expect(engine.activeTransactionID == id)
    }

    @Test("A browser that cannot open still leads to status verification")
    func browserUnavailable() async {
        let transport = SheetTransport()
        transport.script(.status, Sheet.status("transaction_new"))
        let (model, _, _) = await redirected(transport)

        model.browserFailedToOpen()
        #expect(model.browser == .closed)
        #expect(await eventually { transport.count(.status) == 1 })
        #expect(model.canReopenPaymentPage)
    }

    @Test("A return URL closes the page and reads the status; its parameters are never a success")
    func returnURL() async {
        let transport = SheetTransport()
        transport.script(.status, Sheet.status("transaction_new"))
        let (model, engine, results) = await redirected(transport)
        model.browserDidOpen()

        #expect(model.handleReturnURL(URL(string: "simpayhost://payment-return?result=success")!))
        #expect(model.browser == .closed)
        // Wait until the engine has processed the response, not only until it was sent.
        #expect(await eventually { transport.count(.status) == 1 && engine.lastStatus == .new })
        #expect(model.screen == .progress(.checkingStatus))
        if case .result = model.screen { Issue.record("a return URL must not produce a result") }

        #expect(model.close())
        #expect(await eventually { results.value.count == 1 })
        #expect(results.value == [.pending(transactionID: id, status: .new, reason: .inProgress)])
    }

    @Test("Repeated return URLs read the status again but never create or finish twice")
    func repeatedReturn() async {
        let transport = SheetTransport()
        transport.script(.status, Sheet.status("transaction_new"), Sheet.status("transaction_paid"))
        let (model, _, results) = await redirected(transport)
        model.browserDidOpen()

        let url = URL(string: "simpayhost://payment-return?result=success")!
        #expect(model.handleReturnURL(url))
        #expect(await eventually { transport.count(.status) == 1 })
        #expect(model.handleReturnURL(url))
        let paid = SimPayCheckoutResult.succeeded(transactionID: id, status: .paid)
        #expect(await eventually { model.screen == .result(paid) })

        #expect(model.close())
        #expect(model.handleReturnURL(url) == false)             // after the end: not ours any more
        model.sheetWasDismissed()
        #expect(results.value == [paid])
        #expect(transport.count(.create) == 1)
    }

    @Test("Unrelated or unsafe URLs are not taken", arguments: [
        "otherapp://payment-return", "simpayhost://settings", "javascript://payment-return", "https://payment-return",
    ])
    func unrelatedURL(_ raw: String) async {
        let transport = SheetTransport()
        let (model, _, _) = await redirected(transport)
        model.browserDidOpen()

        #expect(model.handleReturnURL(URL(string: raw)!) == false)
        #expect(model.browser == .open)
        try? await Task.sleep(for: .milliseconds(20))
        #expect(transport.count(.status) == 0)
    }

    @Test("A final status closes the page by itself, for example after paying in a banking app")
    func finalStatusClosesPage() async {
        let transport = SheetTransport()
        transport.script(.status, Sheet.status("transaction_paid"))
        let (model, _, _) = await redirected(transport)
        model.browserDidOpen()

        model.handle(.didEnterBackground)                         // payer switched to the bank app
        model.handle(.willEnterForeground)
        let paid = SimPayCheckoutResult.succeeded(transactionID: id, status: .paid)
        #expect(await eventually { model.screen == .result(paid) })
        #expect(model.browser == .closed)
    }

    @Test("An expired session during the redirect is refreshed through the session store")
    func sessionExpiry() async {
        let transport = SheetTransport()
        let provider = CountingSessionProvider()
        transport.script(.status, Sheet.http(401), Sheet.status("transaction_paid"))
        let (model, _, _) = await redirected(transport, provider: provider)
        model.browserDidOpen()

        #expect(model.handleReturnURL(Sheet.returnURLs.success))
        let paid = SimPayCheckoutResult.succeeded(transactionID: id, status: .paid)
        #expect(await eventually { model.screen == .result(paid) })
        #expect(provider.calls == 2)
        #expect(transport.count(.create) == 1)
    }

    @Test("No connection after the return keeps the transaction pending, never failed")
    func offlineAfterReturn() async {
        let transport = SheetTransport()
        transport.script(.status, .failure(URLError(.notConnectedToInternet)))
        let (model, _, results) = await redirected(transport)
        model.browserDidOpen()

        #expect(model.handleReturnURL(Sheet.returnURLs.failure))
        #expect(await eventually { transport.count(.status) == 1 })
        #expect(model.screen == .progress(.checkingStatus))

        #expect(model.close())
        #expect(await eventually { results.value.count == 1 })
        #expect(results.value == [.pending(transactionID: id, status: nil, reason: .statusUnavailable)])
        #expect(transport.count(.create) == 1)
    }

    @Test("Closing on the payment page screen reports the transaction as pending")
    func closeWhileRedirecting() async {
        let transport = SheetTransport()
        let (model, _, results) = await redirected(transport)

        #expect(model.isDismissLocked == false)
        #expect(model.close())
        #expect(await eventually { results.value.count == 1 })
        #expect(results.value.first?.transactionID == id)
        if case .pending = results.value.first {} else { Issue.record("\(results.value)") }
        #expect(model.browser == .closed)
    }
}
