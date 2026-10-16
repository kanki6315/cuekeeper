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

    func testEventSurfaces() {
        continueAfterFailure = false
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = tablet ? .landscapeLeft : .portrait
        for (route, dark, large) in [("event", false, false), ("event", true, false), ("edit-event", false, false), ("edit-event", true, false), ("add-job", false, false), ("event", true, true), ("edit-event", true, true)] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--event-fixtures", "--design-screen=\(route)"]
                + ["-appearance", dark ? "dark" : "light"] + (dark ? ["--design-dark"] : [])
                + (large ? ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraLarge.rawValue] : [])
            app.launch()
            let ready = route == "add-job" ? app.buttons["wizard-continue"] : route == "edit-event" ? app.buttons["save-event"] : app.buttons["edit-event"]
            XCTAssertTrue(ready.waitForExistence(timeout: 10))
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "events-\(tablet ? "ipad" : "iphone")-\(route)-\(dark ? "dark-large" : "light")"; shot.lifetime = .keepAlways; add(shot)
            if route == "edit-event" {
                XCTAssertFalse(app.buttons["editor-booking-section"].exists)
                let client = app.textFields["library-Client-name"]
                for _ in 0..<8 where !client.isHittable { app.swipeUp() }
                let work = app.buttons["edit-booking-status-booked"]
                for _ in 0..<3 where !work.isHittable { app.swipeUp() }
                let details = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                details.name = "booking-\(tablet ? "ipad" : "iphone")-\(dark ? "dark" : "light")-\(large ? "large" : "normal")"
                details.lifetime = .keepAlways; add(details)
            }
            app.terminate()
        }
    }
}
