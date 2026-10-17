import CoreData
import XCTest
@testable import Cuekeeper

final class PaymentsReadinessTests: XCTestCase {
    private let today = "2026-10-16"
    private let client = UUID()

    private func facts(_ title: String = "Event", start: String = "2026-10-13", end: String? = nil, status: String = "completed",
                       client: UUID?? = nil, missing: [String] = [], fee: EventFeeFact = .value(FeeValue(amount: 65_000, currency: "EUR")),
                       billing: EventBillingFact = .notInvoiced, billed: Int64? = nil,
                       blocking: Int = 0, rebillable: [EventExpenseFact] = []) -> ReadinessFacts {
        let clientID: UUID? = client ?? self.client
        return ReadinessFacts(jobID: UUID(), title: title, startDay: start, endDay: end ?? start, bookingStatus: status,
                              clientID: clientID, clientName: clientID == nil ? nil : "Northside", clientDetailsMissing: missing, fee: fee,
                              billing: billing, billedAmount: billed,
                              blockingReceipts: (0..<blocking).map { _ in EventExpenseFact(id: UUID(), merchant: "Fuel", amount: 3840, currency: "EUR") },
                              rebillable: rebillable)
    }
    private func readiness(_ facts: ReadinessFacts) -> EventReadiness { EventReadiness(facts, today: today) }

    // MARK: Gates

    func testAllGatesDoneIsReady() {
        let event = readiness(facts())
        XCTAssertEqual(event.state, .ready)
        XCTAssertTrue(ReadinessGate.allCases.allSatisfy { event.gates[$0] == .done })
        XCTAssertTrue(event.gaps.isEmpty)
        XCTAssertEqual(event.amount, 65_000); XCTAssertEqual(event.currency, "EUR")
    }

    func testUpcomingWorkIsNotYetAndOtherGapsStillShow() {
        let event = readiness(facts(start: "2026-10-30", status: "booked", fee: .value(FeeValue(amount: nil, currency: "USD"))))
        XCTAssertEqual(event.state, .upcoming)
        XCTAssertEqual(event.gates[.work], .notYet)
        XCTAssertEqual(event.gates[.fee], .missing)
        XCTAssertEqual(event.gaps.map(\.text), ["Fee to agree"])
    }

    func testEndedButNotCompletedWorkIsMissing() {
        let event = readiness(facts(start: "2026-10-10", end: "2026-10-11", status: "booked"))
        XCTAssertEqual(event.gates[.work], .missing)
        XCTAssertEqual(event.state, .heldUp)
        XCTAssertEqual(event.gaps.first?.text, "Mark completed")
    }

    func testInProgressWorkIsNotYet() {
        XCTAssertEqual(readiness(facts(start: "2026-10-16", end: "2026-10-18", status: "booked")).gates[.work], .notYet)
    }

    func testFeeConflictAndUnknownAreMissingButZeroIsNoFee() {
        XCTAssertEqual(readiness(facts(fee: .conflict)).gaps.map(\.text), ["Fee needs review"])
        XCTAssertEqual(readiness(facts(fee: .conflict)).state, .heldUp)
        XCTAssertEqual(readiness(facts(fee: .value(FeeValue(amount: nil)))).gates[.fee], .missing)
        let zero = readiness(facts(fee: .value(FeeValue(amount: 0, currency: "EUR"))))
        XCTAssertEqual(zero.gates[.fee], .done)
        XCTAssertEqual(zero.state, .noFee)
        XCTAssertNil(zero.state.bucket)
    }

    func testOnlyBlockingReceiptsHoldUpInvoicing() {
        let one = readiness(facts(blocking: 1))
        XCTAssertEqual(one.gates[.receipts], .missing)
        XCTAssertEqual(one.gaps.map(\.text), ["1 receipt to finish"])
        XCTAssertEqual(readiness(facts(blocking: 2)).gaps.map(\.text), ["2 receipts to finish"])
        let rebill = EventExpenseFact(id: UUID(), merchant: "Parking", amount: 2580, currency: "EUR")
        XCTAssertEqual(readiness(facts(rebillable: [rebill])).state, .ready)
    }

