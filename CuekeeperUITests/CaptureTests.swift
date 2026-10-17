import XCTest

// Keep independently reset workflows schedulable across XCTest workers.
final class SessionCaptureTests: EventWorkflowTestCase {
    func testSessionCaptureAndConfirmationValidation() {
        let app = seededEvent("Studio finals")
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
        captureScreenshot("Session editor")
        app.buttons["save-session"].tap()
        if !app.buttons["save-session"].waitForNonExistence(timeout: 5) { print("SAVE_SESSION_FAILURE\n" + app.debugDescription); XCTFail("Session save did not dismiss") }
        captureScreenshot("Session details")
    }
}

final class ClientLibraryTests: EventWorkflowTestCase {
    func testClientLibraryAndFilters() {
        // Filters are only available when there is an event to filter.
        let app = seededEvent("Client filter event", openDetails: false)
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
        captureScreenshot("Save error preserves draft")
        alert.buttons["OK"].tap()
        XCTAssertEqual(name.value as? String, "North Sports")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 5))
        app.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.buttons["Save"].waitForNonExistence(timeout: 5))
        app.staticTexts["North Sports"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Client"].waitForExistence(timeout: 5))
        captureScreenshot("Client details")
        let events = app.buttons["Events"].firstMatch
        if events.exists { events.tap() } else { app.staticTexts["Events"].firstMatch.tap() }
        let filterButton = app.buttons["filter-jobs"]
        XCTAssertTrue(filterButton.waitForExistence(timeout: 5))
        filterButton.tap()
        XCTAssertTrue(waitUntilHittable(app.buttons["Done"]))
        captureScreenshot("Job filters")
        XCTAssertTrue(app.buttons["Done"].exists)
        app.buttons["Done"].tap()
    }
}

final class SessionSeriesTests: EventWorkflowTestCase {
    func testRepeatedSessionEntryAndBulkSeries() {
        let app = seededEvent("Race weekend")
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
}

final class EventDateEditingTests: EventWorkflowTestCase {
    func testEventEditDatesAndDiscard() {
        let app = seededEvent("Original weekend")
        app.buttons["edit-event"].tap()
        let multiple = app.switches["job-multiple-days"]; multiple.switches.firstMatch.tap()
        XCTAssertTrue(app.datePickers["job-end-date"].exists)
        let location = app.textFields["job-location"]; reveal(location, in: app); location.tap(); location.typeText("Silverstone\n")
        // Saving waits for the typed place's timezone lookup.
        let save = app.buttons["save-event"]
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: save)], timeout: 10), .completed)
        save.tap()
        XCTAssertTrue(app.buttons["save-event"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.descendants(matching: .any).matching(NSPredicate(format: "identifier == %@ AND label CONTAINS %@", "event-location", "Silverstone")).firstMatch.waitForExistence(timeout: 5))
        app.buttons["edit-event"].tap()
        reveal(location, in: app); location.tap(); location.typeText(" discarded\n")
        app.buttons["Cancel"].tap(); app.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.buttons["save-event"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.descendants(matching: .any)["event-location"].label.contains("discarded"))
    }
}
