import XCTest

final class UpcomingTests: RegressionUITestCase {

    private func launch(_ extra: [String]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures"] + extra
        app.launch(); return app
    }
    private func shot(_ name: String) {
        captureScreenshot("upcoming-\(UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")-\(name)")
    }

    func testNowMergesJobsInFlightAndPlanCollapsesToSettle() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(["--today-fixtures"])
        let now = app.buttons["upcoming-mode-now"], plan = app.buttons["upcoming-mode-plan"]
        XCTAssertTrue(app.descendants(matching: .any)["upcoming-on-deck"].waitForExistence(timeout: 15))
        XCTAssertTrue(now.isSelected)
        XCTAssertTrue(app.staticTexts["Run of show"].exists)
        XCTAssertTrue(app.buttons["scan-receipt-header"].exists)
        XCTAssertFalse(app.textFields["search-jobs"].exists)
        shot("now")
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Evening review"].firstMatch.exists)
        shot("now-lower")

        plan.tap()
        XCTAssertTrue(plan.isSelected)
        let toggle = app.buttons["settle-toggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Show less"].exists)
        shot("plan-collapsed")
        toggle.tap()
        XCTAssertTrue(app.staticTexts["Show less"].waitForExistence(timeout: 3))
        XCTAssertTrue(app.staticTexts["Fees to agree"].firstMatch.exists)
        shot("plan-expanded")
        XCTAssertTrue(app.otherElements["fortnight-strip"].exists || app.staticTexts["Next two weeks"].exists)
        XCTAssertTrue(app.staticTexts["Coming up"].exists)

        // A manual choice holds while the same jobs are in flight.
        app.terminate()
        app.launchArguments = ["--ui-testing", "--design-fixtures", "--today-fixtures"]
        app.launch()
        XCTAssertTrue(app.buttons["upcoming-mode-plan"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.buttons["upcoming-mode-plan"].isSelected)
        app.buttons["upcoming-mode-now"].tap()
        XCTAssertTrue(app.buttons["upcoming-mode-now"].isSelected)
        XCTAssertTrue(app.buttons["add-job"].isHittable)
    }

    func testSettleActionMarksAnOverEventCompleted() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(["--design-screen=root", "--upcoming-past-fixture"])
        let plan = app.buttons["upcoming-mode-plan"]
        XCTAssertTrue(plan.waitForExistence(timeout: 15)); plan.tap()
        let complete = app.buttons["settle-item-eventOver"].firstMatch
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        shot("plan-event-over")
        complete.tap()
        XCTAssertTrue(complete.waitForNonExistence(timeout: 5))
    }

    func testLargeTextKeepsBothModesReachable() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(["--today-fixtures", "--design-dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"])
        XCTAssertTrue(app.buttons["upcoming-mode-now"].waitForExistence(timeout: 15))
        shot("now-large-text")
        app.buttons["upcoming-mode-plan"].tap()
        XCTAssertTrue(app.buttons["settle-toggle"].waitForExistence(timeout: 5))
        shot("plan-large-text")
    }
}
