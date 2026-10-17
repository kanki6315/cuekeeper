import XCTest

final class ExpensesMonthUITests: DaybookUITestCase {
    func testMonthFilterFinishAndBusinessCost() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=expenses-overview"]
        app.launch()

        XCTAssertTrue(app.staticTexts["payments-month"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Trackside Cafe"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Adobe Creative Cloud"].exists)
        captureScreenshot("expenses-month")

        // Business shows only costs with no event.
        element("expense-filter-business", in: app).tap()
        XCTAssertTrue(app.staticTexts["Dropbox Plus"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Trackside Cafe"].exists)
        captureScreenshot("expenses-business-filter")
        element("expense-filter-all", in: app).tap()

        // To finish includes Wallet drafts and Claude Pro's next month.
        let toggle = app.buttons["expenses-finish-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5)); toggle.tap()
        XCTAssertTrue(app.buttons["expenses-finish-add"].waitForExistence(timeout: 5))
        captureScreenshot("expenses-finish-expanded")

        // Adding the due month opens a prefilled business cost and saves it without a photo.
        app.buttons["expenses-finish-add"].tap()
        XCTAssertTrue(app.navigationBars["Business cost"].waitForExistence(timeout: 5))
        captureScreenshot("expenses-business-editor")
        app.buttons["save-expense"].tap()
        XCTAssertFalse(app.buttons["expenses-finish-add"].waitForExistence(timeout: 3))
    }
}
