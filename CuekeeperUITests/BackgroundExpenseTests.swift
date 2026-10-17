import XCTest

final class BackgroundExpenseUITests: RegressionUITestCase {
    private func launch(_ route: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=\(route)"]
        app.launch(); return app
    }
    private func shot(_ name: String) {
        captureScreenshot(name)
    }
    func testCompleteDraftWithAttachedReceiptAndChooseEvent() {
        let app = launch("pending-expenses")
        let row = app.buttons.matching(identifier: "pending-expense-row").matching(NSPredicate(format: "label CONTAINS %@", "Circuit Parking")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15)); shot("pending-expenses")
        row.tap()
        XCTAssertTrue(app.buttons["expense-choose-event"].waitForExistence(timeout: 5)); shot("background-draft")
        app.buttons["expense-choose-event"].tap()
        let event = app.buttons["choose-expense-event-row"].firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 5)); event.tap()
        XCTAssertTrue(app.buttons["save-expense"].waitForExistence(timeout: 5)); app.buttons["save-expense"].tap()
        XCTAssertTrue(app.navigationBars["Expenses to complete"].waitForExistence(timeout: 5))
        XCTAssertFalse(row.exists)
        XCTAssertTrue(app.buttons.matching(identifier: "pending-expense-row").matching(NSPredicate(format: "label CONTAINS %@", "Hotel")).firstMatch.exists)
        shot("completed-draft-removed")
    }
    func testNotificationRouteOpensExactPhotoLessDraftAndKeepsIt() {
        let app = launch("expense-notification")
        let merchant = app.textFields["expense-merchant"]
        XCTAssertTrue(merchant.waitForExistence(timeout: 15)); XCTAssertEqual(merchant.value as? String, "Hotel")
        XCTAssertFalse(app.buttons["save-expense"].isEnabled)
        shot("notification-draft")
        app.buttons["Keep Draft"].tap()
        XCTAssertTrue(app.staticTexts["Opening expense…"].waitForExistence(timeout: 5))
    }
    func testConflictedDraftCanCloseWithoutSaving() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=pending-expenses", "--ui-test-expense-conflict"]
        app.launch()
        let row = app.buttons.matching(identifier: "pending-expense-row").matching(NSPredicate(format: "label CONTAINS %@", "Circuit Parking")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 15))
        row.tap()
        let keep = app.buttons["Keep Draft"]
        XCTAssertTrue(keep.waitForExistence(timeout: 5))
        keep.tap()
        let close = app.buttons["Close without saving"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        app.buttons["Keep Editing"].tap()
        XCTAssertTrue(keep.exists)
        keep.tap()
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        close.tap()
        XCTAssertTrue(row.waitForExistence(timeout: 5))
    }

    func testSettingsInstructionsAndPendingPrompt() {
        let app = launch("pending-root")
        // The Expenses tab lists drafts under To finish; the full completion list opens from Payments.
        let payments = app.buttons["Payments"].firstMatch
        _ = payments.waitForExistence(timeout: 15)
        if payments.exists { payments.tap() } else { app.staticTexts["Payments"].firstMatch.tap() }
        let pending = app.buttons["pending-expenses"].firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 10))
        pending.tap()
        XCTAssertTrue(app.navigationBars["Expenses to complete"].waitForExistence(timeout: 5))
        app.buttons["Wallet automation setup"].tap()
        XCTAssertTrue(app.navigationBars["Wallet Automation"].waitForExistence(timeout: 5))
        shot("wallet-automation-steps")
        app.buttons["Help & Options"].tap()
        app.buttons["Completion Reminders"].tap()
        let enable = app.buttons["enable-expense-reminders"]
        for _ in 0..<6 where !enable.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(enable.exists)
        shot("wallet-automation-reminders")
    }
    func testWalletScreenshotGuide() {
        let app = launch("expense-automation")
        XCTAssertTrue(app.buttons["install-wallet-shortcut"].waitForExistence(timeout: 15))
        let manualSetup = app.buttons["wallet-manual-setup"]
        for _ in 0..<6 where !manualSetup.isHittable { app.scrollViews.firstMatch.swipeUp() }
        manualSetup.tap()
        XCTAssertTrue(app.navigationBars["Set Up Manually"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.images["wallet-setup-example"].exists)
        XCTAssertTrue(app.buttons["open-wallet-shortcuts"].isHittable)
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "If you know the currency")).firstMatch.isHittable)
        shot("wallet-manual-screenshot-guide")
        let mapping = app.staticTexts["Transaction date → Current Date output"]
        for _ in 0..<6 where !mapping.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(mapping.isHittable)
        XCTAssertTrue(app.buttons["open-wallet-shortcuts"].isHittable)
        shot("wallet-manual-mappings")
        app.buttons["Help & Options"].tap()
        XCTAssertTrue(app.buttons["Include Payment Details"].waitForExistence(timeout: 5))
    }

    func testRemoveDraftHasConfirmation() {
        let app = launch("pending-expenses")
        XCTAssertTrue(app.buttons["remove-expense-draft"].firstMatch.waitForExistence(timeout: 15))
        let initial = app.buttons.matching(identifier: "pending-expense-row").count
        app.buttons["remove-expense-draft"].firstMatch.tap()
        XCTAssertTrue(app.buttons["Keep Draft"].waitForExistence(timeout: 5)); app.buttons["Keep Draft"].tap()
        XCTAssertEqual(app.buttons.matching(identifier: "pending-expense-row").count, initial)
        app.buttons["remove-expense-draft"].firstMatch.tap()
        shot("remove-draft-confirmation")
        app.alerts.buttons["Remove Draft"].tap()
        XCTAssertEqual(app.buttons.matching(identifier: "pending-expense-row").count, initial - 1)
    }
}
