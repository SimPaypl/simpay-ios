import XCTest

/// End-to-end tests of the SDK in a real app on the simulator, against the mocked API of
/// the integration host. No network and no real payment is involved.
///
/// Screenshots are attached to the results and, when `SIMPAY_SCREENSHOT_DIR` is set
/// (`TEST_RUNNER_SIMPAY_SCREENSHOT_DIR=/tmp/shots xcodebuild test ...`), written there.
final class CheckoutIntegrationUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(_ scenario: String, language: String = "pl", extra: [String] = []) {
        app = XCUIApplication()
        app.launchArguments = ["-scenario", scenario, "-AppleLanguages", "(\(language))", "-AppleLocale", language == "pl" ? "pl_PL" : "en_US"] + extra
        app.launch()
    }

    // MARK: Helpers

    private func element(_ identifier: String) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    private func waitFor(_ element: XCUIElement, _ timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: timeout), "missing \(element)", file: file, line: line)
    }

    private func waitForLabel(_ element: XCUIElement, containing text: String, timeout: TimeInterval = 15, file: StaticString = #filePath, line: UInt = #line) {
        let predicate = NSPredicate(format: "label CONTAINS %@", text)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: element)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: timeout), .completed, "\(element) never contained \"\(text)\"", file: file, line: line)
    }

    private func openSheet(uikit: Bool = false) {
        app.buttons[uikit ? "host.pay.uikit" : "host.pay.swiftui"].tap()
        waitFor(app.buttons["simpay.channel.blik-level0"])
    }

    private func payWithBlik(_ code: String = "482913") {
        app.buttons["simpay.channel.blik-level0"].tap()
        waitFor(app.buttons["simpay.blik.pay"])
        app.typeText(code)
        app.buttons["simpay.blik.pay"].tap()
    }

    /// Opens a URL through the system, as a bank page or another app would. Unlike
    /// `XCUIApplication.open`, this does not relaunch the app, so the checkout survives.
    private func openFromSystem(_ url: URL) {
        XCUIDevice.shared.system.open(url)
        let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let confirm = springboard.buttons.matching(NSPredicate(format: "label IN %@", ["Open", "Otwórz"])).firstMatch
        if confirm.waitForExistence(timeout: 2) { confirm.tap() }
        XCTAssertEqual(app.wait(for: .runningForeground, timeout: 5), true)
    }

    /// The close button of SFSafariViewController (not the sheet's own close button).
    private var safariCloseButton: XCUIElement {
        app.buttons.matching(NSPredicate(format: "(identifier == 'CancelBarItemButton' OR label == 'Zamknij' OR label == 'Close' OR label == 'Done' OR label == 'Gotowe' OR label == 'Anuluj' OR label == 'Cancel') AND identifier != 'simpay.close' AND identifier != 'simpay.done'")).firstMatch
    }

    private func screenshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let directory = ProcessInfo.processInfo.environment["SIMPAY_SCREENSHOT_DIR"] {
            try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
            try? shot.pngRepresentation.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(name).png"))
        }
    }

    // MARK: BLIK

    func testBlikPaymentSucceedsOnlyFromStatus() {
        launch("blikPaid")
        screenshot("host-01-start")
        openSheet()
        screenshot("host-02-channels")

        app.buttons["simpay.channel.blik-level0"].tap()
        waitFor(app.buttons["simpay.blik.pay"])
        XCTAssertFalse(app.buttons["simpay.blik.pay"].isEnabled)
        app.typeText("4829")
        XCTAssertFalse(app.buttons["simpay.blik.pay"].isEnabled)
        app.typeText("13")
        XCTAssertTrue(app.buttons["simpay.blik.pay"].isEnabled)
        screenshot("host-03-blik-code")
        app.buttons["simpay.blik.pay"].tap()

        waitForLabel(element("simpay.awaiting"), containing: "Potwierdź płatność")
        screenshot("host-04-awaiting-bank")
        waitForLabel(element("simpay.result"), containing: "Płatność zakończona")
        screenshot("host-05-success")
        app.buttons["simpay.done"].tap()

        waitForLabel(app.staticTexts["host.results"], containing: "succeeded")
        XCTAssertEqual(app.staticTexts["host.results"].label, "succeeded")
        XCTAssertEqual(app.staticTexts["host.created"].label, "transactions created: 1")
    }

    func testRejectedCodeCanBeCorrected() {
        launch("blikRejectedThenPaid")
        openSheet()
        payWithBlik("111111")
        waitFor(element("simpay.blik.problem"))
        XCTAssertTrue(element("simpay.blik.problem").label.contains("błędny kod"))
        screenshot("host-06-blik-rejected")

        app.typeText("222222")
        app.buttons["simpay.blik.pay"].tap()
        waitForLabel(element("simpay.result"), containing: "Płatność zakończona")
        app.buttons["simpay.done"].tap()
        waitForLabel(app.staticTexts["host.results"], containing: "succeeded")
        XCTAssertEqual(app.staticTexts["host.created"].label, "transactions created: 2")
    }

    func testUnknownCreateOutcomeIsNeitherFailureNorCancel() {
        launch("createTimeout")
        openSheet()
        payWithBlik()
        waitForLabel(element("simpay.result"), containing: "Nie możemy potwierdzić płatności")
        XCTAssertTrue(element("simpay.result").label.contains("Nie płać ponownie"))
        screenshot("host-07-outcome-unknown")
        app.buttons["simpay.done"].tap()
        waitForLabel(app.staticTexts["host.results"], containing: "outcomeUnknown")
    }

    // MARK: Redirect

    func testRedirectReturnThroughURLScheme() {
        launch("redirectPaidAfterReturn")
        openSheet()
        app.buttons["simpay.channel.mbank"].tap()

        waitFor(safariCloseButton, 15)
        screenshot("host-08-payment-page")

        // The bank sends the payer back through the app's URL scheme.
        let returnURL = URL(string: "simpayhost://payment-return?result=success")!
        openFromSystem(returnURL)
        waitForLabel(element("simpay.result"), containing: "Płatność zakończona", timeout: 20)
        XCTAssertFalse(safariCloseButton.exists)
        screenshot("host-09-paid-after-return")

        // A second delivery of the same deep link changes nothing.
        openFromSystem(returnURL)
        app.buttons["simpay.done"].tap()
        waitForLabel(app.staticTexts["host.results"], containing: "succeeded")
        XCTAssertEqual(app.staticTexts["host.results"].label, "succeeded")
        XCTAssertEqual(app.staticTexts["host.created"].label, "transactions created: 1")
        waitForLabel(app.staticTexts["host.returns"], containing: "count: 2")
    }

    func testClosingTheBrowserChecksStatusAndAllowsReopening() {
        launch("redirectPending")
        openSheet()
        app.buttons["simpay.channel.mbank"].tap()
        waitFor(safariCloseButton, 15)
        safariCloseButton.tap()

        waitFor(app.buttons["simpay.redirect.reopen"])
        screenshot("host-10-after-browser-closed")
        app.buttons["simpay.redirect.reopen"].tap()
        waitFor(safariCloseButton, 15)
        safariCloseButton.tap()
        waitFor(app.buttons["simpay.redirect.reopen"])

        app.buttons["simpay.close"].tap()
        waitForLabel(app.staticTexts["host.results"], containing: "pending")
        XCTAssertEqual(app.staticTexts["host.created"].label, "transactions created: 1")
    }

    func testManualReturnFromBackground() {
        launch("redirectPaidAfterReturn")
        openSheet()
        app.buttons["simpay.channel.mbank"].tap()
        waitFor(safariCloseButton, 15)

        // The payer leaves for a banking app and comes back by hand, without a deep link.
        XCUIDevice.shared.press(.home)
        sleep(2)
        app.activate()
        waitFor(safariCloseButton, 10)
        safariCloseButton.tap()
        waitFor(app.buttons["simpay.redirect.reopen"])
        XCTAssertFalse(element("simpay.result").exists)          // returning is not a payment

        app.buttons["simpay.close"].tap()
        waitForLabel(app.staticTexts["host.results"], containing: "pending")
        XCTAssertEqual(app.staticTexts["host.created"].label, "transactions created: 1")
    }

    func testExpiredSessionDuringRedirectIsRefreshed() {
        launch("sessionExpiredThenPaid")
        openSheet()
        app.buttons["simpay.channel.mbank"].tap()
        waitFor(safariCloseButton, 15)
        openFromSystem(URL(string: "simpayhost://payment-return?result=success")!)
        waitForLabel(element("simpay.result"), containing: "Płatność zakończona", timeout: 20)
        app.buttons["simpay.done"].tap()
        waitForLabel(app.staticTexts["host.results"], containing: "succeeded")
    }

    func testLostConnectionAfterReturnStaysPending() {
        launch("statusOffline")
        openSheet()
        app.buttons["simpay.channel.mbank"].tap()
        waitFor(safariCloseButton, 15)
        openFromSystem(URL(string: "simpayhost://payment-return?result=success")!)
        waitFor(app.buttons["simpay.redirect.reopen"], 15)
        XCTAssertFalse(element("simpay.result").exists)
        app.buttons["simpay.close"].tap()
        waitForLabel(app.staticTexts["host.results"], containing: "pending(status_unavailable)")
    }

    func testUnrelatedDeepLinkIsIgnored() {
        launch("redirectPending")
        openFromSystem(URL(string: "simpayhost://payment-return?result=success")!)   // no checkout yet
        waitForLabel(app.staticTexts["host.returns"], containing: "count: 1")
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'ignored'")).firstMatch.exists)
    }

    // MARK: Lifecycle

    func testBackgroundDuringBankConfirmationKeepsTheTransaction() {
        launch("blikPending")
        openSheet()
        payWithBlik()
        waitForLabel(element("simpay.awaiting"), containing: "Potwierdź płatność")

        XCUIDevice.shared.press(.home)
        sleep(3)
        app.activate()
        waitForLabel(element("simpay.awaiting"), containing: "Potwierdź płatność")

        app.buttons["simpay.close"].tap()
        waitForLabel(app.staticTexts["host.results"], containing: "pending")
        XCTAssertEqual(app.staticTexts["host.created"].label, "transactions created: 1")
    }

    func testTerminatedAppStartsCleanWithoutNewTransaction() {
        launch("blikPending")
        openSheet()
        payWithBlik()
        waitForLabel(element("simpay.awaiting"), containing: "Potwierdź płatność")
        app.terminate()

        launch("blikPending")
        XCTAssertFalse(app.buttons["simpay.channel.blik-level0"].exists)
        XCTAssertEqual(app.staticTexts["host.created"].label, "transactions created: 0")
    }

    // MARK: Presentation

    func testPresentFromUIKitAndCancelBeforeTransaction() {
        launch("blikPaid")
        openSheet(uikit: true)
        app.buttons["simpay.close"].tap()
        waitForLabel(app.staticTexts["host.results"], containing: "cancelled")
        XCTAssertEqual(app.staticTexts["host.created"].label, "transactions created: 0")
    }

    func testChannelErrorAndEnglish() {
        launch("channelsError", language: "en")
        app.buttons["host.pay.swiftui"].tap()
        waitFor(app.buttons["simpay.retry"], 15)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'temporarily unavailable'")).firstMatch.exists
            || app.otherElements.matching(NSPredicate(format: "label CONTAINS 'temporarily unavailable'")).firstMatch.exists)
        screenshot("host-11-channels-error-en")
        // Closing after a failure before any transaction reports that failure (as on Android).
        app.buttons["simpay.close"].tap()
        waitForLabel(app.staticTexts["host.results"], containing: "failed(channels_failed)")
    }

    // MARK: Accessibility

    func testVoiceOverLabels() {
        launch("blikPaid")
        openSheet()
        XCTAssertEqual(app.buttons["simpay.close"].label, "Zamknij")
        XCTAssertTrue(app.buttons["simpay.channel.blik-level0"].label.contains("BLIK"))
        XCTAssertTrue(app.buttons["simpay.channel.mbank"].label.contains("mBank"))
        XCTAssertEqual(element("simpay.amount").label.contains("149,99"), true)

        app.buttons["simpay.channel.blik-level0"].tap()
        let field = element("simpay.blik.code")
        waitFor(field)
        XCTAssertEqual(field.label, "Kod BLIK")
        app.typeText("482")
        XCTAssertEqual(field.value as? String, "Wpisano 3 z 6 cyfr")      // digits are never read aloud
    }

    func testAccessibilityAudit() throws {
        try audit(language: "en")
    }

    func testAccessibilityAuditPolish() throws {
        try audit(language: "pl")
    }

    private func audit(language: String) throws {
        guard #available(iOS 17.0, *) else { throw XCTSkip("Accessibility audits need iOS 17") }
        launch("blikPaid", language: language)
        openSheet()
        try app.performAccessibilityAudit(for: [.contrast, .elementDetection, .hitRegion, .sufficientElementDescription, .dynamicType, .textClipped]) { issue in
            Self.log(issue)
            // System elements of the sheet (grabber; on some devices an element with no
            // accessibility node at all) are outside the SDK's control. SDK buttons are 44 pt.
            if issue.auditType == .hitRegion, issue.element == nil || issue.element?.identifier == "" { return true }
            // Heuristic warning only: testAccessibilityTextSize measures this subtitle at
            // an accessibility size and asserts that it wraps inside its row.
            return issue.auditType == .textClipped && issue.element?.label == "Zapłać bez wychodzenia z aplikacji"
        }
        app.buttons["simpay.channel.blik-level0"].tap()
        waitFor(app.buttons["simpay.blik.pay"])
        // Audit the settled screen: the keyboard slides in after the transition and the
        // audit would otherwise sample half-faded text.
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        try app.performAccessibilityAudit(for: [.contrast, .sufficientElementDescription, .dynamicType, .textClipped]) { issue in
            Self.log(issue)
            return false
        }
    }

    @available(iOS 17.0, *)
    private static func log(_ issue: XCUIAccessibilityAuditIssue) {
        let element = issue.element.map { "id='\($0.identifier)' label='\($0.label)' frame=\($0.frame)" } ?? "no element"
        print("ACCESSIBILITY-AUDIT \(issue.auditType.rawValue) \(issue.compactDescription): \(element)")
    }

    func testAccessibilityTextSize() {
        launch("blikPaid", extra: ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"])
        openSheet()
        XCTAssertTrue(app.buttons["simpay.channel.blik-level0"].isHittable)
        let row = app.buttons["simpay.channel.blik-level0"]
        let subtitle = row.staticTexts["Zapłać bez wychodzenia z aplikacji"]
        // At accessibility sizes the subtitle wraps and stays inside its row.
        XCTAssertTrue(row.frame.contains(subtitle.frame), "\(subtitle.frame) outside \(row.frame)")
        XCTAssertGreaterThan(subtitle.frame.height, 40)
        screenshot("host-12-channels-accessibility-xl")
        app.buttons["simpay.channel.blik-level0"].tap()
        waitFor(app.buttons["simpay.blik.pay"])
        app.typeText("482913")
        screenshot("host-13-blik-accessibility-xl")
    }
}
