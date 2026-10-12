import XCTest

final class CaptureTests: XCTestCase {
    func testCapturePersistsAcrossLaunch() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store"]
        app.launch()
        XCTAssertTrue(app.buttons["add-job"].waitForExistence(timeout: 10))
        app.buttons["add-job"].tap()
        let name = app.textFields["job-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["save-job"].isEnabled)
        name.tap()
        name.typeText("Test broadcast")
        app.buttons["save-job"].tap()
        XCTAssertTrue(app.staticTexts["Test broadcast"].waitForExistence(timeout: 5))
        app.terminate()
        app.launchArguments = ["--ui-testing"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Test broadcast"].waitForExistence(timeout: 10))
        app.staticTexts["Test broadcast"].tap()
        let status = app.descendants(matching: .any)["booking-status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.value as? String, "Tentative")
    }
}
