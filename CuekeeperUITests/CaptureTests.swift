import XCTest

final class CaptureTests: XCTestCase {
    func testBroadcastLinkCanBeCapturedBeforeScheduling() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store"]
        app.launch()
        XCTAssertTrue(app.buttons["add-job"].waitForExistence(timeout: 10))
        app.buttons["add-job"].tap()
        let name = app.textFields["job-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Archive broadcast\n")
        app.buttons["save-job"].tap()
        XCTAssertTrue(app.buttons["save-job"].waitForNonExistence(timeout: 5))
        app.staticTexts["Archive broadcast"].firstMatch.tap()
        let addLink = app.buttons["job-add-link"]
        for _ in 0..<8 where !addLink.isHittable { app.swipeUp() }
        addLink.tap()
        let url = app.textFields["quick-broadcast-url"]
        XCTAssertTrue(url.waitForExistence(timeout: 5))
        url.tap(); url.typeText("https://example.com/archive")
        app.buttons["save-broadcast-link"].tap()
        XCTAssertTrue(app.buttons["save-broadcast-link"].waitForNonExistence(timeout: 5))
        // Open the newly created session: no date/time or fee was required.
        let session = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Session")).firstMatch
        for _ in 0..<6 where !session.isHittable { app.swipeDown() }
        XCTAssertTrue(session.waitForExistence(timeout: 5))
        session.tap()
        let link = app.links["https://example.com/archive"]
        if !link.exists {
            for _ in 0..<6 where !link.isHittable { app.swipeUp() }
        }
        XCTAssertTrue(link.waitForExistence(timeout: 5))
    }

    func testInvoiceAndPartialPaymentWorkflow() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store"]
        app.launch()
        XCTAssertTrue(app.buttons["add-job"].waitForExistence(timeout: 10))
        app.buttons["add-job"].tap()
        let name = app.textFields["job-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Invoiced show\n")
        let client = app.textFields["job-client"]
        for _ in 0..<4 where !client.isHittable { app.swipeUp() }
        client.tap(); client.typeText("Studio Network")
        app.buttons["save-job"].tap()
        if !app.buttons["save-job"].waitForNonExistence(timeout: 5) { print("SAVE_JOB_FAILURE\n" + app.debugDescription); XCTFail("Job save did not dismiss") }
        app.staticTexts["Invoiced show"].firstMatch.tap()
        let addInvoice = app.buttons["add-job-invoice"]
        for _ in 0..<7 where !addInvoice.isHittable { app.swipeUp() }
        addInvoice.tap()
        let reference = app.textFields["invoice-reference"]
        XCTAssertTrue(reference.waitForExistence(timeout: 5))
        reference.tap(); reference.typeText("INV-200")
        let billed = app.textFields["billed-Invoiced show"]
        for _ in 0..<5 where !billed.isHittable { app.swipeUp() }
        billed.tap(); billed.typeText("200")
        let status = app.buttons["invoice-status"]
        for _ in 0..<5 where !status.isHittable { app.swipeUp() }
        status.tap(); app.buttons["Sent"].tap()
        let editor = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        editor.name = "Invoice editor"; editor.lifetime = .keepAlways; add(editor)
        app.buttons["save-invoice"].tap()
        XCTAssertTrue(app.buttons["save-invoice"].waitForNonExistence(timeout: 5))
        let invoice = app.staticTexts["INV-200"].firstMatch
        for _ in 0..<4 where !invoice.isHittable { app.swipeUp() }
        XCTAssertTrue(invoice.waitForExistence(timeout: 5)); invoice.tap()
        let record = app.buttons["record-payment"]
        for _ in 0..<6 where !record.isHittable { app.swipeUp() }
        record.tap()
        let amount = app.textFields["payment-amount"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        amount.tap(); amount.typeText("75")
        app.buttons["save-payment"].tap()
        XCTAssertTrue(app.buttons["save-payment"].waitForNonExistence(timeout: 5))
        let balance = app.descendants(matching: .any)["invoice-balance"].firstMatch
        for _ in 0..<6 where !balance.isHittable { app.swipeDown() }
        XCTAssertTrue(balance.waitForExistence(timeout: 5))
        XCTAssertEqual(balance.value as? String, "$125.00")
        let details = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        details.name = "Invoice partial balance"; details.lifetime = .keepAlways; add(details)
        let payments = app.buttons["Payments"].firstMatch
        if payments.exists { payments.tap() } else { app.staticTexts["Payments"].firstMatch.tap() }
        XCTAssertTrue(app.staticTexts["Invoiced outstanding"].firstMatch.waitForExistence(timeout: 5))
        let overview = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        overview.name = "Payments overview"; overview.lifetime = .keepAlways; add(overview)
    }

    func testOverallFeeCanBeSavedWithoutBreakdown() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store"]
        app.launch()
        XCTAssertTrue(app.buttons["add-job"].waitForExistence(timeout: 10))
        app.buttons["add-job"].tap()
        let name = app.textFields["job-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Paid broadcast")
        app.buttons["save-job"].tap()
        XCTAssertTrue(app.staticTexts["Paid broadcast"].waitForExistence(timeout: 5))
        app.staticTexts["Paid broadcast"].tap()
        let fee = app.buttons["job-fee"]
        for _ in 0..<5 where !fee.isHittable { app.swipeUp() }
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
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store"]
        app.launch()
        XCTAssertTrue(app.buttons["add-job"].waitForExistence(timeout: 10))
        app.buttons["add-job"].tap()
        let name = app.textFields["job-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Breakdown broadcast\n")
        app.buttons["save-job"].tap()
        XCTAssertTrue(app.buttons["save-job"].waitForNonExistence(timeout: 5))
        app.staticTexts["Breakdown broadcast"].firstMatch.tap()
        let fee = app.buttons["job-fee"]
        for _ in 0..<6 where !fee.isHittable { app.swipeUp() }
        fee.tap(); app.buttons["edit-fee"].tap()
        let overall = app.textFields["overall-fee"]
        XCTAssertTrue(overall.waitForExistence(timeout: 5))
        overall.tap(); overall.typeText("150")
        let add = app.buttons["add-fee-item"]
        for _ in 0..<6 where !add.isHittable { app.swipeUp() }
        add.tap()
        let rate = app.textFields["Rate (negative for adjustments)"]
        for _ in 0..<6 where !rate.isHittable { app.swipeUp() }
        rate.tap(); rate.typeText("100\n")
        app.buttons["save-fee"].tap()
        XCTAssertTrue(app.buttons["save-fee"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["$150.00"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Breakdown total: $100.00. The overall fee remains unchanged."].exists)
        app.buttons["edit-fee"].tap()
        let useTotal = app.buttons["Use Breakdown Total"]
        for _ in 0..<8 where !useTotal.isHittable { app.swipeUp() }
        useTotal.tap(); app.buttons["save-fee"].tap()
        XCTAssertTrue(app.buttons["save-fee"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["$100.00"].firstMatch.waitForExistence(timeout: 5))
    }

    func testSessionCaptureLinksAndConfirmationValidation() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store"]
        app.launch()
        XCTAssertTrue(app.buttons["add-job"].waitForExistence(timeout: 10))
        app.buttons["add-job"].tap()
        let name = app.textFields["job-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap(); name.typeText("Studio finals")
        app.buttons["save-job"].tap()
        XCTAssertTrue(app.staticTexts["Studio finals"].waitForExistence(timeout: 5))
        app.staticTexts["Studio finals"].tap()
        let addSession = app.buttons["add-session"]
        for _ in 0..<4 where !addSession.isHittable { app.swipeUp() }
        addSession.tap()
        let sessionName = app.textFields["session-name"]
        XCTAssertTrue(sessionName.waitForExistence(timeout: 5))
        sessionName.tap(); sessionName.typeText("Final programme")
        app.buttons["save-session"].tap()
        if !app.buttons["save-session"].waitForNonExistence(timeout: 5) { print("SAVE_SESSION_FAILURE\n" + app.debugDescription); XCTFail("Session save did not dismiss") }
        XCTAssertTrue(app.staticTexts["Final programme"].waitForExistence(timeout: 5))
        app.staticTexts["Final programme"].tap()
        app.buttons["edit-session"].tap()
        for _ in 0..<6 where !app.buttons["session-schedule"].isHittable { app.swipeUp() }
        XCTAssertTrue(app.buttons["session-schedule"].waitForExistence(timeout: 5))
        app.buttons["session-schedule"].tap(); app.buttons["Confirmed"].tap()
        app.buttons["save-session"].tap()
        let alert = app.alerts["Couldn’t save changes"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["OK"].tap()
        app.buttons["session-schedule"].tap(); app.buttons["Tentative"].tap()
        let editor = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        editor.name = "Session editor"; editor.lifetime = .keepAlways; add(editor)
        let addLink = app.buttons["add-broadcast-link"]
        for _ in 0..<6 where !addLink.isHittable { app.swipeUp() }
        addLink.tap()
        let url = app.textFields["broadcast-url"]
        for _ in 0..<3 where !url.isHittable { app.swipeUp() }
        url.tap(); url.typeText("https://example.com/finals")
        app.buttons["save-session"].tap()
        if !app.buttons["save-session"].waitForNonExistence(timeout: 5) { print("SAVE_SESSION_FAILURE\n" + app.debugDescription); XCTFail("Session save did not dismiss") }
        XCTAssertTrue(app.links["https://example.com/finals"].waitForExistence(timeout: 5))
        let details = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        details.name = "Session details and link"; details.lifetime = .keepAlways; add(details)
    }

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
        if !app.buttons["save-job"].waitForNonExistence(timeout: 5) { print("SAVE_JOB_FAILURE\n" + app.debugDescription); XCTFail("Job save did not dismiss") }
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
    func testEditDuplicateAndDiscard() {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store"]
        app.launch()
        XCTAssertTrue(app.buttons["add-job"].waitForExistence(timeout: 10))
        app.buttons["add-job"].tap()
        let name = app.textFields["job-name"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText("Weekend coverage")
        app.buttons["save-job"].tap()
        if !app.buttons["save-job"].waitForNonExistence(timeout: 5) { print("SAVE_JOB_FAILURE\n" + app.debugDescription); XCTFail("Job save did not dismiss") }
        XCTAssertTrue(app.staticTexts["Weekend coverage"].waitForExistence(timeout: 5))
        app.staticTexts["Weekend coverage"].tap()
        app.buttons["edit-job"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(" updated\n")
        app.buttons["edit-booking-status"].tap()
        app.buttons["Booked"].tap()
        Thread.sleep(forTimeInterval: 1) // Let the native sheet/menu transition settle for the review capture.
        let editor = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        editor.name = "Job editor"
        editor.lifetime = .keepAlways
        add(editor)
        app.buttons["save-job"].tap()
        if !app.buttons["save-job"].waitForNonExistence(timeout: 5) { print("SAVE_JOB_FAILURE\n" + app.debugDescription); XCTFail("Job save did not dismiss") }
        let status = app.descendants(matching: .any)["booking-status"].firstMatch
        XCTAssertTrue(status.waitForExistence(timeout: 5))
        XCTAssertEqual(status.value as? String, "Booked")
        Thread.sleep(forTimeInterval: 1)
        let detail = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        detail.name = "Job details"
        detail.lifetime = .keepAlways
        add(detail)
        for _ in 0..<7 where !app.buttons["duplicate-job"].isHittable { app.swipeUp() }
        app.buttons["duplicate-job"].tap()
        XCTAssertTrue(app.buttons["save-job"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["save-job"].isEnabled)
        let dates = app.switches["confirm-duplicate-dates"]
        dates.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)).tap()
        let enabled = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == true"), object: app.buttons["save-job"])
        XCTAssertEqual(XCTWaiter.wait(for: [enabled], timeout: 5), .completed)
        app.buttons["save-job"].tap()
        if !app.buttons["save-job"].waitForNonExistence(timeout: 5) { print("SAVE_JOB_FAILURE\n" + app.debugDescription); XCTFail("Job save did not dismiss") }
        XCTAssertTrue(app.buttons["edit-job"].waitForExistence(timeout: 5))
        app.buttons["edit-job"].tap()
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        name.tap()
        name.typeText(" discarded\n")
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.buttons["Discard Changes"].waitForExistence(timeout: 5))
        app.buttons["Discard Changes"].tap()
        XCTAssertFalse(app.staticTexts["Weekend coverage updated discarded"].exists)
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
        app.staticTexts["North Sports"].tap()
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

}
