import XCTest

/// Record review after a restore: events are chosen field by field, payments as one whole copy.
final class IdentityReviewTests: DaybookUITestCase {
    private func launch(dark: Bool = false, large: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--identity-conflict-fixtures", "--design-screen=identity-review"]
            + (dark ? ["--design-dark"] : [])
            + (large ? ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraLarge.rawValue] : [])
        app.launch()
        return app
    }

    func testResolveEventFieldByFieldAndPaymentAsWholeCopy() {
        continueAfterFailure = false
        let app = launch()
        let rows = app.buttons.matching(identifier: "identity-conflict")
        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
        XCTAssertEqual(rows.count, 2)
        capture("review-list")

        rows.element(boundBy: 0).tap()
        XCTAssertTrue(app.staticTexts["Booking status"].waitForExistence(timeout: 5))
        capture("review-event")
        app.buttons["Silverstone 6H, Copy 2"].tap()
        app.buttons["resolve-conflict"].tap()

        XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 5))
        XCTAssertEqual(rows.count, 1)
        rows.firstMatch.tap()
        XCTAssertTrue(app.staticTexts["Which payment did you receive?"].waitForExistence(timeout: 5))
        capture("review-payment")
        app.buttons["resolve-conflict"].tap()
        XCTAssertTrue(app.staticTexts["Nothing to review. Copies that match are combined automatically."].waitForExistence(timeout: 5))
        capture("review-done")
    }

    func testReviewScreensInDarkModeAndLargeText() {
        for (dark, large) in [(true, false), (false, true)] {
            let app = launch(dark: dark, large: large)
            let rows = app.buttons.matching(identifier: "identity-conflict")
            XCTAssertTrue(rows.firstMatch.waitForExistence(timeout: 10))
            let suffix = dark ? "dark" : "large"
            capture("review-list-\(suffix)")
            rows.element(boundBy: 0).tap()
            XCTAssertTrue(app.buttons["resolve-conflict"].waitForExistence(timeout: 5))
            capture("review-event-\(suffix)")
            app.navigationBars.buttons.element(boundBy: 0).tap()
            XCTAssertTrue(rows.element(boundBy: 1).waitForExistence(timeout: 5))
            rows.element(boundBy: 1).tap()
            XCTAssertTrue(app.buttons["resolve-conflict"].waitForExistence(timeout: 5))
            capture("review-payment-\(suffix)")
            app.terminate()
        }
    }
}
