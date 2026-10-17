import XCTest

// Keep independently reset workflows schedulable across XCTest workers.
final class InvoicePaymentWorkflowTests: EventWorkflowTestCase {
    func testInvoiceAndPartialPaymentWorkflow() {
        let app = seededEvent("Invoiced show")
        openEventTab("money", in: app)
        let addInvoice = app.buttons["add-job-invoice"]
        reveal(addInvoice, in: app)
        addInvoice.tap()
        // The event it started from is already ticked, even before its fee is known.
        let line = app.descendants(matching: .any)["invoice-line-Invoiced show"]
        XCTAssertTrue(line.waitForExistence(timeout: 5))
        XCTAssertTrue(line.isSelected)
        captureScreenshot("Invoice lines")
        app.buttons["invoice-next"].tap()
        let reference = app.textFields["invoice-reference"]
        XCTAssertTrue(reference.waitForExistence(timeout: 5))
        let status = app.buttons["invoice-status-sent"]
        reveal(status, in: app)
        status.tap()
        reference.tap(); reference.typeText("INV-200")
        let billed = app.textFields.matching(NSPredicate(format: "identifier BEGINSWITH %@", "billed-")).firstMatch
        reveal(billed, in: app)
        billed.tap(); billed.typeText("200")
        if app.keyboards.buttons["Return"].exists { billed.typeText("\n") }
        captureScreenshot("Invoice editor")
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
        captureScreenshot("Record payment sheet")
        app.buttons["save-payment"].tap()
        XCTAssertTrue(app.buttons["save-payment"].waitForNonExistence(timeout: 5))
        let balance = app.descendants(matching: .any)["invoice-balance"].firstMatch
        reveal(balance, in: app)
        XCTAssertTrue(balance.waitForExistence(timeout: 5))
        XCTAssertEqual(balance.value as? String, "$125.00")
        captureScreenshot("Invoice partial balance")
        // iPhone shows a tab bar; the iPad sidebar lists sections as cells labelled by name.
        let tab = app.tabBars.buttons["Payments"]
        if tab.exists { tab.tap() } else { app.cells.matching(NSPredicate(format: "label == %@", "Payments")).firstMatch.tap() }
        XCTAssertTrue(app.staticTexts["payments-month"].waitForExistence(timeout: 5))
        let paymentRow = app.buttons["readiness-Invoiced show"]
        reveal(paymentRow, in: app)
        XCTAssertTrue(paymentRow.exists)
        // Compact rows combine the status into their label; wide layouts expose it separately.
        let owed = app.descendants(matching: .any).matching(NSPredicate(
            format: "label CONTAINS %@ AND label CONTAINS %@", "INV-200", "$125.00 owed")).firstMatch
        XCTAssertTrue(owed.waitForExistence(timeout: 5))
        captureScreenshot("Payments overview")
    }
}

final class FeeEditingTests: EventWorkflowTestCase {
    func testOverallFeeCanBeSavedWithoutBreakdown() {
        let app = seededEvent("Paid broadcast")
        XCTAssertTrue(app.staticTexts["Studio Network"].firstMatch.exists)
        XCTAssertFalse(app.buttons["event-add-client"].exists)
        XCTAssertFalse(app.buttons["Include Existing Booking"].exists)
        openEventTab("money", in: app)
        let fee = app.buttons["job-fee"]
        reveal(fee, in: app)
        fee.tap()
        XCTAssertTrue(app.buttons["edit-fee"].waitForExistence(timeout: 5))
        app.buttons["edit-fee"].tap()
        XCTAssertTrue(app.navigationBars["Edit Event"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["editor-add-client"].exists)
        let amount = app.textFields["overall-fee"]
        XCTAssertTrue(amount.waitForExistence(timeout: 5))
        XCTAssertTrue(amount.isHittable)
        amount.tap(); amount.typeText("1234.56")
        captureScreenshot("Fee editor")
        app.buttons["save-event"].tap()
        if !app.buttons["save-event"].waitForNonExistence(timeout: 5) { print("SAVE_FEE_FAILURE\n" + app.debugDescription); XCTFail("Fee save did not dismiss") }
        XCTAssertTrue(app.staticTexts["$1,234.56"].firstMatch.waitForExistence(timeout: 5))
        captureScreenshot("Fee and history")
    }

    func testBreakdownChangesOverallFeeOnlyWhenExplicitlyApplied() {
        let app = seededEvent("Breakdown broadcast")
        openEventTab("money", in: app)
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
}
