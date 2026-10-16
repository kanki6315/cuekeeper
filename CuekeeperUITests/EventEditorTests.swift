import XCTest

final class EventEditorTests: DaybookUITestCase {
    func testDeleteEventRequiresConfirmation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=root"]
        app.launch()
        let event = app.staticTexts["City vs United"].firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 10))
        event.tap()
        let details = app.buttons["event-tab-details"]
        if details.waitForExistence(timeout: 5) { details.tap() }
        let delete = app.buttons["delete-job"]
        for _ in 0..<15 where !delete.isHittable {
            app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.8))
                .press(forDuration: 0.01, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.25)))
        }
        XCTAssertTrue(delete.isHittable)
        XCTAssertTrue(app.buttons["duplicate-job"].exists)
        delete.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 3))
        capture("delete-event-confirmation")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(delete.exists)
        delete.tap()
        app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Delete Event", "delete-job")).firstMatch.tap()
        XCTAssertTrue(event.waitForNonExistence(timeout: 5))
        app.terminate()
        app.launchArguments.removeAll { $0 == "--reset-test-store" }
        app.launch()
        XCTAssertTrue(app.staticTexts["Studio highlights"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertFalse(app.staticTexts["City vs United"].exists)
    }

    func testEventAndWorkTimezonesFollowArrangement() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=edit-event"]
        app.launch()
        // Timezones are read-only; places set them.
        XCTAssertTrue(element("event-timezone", in: app).waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["event-timezone"].exists)
        let arrangement = app.buttons["work-arrangement"]
        for _ in 0..<8 where !arrangement.isHittable { app.swipeUp() }
        XCTAssertTrue(arrangement.isHittable)
        XCTAssertTrue(app.textFields["work-location"].exists)
        XCTAssertTrue(element("work-timezone", in: app).exists)
        capture("timezone-remote")
        arrangement.tap(); app.buttons["On-site"].tap()
        XCTAssertFalse(app.textFields["work-location"].exists)
        XCTAssertFalse(element("work-timezone", in: app).exists)
        capture("timezone-onsite")
        arrangement.tap(); app.buttons["Hybrid"].tap()
        XCTAssertTrue(app.textFields["work-location"].exists)
        XCTAssertTrue(element("work-timezone", in: app).exists)
        capture("timezone-hybrid")
        app.buttons["Cancel"].tap(); app.buttons["Discard Changes"].tap()
        app.terminate()
        for large in [false, true] {
            app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=edit-session", "--design-dark"]
                + (large ? ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"] : [])
            app.launch()
            XCTAssertTrue(app.buttons["save-session"].waitForExistence(timeout: 10))
            // LabeledContent exposes a combined label at standard text sizes.
            let forms = app.scrollViews.matching(identifier: "daybook-form")
            let editor = forms.element(boundBy: forms.count - 1)
            let zone = editor.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", "Event timezone")).firstMatch
            for _ in 0..<5 where !zone.isHittable { editor.swipeUp() }
            XCTAssertTrue(zone.isHittable)
            XCTAssertFalse(app.buttons["event-timezone"].exists)
            XCTAssertFalse(element("work-timezone", in: app).exists)
            capture(large ? "session-inherited-timezone-large" : "session-inherited-timezone")
            app.terminate()
        }
    }

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
}
