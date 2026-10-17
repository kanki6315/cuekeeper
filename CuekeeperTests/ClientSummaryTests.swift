import XCTest
@testable import Cuekeeper

final class ClientSummaryTests: XCTestCase {
    private let today = "2026-10-16"

    private func event(_ title: String, start: String, end: String? = nil, status: String = "booked") -> EventsListFacts {
        EventsListFacts(objectID: nil, key: UUID().uuidString, title: title, client: "Apex", series: [], bookingStatus: status,
                        startDay: start, endDay: end ?? start, sessions: [], payment: nil)
    }
    private func readiness(_ title: String, start: String, status: String = "completed", amount: Int64? = 100_000,
                           currency: String = "USD", billing: EventBillingFact = .notInvoiced) -> EventReadiness {
        EventReadiness(ReadinessFacts(jobID: UUID(), title: title, startDay: start, endDay: start, bookingStatus: status,
                                      clientID: UUID(), clientName: "Apex", clientDetailsMissing: [],
                                      fee: .value(FeeValue(amount: amount, currency: currency)), billing: billing, billedAmount: nil,
                                      blockingReceipts: [], rebillable: []), today: today)
    }
    private func invoice(_ reference: String, balance: Int64, total: Int64 = 100_000, currency: String = "USD",
                         status: String? = "sent", sent: String = "2026-09-01", due: String = "") -> ClientInvoiceFact {
        ClientInvoiceFact(objectID: nil, key: reference, reference: reference, events: [], currency: currency, total: total,
                          balance: balance, status: status, sentDay: sent, dueDay: due)
    }

    func testUpcomingIsSoonestFirstWithUndatedLastAndPastGroupsByYear() {
        let summary = ClientSummary(events: [
            event("Later", start: "2026-11-08"), event("Undated", start: ""), event("Soon", start: "2026-10-24"),
            event("Done", start: "2026-08-30", status: "completed"), event("Old", start: "2025-06-01", status: "completed"),
            event("Dropped", start: "2026-12-01", status: "cancelled"),
        ], today: today)
        XCTAssertEqual(summary.upcoming.map(\.facts.title), ["Soon", "Later", "Undated"])
        XCTAssertEqual(summary.past.map(\.year), ["2026", "2025"])
        XCTAssertEqual(summary.past[0].rows.map(\.facts.title), ["Dropped", "Done"])
        XCTAssertEqual(summary.eventCount, 5, "Cancelled events are not counted")
        XCTAssertEqual(summary.sinceDay, "2025-06-01")
        XCTAssertEqual(summary.lastDay, "2026-08-30")
    }

    func testOwedAndOverdueComeFromOpenSentInvoicesPerCurrency() {
        let summary = ClientSummary(events: [], invoices: [
            invoice("A", balance: 315_000, due: "2026-10-04"),
            invoice("B", balance: 48_000, currency: "EUR", due: "2026-11-01"),
            invoice("Paid", balance: 0),
            invoice("Draft", balance: 90_000, status: "draft"),
            invoice("Void", balance: 0, status: "void"),
        ], today: today)
        XCTAssertEqual(summary.owed, [CurrencyAmount(currency: "EUR", amount: 48_000), CurrencyAmount(currency: "USD", amount: 315_000)])
        XCTAssertEqual(summary.overdue, [CurrencyAmount(currency: "USD", amount: 315_000)])
        XCTAssertEqual(summary.invoices.map(\.reference), ["A", "B", "Draft", "Paid", "Void"])
        XCTAssertEqual(summary.standing?.tone, .amber)
        XCTAssertTrue(summary.standing?.text.hasSuffix("overdue") ?? false)
    }

    func testStandingFallsBackToOwedThenMissingDetailsOnlyWithWorkAhead() {
        let owed = ClientSummary(events: [], invoices: [invoice("B", balance: 48_000, due: "2026-11-01")], today: today)
        XCTAssertEqual(owed.standing?.tone, .muted)

        let gaps = ClientInvoicing(billingName: "Apex", email: "a@b.co", address: "", termsDays: 30)
        let ahead = ClientSummary(events: [event("Soon", start: "2026-10-24")], invoicing: gaps, today: today)
        XCTAssertEqual(ahead.standing, EventsBadge(text: "Needs address", tone: .amber))

        let idle = ClientSummary(events: [event("Done", start: "2026-01-10", status: "completed")], invoicing: gaps, today: today)
        XCTAssertNil(idle.standing)
        XCTAssertTrue(idle.detailsNeeded.isEmpty)
    }

    func testMoneyBucketsOneYearAndReadyGroupsByCurrency() {
        let summary = ClientSummary(events: [], readiness: [
            readiness("Ready", start: "2026-09-27", amount: 340_000),
            readiness("Ahead", start: "2026-11-08", status: "booked", amount: 200_000),
            readiness("Euro", start: "2026-05-01", amount: 65_000, currency: "EUR"),
            readiness("Unknown", start: "2026-04-01", amount: nil),
            readiness("Last year", start: "2025-06-01", amount: 999_000),
        ], today: today)
        XCTAssertEqual(summary.years, ["2026", "2025"])
        XCTAssertEqual(summary.defaultYear, "2026")
        let money = summary.money(in: "2026")
        XCTAssertEqual(money.map(\.currency), ["EUR", "USD"])
        XCTAssertEqual(money[1].amounts[.ready], 340_000)
        XCTAssertEqual(money[1].amounts[.toHappen], 200_000)
        XCTAssertEqual(money[1].unknownFees, 1)
        XCTAssertEqual(summary.readyToInvoice.map(\.currency), ["EUR", "USD"])
        XCTAssertEqual(summary.readyToInvoice[1].events.map(\.facts.title), ["Last year", "Ready"], "Ready work from any year, oldest first")
    }

    func testDefaultYearFallsBackToLatestYearWithWork() {
        let summary = ClientSummary(events: [], readiness: [readiness("Old", start: "2024-03-01")], today: today)
        XCTAssertEqual(summary.defaultYear, "2024")
    }

    func testInvoiceStates() {
        XCTAssertEqual(invoice("R", balance: 0, status: nil).state(today: today), .review)
        XCTAssertEqual(invoice("C", balance: -500).state(today: today), .credit)
        XCTAssertEqual(invoice("O", balance: 10, due: "2026-10-16").state(today: today), .open(overdue: false))
        XCTAssertEqual(invoice("O", balance: 10, due: "2026-10-15").state(today: today), .open(overdue: true))
        XCTAssertEqual(invoice("N", balance: 10).state(today: today), .open(overdue: false), "No due day is never overdue")
    }

    func testInitials() {
        XCTAssertEqual("Apex Media".initials, "AM")
        XCTAssertEqual("Meridian Motorsport TV".initials, "MM")
        XCTAssertEqual("F1TV".initials, "F")
        XCTAssertEqual("  ".initials, "?")
    }
}
