import XCTest

/// Helpers shared by UI workflow classes. Workflows are split into small classes
/// so parallel test runs can spread them across simulator clones.
class RegressionUITestCase: XCTestCase {
    override func setUpWithError() throws {
        try super.setUpWithError()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
    }

    /// Upcoming is date-sensitive; record workflows use the full Events list.
    func openEvents(in app: XCUIApplication) {
        let events = app.buttons["Events"].firstMatch
        if events.waitForExistence(timeout: 5) { events.tap() }
        else {
            let sidebarEvents = app.staticTexts["Events"].firstMatch
            XCTAssertTrue(sidebarEvents.waitForExistence(timeout: 5))
            sidebarEvents.tap()
        }
    }

    /// Success captures are opt-in. XCTest still collects its normal failure evidence.
    func captureScreenshot(_ name: String) {
        guard ProcessInfo.processInfo.environment["CUEKEEPER_TEST_SCREENSHOTS"] == "1" else { return }
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

class DaybookUITestCase: RegressionUITestCase {
    func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        app.descendants(matching: .any).matching(identifier: identifier).firstMatch
    }

    func dismissKeyboardIntroduction(in app: XCUIApplication) {
        let introduction = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", "Continue", "wizard-continue")).firstMatch
        if introduction.waitForExistence(timeout: 2), introduction.isHittable { introduction.tap() }
    }

    @discardableResult
    func waitUntilHittable(_ element: XCUIElement, timeout: TimeInterval = 5) -> Bool {
        let hittable = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: element)
        return XCTWaiter.wait(for: [hittable], timeout: timeout) == .completed
    }

    func capture(_ name: String) {
        captureScreenshot(name)
    }
}

/// Event workflows start with one persisted event, without replaying the wizard.
class EventWorkflowTestCase: DaybookUITestCase {
    /// Event details split into Schedule / Money / Details tabs on narrow layouts.
    func openEventTab(_ tab: String, in app: XCUIApplication) {
        let button = app.buttons["event-tab-\(tab)"]
        if button.waitForExistence(timeout: 5) { button.tap() }
    }

    /// Scroll the active editor or right-hand detail pane, not the iPad job list.
    func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<10 {
            let forms = app.scrollViews.matching(identifier: "daybook-form")
            let target = forms.count > 0 ? forms.element(boundBy: forms.count - 1) : app.scrollViews.firstMatch
            guard target.exists else { return }
            let top = target.frame.minY + 96
            var bottom = target.frame.maxY - (app.buttons["Cancel"].exists ? 24 : 104)
            if app.keyboards.firstMatch.exists { bottom = min(bottom, app.keyboards.firstMatch.frame.minY - 12) }
            let bounds = CGRect(x: target.frame.minX, y: top, width: target.frame.width, height: max(1, bottom - top))
            let exists = element.exists
            let frame = exists ? element.frame : CGRect(x: 0, y: bottom + 100, width: 0, height: 0)
            if exists && element.isHittable && frame.minY >= bounds.minY && frame.maxY <= bounds.maxY { return }
            let upward = frame.minY >= bounds.minY
            // Keep drag points inside the visible content, above any software keyboard.
            let origin = target.coordinate(withNormalizedOffset: .zero)
            let start = origin.withOffset(CGVector(dx: target.frame.width * 0.65, dy: top - target.frame.minY + bounds.height * (upward ? 0.8 : 0.2)))
            let end = origin.withOffset(CGVector(dx: target.frame.width * 0.65, dy: top - target.frame.minY + bounds.height * (upward ? 0.2 : 0.8)))
            start.press(forDuration: 0.05, thenDragTo: end)
        }
    }

    @discardableResult
    func seededEvent(_ title: String, client: String = "Studio Network", openDetails: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures",
                               "--workflow-event-title=\(title)", "--workflow-event-client=\(client)"]
        app.launch()
        // Go through Events so Upcoming's date/mode policy cannot hide the prerequisite.
        openEvents(in: app)
        let event = app.staticTexts[title].firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 10))
        if openDetails {
            event.tap()
            XCTAssertTrue(app.buttons["edit-event"].waitForExistence(timeout: 5))
        }
        return app
    }
}
