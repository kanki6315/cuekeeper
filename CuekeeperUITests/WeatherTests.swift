import XCTest

final class WeatherTests: XCTestCase {
    private func launch(route: String, dark: Bool = false, large: Bool = false) -> XCUIApplication {
        continueAfterFailure = false
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--weather-fixtures", "--design-screen=\(route)"]
            + (dark ? ["--design-dark"] : [])
            + (large ? ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraLarge.rawValue] : [])
        app.launch()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
        return app
    }
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            let forms = app.scrollViews.matching(identifier: "daybook-form")
            let scroll = forms.element(boundBy: forms.count - 1)
            scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.85))
                .press(forDuration: 0.05, thenDragTo: scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.25)))
        }
        XCTAssertTrue(element.isHittable)
    }
    private func positionNearTop(_ element: XCUIElement, in app: XCUIApplication) {
        reveal(element, in: app)
        let forms = app.scrollViews.matching(identifier: "daybook-form")
        let scroll = forms.element(boundBy: forms.count - 1)
        let delta = min(max(element.frame.minY - scroll.frame.minY - 80, 0), scroll.frame.height * 0.6)
        if delta > 20 {
            let origin = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.85))
            origin.press(forDuration: 0.1, thenDragTo: origin.withOffset(CGVector(dx: 0, dy: -delta)), withVelocity: .slow, thenHoldForDuration: 0.4)
        }
    }
    private func capture(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = "weather-\(UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")-\(name)"
        attachment.lifetime = .keepAlways; add(attachment)
    }

    func testForecastAndHourlyDetails() {
        for dark in [false, true] {
            let app = launch(route: "event", dark: dark, large: dark)
            let status = app.descendants(matching: .any)["weather-outdated"].firstMatch
            reveal(status, in: app)
            positionNearTop(status, in: app)
            capture(dark ? "forecast-dark-large" : "forecast-light")
            let session = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Hourly from call time")).firstMatch
            reveal(session, in: app)
            session.tap()
            let hour = app.descendants(matching: .any)["weather-hour"].firstMatch
            XCTAssertTrue(hour.waitForExistence(timeout: 5))
            positionNearTop(hour, in: app)
            capture(dark ? "hourly-dark-large" : "hourly-light")
            app.terminate()
        }
    }

    func testTrackSearchSelectionAndRemoval() {
        let app = launch(route: "edit-event")
        reveal(app.buttons["remove-track"], in: app); app.buttons["remove-track"].tap()
        app.buttons["choose-track"].tap()
        let field = app.textFields["track-search-field"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("Daytona")
        let result = app.buttons["track-result-0"]
        XCTAssertTrue(result.waitForExistence(timeout: 5)); reveal(result, in: app); result.tap()
        let use = app.buttons["use-track"]; reveal(use, in: app)
        capture("track-selection"); use.tap()
        XCTAssertTrue(app.buttons["save-event"].waitForExistence(timeout: 5)); app.buttons["save-event"].tap()
        let status = app.descendants(matching: .any)["weather-outdated"].firstMatch
        reveal(status, in: app)
        XCTAssertTrue(status.exists)
        app.buttons["edit-event"].tap()
        reveal(app.buttons["remove-track"], in: app); app.buttons["remove-track"].tap()
        app.buttons["save-event"].tap()
        XCTAssertFalse(app.descendants(matching: .any)["weather-outdated"].firstMatch.exists)
    }
}
