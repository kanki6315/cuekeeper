import XCTest

final class CaptureTests: EventWorkflowTestCase {
    func testSessionCaptureAndConfirmationValidation() {
        let app = createEvent("Studio finals")
        let addSession = app.buttons["add-session"]
        reveal(addSession, in: app)
        addSession.tap()
        let sessionName = app.textFields["session-name"]
        XCTAssertTrue(sessionName.waitForExistence(timeout: 5))
        sessionName.tap(); sessionName.typeText("Final programme")
        app.buttons["save-session"].tap()
        if !app.buttons["save-session"].waitForNonExistence(timeout: 5) { print("SAVE_SESSION_FAILURE\n" + app.debugDescription); XCTFail("Session save did not dismiss") }
        XCTAssertTrue(app.staticTexts["Final programme"].waitForExistence(timeout: 5))
        app.staticTexts["Final programme"].firstMatch.tap()
        app.buttons["edit-session"].tap()
        reveal(app.segmentedControls["session-schedule"], in: app)
        XCTAssertTrue(app.segmentedControls["session-schedule"].waitForExistence(timeout: 5))
        app.segmentedControls["session-schedule"].buttons["Confirmed"].tap()
        app.buttons["save-session"].tap()
        let alert = app.alerts["Couldn’t save changes"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["OK"].tap()
        app.segmentedControls["session-schedule"].buttons["Tentative"].tap()
        let editor = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        editor.name = "Session editor"; editor.lifetime = .keepAlways; add(editor)
        app.buttons["save-session"].tap()
        if !app.buttons["save-session"].waitForNonExistence(timeout: 5) { print("SAVE_SESSION_FAILURE\n" + app.debugDescription); XCTFail("Session save did not dismiss") }
        let details = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        details.name = "Session details"; details.lifetime = .keepAlways; add(details)
    }

    func testClientLibraryAndFilters() {
        // Filters are only available when there is an event to filter.
        let app = createEvent("Client filter event")
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
        XCTAssertTrue(waitUntilHittable(alert.buttons["OK"]))
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
        app.staticTexts["North Sports"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Client"].waitForExistence(timeout: 5))
        let client = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        client.name = "Client details"
        client.lifetime = .keepAlways
        add(client)
        let events = app.buttons["Events"].firstMatch
        if events.exists { events.tap() } else { app.staticTexts["Events"].firstMatch.tap() }
        let filterButton = app.buttons["filter-jobs"]
        XCTAssertTrue(filterButton.waitForExistence(timeout: 5))
        filterButton.tap()
        XCTAssertTrue(waitUntilHittable(app.buttons["Done"]))
        let filters = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        filters.name = "Job filters"
        filters.lifetime = .keepAlways
        add(filters)
        XCTAssertTrue(app.buttons["Done"].exists)
        app.buttons["Done"].tap()
    }

    func testRepeatedSessionEntryAndBulkSeries() {
        let app = createEvent("Race weekend", openBooking: false)
        reveal(app.buttons["add-session"], in: app); app.buttons["add-session"].tap()
        let name = app.textFields["session-name"]; XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Qualifying\n")
        let series = app.textFields["library-WorkSeries-name"]; series.tap(); series.typeText("Series A\n")
        let another = app.buttons["save-another-session"]; reveal(another, in: app); another.tap()
        XCTAssertTrue(another.waitForExistence(timeout: 5))
        reveal(name, in: app); name.tap(); name.typeText("Race\n")
        XCTAssertEqual(series.value as? String, "Series A")
        let reuse = app.buttons["reuse-WorkSeries"]; reveal(reuse, in: app); reuse.tap(); app.buttons["Series A"].tap()
        app.buttons["save-session"].tap()
        XCTAssertTrue(app.buttons["save-session"].waitForNonExistence(timeout: 5))
        let batch = app.buttons["batch-sessions"]; reveal(batch, in: app); batch.tap()
        app.buttons["Select All"].tap()
        let change = app.switches["Change series"]; reveal(change, in: app); change.switches.firstMatch.tap()
        let newSeries = app.textFields["library-WorkSeries-name"]; reveal(newSeries, in: app); newSeries.tap(); newSeries.typeText("Series B\n")
        app.buttons["apply-session-changes"].tap()
        XCTAssertTrue(app.buttons["apply-session-changes"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "Series B").count, 2)
    }

    func testEventEditDatesAndDiscard() {
        let app = createEvent("Original weekend", openBooking: false)
        app.buttons["edit-event"].tap()
        let multiple = app.switches["job-multiple-days"]; multiple.switches.firstMatch.tap()
        XCTAssertTrue(app.datePickers["job-end-date"].exists)
        let location = app.textFields["job-location"]; reveal(location, in: app); location.tap(); location.typeText("Silverstone\n")
        app.buttons["save-event"].tap()
        XCTAssertTrue(app.buttons["save-event"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Silverstone"].exists)
        app.buttons["edit-event"].tap()
        reveal(location, in: app); location.tap(); location.typeText(" discarded\n")
        app.buttons["Cancel"].tap(); app.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.buttons["save-event"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Silverstone discarded"].exists)
    }
}
