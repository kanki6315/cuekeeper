import XCTest

final class EventVisualTests: XCTestCase {
    func testCompactEventFilters() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures",
                               "--design-screen=root", "-appearance", "light"]
        app.launch()
        XCTAssertTrue(app.buttons["upcoming-scope-All"].waitForExistence(timeout: 10))
        let events = app.buttons["Events"].firstMatch
        if events.exists { events.tap() } else { app.staticTexts["Events"].firstMatch.tap() }
        let active = app.buttons["event-status-scope-Active"]
        XCTAssertTrue(active.waitForExistence(timeout: 5))
        active.tap()
        XCTAssertTrue(active.isSelected)
        app.buttons["event-status-scope-All"].tap()
        XCTAssertTrue(app.buttons["event-status-scope-All"].isSelected)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = "compact-events-page"
        screenshot.lifetime = .keepAlways
        add(screenshot)
    }

    func testSessionChoicesAdaptToTextSize() {
        continueAfterFailure = false
        for large in [false, true] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=edit-session", "--design-dark"]
                + (large ? ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraLarge.rawValue] : [])
            app.launch()
            XCTAssertTrue(app.buttons["save-session"].waitForExistence(timeout: 10))
            let schedule = large ? app.buttons["session-schedule"] : app.segmentedControls["session-schedule"]
            for _ in 0..<10 where !schedule.isHittable { app.swipeUp() }
            XCTAssertTrue(schedule.isHittable)
            if large {
                XCTAssertFalse(app.segmentedControls["session-schedule"].exists)
                schedule.tap()
                app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Tentative", "booking-status-tentative")).element.tap()
            } else {
                schedule.buttons["Tentative"].tap()
                XCTAssertTrue(schedule.buttons["Tentative"].isSelected)
            }
            let coverage = large ? app.buttons["session-coverage"] : app.segmentedControls["session-coverage"]
            for _ in 0..<5 where !coverage.isHittable { app.swipeUp() }
            XCTAssertTrue(coverage.isHittable)
            if large { coverage.tap(); app.buttons["Not covering"].tap() }
            else { coverage.buttons["Not covering"].tap(); XCTAssertTrue(coverage.buttons["Not covering"].isSelected) }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "session-choices-\(UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")-\(large ? "large" : "normal")"
            shot.lifetime = .keepAlways; add(shot)
            app.buttons["Cancel"].tap()
            if app.buttons["Discard Changes"].waitForExistence(timeout: 2) { app.buttons["Discard Changes"].tap() }
            app.terminate()
        }
    }

    func testGlassCompletionActions() {
        continueAfterFailure = false
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=job", "--design-dark"]
        app.launch()
        let edit = app.buttons["edit-event"]
        XCTAssertTrue(edit.waitForExistence(timeout: 10)); edit.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        let complete = app.buttons["Mark completed"]
        XCTAssertTrue(complete.waitForExistence(timeout: 5))
        complete.tap()
        let completed = app.buttons["booking-status-completed"]
        XCTAssertTrue(completed.waitForExistence(timeout: 5))
        XCTAssertTrue(completed.isSelected)
        XCTAssertFalse(complete.exists)
    }
}
