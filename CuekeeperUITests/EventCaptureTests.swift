import XCTest

/// Screenshots of event detail and editor surfaces for design review.
final class EventCaptureTests: XCTestCase {
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
