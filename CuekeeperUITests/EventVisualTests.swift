import XCTest

final class EventVisualTests: XCTestCase {
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
                app.buttons["Tentative"].tap()
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
                + (dark ? ["--design-dark"] : [])
                + (large ? ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraLarge.rawValue] : [])
            app.launch()
            let ready = route == "add-job" ? app.buttons["wizard-continue"] : route == "edit-event" ? app.buttons["save-event"] : app.buttons["edit-event"]
            XCTAssertTrue(ready.waitForExistence(timeout: 10))
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "events-\(tablet ? "ipad" : "iphone")-\(route)-\(dark ? "dark-large" : "light")"; shot.lifetime = .keepAlways; add(shot)
            if route == "edit-event" {
                let booking = app.buttons["editor-booking-section"].firstMatch
                for _ in 0..<8 where !booking.isHittable { app.swipeUp() }
                if !app.textFields["library-WorkProject-name"].exists { booking.tap() }
                let work = app.buttons["edit-booking-status"]
                for _ in 0..<3 where !work.isHittable { app.swipeUp() }
                let details = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                details.name = "booking-\(tablet ? "ipad" : "iphone")-\(dark ? "dark" : "light")-\(large ? "large" : "normal")"
                details.lifetime = .keepAlways; add(details)
            }
            app.terminate()
        }
    }
}
