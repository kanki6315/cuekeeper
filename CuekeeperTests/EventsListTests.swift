import XCTest
@testable import Cuekeeper

final class EventsListTests: XCTestCase {
    /// Friday 16 October 2026; the window starts Friday 2 October.
    private let today = "2026-10-16"

    private func session(_ title: String, _ day: String, _ time: String? = "10:00") -> EventsListSession {
        EventsListSession(day: day, title: title, time: time)
    }
    private func event(_ title: String, start: String, end: String? = nil, status: String = "booked",
                       sessions: [EventsListSession] = [], payment: PaymentState? = nil,
                       fee: Int64? = 215_000, currency: String = "USD") -> EventsListFacts {
        var readiness: EventReadiness?
        if let payment {
            // Build billing facts that land on the requested state.
            let billing: EventBillingFact
            switch payment {
            case let .invoiced(reference, balance, currency, dueDay):
                billing = .sent(invoiceID: UUID(), reference: reference, currency: currency, total: balance, balance: balance, dueDay: dueDay, otherEvents: 0)
            case .paid: billing = .sent(invoiceID: UUID(), reference: "INV-1", currency: currency, total: fee ?? 0, balance: 0, dueDay: "", otherEvents: 0)
            default: billing = .notInvoiced
            }
            let facts = ReadinessFacts(jobID: UUID(), title: title, startDay: start, endDay: end ?? start, bookingStatus: status,
                                       clientID: UUID(), clientName: "F1TV", clientDetailsMissing: [],
                                       fee: .value(FeeValue(amount: fee, currency: currency)), billing: billing, billedAmount: nil,
                                       blockingReceipts: payment == .heldUp
                                           ? [EventExpenseFact(id: UUID(), merchant: "Fuel", amount: 3840, currency: currency)] : [],
                                       rebillable: [])
            readiness = EventReadiness(facts, today: today)
        }
        return EventsListFacts(objectID: nil, key: UUID().uuidString, title: title, client: "F1TV", series: ["F1"], bookingStatus: status,
                               startDay: start, endDay: end ?? start, sessions: sessions, payment: readiness)
    }
    private func list(_ events: [EventsListFacts], windowed: Bool = true, showEarlier: Bool = false) -> EventsList {
        EventsList(events: events, today: today, windowed: windowed, showEarlier: showEarlier)
    }

    // MARK: Window

    func testWindowHidesEventsThatEndedMoreThanTwoWeeksAgo() {
        let result = list([event("Old", start: "2026-09-25", end: "2026-10-01", status: "completed"),
                           event("Edge", start: "2026-09-30", end: "2026-10-02", status: "completed"),
                           event("Austin", start: "2026-10-16", end: "2026-10-18")])
        XCTAssertEqual(result.cutoff, "2026-10-02")
        XCTAssertEqual(result.rows.map(\.facts.title), ["Edge", "Austin"])
        XCTAssertEqual(result.hiddenEarlier, 1)
    }

    func testShowEarlierAndUnwindowedScopesKeepEverything() {
        let events = [event("Old", start: "2026-09-01", status: "completed"), event("Austin", start: "2026-10-16")]
        XCTAssertEqual(list(events, showEarlier: true).rows.count, 2)
        XCTAssertEqual(list(events, showEarlier: true).hiddenEarlier, 1)
        XCTAssertEqual(list(events, windowed: false).rows.count, 2)
        XCTAssertEqual(list(events, windowed: false).hiddenEarlier, 0)
    }

    // MARK: Months and today

    func testRowsGroupByStartMonthWithUndatedEventsLast() {
        let result = list([event("Bathurst", start: "2026-11-05", end: "2026-11-08"),
                           event("Undated", start: "", end: ""),
                           event("Halloween", start: "2026-10-30", end: "2026-11-01"),
                           event("Austin", start: "2026-10-16", end: "2026-10-18")])
        XCTAssertEqual(result.months.map(\.month), ["2026-10", "2026-11", ""])
        XCTAssertEqual(result.months[0].rows.map(\.facts.title), ["Austin", "Halloween"])
    }

    func testTodayMarkerSitsAboveTheFirstEventNotYetOver() {
        let result = list([event("Suzuka", start: "2026-10-09", end: "2026-10-11", status: "completed"),
                           event("Austin", start: "2026-10-16", end: "2026-10-18"),
                           event("Mexico", start: "2026-10-23", end: "2026-10-25")])
        XCTAssertEqual(result.todayBefore, result.rows[1].id)
        XCTAssertNil(list([event("Austin", start: "2026-10-16")]).todayBefore, "Nothing above it, so no marker")
    }

    func testMonthTotalsCountOnlyWhatIsStillOwed() {
        let result = list([event("Suzuka", start: "2026-10-09", end: "2026-10-11", status: "completed", payment: .ready),
                           event("Monza", start: "2026-10-03", status: "completed", payment: .invoiced(reference: "INV-7", balance: 50_000, currency: "EUR", dueDay: "2026-10-30")),
                           event("Paid", start: "2026-10-05", status: "completed", payment: .paid(reference: "INV-1")),
                           event("Austin", start: "2026-10-16", end: "2026-10-18")])
        XCTAssertEqual(result.months[0].toCollect, [CurrencyAmount(currency: "EUR", amount: 50_000), CurrencyAmount(currency: "USD", amount: 215_000)])
    }

