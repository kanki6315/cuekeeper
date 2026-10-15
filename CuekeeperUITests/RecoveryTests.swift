import XCTest

final class RecoveryTests: XCTestCase {
    func testRestoreDeletedEventAndBackupSettings() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = tablet ? .landscapeLeft : .portrait
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=recently-deleted"]
        app.launch()
        let row = app.cells.containing(.staticText, identifier: "City vs United").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        capture("recently-deleted")
        row.swipeRight()
        let restore = app.buttons["Restore City vs United"]
        XCTAssertTrue(restore.waitForExistence(timeout: 5))
        XCTAssertTrue(row.exists, "Swiping must only reveal Restore")
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
    func testDeleteRequiresTapAndConfirmation() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=recently-deleted"]
        app.launch()
        let row = app.cells.containing(.staticText, identifier: "City vs United").firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 10))
        row.swipeLeft()
        let delete = app.buttons["Permanently delete City vs United"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        XCTAssertTrue(row.exists)
        XCTAssertFalse(app.buttons["Delete Permanently"].exists)
        delete.tap()
        XCTAssertTrue(app.buttons["Cancel"].waitForExistence(timeout: 5))
        app.buttons["Cancel"].tap()
        XCTAssertTrue(row.exists, "Cancel must keep the record recoverable")
        row.swipeLeft()
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.tap()
        let confirm = app.buttons["Delete Permanently"]
        XCTAssertTrue(confirm.waitForExistence(timeout: 5))
        confirm.tap()
        XCTAssertTrue(app.staticTexts["Removed from Recently Deleted."].waitForExistence(timeout: 5))
        XCTAssertFalse(row.exists)
    }

    func testRecoveryLayoutsAndAccessibleActions() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let device = UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        for (name, size, dark) in [
            ("standard-dark", UIContentSizeCategory.large, true),
            ("largest-dark", UIContentSizeCategory.accessibilityExtraExtraExtraLarge, true),
            ("largest-light", UIContentSizeCategory.accessibilityExtraExtraExtraLarge, false)
        ] {
            let app = XCUIApplication()
            app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=recently-deleted",
                                   "-UIPreferredContentSizeCategoryName", size.rawValue] + (dark ? ["--design-dark"] : [])
            app.launch()
            let row = app.cells.containing(.staticText, identifier: "City vs United").firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 10))
            XCTAssertTrue(row.isHittable)
            capture("recovery-\(device)-\(name)")
            row.swipeLeft()
            let delete = app.buttons["Permanently delete City vs United"]
            XCTAssertTrue(delete.waitForExistence(timeout: 5))
            XCTAssertTrue(delete.isHittable)
            XCTAssertTrue(row.exists)
            capture("recovery-\(device)-\(name)-delete")
            delete.tap()
            let cancel = app.buttons["Cancel"]
            XCTAssertTrue(cancel.waitForExistence(timeout: 5))
            cancel.tap()
            XCTAssertTrue(row.exists)
            row.swipeRight()
            let restore = app.buttons["Restore City vs United"]
            XCTAssertTrue(restore.waitForExistence(timeout: 5))
            XCTAssertTrue(restore.isHittable)
            capture("recovery-\(device)-\(name)-restore")
            restore.tap()
            XCTAssertTrue(app.staticTexts["Restored City vs United."].waitForExistence(timeout: 5))
            app.terminate()
        }
    }

    func testBackupFilePickersAndLayouts() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=backups"]
        app.launch()
        let export = app.buttons["backup-export"]
        XCTAssertTrue(export.waitForExistence(timeout: 10))
        if !export.isHittable { app.swipeUp() }
        capture("backups-files-light")
        export.tap()
        let save = app.buttons["DOCPicker.actionButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        capture("backup-export-picker")
        save.tap()
        XCTAssertTrue(app.staticTexts["Backup exported. Keep the file in a safe place."].waitForExistence(timeout: 10))
        let importer = app.buttons["backup-import"]
        if !importer.isHittable { app.swipeUp() }
        importer.tap()
        let file = app.cells.matching(NSPredicate(format: "label BEGINSWITH %@", "Cuekeeper-")).firstMatch
        if !file.waitForExistence(timeout: 5) {
            let browse = app.buttons["Browse"].firstMatch
            if browse.exists { browse.tap() }
            let local = app.staticTexts[UIDevice.current.userInterfaceIdiom == .pad ? "On My iPad" : "On My iPhone"].firstMatch
            if local.exists { local.tap() }
        }
        capture("backup-import-picker")
        if !file.waitForExistence(timeout: 10) { print(app.debugDescription) }
        XCTAssertTrue(file.exists)
        file.tap()
        XCTAssertTrue(app.buttons["Restore Backup"].waitForExistence(timeout: 10))
        capture("backup-file-confirmation")
        app.buttons["Restore Backup"].tap()
        let complete = NSPredicate(format: "label CONTAINS %@", "Restore complete")
        expectation(for: complete, evaluatedWith: app.staticTexts["backup-notice"])
        waitForExpectations(timeout: 10)
        app.terminate()
        app.launchArguments += ["--design-dark", "-UIPreferredContentSizeCategoryName", UIContentSizeCategory.accessibilityExtraExtraExtraLarge.rawValue]
        app.launch()
        XCTAssertTrue(app.buttons["backup-now"].waitForExistence(timeout: 10))
        capture("backups-largest-text-dark")
        for _ in 0..<8 {
            if app.buttons["backup-import"].isHittable { break }
            app.swipeUp()
        }
        XCTAssertTrue(app.buttons["backup-import"].isHittable)
        capture("backups-files-largest-text-dark")
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
