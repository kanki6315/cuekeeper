import XCTest

final class PaymentsTests: XCTestCase {
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
}
