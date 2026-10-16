import XCTest

final class FeeAndInvoiceTests: EventWorkflowTestCase {
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
        XCTAssertTrue(app.staticTexts["Invoiced"].firstMatch.waitForExistence(timeout: 5))
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
        app.buttons["save-event"].tap()
        if !app.buttons["save-event"].waitForNonExistence(timeout: 5) { print("SAVE_FEE_FAILURE\n" + app.debugDescription); XCTFail("Fee save did not dismiss") }
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
        app.buttons["save-event"].tap()
        XCTAssertTrue(app.buttons["save-event"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["$150.00"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Breakdown total: $100.00. The overall fee remains unchanged."].exists)
        app.buttons["edit-fee"].tap()
        let useTotal = app.buttons["Use Breakdown Total"]
        reveal(useTotal, in: app)
        useTotal.tap(); app.buttons["save-event"].tap()
        XCTAssertTrue(app.buttons["save-event"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["$100.00"].firstMatch.waitForExistence(timeout: 5))
    }

    func testSingleClientEventHasDirectFeesAndNoGroupingActions() {
        let app = createEvent("Silverstone weekend", client: "Client A", openBooking: false)
        XCTAssertTrue(app.staticTexts["Client A"].firstMatch.exists)
        XCTAssertFalse(app.buttons["event-add-client"].exists)
        XCTAssertFalse(app.buttons["Include Existing Booking"].exists)
        let fee = app.buttons["job-fee"]; reveal(fee, in: app); fee.tap()
        XCTAssertTrue(app.buttons["edit-fee"].waitForExistence(timeout: 5))
        app.buttons["edit-fee"].tap()
        XCTAssertTrue(app.navigationBars["Edit Event"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["editor-add-client"].exists)
        let amount = app.textFields["overall-fee"]
        XCTAssertTrue(amount.isHittable); amount.tap(); amount.typeText("300")
        app.buttons["save-event"].tap()
        XCTAssertTrue(app.navigationBars["Edit Event"].waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["$300.00"].firstMatch.exists)
    }
}
