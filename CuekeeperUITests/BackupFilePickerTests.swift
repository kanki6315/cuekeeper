import XCTest

/// Drives Apple's Files pickers for backup export and import. They run out of process and drop taps
/// on parallel simulator clones, so this class runs alone from the serial `Cuekeeper - System Pickers` scheme.
final class BackupFilePickerTests: XCTestCase {
    func testSystemFilePickersExportAndImport() {
        continueAfterFailure = false
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=backups"]
        app.launch()
        XCTAssertTrue(app.buttons["backup-now"].waitForExistence(timeout: 10))
        capture("backups-files-light")
        revealFiles(app)
        let export = button(app, "backup-export", "Export to Files")
        XCTAssertTrue(export.waitForExistence(timeout: 5))
        export.tap()
        let save = app.buttons["DOCPicker.actionButton"]
        XCTAssertTrue(save.waitForExistence(timeout: 15))
        capture("backup-export-picker")
        save.tap()
        XCTAssertTrue(app.staticTexts["Backup exported. Keep the file in a safe place."].waitForExistence(timeout: 10))
        revealFiles(app)
        let importer = button(app, "backup-import", "Import a Backup")
        XCTAssertTrue(importer.waitForExistence(timeout: 5))
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
    }

    /// Files actions sit inline beside the status on regular width and behind a toolbar menu otherwise.
    private func revealFiles(_ app: XCUIApplication) {
        let export = button(app, "backup-export", "Export to Files")
        if export.exists && export.isHittable { return }
        let menu = button(app, "backup-files", "Files")
        if menu.exists { menu.tap(); return }
        for _ in 0..<8 where !export.isHittable { app.swipeUp() }
    }

    /// Menu items do not always keep accessibility identifiers, so fall back to the label.
    private func button(_ app: XCUIApplication, _ identifier: String, _ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier == %@ OR label == %@", identifier, label)).firstMatch
    }

    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
}
