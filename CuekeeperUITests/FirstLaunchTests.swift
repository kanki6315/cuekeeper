import XCTest

final class FirstLaunchUITests: RegressionUITestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }
    private func capture(_ name: String) {
        captureScreenshot(name)
    }

    func testSetupPreferencesFinishAndReplay() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--first-launch", "--ui-test-sync-receiving"]
        app.launch()
        XCTAssertTrue(app.buttons["setup-start"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Syncing your data"].exists)
        XCTAssertFalse(app.staticTexts["Bookings, schedules and payments—even before every detail is confirmed."].exists)
        capture("first-launch-welcome")
        app.buttons["setup-start"].tap()
        XCTAssertTrue(app.buttons["setup-preferences-continue"].waitForExistence(timeout: 5))
        capture("first-launch-preferences")
        app.buttons.matching(identifier: "preference-role").firstMatch.tap()
        app.buttons["Commentator"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "preference-role").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(identifier: "preference-role").firstMatch.label.contains("Commentator"))
        app.segmentedControls.buttons["Dark"].tap()
        capture("first-launch-preferences-dark")
        app.buttons["setup-preferences-continue"].tap()
        XCTAssertTrue(app.buttons["setup-skip-calendar"].waitForExistence(timeout: 5))
        capture("first-launch-calendar-dark")
        app.buttons["setup-skip-calendar"].tap()
        XCTAssertTrue(app.buttons["add-job"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["sync-feedback"].exists)
        XCTAssertFalse(app.textFields["search-jobs"].exists)
        capture("first-launch-empty-dark")
        app.terminate()
        app.launchArguments = ["--ui-testing", "--first-launch"]
        app.launch()
        XCTAssertTrue(app.buttons["add-job"].waitForExistence(timeout: 10))
        XCTAssertFalse(app.buttons["setup-start"].exists)
        if app.tabBars.buttons["Settings"].exists { app.tabBars.buttons["Settings"].tap() }
        else { app.staticTexts["Settings"].firstMatch.tap() }
        let replay = app.buttons["run-setup-again"]
        for _ in 0..<5 where !replay.isHittable { app.swipeUp() }
        XCTAssertTrue(replay.waitForExistence(timeout: 5)); replay.tap()
        XCTAssertTrue(app.buttons["setup-start"].waitForExistence(timeout: 5))
        app.buttons["setup-start"].tap()
        XCTAssertTrue(app.buttons.matching(identifier: "preference-role").firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons.matching(identifier: "preference-role").firstMatch.label.contains("Commentator"))
        XCTAssertTrue(app.segmentedControls.buttons.matching(identifier: "Dark").firstMatch.isSelected)
    }

    func testBackupEmptyStateAndBackNavigation() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--first-launch"]
        app.launch()
        XCTAssertTrue(app.buttons["setup-backups"].waitForExistence(timeout: 10))
        app.buttons["setup-backups"].tap()
        XCTAssertTrue(app.staticTexts["No backups found"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["setup-review-restore"].isEnabled)
        capture("first-launch-backup-empty")
        app.navigationBars.buttons.firstMatch.tap()
        XCTAssertTrue(app.buttons["setup-start"].waitForExistence(timeout: 5))
    }

    func testLargeTextSetupRemainsNavigable() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--first-launch", "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        XCTAssertTrue(app.buttons["setup-start"].waitForExistence(timeout: 10))
        capture("first-launch-welcome-large")
        app.buttons["setup-start"].tap()
        XCTAssertTrue(app.buttons["setup-preferences-continue"].waitForExistence(timeout: 5))
        capture("first-launch-preferences-large")
        app.buttons["setup-preferences-continue"].tap()
        XCTAssertTrue(app.buttons["setup-skip-calendar"].waitForExistence(timeout: 5))
        capture("first-launch-calendar-large")
        app.buttons["setup-skip-calendar"].tap()
        XCTAssertTrue(app.buttons["add-job"].waitForExistence(timeout: 5))
    }

    func testReturningUserAndBackupRecovery() {
        let app = XCUIApplication()
        // A restore requires no active iCloud import.
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--first-launch", "--setup-backup-fixture"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Welcome back"].waitForExistence(timeout: 10))
        capture("first-launch-returning")
        app.buttons["setup-backups"].tap()
        let review = app.buttons["setup-review-restore"]
        XCTAssertTrue(review.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", "1 event · ")).firstMatch.waitForExistence(timeout: 5))
        capture("first-launch-backup-picker")
        review.tap()
        XCTAssertTrue(app.buttons["Restore Backup"].waitForExistence(timeout: 5))
        capture("first-launch-backup-confirmation")
        app.buttons["Restore Backup"].tap()
        XCTAssertTrue(app.alerts["Backup recovered"].waitForExistence(timeout: 5))
        app.alerts.buttons["Continue setup"].tap()
        XCTAssertTrue(app.buttons["setup-preferences-continue"].waitForExistence(timeout: 5))
        app.buttons["setup-preferences-continue"].tap()
        app.buttons["setup-skip-calendar"].tap()
        XCTAssertTrue(app.staticTexts["Recovered broadcast"].firstMatch.waitForExistence(timeout: 5))
    }
}
