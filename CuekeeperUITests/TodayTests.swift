import XCTest

final class TodayTests: XCTestCase {
    func testWidgetLinkReturnsToToday() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--today-fixtures"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Day schedule"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["upcoming-scope-All"].tap()
        XCTAssertTrue(app.textFields["search-jobs"].waitForExistence(timeout: 3))
        app.open(URL(string: "cuekeeper://today")!)
        XCTAssertTrue(app.staticTexts["Day schedule"].firstMatch.waitForExistence(timeout: 5))
        app.staticTexts["Qualifying"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Qualifying"].waitForExistence(timeout: 3))
        app.open(URL(string: "cuekeeper://today")!)
        XCTAssertTrue(app.staticTexts["Day schedule"].firstMatch.waitForExistence(timeout: 5))
    }
    func testTodayLargeText() {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--today-fixtures", "--design-dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Day schedule"].firstMatch.waitForExistence(timeout: 15))
        app.swipeUp()
        XCTAssertTrue(app.staticTexts["Silverstone weekend"].firstMatch.exists)
        Thread.sleep(forTimeInterval: 0.6)
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "today-\(UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")-large-text"; shot.lifetime = .keepAlways; add(shot)
    }
    func testAccessoryLayouts() {
        let app = XCUIApplication()
        XCUIDevice.shared.orientation = .portrait
        for theme in ["light", "dark"] {
            app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--today-fixtures", "--design-screen=accessories"] + (theme == "dark" ? ["--design-dark"] : [])
            app.launch()
            XCTAssertTrue(app.staticTexts["Lock Screen accessories"].waitForExistence(timeout: 15))
            Thread.sleep(forTimeInterval: 0.6)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "today-\(UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone")-accessories-\(theme)"; shot.lifetime = .keepAlways; add(shot)
            app.terminate()
        }
    }
    func testTodayAndWidgetLayouts() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = tablet ? .landscapeLeft : .portrait
        for theme in ["light", "dark"] {
            for route in ["root", "widgets"] {
                app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--today-fixtures", "--design-screen=\(route)"] + (theme == "dark" ? ["--design-dark"] : [])
                app.launch()
                XCTAssertTrue(app.staticTexts[route == "root" ? "Day schedule" : "Small widget · one event"].firstMatch.waitForExistence(timeout: 15))
                if route == "root" {
                    XCTAssertTrue(app.staticTexts["Qualifying"].firstMatch.exists)
                    XCTAssertTrue(app.staticTexts["Silverstone weekend"].firstMatch.exists)
                }
                Thread.sleep(forTimeInterval: 0.6)
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = "today-\(tablet ? "ipad" : "iphone")-\(route)-\(theme)"; shot.lifetime = .keepAlways; add(shot)
                if route == "root" && !tablet {
                    app.swipeUp()
                    XCTAssertTrue(app.staticTexts["Evening review"].firstMatch.waitForExistence(timeout: 3))
                    XCTAssertTrue(app.staticTexts["Studio highlights"].firstMatch.exists)
                    let lower = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); lower.name = "today-iphone-lower-\(theme)"; lower.lifetime = .keepAlways; add(lower)
                    app.staticTexts["Evening review"].firstMatch.tap()
                    XCTAssertTrue(app.navigationBars["Evening review"].waitForExistence(timeout: 3))
                }
                app.terminate()
            }
        }
    }
}
