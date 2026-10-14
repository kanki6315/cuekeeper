import XCTest

final class DesignSupplementTests: XCTestCase {
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
        XCTAssertTrue(app.staticTexts["Completed"].waitForExistence(timeout: 5))
        XCTAssertFalse(complete.exists)
    }

    /// Verify the changed scope control and capture glass on populated working screens.
    func testCombinedGlassSurfaces() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = tablet ? .landscapeLeft : .portrait
        for dark in [false, true] {
            for route in ["root", "payments", "edit-job", "settings"] {
                app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=\(route)"] + (dark ? ["--design-dark"] : [])
                app.launch()
                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
                if route == "root" {
                    let scope = app.buttons["upcoming-scope"]
                    XCTAssertTrue(scope.waitForExistence(timeout: 10))
                    scope.tap()
                    app.buttons["This week"].tap()
                    XCTAssertTrue(scope.label.contains("This week"))
                    scope.tap()
                    app.buttons["All upcoming"].tap()
                    XCTAssertTrue(scope.label.contains("All upcoming"))
                    XCTAssertTrue(app.buttons["add-job"].isHittable)
                }
                Thread.sleep(forTimeInterval: 1)
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = "glass-\(tablet ? "ipad" : "iphone")-\(route)-\(dark ? "dark" : "light")"
                shot.lifetime = .keepAlways; add(shot)
                app.terminate()
            }
        }
    }

    func testReviewCorrections() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = tablet ? .landscapeLeft : .portrait
        for (route, large, dark) in [("root", false, false), ("job", false, false), ("add-job", false, false), ("root", false, true), ("root", true, true), ("job", true, true), ("edit-session", true, true)] {
            app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=\(route)", "-UIPreferredContentSizeCategoryName", large ? UIContentSizeCategory.accessibilityExtraLarge.rawValue : UIContentSizeCategory.large.rawValue] + (dark ? ["--design-dark"] : [])
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            Thread.sleep(forTimeInterval: 2)
            let name = "\(tablet ? "ipad" : "iphone")-\(route)-\(large ? "ax3" : "normal")-\(dark ? "dark" : "light")"
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); screenshot.name = name; screenshot.lifetime = .keepAlways; add(screenshot)
            if route == "edit-session" {
                app.scrollViews.element(boundBy: app.scrollViews.count - 1).swipeUp()
                let lower = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); lower.name = name + "-lower"; lower.lifetime = .keepAlways; add(lower)
            }
            app.terminate()
        }
        if tablet {
            XCUIDevice.shared.orientation = .portrait
            app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=root", "-UIPreferredContentSizeCategoryName", UIContentSizeCategory.large.rawValue]
            app.launch(); Thread.sleep(forTimeInterval: 2)
            let portrait = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); portrait.name = "ipad-root-portrait-light"; portrait.lifetime = .keepAlways; add(portrait)
        }
    }

    func testSecondaryEditorsAndLargeText() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = tablet ? .landscapeLeft : .portrait
        for (route, large) in [("root", false), ("client", false), ("receipt", false), ("edit-client", false), ("edit-project", false), ("edit-series", false), ("edit-role", false), ("payments", false), ("filters", false), ("root", true), ("payments", true), ("edit-session", true)] {
            app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-dark", "--design-screen=\(route)"] + ["-UIPreferredContentSizeCategoryName", large ? UIContentSizeCategory.accessibilityExtraLarge.rawValue : UIContentSizeCategory.large.rawValue]
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            Thread.sleep(forTimeInterval: 2)
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = "\(tablet ? "ipad" : "iphone")-\(route)-\(large ? "accessibility3" : "secondary")"
            screenshot.lifetime = .keepAlways; add(screenshot)
            if large {
                let scroll = app.scrollViews.element(boundBy: app.scrollViews.count - 1)
                scroll.swipeUp()
                let lower = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); lower.name = (screenshot.name ?? route) + "-lower"; lower.lifetime = .keepAlways; add(lower)
            }
            app.terminate()
        }
    }
}
