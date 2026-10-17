import XCTest

final class EventWizardTests: DaybookUITestCase {
    func testEventCreationUsesMultiDateCalendar() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=add-job", "--design-dark"]
        app.launch()
        XCTAssertTrue(app.buttons["wizard-continue"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.switches["job-multiple-days"].exists)
        capture("event-creation-calendar")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.dateFormat = "MMMM d"
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let day = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", formatter.string(from: tomorrow))).firstMatch
        XCTAssertTrue(day.exists)
        day.tap()
        capture("event-creation-range")
        for _ in 0..<3 where !app.descendants(matching: .any)["event-end-summary"].exists { app.swipeUp() }
        XCTAssertTrue(app.descendants(matching: .any)["event-end-summary"].exists, app.debugDescription)
    }

    func testInlineNativeSessionTimesAndIndependentClear() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=add-job", "--wizard-foreign-session", "--design-dark"]
        app.launch()
        // The foreign-date fixture also exercises the inline time controls below.
        XCTAssertTrue(app.buttons["wizard-continue"].waitForExistence(timeout: 10))
        let date = app.datePickers["wizard-session-date"]
        XCTAssertTrue(date.waitForExistence(timeout: 5))
        XCTAssertTrue(date.debugDescription.contains("Jan 15") || date.debugDescription.contains("January 15"), "Session should display January 15 in Tokyo, not January 14 in New York: \(date.debugDescription)")
        capture("wizard-foreign-session-date")
        let start = app.buttons["session-time-Start-unset"]
        XCTAssertTrue(start.waitForExistence(timeout: 10))
        for _ in 0..<4 where !start.isHittable { app.swipeUp() }
        start.tap()
        XCTAssertTrue(app.datePickers["session-time-Start"].exists)
        XCTAssertFalse(app.navigationBars["Start & end"].exists)
        XCTAssertFalse(app.datePickers["End date"].exists)
        XCTAssertFalse(app.textFields["schedule-time-Start"].exists)
        let end = app.buttons["session-time-End-unset"]
        XCTAssertTrue(end.exists)
        XCTAssertFalse(app.datePickers["session-time-End"].exists)
        end.tap()
        XCTAssertTrue(app.datePickers["session-time-End"].exists)
        app.buttons["Clear start"].tap()
        XCTAssertTrue(start.exists)
        XCTAssertTrue(app.datePickers["session-time-End"].exists)
        app.buttons["Clear end"].tap()
        XCTAssertTrue(end.exists)
        capture("inline-native-session-times-cleared")
        app.buttons["wizard-continue"].tap()
        XCTAssertTrue(app.buttons["work-arrangement"].waitForExistence(timeout: 5))
        XCTAssertFalse(element("work-timezone", in: app).exists)
        capture("wizard-winter-work-timezone")
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
        XCTAssertFalse(booking.buttons["Completed"].exists)
        XCTAssertFalse(booking.buttons["Cancelled"].exists)
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
        XCTAssertTrue(next.waitForNonExistence(timeout: 5))
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

}
