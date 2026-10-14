import XCTest

/// Capture actual SwiftUI screens with synthetic data in the isolated test store.
final class DesignCaptureTests: XCTestCase {
    func testExistingScreens() {
        continueAfterFailure = false
        let app = XCUIApplication()
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        XCUIDevice.shared.orientation = tablet ? .landscapeLeft : .portrait
        let routes = ["root", "job", "add-job", "edit-job", "session", "edit-session", "fee", "edit-fee", "payments", "invoice", "edit-invoice", "payment", "client", "project", "series", "clients", "settings", "calendar", "filters", "timezone", "link"]
        for theme in ["light", "dark"] {
        for route in routes {
            app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=\(route)"] + (theme == "dark" ? ["--design-dark"] : [])
            app.launch()
            XCTAssertTrue(app.wait(for: .runningForeground, timeout: 10))
            let ready = NSPredicate(format: "count > 0")
            expectation(for: ready, evaluatedWith: app.staticTexts)
            waitForExpectations(timeout: 10)
            // Wait for layout and native navigation transitions, not background services.
            Thread.sleep(forTimeInterval: 1)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            shot.name = "\(theme)-\(tablet ? "ipad-landscape" : "iphone")-\(route)"; shot.lifetime = .keepAlways; add(shot)
            if route == "root" {
                let jobs = app.buttons["Events"].firstMatch
                if jobs.exists { jobs.tap() } else { app.staticTexts["Events"].firstMatch.tap() }
                Thread.sleep(forTimeInterval: 0.5)
                let jobsShot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); jobsShot.name = "\(theme)-\(tablet ? "ipad-landscape" : "iphone")-jobs"; jobsShot.lifetime = .keepAlways; add(jobsShot)
            }
            if ["job", "edit-job", "edit-session", "edit-fee", "invoice", "edit-invoice", "settings", "payments"].contains(route) {
                let scroll = app.scrollViews.element(boundBy: app.scrollViews.count - 1)
                if scroll.exists { scroll.swipeUp() } else { app.swipeUp() }
                Thread.sleep(forTimeInterval: 0.3)
                let lower = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); lower.name = "\(theme)-\(tablet ? "ipad-landscape" : "iphone")-\(route)-lower"; lower.lifetime = .keepAlways; add(lower)
            }
            app.terminate()
        }
        }
        if tablet {
            XCUIDevice.shared.orientation = .portrait
            app.launchArguments = ["--ui-testing", "--design-fixtures", "--design-screen=root"]
            app.launch(); Thread.sleep(forTimeInterval: 2)
            let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.name = "ipad-portrait-root"; shot.lifetime = .keepAlways; add(shot)
        }
    }
}
