import XCTest

final class BackgroundExpenseUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(_ route: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=\(route)"]
        app.launch(); return app
    }
    private func shot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
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
    func testSettingsInstructionsAndPendingPrompt() {
        let app = launch("pending-root")
        let pending = app.buttons["pending-expenses"].firstMatch
        XCTAssertTrue(pending.waitForExistence(timeout: 15)); shot("pending-upcoming-prompt")
        pending.tap()
        XCTAssertTrue(app.navigationBars["Expenses to complete"].waitForExistence(timeout: 5))
        app.buttons["Wallet automation setup"].tap()
        XCTAssertTrue(app.navigationBars["Wallet Automation"].waitForExistence(timeout: 5))
        shot("wallet-automation-steps")
        let enable = app.buttons["enable-expense-reminders"]
        for _ in 0..<6 where !enable.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(enable.exists)
        shot("wallet-automation-reminders")
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
