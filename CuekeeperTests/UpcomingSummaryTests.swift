import XCTest
@testable import Cuekeeper

final class UpcomingSummaryTests: XCTestCase {
    private let london = TimeZone(identifier: "Europe/London")!
    private let newYork = TimeZone(identifier: "America/New_York")!
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    /// Thursday 15 October 2026, 18:00 in New York.
    private var now: Date { date("2026-10-15T22:00:00Z") }

    private func session(_ title: String, day: String, start: String? = nil, end: String? = nil, call: String? = nil,
                         confirmed: Bool = true, coverage: String = "covering") -> EventSessionFact {
        EventSessionFact(id: UUID(), title: title, day: day, start: start.map(date), end: end.map(date), call: call.map(date),
                         confirmed: confirmed, coverage: coverage)
    }
    private func job(_ title: String, status: String = "booked", start: String, end: String? = nil, sessions: [EventSessionFact] = [],
                     arrangement: WorkArrangement = .remote, zone: TimeZone? = nil, client: String? = "Northside Sports",
                     fee: EventFeeFact = .value(FeeValue(amount: 180_000, currency: "EUR", agreement: "agreed")),
                     billing: EventBillingFact = .notInvoiced) -> UpcomingJobFact {
        let eventZone = zone ?? london
        let facts = EventDetailFacts(bookingStatus: status, hasClient: client != nil, startDay: start, endDay: end ?? start,
                                     eventZone: eventZone, workZone: arrangement == .remote ? newYork : nil,
                                     sessions: sessions, fee: fee, billing: billing, expenseDrafts: [])
        return UpcomingJobFact(id: UUID(), title: title, client: client, work: "Commentator", arrangement: arrangement, facts: facts)
    }
    private func summary(_ jobs: [UpcomingJobFact], receipts: [UpcomingReceiptFact] = [], at time: Date? = nil) -> UpcomingSummary {
        UpcomingSummary(jobs: jobs, receipts: receipts, now: time ?? now, zone: newYork)
    }

    // MARK: In flight

    func testInFlightCoversTheNext72HoursAtBothEdges() {
        let inside = job("Silverstone weekend", start: "2026-10-18")
        let edge = job("Edge", start: "2026-10-19", sessions: [session("Show", day: "2026-10-19", start: "2026-10-18T21:30:00Z")])
        let outside = job("Studio highlights", start: "2026-10-20")
        let result = summary([outside, edge, inside])
        XCTAssertEqual(result.inFlight.map(\.title), ["Silverstone weekend", "Edge"])
        XCTAssertEqual(result.defaultMode, .now)
        XCTAssertEqual(result.afterThis?.title, "Studio highlights")
    }

    func testCompletedAndCancelledJobsAreNeverInFlight() {
        let done = job("Done", status: "completed", start: "2026-10-16")
        let off = job("Off", status: "cancelled", start: "2026-10-16")
        XCTAssertTrue(summary([done, off]).inFlight.isEmpty)
    }

    func testARunningSessionKeepsItsJobInFlight() {
        let overnight = job("Night race", start: "2026-10-15",
                            sessions: [session("Race", day: "2026-10-15", start: "2026-10-15T21:00:00Z", end: "2026-10-16T01:00:00Z")])
        // Day keys alone would not include a job whose London day has passed; the running session does.
        let later = date("2026-10-16T00:30:00Z")
        XCTAssertEqual(summary([overnight], at: later).inFlight.map(\.title), ["Night race"])
    }

    func testIdleShowsNextWorkAndDefaultsToPlan() {
        let practice = session("Practice 1", day: "2026-11-13", start: "2026-11-13T09:00:00Z", call: "2026-11-13T08:00:00Z")
        let result = summary([job("Abu Dhabi finale", start: "2026-11-13", end: "2026-11-15", sessions: [practice])])
        XCTAssertTrue(result.inFlight.isEmpty)
        XCTAssertEqual(result.defaultMode, .plan)
        XCTAssertEqual(result.nextWork?.job.title, "Abu Dhabi finale")
        XCTAssertEqual(result.nextWork?.daysUntil, 29)
        XCTAssertEqual(result.nextWork?.first?.title, "Practice 1")
    }

