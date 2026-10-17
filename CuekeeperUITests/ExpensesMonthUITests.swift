import XCTest

final class ExpensesMonthUITests: DaybookUITestCase {
    private func launch(_ route: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-test-store", "--design-fixtures", "--design-screen=\(route)"]
        app.launch(); return app
    }
    private func choose(_ option: String, from menu: String, in app: XCUIApplication) {
        element(menu, in: app).tap()
        let item = app.buttons[option].firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5)); item.tap()
    }

    func testLedgerFiltersAndInboxRepeat() {
        let app = launch("expenses-overview")

        XCTAssertTrue(app.staticTexts["expenses-period"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Trackside Cafe"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Adobe Creative Cloud"].exists)
        captureScreenshot("expenses-ledger")

        // Business shows only costs with no event; Clear brings everything back.
        choose("Business", from: "ledger-type", in: app)
        XCTAssertTrue(app.staticTexts["Dropbox Plus"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Trackside Cafe"].exists)
        captureScreenshot("expenses-ledger-business")
        element("ledger-clear", in: app).tap()
        XCTAssertTrue(app.staticTexts["Trackside Cafe"].waitForExistence(timeout: 5))

        // A quarter or all time replaces the month without leaving the Ledger.
        choose("Quarter", from: "ledger-period", in: app)
        XCTAssertTrue(app.staticTexts["expenses-period"].label.hasPrefix("Q"))
        choose("All time", from: "ledger-period", in: app)
        XCTAssertEqual(app.staticTexts["expenses-period"].label, "All time")
        XCTAssertFalse(element("period-previous", in: app).exists)
        XCTAssertTrue(app.staticTexts["Claude Pro"].exists, "Earlier months appear under their own headings")
        captureScreenshot("expenses-ledger-all-time")

        // The inbox offers Claude Pro's next month whatever period the Ledger shows.
        element("expenses-mode-inbox", in: app).tap()
        let add = app.buttons["expenses-finish-add"]
        XCTAssertTrue(add.waitForExistence(timeout: 5))
        captureScreenshot("expenses-inbox")
        add.tap()
        XCTAssertTrue(app.navigationBars["Business cost"].waitForExistence(timeout: 5))
        app.buttons["save-expense"].tap()
        XCTAssertFalse(app.buttons["expenses-finish-add"].waitForExistence(timeout: 3))
    }

    func testInboxGroupsStaleDraftsAndRemovesSelected() {
        let app = launch("expenses-inbox")
        XCTAssertTrue(app.staticTexts["Holding up invoicing"].waitForExistence(timeout: 15))
        XCTAssertTrue(app.staticTexts["Older than 30 days"].exists)
        let showAll = app.buttons["expenses-inbox-show-stale"]
        for _ in 0..<6 where !showAll.isHittable { app.swipeUp() }
        XCTAssertTrue(showAll.isHittable, "Seven stale drafts show five at first")
        captureScreenshot("expenses-inbox-groups")
        showAll.tap()
        XCTAssertFalse(showAll.exists)

        app.swipeDown(); app.swipeDown()
        element("expenses-inbox-select", in: app).tap()
        let picks = app.buttons.matching(identifier: "expenses-inbox-pick")
        XCTAssertTrue(picks.firstMatch.waitForExistence(timeout: 5))
        // The list only builds rows on screen, so follow the chosen drafts by name rather than counting rows.
        let chosen = [picks.element(boundBy: 0).label, picks.element(boundBy: 1).label]
        func row(_ label: String) -> XCUIElement { app.buttons.matching(NSPredicate(format: "label == %@", label)).firstMatch }
        picks.element(boundBy: 0).tap(); picks.element(boundBy: 1).tap()
        XCTAssertTrue(app.staticTexts["2 selected"].exists)
        captureScreenshot("expenses-inbox-selecting")

        app.buttons["expenses-inbox-remove"].tap()
        // The dialog anchors to Remove as a popover, which has no cancel button: tapping away keeps the drafts.
        XCTAssertTrue(app.buttons["Remove 2 Drafts"].waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.12)).tap()
        XCTAssertFalse(app.buttons["Remove 2 Drafts"].waitForExistence(timeout: 2))
        XCTAssertTrue(chosen.allSatisfy { row($0).exists })
        app.buttons["expenses-inbox-remove"].tap()
        app.buttons["Remove 2 Drafts"].tap()
        XCTAssertFalse(element("expenses-inbox-remove", in: app).waitForExistence(timeout: 3))
        element("expenses-inbox-select", in: app).tap()
        XCTAssertTrue(picks.firstMatch.waitForExistence(timeout: 5))
        XCTAssertFalse(chosen.contains { row($0).exists })
    }

    func testInboxSwipesChooseEventAndRemove() {
        let app = launch("expenses-inbox")
        let hotel = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Hotel")).firstMatch
        XCTAssertTrue(hotel.waitForExistence(timeout: 15))
        XCTAssertTrue(hotel.label.contains("No event yet"))
        for _ in 0..<4 where !hotel.isHittable || hotel.frame.maxY > app.frame.maxY * 0.8 { app.swipeUp() }

        // Swiping right offers Choose Event; a full swipe runs it straight away.
        hotel.swipeRight()
        if !app.navigationBars["Choose Event"].waitForExistence(timeout: 2) {
            let choose = app.buttons["Choose Event"].firstMatch
            XCTAssertTrue(choose.waitForExistence(timeout: 5))
            captureScreenshot("expenses-inbox-swipe-right")
            choose.tap()
        }
        let event = app.buttons["choose-expense-event-row"].firstMatch
        XCTAssertTrue(event.waitForExistence(timeout: 5)); event.tap()
        // Still a draft, now holding up its event's invoice.
        XCTAssertTrue(hotel.waitForExistence(timeout: 5))
        XCTAssertFalse(hotel.label.contains("No event yet"))

        // Swiping left offers Remove, which always asks first.
        let shell = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Shell")).firstMatch
        for _ in 0..<6 where !shell.isHittable { app.swipeUp() }
        shell.swipeLeft()
        let remove = app.buttons["Remove"].firstMatch
        XCTAssertTrue(remove.waitForExistence(timeout: 5))
        captureScreenshot("expenses-inbox-swipe-left")
        remove.tap()
        let confirm = app.buttons["Remove Draft"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertFalse(shell.waitForExistence(timeout: 3))
    }
}
