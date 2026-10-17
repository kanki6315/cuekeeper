import XCTest

// Keep independently reset workflows schedulable across XCTest workers.
final class WizardSeasonTests: DaybookUITestCase {
    func testSeasonAndOptionalSteps() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=add-job"]
        app.launch()
        let next = app.buttons["wizard-continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        app.buttons["Season / multiple events"].tap()
        for label in ["Client, project & series", "Session times", "Role & location", "Fee & payment"] {
            let toggle = app.switches[label]
            if !toggle.isHittable { app.swipeUp() }
            toggle.tap()
        }
        next.tap()
        XCTAssertTrue(app.buttons["Add event"].waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(app.textFields["championship-search"].waitForExistence(timeout: 5))
        capture("wizard-client")
        next.tap()
        XCTAssertTrue(app.buttons["Add session"].waitForExistence(timeout: 5))
        app.buttons["Add session"].tap()
        capture("wizard-session")
        next.tap()
        next.tap()
        XCTAssertTrue(app.switches["Provide fee breakdown"].waitForExistence(timeout: 5))
        capture("wizard-payment")
        next.tap()
        XCTAssertTrue(app.staticTexts["Event calendar"].waitForExistence(timeout: 5))
        capture("wizard-season-review")
    }

    func testCopySessionsBetweenSeasonEvents() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=add-job"]
        app.launch()
        let next = app.buttons["wizard-continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        app.buttons["Season / multiple events"].tap()
        app.switches["Session times"].tap()
        next.tap()
        app.buttons["Add event"].tap()
        let title = app.textFields["Title (optional)"]
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        title.tap(); title.typeText("Round two")
        app.buttons["Done"].tap()
        next.tap()
        app.buttons["Add session"].tap()
        app.buttons["Session 1"].tap()
        app.buttons["Copy sessions to other events"].tap()
        app.switches["Round two"].tap()
        app.buttons["Copy sessions"].tap()
        XCTAssertTrue(app.staticTexts["Sessions copied to 1 event."].waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(app.staticTexts["Round two"].waitForExistence(timeout: 5))
        capture("wizard-two-events-review")
        next.tap()
        XCTAssertTrue(next.waitForNonExistence(timeout: 5))
    }
}

final class WizardLibraryTests: DaybookUITestCase {
    func testChampionshipReuseAndLocationSuggestions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=add-job", "--location-fixtures"]
        app.launch()
        let next = app.buttons["wizard-continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        app.switches["Client, project & series"].tap()
        app.switches["Role & location"].tap()
        next.tap()
        let championship = app.textFields["championship-search"]
        championship.tap()
        dismissKeyboardIntroduction(in: app)
        championship.typeText("SportsCar")
        let suggestion = app.buttons["SportsCar Championship"]
        for _ in 0..<4 where !suggestion.isHittable || suggestion.frame.maxY > next.frame.minY { app.swipeUp() }
        suggestion.tap()
        XCTAssertTrue(app.staticTexts["SportsCar Championship"].exists)

        for _ in 0..<3 where !championship.isHittable || championship.frame.maxY > next.frame.minY - 12 { app.swipeUp() }
        championship.tap(); dismissKeyboardIntroduction(in: app); championship.typeText("Support championship")
        let add = app.buttons["championship-search-add"]
        for _ in 0..<4 where !add.isHittable || add.frame.maxY > next.frame.minY { app.swipeUp() }
        add.tap()
        XCTAssertTrue(app.staticTexts["Support championship"].exists)
        capture("wizard-multiple-series")
        next.tap()
        let arrangement = app.buttons["work-arrangement"]
        for _ in 0..<4 where !arrangement.isHittable { app.swipeUp() }
        arrangement.tap(); app.buttons["Remote"].tap()
        let location = app.textFields["work-location"]
        if !location.isHittable { app.swipeUp() }
        location.tap(); location.typeText("Silverstone")
        let locationSuggestion = app.buttons.matching(identifier: "location-suggestion").firstMatch
        XCTAssertTrue(locationSuggestion.waitForExistence(timeout: 5))
        capture("wizard-apple-location-suggestions")
        locationSuggestion.tap()
        XCTAssertTrue((location.value as? String)?.localizedCaseInsensitiveContains("Silverstone") == true)
    }
}

final class WizardLocationTests: DaybookUITestCase {
    func testChosenLocationSetsEventTimezone() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=add-job",
                               "--location-fixtures", "--slow-location-fixtures"]
        app.launch()
        let next = app.buttons["wizard-continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        let location = app.textFields["job-location"]
        for _ in 0..<6 where !location.isHittable || location.frame.maxY > next.frame.minY - 12 { app.swipeUp() }
        location.tap(); dismissKeyboardIntroduction(in: app); location.typeText("Vancouver")
        let suggestion = app.buttons.matching(identifier: "location-suggestion").firstMatch
        XCTAssertTrue(suggestion.waitForExistence(timeout: 5))
        suggestion.tap()
        // Continue waits for the lookup so the old zone can't be saved by accident.
        XCTAssertTrue(element("event-timezone-pending", in: app).waitForExistence(timeout: 2))
        XCTAssertFalse(next.isEnabled)
        let zone = element("event-timezone", in: app)
        let settled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: element("event-timezone-pending", in: app))
        XCTAssertEqual(XCTWaiter.wait(for: [settled], timeout: 10), .completed)
        XCTAssertTrue(zone.label.contains("Pacific"))
        XCTAssertTrue(next.isEnabled)
        capture("wizard-location-sets-timezone")
        // Typing a place without picking a suggestion still replaces the old zone.
        location.tap()
        location.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: 40) + "Silverstone")
        let notPacific = XCTNSPredicateExpectation(predicate: NSPredicate(format: "NOT (label CONTAINS %@)", "Pacific"), object: zone)
        XCTAssertEqual(XCTWaiter.wait(for: [notPacific], timeout: 10), .completed)
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isEnabled == true"), object: next)
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
    }
}