    // MARK: Run of show

    func testTwoJobsMergeIntoOneDayWithAGapLineBetweenJobs() {
        let qualifying = session("Qualifying", day: "2026-10-17", start: "2026-10-17T13:00:00Z", end: "2026-10-17T14:00:00Z", call: "2026-10-17T12:00:00Z")
        let derby = session("Derby live", day: "2026-10-17", start: "2026-10-17T16:30:00Z", end: "2026-10-17T19:00:00Z", call: "2026-10-17T15:30:00Z")
        let sprint = session("Sprint", day: "2026-10-17", confirmed: false, coverage: "undecided")
        let silverstone = job("Silverstone weekend", start: "2026-10-16", end: "2026-10-18", sessions: [qualifying, sprint])
        let studio = job("City derby", start: "2026-10-17", sessions: [derby], arrangement: .hybrid, zone: newYork)
        let result = summary([silverstone, studio])
        XCTAssertEqual(result.days.map(\.key), ["2026-10-17"])
        XCTAssertEqual(result.days[0].rows.map(\.session.title), ["Qualifying", "Derby live", "Sprint"])
        XCTAssertNil(result.days[0].rows[0].gapBefore)
        XCTAssertEqual(result.days[0].rows[1].gapBefore, 90 * 60)
        XCTAssertNil(result.days[0].rows[2].gapBefore)
    }

    func testOnSiteWorkReadsInTheTrackZoneWhenItIsTheOnlyZone() {
        let race = session("Race 1", day: "2026-10-17", start: "2026-10-17T09:00:00Z")
        let result = summary([job("Brands Hatch", start: "2026-10-17", sessions: [race], arrangement: .onSite)])
        XCTAssertEqual(result.displayZone.identifier, "Europe/London")
        XCTAssertEqual(result.days[0].rows[0].showsZone, false)
    }

    func testOnSiteWorkBesideRemoteWorkLabelsItsZone() {
        let race = session("Race 1", day: "2026-10-17", start: "2026-10-17T09:00:00Z")
        let show = session("Show", day: "2026-10-17", start: "2026-10-17T20:00:00Z")
        let result = summary([job("Brands Hatch", start: "2026-10-17", sessions: [race], arrangement: .onSite),
                              job("Remote show", start: "2026-10-17", sessions: [show])])
        XCTAssertEqual(result.displayZone.identifier, "America/New_York")
        let rows = result.days.flatMap(\.rows)
        XCTAssertEqual(rows.first { $0.session.title == "Race 1" }?.showsZone, true)
        XCTAssertEqual(rows.first { $0.session.title == "Race 1" }?.zone.identifier, "Europe/London")
    }

    func testOvernightSessionGroupsByItsStartInTheDisplayZone() {
        let late = session("Late show", day: "2026-10-17", start: "2026-10-17T03:30:00Z", end: "2026-10-17T05:00:00Z")
        let result = summary([job("Late", start: "2026-10-17", sessions: [late])])
        XCTAssertEqual(result.days.map(\.key), ["2026-10-16"])
    }

    // MARK: To settle

    func testItemsRankByTheirDayWithPastEventsFirst() {
        let over = job("City vs United", start: "2026-10-13")
        let sprint = session("Sprint", day: "2026-10-17")
        let weekend = job("Silverstone weekend", start: "2026-10-16", end: "2026-10-18", sessions: [sprint])
        let studio = job("Studio highlights", status: "tentative", start: "2026-10-20")
        let finals = job("National finals", start: "2026-10-30", fee: .value(FeeValue(currency: "EUR")))
        let receipt = UpcomingReceiptFact(id: UUID(), merchant: "Fuel", amount: 3_840, currency: "EUR", day: "2026-10-14")
        let result = summary([finals, studio, weekend, over], receipts: [receipt])
        XCTAssertEqual(result.items.map(\.item.kind), [.eventOver, .expenseDraft, .sessionTime, .tentativeBooking, .feeUnknown])
        XCTAssertEqual(result.items.first?.item.title, "City vs United is over")
        XCTAssertEqual(result.items.first?.item.action, .markCompleted)
        XCTAssertEqual(result.categorySummary, "2 bookings · 1 schedule · 2 money")
        XCTAssertEqual(result.openCount(for: weekend.id), 1)
    }

