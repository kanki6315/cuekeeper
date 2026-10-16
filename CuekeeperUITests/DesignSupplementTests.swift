import XCTest

final class DesignSupplementTests: XCTestCase {
    func testReadyToInvoiceClientGroups() {
        continueAfterFailure = false
        let app = XCUIApplication()
        for dark in [false, true] {
            app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=payments"]
                + (dark ? ["--design-dark", "-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraLarge.rawValue] : [])
            app.launch()
            let client = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND label CONTAINS %@", "IMSA", "2 events")).firstMatch
            for _ in 0..<5 where !client.isHittable { app.swipeUp() }
            XCTAssertTrue(client.waitForExistence(timeout: 5))
            XCTAssertTrue(client.label.contains("2,400.00"))
            XCTAssertTrue(client.label.contains("900.00"))
            XCTAssertFalse(app.staticTexts["Sebring AEC"].exists)
            client.tap()
            XCTAssertTrue(app.staticTexts["Sebring AEC"].waitForExistence(timeout: 5))
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "ready-client-expanded-\(dark ? "dark-large" : "light")"
            shot.lifetime = .keepAlways; add(shot)
            client.tap()
            XCTAssertFalse(app.staticTexts["Sebring AEC"].exists)
            client.tap()
            let event = app.staticTexts["Sebring AEC"]
            for _ in 0..<5 where !event.isHittable { app.swipeUp() }
            event.tap()
            XCTAssertTrue(app.buttons["edit-event"].waitForExistence(timeout: 5))
        }
    }

    /// Captures each event tab and checks that a To settle action opens its record.
    func testEventPageTabsAndOpenItems() {
        continueAfterFailure = false
        let app = XCUIApplication()
        for (dark, large) in [(false, false), (true, false), (false, true)] {
            app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=event"]
                + (dark ? ["--design-dark"] : [])
                + (large ? ["-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraLarge.rawValue] : [])
            app.launch()
            let variant = dark ? "dark" : large ? "light-large" : "light"
            XCTAssertTrue(app.descendants(matching: .any)["open-items"].waitForExistence(timeout: 10))
            for tab in ["schedule", "money", "details"] {
                let button = app.buttons["event-tab-\(tab)"]
                XCTAssertTrue(button.waitForExistence(timeout: 5))
                for _ in 0..<5 where !button.isHittable { app.swipeUp() }
                button.tap()
                let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
                shot.name = "event-page-\(tab)-\(variant)"
                shot.lifetime = .keepAlways; add(shot)
                for _ in 0..<8 where app.scrollViews.firstMatch.exists { app.swipeDown() }
            }
            let action = app.buttons["open-item-balanceOwed"]
            XCTAssertTrue(action.waitForExistence(timeout: 5))
            action.tap()
            XCTAssertTrue(app.navigationBars["Invoice details"].waitForExistence(timeout: 5))
            XCTAssertTrue(app.buttons["record-payment"].exists)
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
        let status = app.buttons["booking-status"]
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        status.tap()
        let completed = app.buttons["booking-status-completed"]
        XCTAssertTrue(completed.waitForExistence(timeout: 5))
        completed.tap()
        XCTAssertTrue(app.buttons["booking-status"].label.contains("Completed"))
    }

    /// Verify the changed scope control and capture glass on populated working screens.
    func testCombinedGlassSurfaces() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = tablet ? .landscapeLeft : .portrait
        for dark in [false, true] {
            for route in ["root", "payments", "edit-job", "settings"] {
                app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=\(route)"] + ["-appearance", dark ? "dark" : "light"] + (dark ? ["--design-dark"] : [])
                app.launch()
                XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
                if route == "root" {
                    let week = app.buttons["upcoming-scope-Week"]
                    let all = app.buttons["upcoming-scope-All"]
                    XCTAssertTrue(week.waitForExistence(timeout: 10))
                    week.tap()
                    XCTAssertTrue(week.isSelected)
                    all.tap()
                    XCTAssertTrue(all.isSelected)
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
            app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=\(route)", "-UIPreferredContentSizeCategoryName", large ? UIContentSizeCategory.accessibilityExtraLarge.rawValue : UIContentSizeCategory.large.rawValue] + ["-appearance", dark ? "dark" : "light"] + (dark ? ["--design-dark"] : [])
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
