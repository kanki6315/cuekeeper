import XCTest

final class SiriEventTests: DaybookUITestCase {
    func testSiriSavedEventEditsInPlace() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--siri-wizard-test", "--siri-import-notice"]
        app.launch()
        XCTAssertTrue(app.buttons["siri-event-done"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["IMSA esports"].exists)
        XCTAssertFalse(app.buttons["wizard-continue"].exists)
        let notice = app.staticTexts["Recurrence wasn’t imported. Only one event was created."]
        XCTAssertTrue(notice.exists)
        let gone = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: notice)
        XCTAssertEqual(XCTWaiter.wait(for: [gone], timeout: 9), .completed)
        app.navigationBars.containing(.button, identifier: "siri-event-done").buttons["edit-event"].tap()
        let location = app.textFields["job-location"]
        XCTAssertTrue(location.waitForExistence(timeout: 5))
        location.tap(); location.typeText("Studio")
        // Saving waits for the typed place's timezone lookup.
        let save = app.buttons["save-event"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: save)], timeout: 5), .completed)
        save.tap()
        XCTAssertTrue(app.staticTexts["Studio"].firstMatch.waitForExistence(timeout: 5))
        app.buttons["siri-event-done"].tap()
        XCTAssertFalse(app.buttons["siri-event-done"].exists)
        XCTAssertTrue(app.staticTexts["IMSA esports"].firstMatch.exists)
    }

    func testSiriClosingWithoutEditsKeepsEvent() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--siri-wizard-test"]
        app.launch()
        XCTAssertTrue(app.buttons["siri-event-done"].waitForExistence(timeout: 10))
        app.navigationBars.containing(.button, identifier: "siri-event-done").buttons["edit-event"].tap()
        XCTAssertTrue(app.buttons["save-event"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        app.buttons["siri-event-done"].tap()
        XCTAssertTrue(app.staticTexts["IMSA esports"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["siri-event-done"].exists)
        XCTAssertTrue(app.staticTexts["IMSA esports"].firstMatch.exists)
    }
}
