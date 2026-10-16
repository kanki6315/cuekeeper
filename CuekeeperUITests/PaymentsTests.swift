import XCTest

final class PaymentsTests: XCTestCase {
    private func launch(dark: Bool = false, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--payments-fixtures", "--design-screen=payments-root"]
            + (dark ? ["--design-dark"] : [])
            + (large ? ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraLarge.rawValue] : [])
        app.launch()
        return app
    }
    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication, up: Bool = true) {
        for _ in 0..<10 where !(element.exists && element.isHittable) { up ? app.swipeUp() : app.swipeDown() }
    }

    func testMonthCloseShowsGatesAndResolvesClientDetails() {
        continueAfterFailure = false
        let app = launch()
        XCTAssertTrue(app.staticTexts["payments-month"].waitForExistence(timeout: 10))
        capture("payments-month-top")
        let harbour = app.buttons["readiness-Harbour regatta"]
        reveal(harbour, in: app)
        XCTAssertTrue(harbour.exists)
        capture("payments-month-clients")
        harbour.tap()

        let client = app.otherElements["gate-client"].exists ? app.otherElements["gate-client"] : app.staticTexts["Client invoicing details"]
        XCTAssertTrue(client.waitForExistence(timeout: 5))
        capture("readiness-sheet")
        let email = app.textFields["invoicing-email"]
        reveal(email, in: app)
        email.tap(); email.typeText("accounts@velocity.example")
        let address = app.textFields["invoicing-address"].exists ? app.textFields["invoicing-address"] : app.textViews["invoicing-address"]
        address.tap(); address.typeText("9 Harbour Street")
        let terms = app.textFields["invoicing-terms"]
        terms.tap(); terms.typeText("30")
        let save = app.buttons["save-invoicing"]
        reveal(save, in: app)
        save.tap()
        let create = app.buttons["readiness-create-invoice"]
        reveal(create, in: app)
        XCTAssertTrue(create.waitForExistence(timeout: 5))
        capture("readiness-sheet-ready")
        app.buttons["Done"].tap()

        let invoice = app.buttons["invoice-ready-Velocity TV"]
        reveal(invoice, in: app, up: false)
        XCTAssertTrue(invoice.waitForExistence(timeout: 5))
    }

    func testReadyGroupStartsInvoiceWithEventsAndReceipt() {
        continueAfterFailure = false
        let app = launch()
        let ready = app.buttons["invoice-ready-Northside Sports"]
        XCTAssertTrue(app.staticTexts["payments-month"].waitForExistence(timeout: 10))
        reveal(ready, in: app)
        ready.tap()
        let receipt = app.switches["invoice-receipt-Etihad parking"]
        reveal(receipt, in: app)
        XCTAssertTrue(receipt.waitForExistence(timeout: 5))
        XCTAssertEqual(receipt.value as? String, "1")
        capture("invoice-from-ready-group")
        let reference = app.textFields["invoice-reference"]
        reveal(reference, in: app, up: false)
        reference.tap(); reference.typeText("INV-0414")
        app.buttons["save-invoice"].tap()
        let cup = app.buttons["readiness-Cup quarter-final"]
        reveal(cup, in: app)
        XCTAssertTrue(cup.waitForExistence(timeout: 5))
        // Compact rows fold the state into the row label; the wide ledger shows it in its own column.
        let drafts = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "On draft invoice")).count
        XCTAssertTrue(cup.label.contains("draft") || drafts >= 3, cup.label)
        XCTAssertFalse(app.buttons["invoice-ready-Northside Sports"].exists)
    }

    func testDarkAndAccessibilityLayouts() {
        let app = launch(dark: true, large: true)
        XCTAssertTrue(app.staticTexts["payments-month"].waitForExistence(timeout: 10))
        capture("payments-dark-ax")
        let harbour = app.buttons["readiness-Harbour regatta"]
        reveal(harbour, in: app)
        XCTAssertTrue(harbour.exists)
        capture("payments-dark-ax-rows")
        app.terminate()
        let light = launch(dark: true)
        XCTAssertTrue(light.staticTexts["payments-month"].waitForExistence(timeout: 10))
        capture("payments-dark")
    }

    func testIPadPortraitAndWideLedger() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "iPad layout")
        XCUIDevice.shared.orientation = .portrait
        let app = launch()
        XCTAssertTrue(app.staticTexts["payments-month"].waitForExistence(timeout: 10))
        capture("payments-ipad-portrait")
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let harbour = app.buttons["readiness-Harbour regatta"]
        XCTAssertTrue(harbour.waitForExistence(timeout: 5))
        capture("payments-ipad-wide")
        harbour.tap()
        XCTAssertTrue(app.buttons["readiness-open-event"].waitForExistence(timeout: 5))
        capture("payments-ipad-readiness")
        app.buttons["Done"].tap()
        app.terminate()
        let dark = launch(dark: true)
        XCTAssertTrue(dark.staticTexts["payments-month"].waitForExistence(timeout: 10))
        capture("payments-ipad-wide-dark")
    }

    func testLedgerKeepsEveryInvoice() {
        let app = launch()
        let ledger = app.buttons["payments-ledger"]
        XCTAssertTrue(app.staticTexts["payments-month"].waitForExistence(timeout: 10))
        reveal(ledger, in: app)
        ledger.tap()
        XCTAssertTrue(app.staticTexts["Awaiting payment"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["APX-2207"].exists)
        capture("payments-ledger")
    }
}