    func testClientGateNeedsAClientAndCompleteDetails() {
        let none = readiness(facts(client: .some(nil)))
        XCTAssertEqual(none.gates[.client], .missing)
        XCTAssertEqual(none.gaps.map(\.text), ["Client to add"])
        let partial = readiness(facts(missing: ["billing email", "address"]))
        XCTAssertEqual(partial.gates[.client], .missing)
        XCTAssertEqual(partial.gaps.map(\.text), ["Client details missing"])
        XCTAssertEqual(partial.state, .heldUp)
    }

    func testGapsListInGateOrder() {
        let event = readiness(facts(start: "2026-10-10", status: "booked", missing: ["billing email"], fee: .value(FeeValue(amount: nil)), blocking: 1))
        XCTAssertEqual(event.gaps.map(\.gate), [.fee, .client, .work, .receipts])
    }

    // MARK: Billing states

    func testBillingStatesWinOverGates() {
        let invoice = UUID()
        XCTAssertEqual(readiness(facts(billing: .draft(invoiceID: invoice))).state, .draft)
        let owed = readiness(facts(billing: .sent(invoiceID: invoice, reference: "INV-0409", currency: "EUR", total: 260_000, balance: 130_000, dueDay: "2026-10-30", otherEvents: 1), billed: 130_000))
        XCTAssertEqual(owed.state, .invoiced(reference: "INV-0409", balance: 130_000, currency: "EUR", dueDay: "2026-10-30"))
        XCTAssertEqual(owed.amount, 130_000)
        XCTAssertFalse(owed.showsGates)
        XCTAssertEqual(readiness(facts(billing: .sent(invoiceID: invoice, reference: "INV-0401", currency: "EUR", total: 39_000, balance: 0, dueDay: "", otherEvents: 0))).state, .paid(reference: "INV-0401"))
        XCTAssertEqual(readiness(facts(billing: .directPayments(paid: 25_000, currency: "USD"))).state, .directPaid)
        XCTAssertEqual(readiness(facts(billing: .review(message: "Twice", invoiceID: nil))).state, .review("Twice"))
    }

    func testBilledAmountOverridesFee() {
        let event = readiness(facts(billing: .draft(invoiceID: UUID()), billed: 60_000))
        XCTAssertEqual(event.amount, 60_000)
    }

    func testCancelledWithoutMoneyIsCancelled() {
        XCTAssertEqual(readiness(facts(status: "cancelled")).state, .cancelled)
    }

    // MARK: Month

    func testMonthGroupsByClientAndKeepsCurrenciesSeparate() {
        let other = UUID()
        let events = [
            readiness(facts("Cup", start: "2026-10-03")),
            readiness(facts("City", start: "2026-10-13")),
            readiness(facts("Silverstone", start: "2026-10-16", end: "2026-10-18", status: "booked", fee: .value(FeeValue(amount: 180_000, currency: "EUR")))),
            readiness(facts("Harbour", start: "2026-10-11", client: .some(other), missing: ["billing email"], fee: .value(FeeValue(amount: 90_000, currency: "USD")))),
            readiness(facts("Finals", start: "2026-10-30", status: "booked", client: .some(other), fee: .value(FeeValue(amount: nil, currency: "USD")))),
            readiness(facts("September", start: "2026-09-20")),
        ]
        let clients = [client: PaymentsMonth.ClientInfo(id: client, name: "Northside", detailsMissing: [], termsDays: 30),
                       other: PaymentsMonth.ClientInfo(id: other, name: "Apex", detailsMissing: ["billing email"], termsDays: nil)]
        let month = PaymentsMonth(month: "2026-10", events: events, clients: clients, openInvoices: [], displayed: ["USD", "EUR"])
        XCTAssertEqual(month.groups.map(\.name), ["Apex", "Northside"])
        XCTAssertEqual(month.groups[1].events.map(\.facts.title), ["Cup", "City", "Silverstone"])
        XCTAssertEqual(month.groups[1].readyTotals.map(\.amount), [130_000])
        let eur = month.currencies.first { $0.currency == "EUR" }!
        XCTAssertEqual(eur.amounts[.ready], 130_000)
        XCTAssertEqual(eur.amounts[.toHappen], 180_000)
        let usd = month.currencies.first { $0.currency == "USD" }!
        XCTAssertEqual(usd.amounts[.heldUp], 90_000)
        XCTAssertEqual(usd.unknownFees, 1)
        XCTAssertNil(usd.amounts[.ready])
        XCTAssertEqual(month.currencies.map(\.currency), ["USD", "EUR"])
        // Earlier finished work still waiting to be invoiced is not lost.
        XCTAssertEqual(month.earlier.map(\.id), ["event-\(events[5].id)"])
    }

