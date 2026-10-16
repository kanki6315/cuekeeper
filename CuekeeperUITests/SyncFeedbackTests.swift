import XCTest

final class SyncFeedbackTests: EventWorkflowTestCase {
    func testFloatingSyncFeedbackDoesNotMoveContentAndKeepsWarnings() throws {
        guard UIDevice.current.userInterfaceIdiom == .phone else { throw XCTSkip("Floating feedback is for the tab layout") }
        let app = XCUIApplication()
        var headerY: CGFloat = 0
        for state in ["idle", "receiving", "error"] {
            app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=root", "--design-dark"]
            if state != "idle" { app.launchArguments.append("--ui-test-sync-\(state)") }
            app.launch()
            let addButton = app.buttons["add-job"]
            XCTAssertTrue(addButton.waitForExistence(timeout: 10))
            if state == "idle" { headerY = addButton.frame.minY }
            else {
                let toast = app.buttons["sync-feedback"]
                XCTAssertTrue(toast.waitForExistence(timeout: 10))
                XCTAssertEqual(addButton.frame.minY, headerY, accuracy: 1)
                XCTAssertLessThanOrEqual(toast.frame.maxY, app.tabBars.firstMatch.frame.minY)
                if state == "error" {
                    XCTAssertTrue(toast.label.contains("Warning"))
                    app.tabBars.buttons["Payments"].tap()
                    XCTAssertTrue(toast.waitForExistence(timeout: 5))
                    XCTAssertTrue(toast.label.contains("iCloud needs attention"))
                }
            }
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "floating-sync-\(state)"; shot.lifetime = .keepAlways; add(shot)
            if state == "error" {
                app.buttons["sync-feedback"].tap()
                XCTAssertTrue(app.tabBars.buttons["Settings"].isSelected)
                let summary = app.descendants(matching: .any)["sync-summary"]
                XCTAssertTrue(summary.waitForExistence(timeout: 5))
                XCTAssertEqual(summary.label, "Warning: Sync paused")
                XCTAssertEqual(summary.value as? String, "Couldn’t receive changes. iCloud will try again.")
            }
            app.terminate()
        }
    }

    func testSettingsSummarizesSyncStateWithoutBackups() {
        let app = XCUIApplication()
        let cases: [(flag: String?, extra: [String], label: String, value: String?)] = [
            (nil, [], "Saved on this device", "iCloud sync is off"),
            ("receiving", [], "Receiving changes", nil),
            ("offline", ["--design-dark"], "Offline", "Syncs when you reconnect"),
            ("error", ["--design-dark", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXL"],
             "Warning: Sync paused", "Couldn’t receive changes. iCloud will try again."),
        ]
        for item in cases {
            app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=settings"] + item.extra
            if let flag = item.flag { app.launchArguments.append("--ui-test-sync-\(flag)") }
            app.launch()
            let summary = app.descendants(matching: .any)["sync-summary"]
            XCTAssertTrue(summary.waitForExistence(timeout: 10))
            reveal(summary, in: app)
            XCTAssertEqual(summary.label, item.label)
            XCTAssertEqual(summary.value as? String ?? "", item.value ?? "")
            XCTAssertFalse(app.staticTexts["Storage & iCloud"].exists)
            XCTAssertFalse(app.staticTexts["Last backup"].exists)
            XCTAssertTrue(app.buttons["backups-link"].exists)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "settings-sync-\(item.flag ?? "local")"; shot.lifetime = .keepAlways; add(shot)
            app.terminate()
        }
    }

    func testSyncFeedbackRemainsNonblocking() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--ui-test-sync-receiving", "--setup-returning"]
        app.launch()
        XCTAssertTrue(app.buttons["sync-feedback"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Receiving changes…"].exists)
        let receiving = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        receiving.name = "Receiving iCloud changes"; receiving.lifetime = .keepAlways; add(receiving)
        app.buttons["add-job"].tap()
        XCTAssertTrue(app.buttons["wizard-continue"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--ui-testing", "--ui-test-sync-offline"]
        app.launch()
        XCTAssertTrue(app.buttons["sync-feedback"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Offline — changes saved on this device"].exists)
        let offline = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        offline.name = "Offline local storage"; offline.lifetime = .keepAlways; add(offline)
        app.buttons["sync-feedback"].tap()
        XCTAssertTrue(app.staticTexts["Your data"].waitForExistence(timeout: 5))
    }
}
