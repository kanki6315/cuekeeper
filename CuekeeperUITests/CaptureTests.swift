import XCTest

final class CaptureTests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .landscapeLeft : .portrait
    }
    /// Scroll the active editor or right-hand detail pane, not the iPad job list.
    private func reveal(_ element: XCUIElement, in app: XCUIApplication) {
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
    private func createEvent(_ title: String, client: String = "Studio Network", openBooking: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store"]
        app.launch()
        XCTAssertTrue(app.buttons["add-job"].waitForExistence(timeout: 10)); app.buttons["add-job"].tap()
        let next = app.buttons["wizard-continue"]
        XCTAssertTrue(next.waitForExistence(timeout: 5))
        let titleField = app.textFields["job-name"]
        titleField.tap(); titleField.typeText(title + "\n")
        app.switches["Client, project & series"].tap()
        next.tap()
        let clientField = app.textFields["job-client"]
        XCTAssertTrue(clientField.waitForExistence(timeout: 5))
        clientField.tap(); clientField.typeText(client + "\n")
        next.tap(); next.tap()
        XCTAssertTrue(next.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["edit-event"].waitForExistence(timeout: 5))
        if openBooking {
            let details = app.buttons["Booking details & payments"].firstMatch
            reveal(details, in: app); details.tap()
            XCTAssertTrue(app.buttons["edit-job"].waitForExistence(timeout: 5))
        }
        return app
    }

    func testSyncFeedbackRemainsNonblocking() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--ui-test-sync-receiving"]
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
        XCTAssertTrue(app.staticTexts["Storage & iCloud"].waitForExistence(timeout: 5))
    }

    func testBroadcastLinkCanBeCapturedBeforeScheduling() {
        let app = createEvent("Archive broadcast")
        let addLink = app.buttons["job-add-link"]
        reveal(addLink, in: app)
        addLink.tap()
        let url = app.textFields["quick-broadcast-url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap(); url.typeText("https://example.com/archive")
        app.buttons["save-broadcast-link"].tap()
        XCTAssertTrue(app.buttons["save-broadcast-link"].waitForNonExistence(timeout: 5))
        // Open the newly created session: no date/time or fee was required.
        let session = app.buttons.matching(NSPredicate(format: "label CONTAINS %@ AND identifier != %@", "Session", "add-session")).firstMatch
        reveal(session, in: app)
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()
        let link = app.links["https://example.com/archive"]
        if !link.exists {
            reveal(link, in: app)
        }
        XCTAssertTrue(link.waitForExistence(timeout: 5))
    }

    func testInvoiceAndPartialPaymentWorkflow() {
        let app = createEvent("Invoiced show")
        let addInvoice = app.buttons["add-job-invoice"]
        reveal(addInvoice, in: app)
        addInvoice.tap()
        let reference = app.textFields["invoice-reference"]
        XCTAssertTrue(reference.waitForExistence(timeout: 5))
        reference.tap(); reference.typeText("INV-200")
        let billed = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "billed-")).firstMatch
        reveal(billed, in: app)
        billed.tap(); billed.typeText("200")
        if app.keyboards.buttons["Return"].exists { billed.typeText("\n") }
        let status = app.buttons["invoice-status"]
        reveal(status, in: app)
        status.tap(); app.buttons["Sent"].tap()
        let editor = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        editor.name = "Invoice editor"; editor.lifetime = .keepAlways; add(editor)
        XCTAssertEqual(reference.value as? String, "INV-200")
        app.buttons["save-invoice"].tap()
        XCTAssertTrue(app.buttons["save-invoice"].waitForNonExistence(timeout: 5))
        let invoice = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "INV-200")).firstMatch
        reveal(invoice, in: app)
        if !invoice.exists { print("INVOICE_LINK_FAILURE\n" + app.debugDescription) }
        XCTAssertTrue(invoice.waitForExistence(timeout: 5)); invoice.tap()
        let record = app.buttons["record-payment"]
        reveal(record, in: app)
        record.tap()
        let amount = app.textFields["payment-amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap(); amount.typeText("75")
        let paymentEditor = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        paymentEditor.name = "Record payment sheet"; paymentEditor.lifetime = .keepAlways; add(paymentEditor)
        app.buttons["save-payment"].tap()
        XCTAssertTrue(app.buttons["save-payment"].waitForNonExistence(timeout: 5))
        let balance = app.descendants(matching: .any)["invoice-balance"].firstMatch
        reveal(balance, in: app)
        XCTAssertTrue(balance.waitForExistence(timeout: 5))
        XCTAssertEqual(balance.value as? String, "$125.00")
        let details = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        details.name = "Invoice partial balance"; details.lifetime = .keepAlways; add(details)
        let sidebar = app.collectionViews["Sidebar"]
        if sidebar.exists { sidebar.cells.containing(.staticText, identifier: "Payments").firstMatch.tap() }
        else { app.buttons["Payments"].firstMatch.tap() }
        XCTAssertTrue(app.staticTexts["Invoiced outstanding"].firstMatch.waitForExistence(timeout: 5))
        let overview = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        overview.name = "Payments overview"; overview.lifetime = .keepAlways; add(overview)
    }

    func testOverallFeeCanBeSavedWithoutBreakdown() {
        let app = createEvent("Paid broadcast")
        let fee = app.buttons["job-fee"]
        reveal(fee, in: app)
        fee.tap()
        XCTAssertTrue(app.buttons["edit-fee"].waitForExistence(timeout: 5))
        app.buttons["edit-fee"].tap()
        let amount = app.textFields["overall-fee"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap(); amount.typeText("1234.56")
        let editor = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        editor.name = "Fee editor"; editor.lifetime = .keepAlways; add(editor)
        app.buttons["save-fee"].tap()
        if !app.buttons["save-fee"].waitForNonExistence(timeout: 5) { print("SAVE_FEE_FAILURE\n" + app.debugDescription); XCTFail("Fee save did not dismiss") }
        XCTAssertTrue(app.staticTexts["$1,234.56"].firstMatch.waitForExistence(timeout: 5))
        let details = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        details.name = "Fee and history"; details.lifetime = .keepAlways; add(details)
    }

    func testBreakdownChangesOverallFeeOnlyWhenExplicitlyApplied() {
        let app = createEvent("Breakdown broadcast")
        let fee = app.buttons["job-fee"]
        reveal(fee, in: app)
        fee.tap(); app.buttons["edit-fee"].tap()
        let overall = app.textFields["overall-fee"]
        XCTAssertTrue(overall.waitForExistence(timeout: 5))
        overall.tap(); overall.typeText("150")
        // Finish iPad keyboard entry before interacting with another Form row.
        if app.keyboards.buttons["Return"].exists { overall.typeText("\n") }
        let add = app.buttons["add-fee-item"]
        reveal(add, in: app)
        add.tap()
        let rate = app.textFields["Rate (negative for adjustments)"]
        reveal(rate, in: app)
        rate.tap(); rate.typeText("100\n")
        app.buttons["save-fee"].tap()
        XCTAssertTrue(app.buttons["save-fee"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["$150.00"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Breakdown total: $100.00. The overall fee remains unchanged."].exists)
        app.buttons["edit-fee"].tap()
        let useTotal = app.buttons["Use Breakdown Total"]
        reveal(useTotal, in: app)
        useTotal.tap(); app.buttons["save-fee"].tap()
        XCTAssertTrue(app.buttons["save-fee"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["$100.00"].firstMatch.waitForExistence(timeout: 5))
    }

    func testSessionCaptureLinksAndConfirmationValidation() {
        let app = createEvent("Studio finals")
        let addSession = app.buttons["add-session"]
        reveal(addSession, in: app)
        addSession.tap()
        let sessionName = app.textFields["session-name"]
        XCTAssertTrue(sessionName.waitForExistence(timeout: 5))
        sessionName.tap(); sessionName.typeText("Final programme")
        app.buttons["save-session"].tap()
        if !app.buttons["save-session"].waitForNonExistence(timeout: 5) { print("SAVE_SESSION_FAILURE\n" + app.debugDescription); XCTFail("Session save did not dismiss") }
        XCTAssertTrue(app.staticTexts["Final programme"].waitForExistence(timeout: 5))
        app.staticTexts["Final programme"].firstMatch.tap()
        app.buttons["edit-session"].tap()
        reveal(app.segmentedControls["session-schedule"], in: app)
        XCTAssertTrue(app.segmentedControls["session-schedule"].waitForExistence(timeout: 5))
        app.segmentedControls["session-schedule"].buttons["Confirmed"].tap()
        app.buttons["save-session"].tap()
        let alert = app.alerts["Couldn’t save changes"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["OK"].tap()
        app.segmentedControls["session-schedule"].buttons["Tentative"].tap()
        let editor = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        editor.name = "Session editor"; editor.lifetime = .keepAlways; add(editor)
        let more = app.buttons["Roles, notes & links"]; reveal(more, in: app); more.tap()
        let addLink = app.buttons["add-broadcast-link"]
        reveal(addLink, in: app)
        addLink.tap()
        let url = app.textFields["broadcast-url"]
        reveal(url, in: app)
        url.tap(); url.typeText("https://example.com/finals")
        app.buttons["save-session"].tap()
        if !app.buttons["save-session"].waitForNonExistence(timeout: 5) { print("SAVE_SESSION_FAILURE\n" + app.debugDescription); XCTFail("Session save did not dismiss") }
        XCTAssertTrue(app.links["https://example.com/finals"].waitForExistence(timeout: 5))
        let details = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        details.name = "Session details and link"; details.lifetime = .keepAlways; add(details)
    }

    func testClientLibraryAndFilters() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store"]
        app.launch()
        XCTAssertTrue(app.buttons["add-job"].waitForExistence(timeout: 10))
        let settings = app.buttons["Settings"].firstMatch
        if settings.exists { settings.tap() } else { app.staticTexts["Settings"].firstMatch.tap() }
        app.buttons["Clients"].tap()
        app.buttons["Add Client"].tap()
        let name = app.textFields["Name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("North Sports\n")
        XCTAssertEqual(name.value as? String, "North Sports")
        let saveEnabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["Save"])
        XCTAssertEqual(XCTWaiter.wait(for: [saveEnabled], timeout: 5), .completed)
        app.buttons["Save"].tap()
        XCTAssertTrue(app.buttons["Save"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["North Sports"].waitForExistence(timeout: 5))
        app.buttons["Add Client"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("North Sports\n")
        let duplicateEnabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["Save"])
        XCTAssertEqual(XCTWaiter.wait(for: [duplicateEnabled], timeout: 5), .completed)
        app.buttons["Save"].tap()
        let alert = app.alerts["Couldn’t save changes"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 1)
        let failure = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        failure.name = "Save error preserves draft"
        failure.lifetime = .keepAlways
        add(failure)
        alert.buttons["OK"].tap()
        XCTAssertEqual(name.value as? String, "North Sports")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 5))
        app.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.buttons["Save"].waitForNonExistence(timeout: 5))
        app.staticTexts["North Sports"].firstMatch.tap()
        Thread.sleep(forTimeInterval: 1)
        let client = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        client.name = "Client details"
        client.lifetime = .keepAlways
        add(client)
        let upcoming = app.buttons["Upcoming"].firstMatch
        if upcoming.exists { upcoming.tap() } else { app.staticTexts["Upcoming"].firstMatch.tap() }
        app.buttons["filter-jobs"].tap()
        Thread.sleep(forTimeInterval: 1)
        let filters = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        filters.name = "Job filters"
        filters.lifetime = .keepAlways
        add(filters)
        XCTAssertTrue(app.buttons["Done"].exists)
        app.buttons["Done"].tap()
    }

    func testEventClientsAndDirectFeeEditing() {
        let app = createEvent("Silverstone weekend", client: "Client A", openBooking: false)
        let add = app.buttons["event-add-client"]; reveal(add, in: app); add.tap()
        let client = app.textFields["library-Client-name"]
        XCTAssertTrue(client.waitForExistence(timeout: 5)); client.tap(); client.typeText("Client B\n")
        let fee = app.textFields["overall-fee"]; reveal(fee, in: app); fee.tap(); fee.typeText("300")
        app.buttons["save-booking"].tap()
        XCTAssertTrue(app.buttons["save-booking"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.buttons["event-booking-Client A"].exists)
        XCTAssertTrue(app.buttons["event-booking-Client B"].exists)
        XCTAssertTrue(app.staticTexts["$300.00"].exists)
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); screenshot.name = "Event with two client bookings"; screenshot.lifetime = .keepAlways; self.add(screenshot)
        app.terminate(); app.launchArguments = ["--ui-testing"]; app.launch()
        XCTAssertTrue(app.staticTexts["Silverstone weekend"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(app.staticTexts["Client A"].firstMatch.exists); XCTAssertTrue(app.staticTexts["Client B"].firstMatch.exists)
    }

    func testRepeatedSessionEntryAndBulkSeries() {
        let app = createEvent("Race weekend", openBooking: false)
        reveal(app.buttons["add-session"], in: app); app.buttons["add-session"].tap()
        let name = app.textFields["session-name"]; XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Qualifying\n")
        let series = app.textFields["library-WorkSeries-name"]; series.tap(); series.typeText("Series A\n")
        let another = app.buttons["save-another-session"]; reveal(another, in: app); another.tap()
        XCTAssertTrue(another.waitForExistence(timeout: 5))
        reveal(name, in: app); name.tap(); name.typeText("Race\n")
        XCTAssertEqual(series.value as? String, "Series A")
        let reuse = app.buttons["reuse-WorkSeries"]; reveal(reuse, in: app); reuse.tap(); app.buttons["Series A"].tap()
        app.buttons["save-session"].tap()
        XCTAssertTrue(app.buttons["save-session"].waitForNonExistence(timeout: 5))
        let batch = app.buttons["batch-sessions"]; reveal(batch, in: app); batch.tap()
        app.buttons["Select All"].tap()
        let change = app.switches["Change series"]; reveal(change, in: app); change.switches.firstMatch.tap()
        let newSeries = app.textFields["library-WorkSeries-name"]; reveal(newSeries, in: app); newSeries.tap(); newSeries.typeText("Series B\n")
        app.buttons["apply-session-changes"].tap()
        XCTAssertTrue(app.buttons["apply-session-changes"].waitForNonExistence(timeout: 5))
        XCTAssertEqual(app.staticTexts.matching(identifier: "Series B").count, 2)
    }

    func testEventEditDatesAndDiscard() {
        let app = createEvent("Original weekend", openBooking: false)
        app.buttons["edit-event"].tap()
        let multiple = app.switches["job-multiple-days"]; multiple.switches.firstMatch.tap()
        XCTAssertTrue(app.datePickers["job-end-date"].exists)
        let location = app.textFields["job-location"]; reveal(location, in: app); location.tap(); location.typeText("Silverstone\n")
        app.buttons["save-event"].tap()
        XCTAssertTrue(app.buttons["save-event"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Silverstone"].exists)
        app.buttons["edit-event"].tap()
        reveal(location, in: app); location.tap(); location.typeText(" discarded\n")
        app.buttons["Cancel"].tap(); app.buttons["Discard Changes"].tap()
        XCTAssertTrue(app.buttons["save-event"].waitForNonExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Silverstone discarded"].exists)
    }
}
