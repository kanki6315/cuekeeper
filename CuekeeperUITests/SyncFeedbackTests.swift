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
            captureScreenshot("floating-sync-\(state)")
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
        // The state-to-copy matrix is covered by PersistenceTests. This checks UI wiring.
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=settings"]
        app.launch()
        let summary = app.descendants(matching: .any)["sync-summary"]
        XCTAssertTrue(summary.waitForExistence(timeout: 10))
        reveal(summary, in: app)
        XCTAssertEqual(summary.label, "Saved on this device")
        XCTAssertEqual(summary.value as? String, "iCloud sync is off")
        XCTAssertFalse(app.staticTexts["Storage & iCloud"].exists)
        XCTAssertFalse(app.staticTexts["Last backup"].exists)
        XCTAssertTrue(app.buttons["backups-link"].exists)
        captureScreenshot("settings-sync-local")
    }

    func testSyncFeedbackRemainsNonblocking() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--ui-test-sync-receiving", "--setup-returning"]
        app.launch()
        XCTAssertTrue(app.buttons["sync-feedback"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Receiving changes…"].exists)
        captureScreenshot("Receiving iCloud changes")
        app.buttons["add-job"].tap()
        XCTAssertTrue(app.buttons["wizard-continue"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--ui-testing", "--ui-test-sync-offline"]
        app.launch()
        XCTAssertTrue(app.buttons["sync-feedback"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Offline — changes saved on this device"].exists)
        captureScreenshot("Offline local storage")
        app.buttons["sync-feedback"].tap()
        XCTAssertTrue(app.staticTexts["Your data"].waitForExistence(timeout: 5))
    }
}
