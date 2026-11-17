import XCTest

/// Smoke tests of the demo shop. End-to-end scenarios of the SDK are covered by the
/// IntegrationHost UI tests.
final class DemoSmokeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments = ["-scenario", "blikPaid", "-AppleLanguages", "(pl)", "-AppleLocale", "pl_PL"]
        app.launch()
    }

    private func openSheet() {
        let pay = app.buttons["demo.pay"]
        XCTAssertTrue(pay.waitForExistence(timeout: 10))
        pay.tap()
        XCTAssertTrue(app.buttons["simpay.channel.blik-level0"].waitForExistence(timeout: 10))
    }

    func testStorefrontOpensTheSdkSheet() {
        XCTAssertTrue(app.staticTexts["Słuchawki bezprzewodowe"].exists)
        XCTAssertTrue(app.buttons["FAKE"].exists)
        openSheet()
    }

    func testFakeBlikPaymentSucceeds() {
        openSheet()
        app.buttons["simpay.channel.blik-level0"].tap()
        let payBlik = app.buttons["simpay.blik.pay"]
        XCTAssertTrue(payBlik.waitForExistence(timeout: 10))
        app.typeText("482913")
        payBlik.tap()
        let sheetResult = app.descendants(matching: .any).matching(identifier: "simpay.result").firstMatch
        XCTAssertTrue(sheetResult.waitForExistence(timeout: 20))
        XCTAssertTrue(sheetResult.label.contains("Płatność zakończona"))
        app.buttons["simpay.done"].tap()

        let demoResult = app.descendants(matching: .any).matching(identifier: "demo.result").firstMatch
        XCTAssertTrue(demoResult.waitForExistence(timeout: 10))
        XCTAssertTrue(demoResult.label.contains("Płatność zakończona"))
    }

    func testClosingBeforePaymentIsCancelled() {
        openSheet()
        app.buttons["simpay.close"].tap()
        let demoResult = app.descendants(matching: .any).matching(identifier: "demo.result").firstMatch
        XCTAssertTrue(demoResult.waitForExistence(timeout: 10))
        XCTAssertTrue(demoResult.label.contains("anulowana"))
    }
}
