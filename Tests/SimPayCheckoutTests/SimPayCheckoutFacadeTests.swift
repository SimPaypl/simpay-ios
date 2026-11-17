#if os(iOS)
import Foundation
import Testing
import UIKit
@testable import SimPayCheckout
@testable import SimPayCheckoutCore

/// Records presentations instead of using UIKit; the package test host has no app.
@MainActor
final class FakePresenter: SheetPresenter {
    var hostAvailable = true
    var refusesPresentation = false
    private(set) var presented: [UIViewController] = []
    private(set) var dismissed = 0

    func presentationHost(from viewController: UIViewController) -> UIViewController? {
        hostAvailable ? viewController : nil
    }
    func present(_ sheet: UIViewController, from host: UIViewController) -> Bool {
        guard !refusesPresentation else { return false }
        presented.append(sheet)
        return true
    }
    func dismiss(_ sheet: UIViewController, completion: @escaping @MainActor () -> Void) {
        dismissed += 1
        completion()
    }

    var model: PaymentSheetModel? { (presented.last as? PaymentSheetController)?.model }
}

@MainActor
@Suite("SimPayCheckout facade", .serialized)
struct SimPayCheckoutFacadeTests {

    private func checkout(_ transport: SheetTransport, presenter: FakePresenter, center: NotificationCenter = NotificationCenter()) -> SimPayCheckout {
        var dependencies = CheckoutDependencies()
        dependencies.transport = transport
        dependencies.presenter = presenter
        dependencies.clock = Sheet.idleClock
        return SimPayCheckout(
            configuration: SimPayConfiguration(merchantDisplayName: "Sklep Testowy", environment: Sheet.environment),
            sessionProvider: TestSessionProvider(),
            dependencies: dependencies,
            notificationCenter: center
        )
    }

    @Test("Configuration rejects an invalid service id and points to production")
    func configuration() {
        #expect(SimPayConfiguration(serviceID: "../x", merchantDisplayName: "Shop") == nil)
        let configuration = SimPayConfiguration(serviceID: "a1b2c3d4", merchantDisplayName: "  Shop  ")
        #expect(configuration?.merchantDisplayName == "Shop")
        #expect(configuration?.environment.baseURL == APIEnvironment.productionBaseURL)
    }

    @Test("present shows one sheet and delivers exactly one result")
    func presentOnce() async {
        let transport = SheetTransport()
        transport.script(.channels, Sheet.channels(Sheet.blik))
        let presenter = FakePresenter()
        let checkout = checkout(transport, presenter: presenter)
        let results = Box<[SimPayCheckoutResult]>([])

        checkout.present(Sheet.order(), from: UIViewController()) { results.value.append($0) }
        #expect(checkout.isPresenting)
        #expect(presenter.presented.count == 1)
        #expect(await eventually { if case .channels = presenter.model?.screen { return true } else { return false } })

        presenter.model?.close()
        presenter.model?.sheetWasDismissed()
        #expect(await eventually { results.value.count == 1 })
        try? await Task.sleep(for: .milliseconds(20))

        #expect(results.value == [.cancelled])
        #expect(presenter.dismissed == 1)
        #expect(checkout.isPresenting == false)
    }

