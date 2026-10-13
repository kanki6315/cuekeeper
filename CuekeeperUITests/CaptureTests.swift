import XCTest

final class CaptureTests: XCTestCase {
    func testOverallFeeCanBeSavedWithoutBreakdown() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store"]
        app.launch()
        XCTAssertTrue(app.buttons["add-job"].waitForExistence(timeout: 10))
        app.buttons["add-job"].tap()
        let name = app.textFields["job-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Paid broadcast")
        app.buttons["save-job"].tap()
        XCTAssertTrue(app.staticTexts["Paid broadcast"].waitForExistence(timeout: 5))
        app.staticTexts["Paid broadcast"].tap()
        let fee = app.buttons["job-fee"]
        for _ in 0..<5 where !fee.isHittable { app.swipeUp() }
        fee.tap()
        XCTAssertTrue(app.buttons["edit-fee"].waitForExistence(timeout: 5))
        app.buttons["edit-fee"].tap()
        let amount = app.textFields["overall-fee"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap(); amount.typeText("1234.56")
        let editor = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        editor.name = "Fee editor"; editor.lifetime = .keepAlways; add(editor)
        app.buttons["save-fee"].tap()
        XCTAssertTrue(app.buttons["save-fee"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["$1,234.56"].firstMatch.waitForExistence(timeout: 5))
        let details = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        details.name = "Fee and history"; details.lifetime = .keepAlways; add(details)
    }

    func testSessionCaptureLinksAndConfirmationValidation() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store"]
        app.launch()
        XCTAssertTrue(app.buttons["add-job"].waitForExistence(timeout: 10))
        app.buttons["add-job"].tap()
        let name = app.textFields["job-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Studio finals")
        app.buttons["save-job"].tap()
        XCTAssertTrue(app.staticTexts["Studio finals"].waitForExistence(timeout: 5))
        app.staticTexts["Studio finals"].tap()
        let addSession = app.buttons["add-session"]
        for _ in 0..<4 where !addSession.isHittable { app.swipeUp() }
        addSession.tap()
        let sessionName = app.textFields["session-name"]
        XCTAssertTrue(sessionName.waitForExistence(timeout: 5))
        sessionName.tap(); sessionName.typeText("Final programme")
        app.buttons["save-session"].tap()
        XCTAssertTrue(app.buttons["save-session"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Final programme"].waitForExistence(timeout: 5))
        app.staticTexts["Final programme"].tap()
        app.buttons["edit-session"].tap()
        for _ in 0..<6 where !app.buttons["session-schedule"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["session-schedule"].waitForExistence(timeout: 5))
        app.buttons["session-schedule"].tap(); app.buttons["Confirmed"].tap()
        app.buttons["save-session"].tap()
        let alert = app.alerts["Couldn’t save changes"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["OK"].tap()
        app.buttons["session-schedule"].tap(); app.buttons["Tentative"].tap()
        let editor = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        editor.name = "Session editor"; editor.lifetime = .keepAlways; add(editor)
        let addLink = app.buttons["add-broadcast-link"]
        for _ in 0..<6 where !addLink.isHittable { app.swipeUp() }
        addLink.tap()
        let url = app.textFields["broadcast-url"]
        for _ in 0..<3 where !url.isHittable { app.swipeUp() }
        url.tap(); url.typeText("https://example.com/finals")
        app.buttons["save-session"].tap()
        XCTAssertTrue(app.buttons["save-session"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.links["https://example.com/finals"].waitForExistence(timeout: 5))
        let details = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        details.name = "Session details and link"; details.lifetime = .keepAlways; add(details)
    }

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