    // MARK: Day lines

    func testSingleDayEventHasOneLine() {
        let row = EventsListRow(event("Brands Hatch", start: "2026-10-31", sessions: [session("Race 1", "2026-10-31")]), today: today)
        XCTAssertNil(row.endLine)
        XCTAssertEqual(row.lines, [.day("2026-10-31", [session("Race 1", "2026-10-31")])])
        let empty = EventsListRow(event("Brands Hatch", start: "2026-10-31"), today: today)
        XCTAssertEqual(empty.lines, [.scheduleToCome("2026-10-31")])
    }

    func testThreeDayEventHasALinePerDayWithTheEndOnTheLast() {
        let fp1 = session("FP1", "2026-10-16", "11:30"), race = session("Race", "2026-10-18", "14:00")
        let row = EventsListRow(event("Austin", start: "2026-10-16", end: "2026-10-18", sessions: [fp1, race]), today: today)
        XCTAssertEqual(row.lines, [.day("2026-10-16", [fp1]), .day("2026-10-17", []), .day("2026-10-18", [race])])
        XCTAssertEqual(row.endLine, 2)
    }

    func testTwoDayEventKeepsThreeLines() {
        let row = EventsListRow(event("Monza", start: "2026-10-03", end: "2026-10-04", sessions: [session("Race", "2026-10-04")]), today: today)
        XCTAssertEqual(row.lines.count, 3)
        XCTAssertEqual(row.lines[2], .blank)
        XCTAssertEqual(row.endLine, 1)
    }

    func testLongEventFoldsLaterDaysIntoTheLastLine() {
        let sessions = [session("Practice 1", "2026-11-05"), session("Qualifying", "2026-11-06"),
                        session("Top 10", "2026-11-07"), session("Race", "2026-11-08")]
        let row = EventsListRow(event("Bathurst", start: "2026-11-05", end: "2026-11-08", sessions: sessions), today: today)
        XCTAssertEqual(row.lines.count, 3)
        XCTAssertEqual(row.lines[2], .more(days: ["2026-11-07", "2026-11-08"], sessions: 2))
        XCTAssertEqual(row.endLine, 2)
    }

    func testMultiDayEventWithoutScheduleSaysSoOnTheFirstDay() {
        let row = EventsListRow(event("Mexico", start: "2026-10-23", end: "2026-10-25", status: "tentative"), today: today)
        XCTAssertEqual(row.lines, [.scheduleToCome("2026-10-23"), .day("2026-10-24", []), .day("2026-10-25", [])])
    }

    func testUndatedSessionsDoNotCountAsASchedule() {
        let row = EventsListRow(event("Austin", start: "2026-10-16", end: "2026-10-18", sessions: [session("Race", "", nil)]), today: today)
        XCTAssertEqual(row.lines.first, .scheduleToCome("2026-10-16"))
    }

    // MARK: Badges

    func testBadgeShowsBookingBeforeTheWorkAndMoneyAfter() {
        XCTAssertEqual(EventsListRow(event("A", start: "2026-10-23", status: "tentative"), today: today).badge, EventsBadge(text: "Tentative", tone: .amber))
        XCTAssertEqual(EventsListRow(event("A", start: "2026-10-16", end: "2026-10-18"), today: today).badge, EventsBadge(text: "Booked", tone: .accent))
        XCTAssertEqual(EventsListRow(event("A", start: "2026-10-09", status: "completed", payment: .ready), today: today).badge.text, "Ready to invoice")
        XCTAssertEqual(EventsListRow(event("A", start: "2026-10-09", status: "completed", payment: .paid(reference: "INV-1")), today: today).badge, EventsBadge(text: "Paid", tone: .muted))
        XCTAssertEqual(EventsListRow(event("A", start: "2026-10-09", status: "completed", payment: .heldUp), today: today).badge, EventsBadge(text: "To settle", tone: .amber))
        let overdue = PaymentState.invoiced(reference: "INV-2", balance: 100, currency: "USD", dueDay: "2026-10-10")
        XCTAssertEqual(EventsListRow(event("A", start: "2026-09-20", status: "completed", payment: overdue), today: today).badge.text, "Overdue")
        XCTAssertEqual(EventsListRow(event("A", start: "2026-10-09", status: "cancelled"), today: today).badge.text, "Cancelled")
    }

    func testMoreTextListsShortTailsAndCountsLongOnes() {
        XCTAssertEqual(EventsListRowView.moreText(days: ["2026-11-07", "2026-11-08"], sessions: 2), "+ Sat, Sun · 2 sessions")
        XCTAssertEqual(EventsListRowView.moreText(days: ["2026-11-07", "2026-11-08", "2026-11-09", "2026-11-10"], sessions: 0), "+4 more days")
    }
}