    func testBalanceOwedRanksByItsDueDay() {
        let billing = EventBillingFact.sent(invoiceID: UUID(), reference: "INV-1", currency: "EUR", total: 1_000, balance: 500, dueDay: "2026-10-01", otherEvents: 0)
        let owed = job("Paid late", status: "completed", start: "2026-09-10", billing: billing)
        let item = summary([owed]).items.first
        XCTAssertEqual(item?.item.kind, .balanceOwed)
        XCTAssertEqual(item?.rankDay, "2026-10-01")
    }

    func testDistantScheduleGapsWaitButMoneyDoesNot() {
        let distant = job("Season finale", status: "tentative", start: "2027-03-01", sessions: [session("Race", day: "2027-03-01")])
        XCTAssertTrue(summary([distant]).items.isEmpty)
        let unknownFee = job("Season finale", start: "2027-03-01", fee: .value(FeeValue(currency: "EUR")))
        XCTAssertEqual(summary([unknownFee]).items.map(\.item.kind), [.feeUnknown])
    }

    func testAReceiptWithoutAnEventNamesThatInItsContext() {
        let receipt = UpcomingReceiptFact(id: UUID(), merchant: "Wallet", amount: 3_840, currency: "EUR", day: "2026-10-14")
        let item = summary([], receipts: [receipt]).items[0]
        XCTAssertNil(item.jobID)
        XCTAssertEqual(item.context, "Wallet · \(Money.format(3_840, currency: "EUR")) · no event yet")
    }

    // MARK: Fortnight and coming up

    func testFortnightStartsOnMondayAndMarksSessions() {
        let practice = session("Practice 1", day: "2026-10-16", start: "2026-10-16T10:30:00Z")
        let skipped = session("Practice 2", day: "2026-10-16", start: "2026-10-16T14:00:00Z", coverage: "notCovering")
        let sprint = session("Sprint", day: "2026-10-17")
        let weekend = job("Silverstone weekend", start: "2026-10-16", end: "2026-10-18", sessions: [practice, skipped, sprint])
        let studio = job("Studio highlights", status: "tentative", start: "2026-10-20")
        let lapsed = job("Cup replay", start: "2026-10-13")
        let strip = summary([weekend, studio, lapsed]).fortnight
        XCTAssertEqual(strip.count, 14)
        XCTAssertEqual(strip.first?.key, "2026-10-12")
        XCTAssertEqual(strip.first { $0.isToday }?.key, "2026-10-15")
        XCTAssertEqual(strip.first { $0.key == "2026-10-16" }?.marks, [.covering, .notCovering])
        XCTAssertEqual(strip.first { $0.key == "2026-10-17" }?.marks, [.tbc])
        XCTAssertEqual(strip.first { $0.key == "2026-10-20" }?.marks, [.tbc])
        XCTAssertEqual(strip.filter(\.isPast).map(\.key), ["2026-10-12", "2026-10-13", "2026-10-14"])
        XCTAssertEqual(strip.first { $0.key == "2026-10-13" }?.marks, [], "unscheduled days already past are not marked")
    }

    func testComingUpListsActiveJobsWithinThirtyDaysWithCounts() {
        let weekend = job("Silverstone weekend", start: "2026-10-16", end: "2026-10-18", sessions: [session("Sprint", day: "2026-10-17", coverage: "undecided")])
        let studio = job("Studio highlights", status: "tentative", start: "2026-10-20")
        let far = job("Season finale", start: "2027-03-01")
        let done = job("Done", status: "completed", start: "2026-10-16")
        let result = summary([far, studio, weekend, done])
        XCTAssertEqual(result.comingUp.map(\.job.title), ["Silverstone weekend", "Studio highlights"])
        XCTAssertEqual(result.comingUp[0].summary, "Northside Sports · remote · 1 undecided")
        XCTAssertEqual(result.comingUp[1].summary, "Northside Sports · remote · tentative · schedule to come")
        XCTAssertEqual(result.comingUp[1].openCount, 1)
    }
}
