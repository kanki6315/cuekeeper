import XCTest

/// Captures key screens in every theme and appearance, for review whenever a screen changes.
final class ThemeCaptureTests: XCTestCase {
    func testThemes() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        for theme in ["teal", "indigo", "purple", "magenta", "amber", "olive", "espresso", "ink", "graphite"] {
            for appearance in ["light", "dark"] {
                for route in ["root", "job", "payments", "settings"] {
                    app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=\(route)", "--design-theme=\(theme)"] + (appearance == "dark" ? ["--design-dark"] : [])
                    app.launch()
                    XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
                    expectation(for: NSPredicate(format: "count > 0"), evaluatedWith: app.staticTexts)
                    waitForExpectations(timeout: 10)
                    Thread.sleep(forTimeInterval: 1)
                    let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                    shot.name = "\(theme)-\(appearance)-\(device)-\(route)"; shot.lifetime = .keepAlways; add(shot)
                    app.terminate()
                }
            }
        }
    }

    /// The picker shows every theme's icon, so one theme per appearance covers it.
    func testThemePicker() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        for appearance in ["light", "dark"] {
            app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=settings"] + (appearance == "dark" ? ["--design-dark"] : [])
            app.launch()
            let row = app.buttons["preference-theme"].firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            row.tap()
            XCTAssertTrue(app.buttons["theme-indigo"].firstMatch.waitForExistence(timeout: 5))
            Thread.sleep(forTimeInterval: 1)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "picker-\(appearance)-\(device)"; shot.lifetime = .keepAlways; add(shot)
            app.terminate()
        }
    }
}
