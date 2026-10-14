import XCTest

final class EventWizardTests: XCTestCase {
    func testUnifiedEditorShowsBookingFieldsAndDiscardsChanges() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=edit-job"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Edit Event"].waitForExistence(timeout: 10))
        let project = app.textFields["library-WorkProject-name"]
        for _ in 0..<8 where !project.isHittable { app.swipeUp() }
        XCTAssertTrue(project.isHittable)
        project.tap()
        project.typeText(" revised")
        capture("unified-event-booking")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 3))
        app.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.navigationBars["Edit Event"].waitForNonExistence(timeout: 5))
    }

    func testFeeShortcutOpensUnifiedEditorAtFee() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=fee"]
        app.launch()
        XCTAssertTrue(app.buttons["edit-fee"].waitForExistence(timeout: 10))
        app.buttons["edit-fee"].tap()
        XCTAssertTrue(app.navigationBars["Edit Event"].waitForExistence(timeout: 5))
        capture("unified-event-fee")
        XCTAssertTrue(app.textFields["overall-fee"].isHittable)
        app.buttons["Cancel"].tap()
    }

    func testSingleClientEditorKeepsFieldsVisibleAndFeeExpandable() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=edit-event"]
        app.launch()
        XCTAssertTrue(app.navigationBars["Edit Event"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.textFields["job-location"].exists)
        XCTAssertFalse(app.buttons["editor-booking-section"].exists)
        XCTAssertFalse(app.buttons["editor-add-client"].exists)
        XCTAssertEqual(app.textFields.matching(identifier: "library-Client-name").count, 1)
        XCTAssertTrue(app.textFields["library-WorkProject-name"].exists)
        let fee = app.buttons["editor-fee-section"].firstMatch
        for _ in 0..<8 where !fee.isHittable { app.swipeUp() }
        fee.tap()
        XCTAssertTrue(app.textFields["overall-fee"].exists)
        fee.tap()
        XCTAssertFalse(app.textFields["overall-fee"].exists)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.navigationBars["Edit Event"].waitForNonExistence(timeout: 5))
    }

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
        app.buttons["save-event"].tap()
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

    func testClientTypeaheadAndNewBookingChoices() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=add-job"]
        app.launch()
        let next = app.buttons["wizard-continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        app.switches["Client, project & series"].tap()
        next.tap()
        let client = app.textFields["job-client"]
        XCTAssertTrue(client.waitForExistence(timeout: 5))
        client.tap(); dismissKeyboardIntroduction(in: app); client.typeText("Brand new client"); client.typeText("\n")
        XCTAssertFalse(app.buttons["job-client-suggestion"].exists)
        XCTAssertEqual(client.value as? String, "Brand new client")
        next.tap()
        app.navigationBars["New event"].buttons.matching(NSPredicate(format: "label != %@", "Cancel")).firstMatch.tap()
        XCTAssertEqual(client.value as? String, "Brand new client")
        let booking = app.segmentedControls["wizard-booking"]
        XCTAssertTrue(booking.exists)
        for _ in 0..<4 where !booking.isHittable || booking.frame.maxY > next.frame.minY { app.swipeUp() }
        booking.buttons["Booked"].tap()
        XCTAssertTrue(booking.buttons["Booked"].isSelected)
        XCTAssertFalse(app.buttons["Completed"].exists)
        XCTAssertFalse(app.buttons["Cancelled"].exists)
        let cancel = app.navigationBars.buttons["Cancel"]
        XCTAssertGreaterThan(cancel.frame.midX, app.frame.midX)
        capture("wizard-typeahead-booking")
        next.tap()
        XCTAssertTrue(app.staticTexts["Review"].waitForExistence(timeout: 5))
        next.tap()
        XCTAssertTrue(next.waitForNonExistence(timeout: 5))
    }

    func testCreateEventWithSuggestedTitle() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=add-job"]
        app.launch()
        let next = app.buttons["wizard-continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 10))
        capture("wizard-setup")
        next.tap()
        XCTAssertTrue(app.staticTexts["Review"].waitForExistence(timeout: 5))
        capture("wizard-review")
        next.tap()
        XCTAssertFalse(next.waitForExistence(timeout: 2))
    }

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
        XCTAssertFalse(next.waitForExistence(timeout: 2))
    }

    func testDarkLargeTextSetup() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=add-job", "--design-dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["wizard-continue"].waitForExistence(timeout: 10))
        capture("wizard-dark-large-text")
        app.swipeUp()
        capture("wizard-dark-large-text-lower")
        app.buttons["wizard-continue"].tap()
        XCTAssertTrue(app.staticTexts["Review"].waitForExistence(timeout: 5))
        capture("wizard-dark-large-text-review")
        app.swipeUp()
        capture("wizard-dark-large-text-review-lower")
    }

    func testChampionshipReuseAndAppleLocationSuggestions() throws {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=add-job"]
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
        let location = app.textFields["Location"]
        if !location.isHittable { app.swipeUp() }
        location.tap(); location.typeText("Silverstone")
        let locationSuggestion = app.buttons.matching(identifier: "location-suggestion").firstMatch
        guard locationSuggestion.waitForExistence(timeout: 20) else {
            capture("wizard-location-service-unavailable")
            throw XCTSkip("Apple Maps suggestions unavailable in this simulator run; manual location entry retained.")
        }
        capture("wizard-apple-location-suggestions")
        locationSuggestion.tap()
        XCTAssertTrue((location.value as? String)?.localizedCaseInsensitiveContains("Silverstone") == true)
    }

    func testPopulatedAccessibleReviewAndForeignSessionDate() {
        let app = XCUIApplication()
        let base = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=add-job"]
        app.launchArguments = base + ["--wizard-populated-review", "--design-dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["wizard-continue"].waitForExistence(timeout: 10))
        capture("wizard-populated-accessible-review")
        for index in 0..<5 { app.swipeUp(); capture("wizard-populated-accessible-review-\(index)") }
        app.terminate()
        app.launchArguments = base + ["--wizard-foreign-session"]
        app.launch()
        XCTAssertTrue(app.buttons["wizard-continue"].waitForExistence(timeout: 10))
        let date = app.datePickers["wizard-session-date"]
        XCTAssertTrue(date.waitForExistence(timeout: 5))
        XCTAssertTrue(date.debugDescription.contains("Jan 15") || date.debugDescription.contains("January 15"), "Session should display January 15 in Tokyo, not January 14 in New York: \(date.debugDescription)")
        capture("wizard-foreign-session-date")
        app.buttons["wizard-continue"].tap()
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS %@", "UTC−05:00")).firstMatch.waitForExistence(timeout: 5))
        capture("wizard-winter-work-timezone")
    }

    private func dismissKeyboardIntroduction(in app: XCUIApplication) {
        let introduction = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Continue", "wizard-continue")).firstMatch
        if introduction.waitForExistence(timeout: 2), introduction.isHittable { introduction.tap() }
    }

    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name; attachment.lifetime = .keepAlways; add(attachment)
    }
}
