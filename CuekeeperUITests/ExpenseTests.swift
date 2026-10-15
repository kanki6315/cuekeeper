import XCTest

final class ExpenseUITests: XCTestCase {
    func testReviewEditSaveAndReopenReceipt() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=expense"]
        app.launch()
        let merchant = app.textFields["expense-merchant"]
        XCTAssertTrue(merchant.waitForExistence(timeout: 15))
        screenshot("receipt-review-top")
        let form = app.scrollViews.matching(identifier: "daybook-form").element(boundBy: app.scrollViews.matching(identifier: "daybook-form").count - 1)
        form.swipeUp()
        XCTAssertTrue(merchant.isHittable)
        merchant.tap(); merchant.typeText(" corrected\n")
        screenshot("receipt-review-fields")
        app.buttons["save-expense"].tap()
        XCTAssertTrue(app.buttons["edit-event"].waitForExistence(timeout: 5))
        let row = app.buttons["expense-row"].firstMatch
        for _ in 0..<8 where !row.isHittable { app.scrollViews.firstMatch.swipeUp() }
        XCTAssertTrue(row.isHittable); XCTAssertTrue(row.label.contains("corrected")); row.tap()
        XCTAssertTrue(app.buttons["View full receipt photo"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.textFields["expense-merchant"].value as? String == "Circuit Parking corrected")
        screenshot("receipt-saved")
    }
    private func screenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
    func testShortcutEventChoice() throws {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=receipt-shortcut"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Receipt for which event?"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.searchFields.firstMatch.exists)
        screenshot("receipt-shortcut-events")
    }
}
