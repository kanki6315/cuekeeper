import XCTest

final class CaptureTests: XCTestCase {
    func testCapturePersistsAcrossLaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store"]
        app.launch()
        XCTAssertTrue(app.buttons["add-job"].waitForExistence(timeout: 10))
        app.buttons["add-job"].tap()
        let name = app.textFields["job-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["save-job"].isEnabled)
        name.tap()
        name.typeText("Test broadcast")
        app.buttons["save-job"].tap()
        XCTAssertTrue(app.buttons["save-job"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Test broadcast"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Test broadcast"].waitForExistence(timeout: 10))
        app.staticTexts["Test broadcast"].tap()
        let status = app.descendants(matching: .any)["booking-status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.value as? String, "Tentative")
    }
    func testEditDuplicateAndDiscard() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store"]
        app.launch()
        XCTAssertTrue(app.buttons["add-job"].waitForExistence(timeout: 10))
        app.buttons["add-job"].tap()
        let name = app.textFields["job-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Weekend coverage")
        app.buttons["save-job"].tap()
        XCTAssertTrue(app.buttons["save-job"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Weekend coverage"].waitForExistence(timeout: 5))
        app.staticTexts["Weekend coverage"].tap()
        app.buttons["edit-job"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(" updated\n")
        app.buttons["edit-booking-status"].tap()
        app.buttons["Booked"].tap()
        Thread.sleep(forTimeInterval: 1) // Let the native sheet/menu transition settle for the review capture.
        let editor = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        editor.name = "Job editor"
        editor.lifetime = .keepAlways
        add(editor)
        app.buttons["save-job"].tap()
        XCTAssertTrue(app.buttons["save-job"].waitForNonExistence(timeout: 5))
        let status = app.descendants(matching: .any)["booking-status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.value as? String, "Booked")
        Thread.sleep(forTimeInterval: 1)
        let detail = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        detail.name = "Job details"
        detail.lifetime = .keepAlways
        add(detail)
        app.buttons["duplicate-job"].tap()
        XCTAssertTrue(app.buttons["save-job"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["save-job"].isEnabled)
        let dates = app.switches["confirm-duplicate-dates"]
        dates.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["save-job"])
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        app.buttons["save-job"].tap()
        XCTAssertTrue(app.buttons["save-job"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["edit-job"].waitForExistence(timeout: 5))
        app.buttons["edit-job"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(" discarded\n")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 5))
        app.buttons["Discard Changes"].tap()
        XCTAssertFalse(app.staticTexts["Weekend coverage updated discarded"].exists)
    }

    func testClientLibraryAndFilters() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store"]
        app.launch()
        XCTAssertTrue(app.buttons["add-job"].waitForExistence(timeout: 10))
        let settings = app.buttons["Settings"].firstMatch
        if settings.exists { settings.tap() } else { app.staticTexts["Settings"].firstMatch.tap() }
        app.buttons["Clients"].tap()
        app.buttons["Add Client"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("North Sports\n")
        XCTAssertEqual(name.value as? String, "North Sports")
        let saveEnabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["Save"])
        XCTAssertEqual(XCTWaiter.wait(for: [saveEnabled], timeout: 5), .completed)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Save"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["North Sports"].waitForExistence(timeout: 5))
        app.buttons["Add Client"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("North Sports\n")
        let duplicateEnabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["Save"])
        XCTAssertEqual(XCTWaiter.wait(for: [duplicateEnabled], timeout: 5), .completed)
        app.buttons["Save"].tap()
        let alert = app.alerts["Couldn’t save changes"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        let failure = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        failure.name = "Save error preserves draft"
        failure.lifetime = .keepAlways
        add(failure)
        alert.buttons["OK"].tap()
        XCTAssertEqual(name.value as? String, "North Sports")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 5))
        app.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.buttons["Save"].waitForNonExistence(timeout: 5))
        app.staticTexts["North Sports"].tap()
        Thread.sleep(forTimeInterval: 1)
        let client = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        client.name = "Client details"
        client.lifetime = .keepAlways
        add(client)
        let upcoming = app.buttons["Upcoming"].firstMatch
        if upcoming.exists { upcoming.tap() } else { app.staticTexts["Upcoming"].firstMatch.tap() }
        app.buttons["filter-jobs"].tap()
        Thread.sleep(forTimeInterval: 1)
        let filters = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        filters.name = "Job filters"
        filters.lifetime = .keepAlways
        add(filters)
        XCTAssertTrue(app.buttons["Done"].exists)
        app.buttons["Done"].tap()
    }

}
