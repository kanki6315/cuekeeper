import XCTest

final class RecoveryTests: XCTestCase {
    func testRestoreDeletedEventAndBackupSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = tablet ? .landscapeLeft : .portrait
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=recently-deleted"]
        app.launch()
        let restore = app.buttons["Restore City vs United"]
        XCTAssertTrue(restore.waitForExistence(timeout: 10))
        capture("recently-deleted")
        restore.tap()
        XCTAssertTrue(app.staticTexts["Restored City vs United."].waitForExistence(timeout: 5))
        XCTAssertFalse(restore.exists)
        capture("recently-deleted-restored")
        app.terminate()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=backups", "--design-dark"]
        app.launch()
        XCTAssertTrue(app.buttons["backup-now"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["backup-now"].isEnabled)
        app.buttons["backup-now"].tap()
        XCTAssertTrue(app.staticTexts["Backup saved to iCloud."].waitForExistence(timeout: 5))
        capture("backups-dark")
        let restoreBackup = app.buttons["Restore"].firstMatch
        if !restoreBackup.isHittable { app.swipeUp() }
        restoreBackup.tap()
        XCTAssertTrue(app.buttons["Restore Backup"].waitForExistence(timeout: 5))
        app.buttons["Restore Backup"].tap()
        let complete = NSPredicate(format: "label CONTAINS %@", "Restore complete")
        expectation(for: complete, evaluatedWith: app.staticTexts["backup-notice"])
        waitForExpectations(timeout: 5)
        capture("backup-after-restore")
        let delete = app.buttons["Delete Backup"].firstMatch
        if !delete.isHittable { app.swipeUp() }
        delete.tap()
        let confirm = app.buttons.matching(identifier: "Delete Backup").allElementsBoundByIndex.last!
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.staticTexts["No backups yet"].waitForExistence(timeout: 5))
    }
    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
