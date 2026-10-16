import XCTest

final class TodayTests: XCTestCase {
    func testWidgetLinkReturnsToToday() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--today-fixtures"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Day schedule"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["upcoming-scope-All"].tap()
        XCTAssertTrue(app.textFields["search-jobs"].waitForExistence(timeout: 3))
        XCUIDevice.shared.system.open(URL(string: "cuekeeper://today")!)
        XCTAssertTrue(app.staticTexts["Day schedule"].firstMatch.waitForExistence(timeout: 5))
        app.staticTexts["Qualifying"].firstMatch.tap()
        XCTAssertTrue(app.navigationBars["Qualifying"].waitForExistence(timeout: 3))
        XCUIDevice.shared.system.open(URL(string: "cuekeeper://today")!)
        XCTAssertTrue(app.staticTexts["Day schedule"].firstMatch.waitForExistence(timeout: 5))
    }
    func testTodayLinkPreservesWizardUntilUserClosesIt() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--today-fixtures"]
        app.launch()
        let add = app.buttons["add-job"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.tap()
        let next = app.buttons["wizard-continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        let title = app.textFields["job-name"]
        title.tap()
        title.typeText("Draft to keep")
        XCUIDevice.shared.system.open(URL(string: "cuekeeper://today")!)
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCTAssertEqual(title.value as? String, "Draft to keep")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Discard Draft"].waitForExistence(timeout: 3))
        app.buttons["Discard Draft"].tap()
        XCTAssertTrue(app.staticTexts["Day schedule"].firstMatch.waitForExistence(timeout: 5))
    }

    func testTodayLinkWaitsForSessionEditorBeforePoppingDetail() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--today-fixtures"]
        app.launch()
        let session = app.staticTexts["Qualifying"].firstMatch
        XCTAssertTrue(session.waitForExistence(timeout: 15))
        session.tap()
        app.buttons["edit-session"].tap()
        let name = app.textFields["session-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(" changed")
        XCUIDevice.shared.system.open(URL(string: "cuekeeper://today")!)
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertTrue((name.value as? String)?.contains("changed") == true)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 3))
        app.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.staticTexts["Day schedule"].firstMatch.waitForExistence(timeout: 5))
    }

    func testFirstEventWizardSurvivesIncomingEventAndRotation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--ui-test-event-arrives-during-wizard"]
        app.launch()
        let add = app.buttons["add-job"].firstMatch
        XCTAssertTrue(add.waitForExistence(timeout: 15))
        add.tap()
        let next = app.buttons["wizard-continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        // Wait for the synthetic store change that used to replace the iPad root.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertTrue(next.exists)
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .portrait
        app.buttons["Cancel"].tap()
        app.buttons["upcoming-scope-All"].tap()
        XCTAssertTrue(app.staticTexts["Arrived from another device"].firstMatch.waitForExistence(timeout: 5))
    }

    func testExternalRoutesOpenAboveWizardAndReturnToItsDraft() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=pending-root"]
        app.launch()
        XCTAssertTrue(app.buttons["add-job"].firstMatch.waitForExistence(timeout: 15))
        app.buttons["add-job"].firstMatch.tap()
        let name = app.textFields["job-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Preserved underneath")
        for (route, close) in [("calendar", "calendar-route-done"), ("receipt", "Close"), ("siri", "siri-event-done"), ("expense", "Keep Draft")] {
            XCUIDevice.shared.system.open(URL(string: "cuekeeper://ui-test/\(route)")!)
            let button = app.buttons[close]
            XCTAssertTrue(button.waitForExistence(timeout: 8), route)
            if route == "expense" {
                app.navigationBars["Receipt"].swipeDown()
                XCTAssertTrue(button.exists, "A routed draft still requires an explicit close")
            }
            button.tap()
            XCTAssertTrue(name.waitForExistence(timeout: 5), route)
            XCTAssertEqual(name.value as? String, "Preserved underneath", route)
        }
    }

    func testLocalCalendarDisconnectWithoutAccess() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=calendar", "-calendar.selected", "missing-calendar"]
        app.launch()
        let disconnect = app.buttons["calendar-disconnect-keep"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 15))
        disconnect.tap()
        let confirm = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Disconnect without removing entries", "calendar-disconnect-keep")).firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(disconnect.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["calendar-status"].label.contains("Disconnected on this device"))
    }

    func testExternalRouteOpensAboveFirstLaunch() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--first-launch"]
        app.launch()
        XCTAssertTrue(app.buttons["setup-start"].waitForExistence(timeout: 15))
        XCUIDevice.shared.system.open(URL(string: "cuekeeper://ui-test/receipt")!)
        XCTAssertTrue(app.navigationBars["Receipt for which event?"].waitForExistence(timeout: 8))
        app.buttons["Close"].tap()
        XCTAssertTrue(app.buttons["setup-start"].waitForExistence(timeout: 5))
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
