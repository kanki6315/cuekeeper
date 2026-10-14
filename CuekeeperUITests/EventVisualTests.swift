import XCTest

final class EventVisualTests: XCTestCase {
    func testEventSurfaces() {
        continueAfterFailure = false
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = tablet ? .landscapeLeft : .portrait
        for (route, dark, large) in [("event", false, false), ("add-job", false, false), ("event", true, true), ("edit-session", true, true)] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--event-fixtures", "--design-screen=\(route)"]
                + (dark ? ["--design-dark"] : [])
                + (large ? ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraLarge.rawValue] : [])
            app.launch()
            let ready = route == "add-job" ? app.buttons["save-event"] : route == "edit-session" ? app.buttons["save-session"] : app.buttons["edit-event"]
            XCTAssertTrue(ready.waitForExistence(timeout: 10))
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "events-\(tablet ? "ipad" : "iphone")-\(route)-\(dark ? "dark-large" : "light")"; shot.lifetime = .keepAlways; add(shot)
            app.terminate()
        }
    }
}