    @Test("A second present while a sheet is shown fails at once, also from another instance")
    func alreadyPresented() async {
        let presenter = FakePresenter()
        let first = checkout(SheetTransport(), presenter: presenter)
        let second = checkout(SheetTransport(), presenter: presenter)
        let results = Box<[SimPayCheckoutResult]>([])

        first.present(Sheet.order(), from: UIViewController()) { results.value.append($0) }
        first.present(Sheet.order(), from: UIViewController()) { results.value.append($0) }
        let fromOther = await second.present(Sheet.order(), from: UIViewController())

        let expected = SimPayCheckoutError.Code.alreadyPresented
        if case .failed(let error, nil, nil) = results.value.first { #expect(error.code == expected) } else { Issue.record("\(results.value)") }
        if case .failed(let error, nil, nil) = fromOther { #expect(error.code == expected) } else { Issue.record("\(fromOther)") }
        #expect(presenter.presented.count == 1)

        presenter.model?.close()
        #expect(await eventually { results.value.count == 2 })
        #expect(results.value.last == .cancelled)

        // Free again after the result.
        second.present(Sheet.order(), from: UIViewController()) { results.value.append($0) }
        #expect(presenter.presented.count == 2)
        presenter.model?.close()
        #expect(await eventually { results.value.count == 3 })
    }

    @Test("A controller that cannot present reports presentation_failed and creates nothing")
    func presentationFailed() async {
        let transport = SheetTransport()
        let presenter = FakePresenter()
        presenter.hostAvailable = false
        let result = await checkout(transport, presenter: presenter).present(Sheet.order(), from: UIViewController())

        if case .failed(let error, nil, nil) = result { #expect(error.code == .presentationFailed) } else { Issue.record("\(result)") }
        #expect(presenter.presented.isEmpty)
        #expect(transport.count(.channels) == 0)
    }

    @Test("A presentation refused by UIKit reports presentation_failed and leaves the SDK usable")
    func presentationRefused() async {
        let transport = SheetTransport()
        transport.script(.channels, Sheet.channels(Sheet.blik))
        let presenter = FakePresenter()
        presenter.refusesPresentation = true
        let checkout = checkout(transport, presenter: presenter)

        let result = await checkout.present(Sheet.order(), from: UIViewController())
        if case .failed(let error, nil, nil) = result { #expect(error.code == .presentationFailed) } else { Issue.record("\(result)") }
        #expect(checkout.isPresenting == false)
        #expect(transport.count(.channels) == 0)

        presenter.refusesPresentation = false
        let results = Box<[SimPayCheckoutResult]>([])
        checkout.present(Sheet.order(), from: UIViewController()) { results.value.append($0) }
        #expect(presenter.presented.count == 1)
        presenter.model?.close()
        #expect(await eventually { results.value == [.cancelled] })
    }

    @Test("The completion API delivers the result even when the caller keeps no reference")
    func unretainedCheckout() async {
        let transport = SheetTransport()
        transport.script(.channels, Sheet.channels(Sheet.blik))
        let presenter = FakePresenter()
        let results = Box<[SimPayCheckoutResult]>([])
        weak var released: SimPayCheckout?

        do {
            let checkout = checkout(transport, presenter: presenter)
            released = checkout
            checkout.present(Sheet.order(), from: UIViewController()) { results.value.append($0) }
        }
        #expect(released != nil)
        presenter.model?.close()
        #expect(await eventually { results.value == [.cancelled] })

        // Free again: another instance can present.
        let next = checkout(transport, presenter: presenter)
        next.present(Sheet.order(), from: UIViewController()) { results.value.append($0) }
        #expect(presenter.presented.count == 2)
        presenter.model?.close()
        #expect(await eventually { results.value.count == 2 })
    }

    @Test("Swipe is refused during POST; a programmatic dismissal settles the request first")
    func dismissalDuringPost() async {
        let transport = SheetTransport()
        let gate = Gate()
        transport.script(.channels, Sheet.channels(Sheet.blik))
        transport.script(.create, Sheet.created)
        transport.hold(.create, with: gate)
        let presenter = FakePresenter()
        let created = Box<[TransactionID]>([])
        let results = Box<[SimPayCheckoutResult]>([])
        let checkout = checkout(transport, presenter: presenter)

        checkout.present(Sheet.order(), from: UIViewController(), onTransactionCreated: { id in
            MainActor.assumeIsolated { created.value.append(id) }
        }) { results.value.append($0) }
        let controller = presenter.presented.first as! PaymentSheetController
        let model = controller.model
        #expect(await eventually { if case .channels = model.screen { return true } else { return false } })
        model.selectChannel(id: "blik-level0")
        #expect(await eventually { if case .blikEntry = model.screen { return true } else { return false } })
        model.updateBlikCode("482913")
        model.submitBlikCode()
        #expect(await eventually { model.isDismissLocked })

        let sheetPresentation = controller.presentationController!
        #expect(controller.isModalInPresentation)
        #expect(controller.presentationControllerShouldDismiss(sheetPresentation) == false)

        controller.presentationControllerDidDismiss(sheetPresentation)   // forced by the host app
        try? await Task.sleep(for: .milliseconds(20))
        #expect(results.value.isEmpty)

        await gate.open()
        #expect(await eventually { results.value.count == 1 })
        #expect(results.value == [.pending(transactionID: Sheet.transactionID, status: nil, reason: .statusUnavailable)])
        #expect(created.value == [Sheet.transactionID])
        #expect(transport.count(.create) == 1)
        #expect(transport.count(.blik) == 0)
    }

    @Test("Application notifications reach the engine while the sheet is shown, and stop after")
    func lifecycleNotifications() async {
        let transport = SheetTransport()
        transport.script(.channels, Sheet.channels(Sheet.blik))
        transport.script(.create, Sheet.created)
        transport.script(.blik, Sheet.blikAccepted)
        transport.script(.status, Sheet.status("transaction_new"))
        let presenter = FakePresenter()
        let center = NotificationCenter()
        let checkout = checkout(transport, presenter: presenter, center: center)
        let results = Box<[SimPayCheckoutResult]>([])
        checkout.present(Sheet.order(), from: UIViewController()) { results.value.append($0) }
        let model = presenter.model!

        #expect(await eventually { if case .channels = model.screen { return true } else { return false } })
        model.selectChannel(id: "blik-level0")
        #expect(await eventually { if case .blikEntry = model.screen { return true } else { return false } })
        model.updateBlikCode("482913")
        model.submitBlikCode()
        #expect(await eventually { transport.count(.status) == 1 })

        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        #expect(await eventually { transport.count(.status) == 2 })   // immediate read on return
        #expect(transport.count(.create) == 1)

        model.close()
        #expect(await eventually { results.value.count == 1 })
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        try? await Task.sleep(for: .milliseconds(30))
        #expect(transport.count(.status) == 2)
    }

    @Test("Lifecycle observer maps notifications and can be stopped")
    func observer() {
        let center = NotificationCenter()
        let events = Box<[AppLifecycleEvent]>([])
        let observer = AppLifecycleObserver(center: center) { events.value.append($0) }
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.post(name: UIApplication.willEnterForegroundNotification, object: nil)
        observer.stop()
        center.post(name: UIApplication.didEnterBackgroundNotification, object: nil)

        #expect(events.value == [.didEnterBackground, .willEnterForeground])
    }

    @Test("Return URLs reach the checkout being shown, only for its transaction and only while shown")
    func returnURLRouting() async {
        let transport = SheetTransport()
        transport.script(.channels, Sheet.channels(Sheet.mbank))
        transport.script(.create, Sheet.created(redirect: Sheet.paymentPage.absoluteString))
        transport.script(.status, Sheet.status("transaction_new"))
        let presenter = FakePresenter()
        let checkout = checkout(transport, presenter: presenter)
        let results = Box<[SimPayCheckoutResult]>([])
        let returnURL = URL(string: "simpayhost://payment-return?result=success")!

        #expect(SimPayCheckout.handleReturnURL(returnURL) == false)           // nothing shown
        checkout.present(Sheet.order(returns: true), from: UIViewController()) { results.value.append($0) }
        let model = presenter.model!
        #expect(await eventually { if case .channels = model.screen { return true } else { return false } })
        #expect(SimPayCheckout.handleReturnURL(returnURL) == false)           // no transaction yet

        model.selectChannel(id: "mbank")
        #expect(await eventually { model.screen == .redirecting })
        #expect(SimPayCheckout.handleReturnURL(URL(string: "simpayhost://elsewhere")!) == false)

        let activity = NSUserActivity(activityType: NSUserActivityTypeBrowsingWeb)
        activity.webpageURL = URL(string: "https://shop.example/unrelated")
        #expect(SimPayCheckout.handleUserActivity(activity) == false)

        #expect(SimPayCheckout.handleReturnURL(returnURL))
        #expect(await eventually { transport.count(.status) == 1 })
        #expect(checkout.handleReturnURL(returnURL))

        model.close()
        #expect(await eventually { results.value.count == 1 })
        #expect(SimPayCheckout.handleReturnURL(returnURL) == false)           // after the result
        #expect(results.value.count == 1)
        #expect(transport.count(.create) == 1)
    }

    @Test("User-Agent has the Mobile Safari form and no identifiers")
    func userAgent() {
        #expect(DeviceUserAgent.make(systemVersion: "18.1", isPad: false)
            == "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1")
        #expect(DeviceUserAgent.make(systemVersion: "17.4.1", isPad: true).contains("iPad; CPU OS 17_4_1 like Mac OS X"))
    }

    @Test("transactionStatus reads one status without presenting anything")
    func statusRecovery() async throws {
        let transport = SheetTransport()
        transport.script(.status, Sheet.status("transaction_paid"))
        let presenter = FakePresenter()
        let result = try await checkout(transport, presenter: presenter).transactionStatus(of: Sheet.transactionID)

        #expect(result == .succeeded(transactionID: Sheet.transactionID, status: .paid))
        #expect(transport.count(.status) == 1)
        #expect(presenter.presented.isEmpty)
    }
}
#endif