    func testEarlierListsOnlyInvoicesForEarlierWork() {
        let invoice = { (days: [String], ref: String) in
            PaymentsMonth.OpenInvoice(id: UUID(), reference: ref, clientName: "Apex", balance: 315_000, currency: "USD", dueDay: "2026-10-14",
                                      draft: false, paid: 0, total: 315_000, eventDays: days)
        }
        let month = PaymentsMonth(month: "2026-10", events: [], clients: [:],
                                  openInvoices: [invoice(["2026-09-12"], "APX-2207"), invoice(["2026-09-30", "2026-10-02"], "APX-2210")], displayed: ["USD"])
        XCTAssertEqual(month.earlier.count, 1)
        if case let .invoice(_, reference, _, _, _, _, _, _, _) = month.earlier[0] { XCTAssertEqual(reference, "APX-2207") } else { XCTFail() }
    }

    func testEventsWithoutAClientGroupLast() {
        let events = [readiness(facts("Loose", client: .some(nil))), readiness(facts("Zed"))]
        let month = PaymentsMonth(month: "2026-10", events: events, clients: [client: .init(id: client, name: "Zebra", detailsMissing: [], termsDays: 14)],
                                  openInvoices: [], displayed: [])
        XCTAssertEqual(month.groups.map(\.name), ["Zebra", "No client yet"])
    }

    // MARK: Client invoicing and invoice values

    func testClientInvoicingCompletenessAndDueDay() throws {
        var value = ClientInvoicing()
        XCTAssertEqual(value.missing, ["billing name", "billing email", "address", "payment terms"])
        value = ClientInvoicing(billingName: "Northside Sports Media", email: "accounts@example.com", address: "1 Road", termsDays: 30)
        XCTAssertTrue(value.isComplete)
        XCTAssertEqual(value.dueDay(sent: "2026-10-16"), "2026-11-15")
        XCTAssertThrowsError(try ClientInvoicing(email: "not an email").validate())
        XCTAssertThrowsError(try ClientInvoicing(termsDays: 400).validate())
        XCTAssertThrowsError(try InvoicingDraft(ClientInvoicing()).with(terms: "thirty").value())
        XCTAssertEqual(try InvoicingDraft(ClientInvoicing()).with(terms: " 14 ").value().termsDays, 14)
    }

    func testExpenseLinesCountTowardTotalAndStayOptionalInJSON() throws {
        var value = InvoiceValue(clientID: client, currency: "EUR")
        value.lines = [BilledLine(jobID: UUID(), jobName: "Cup", amount: 65_000)]
        let plain = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        XCTAssertFalse(plain.contains("expenseLines"))
        let receipt = BilledExpense(expenseID: UUID(), label: "Parking · 13 Oct", amount: 2580)
        value.expenseLines = [receipt]
        XCTAssertEqual(try value.total(), 67_580)
        XCTAssertNoThrow(try value.validate())
        value.expenseLines = [receipt, receipt]
        XCTAssertThrowsError(try value.validate())
        // An older build's value without expense lines decodes and compares as different billed terms.
        let decoded = try JSONDecoder().decode(InvoiceValue.self, from: Data(plain.utf8))
        XCTAssertNil(decoded.expenseLines)
        value.expenseLines = [receipt]
        XCTAssertFalse(value.sameBilledTerms(as: decoded))
    }
}

private extension InvoicingDraft {
    func with(terms: String) -> InvoicingDraft { var copy = self; copy.terms = terms; return copy }
}
