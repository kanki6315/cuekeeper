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
    private func summary(_ jobs: [UpcomingJobFact], at time: Date? = nil) -> UpcomingSummary {
        UpcomingSummary(jobs: jobs, now: time ?? now, zone: newYork)
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

    // MARK: Event over

    private func overDetails(_ jobs: [UpcomingJobFact], at time: Date? = nil) -> [String?] {
        summary(jobs, at: time).items.filter { $0.item.kind == .eventOver }.map(\.detail)
    }

    func testEventIsOverOnceItsLastCoveredSessionEnds() {
        // London 21:00; the user's clock reads 17:00 on the same day.
        let match = session("Match", day: "2026-10-15", start: "2026-10-15T18:00:00Z", end: "2026-10-15T20:00:00Z")
        XCTAssertEqual(overDetails([job("City vs United", start: "2026-10-15", sessions: [match])]), ["Ended today · Northside Sports"])
    }

    func testEventIsNotOverWhileWorkRemains() {
        let done = session("Warm-up", day: "2026-10-15", start: "2026-10-15T18:00:00Z", end: "2026-10-15T19:00:00Z")
        let later = session("Late kick-off", day: "2026-10-15", start: "2026-10-15T21:30:00Z", end: "2026-10-15T23:00:00Z")
        let untimed = session("Highlights", day: "2026-10-15")
        XCTAssertEqual(overDetails([job("Running late", start: "2026-10-15", sessions: [done, later])]), [])
        // Without an end for every session, the event waits for its last day to pass.
        XCTAssertEqual(overDetails([job("Untimed", start: "2026-10-15", sessions: [done, untimed])]), [])
        XCTAssertEqual(overDetails([job("No sessions", start: "2026-10-15")]), [])
        // Finished sessions do not end an event that still has days to run.
        XCTAssertEqual(overDetails([job("Weekend", start: "2026-10-15", end: "2026-10-16", sessions: [done])]), [])
    }

    func testSessionsNotBeingCoveredDoNotHoldTheEventOpen() {
        let covered = session("Race", day: "2026-10-15", start: "2026-10-15T18:00:00Z", end: "2026-10-15T20:00:00Z")
        let skipped = session("Podium", day: "2026-10-15", start: "2026-10-15T22:30:00Z", end: "2026-10-15T23:00:00Z", coverage: "notCovering")
        XCTAssertEqual(overDetails([job("Race day", start: "2026-10-15", sessions: [covered, skipped])]), ["Ended today · Northside Sports"])
    }

    func testEndedDayReadsInTheUsersClock() {
        // 20:30 in New York is already 01:30 tomorrow in London: still "today" for the user.
        let afterLondonMidnight = date("2026-10-16T00:30:00Z")
        XCTAssertEqual(overDetails([job("City vs United", start: "2026-10-15")], at: afterLondonMidnight), ["Ended today · Northside Sports"])
        // Sydney's date runs ahead; work that has finished never reads as ending tomorrow.
        let sydney = TimeZone(identifier: "Australia/Sydney")!
        let morning = session("Qualifying", day: "2026-10-16", start: "2026-10-15T19:00:00Z", end: "2026-10-15T21:00:00Z")
        XCTAssertEqual(overDetails([job("Bathurst", start: "2026-10-16", sessions: [morning], zone: sydney)]), ["Ended today · Northside Sports"])
    }

    func testItemsRankByTheirDayWithPastEventsFirst() {
        let over = job("City vs United", start: "2026-10-13")
        let sprint = session("Sprint", day: "2026-10-17")
        let weekend = job("Silverstone weekend", start: "2026-10-16", end: "2026-10-18", sessions: [sprint])
        let studio = job("Studio highlights", status: "tentative", start: "2026-10-20")
        let finals = job("National finals", start: "2026-10-30", fee: .value(FeeValue(currency: "EUR")))
        let result = summary([finals, studio, weekend, over])
        XCTAssertEqual(result.items.map(\.item.kind), [.eventOver, .sessionTime, .tentativeBooking, .feeUnknown])
        XCTAssertEqual(result.items.first?.item.title, "City vs United is over")
        XCTAssertEqual(result.items.first?.item.action, .markCompleted)
        XCTAssertEqual(result.categorySummary, "1 event to complete · 1 session time to add · 2 more")
        XCTAssertEqual(result.items.map(\.title), ["City vs United", "Silverstone weekend", "Studio highlights", "National finals"])
        XCTAssertEqual(result.items.map(\.detail), ["Ended 2 days ago · Northside Sports", "Sprint · in 2 days", "Starts in 5 days", "Booked · in 15 days"])
        XCTAssertEqual(result.items.map(\.day), ["2026-10-13", "2026-10-17", "2026-10-20", "2026-10-30"])
        XCTAssertEqual(result.settleGroups.map(\.heading), ["Events to complete", "Session times to add", "Bookings on hold", "Fees to agree"])
        XCTAssertEqual(result.openCount(for: weekend.id), 1)
    }

    func testUnknownFeesGroupAndFlagTheOneHoldingUpAnInvoice() {
        let unknown = EventFeeFact.value(FeeValue(currency: "EUR"))
        let worked = job("IRSC: R3", status: "completed", start: "2026-10-14", fee: unknown)
        let today = job("Veterans Race", start: "2026-10-15", fee: unknown)
        let tomorrow = job("R1 Finals", start: "2026-10-16", fee: unknown)
        let result = summary([tomorrow, today, worked])
        XCTAssertEqual(result.settleGroups.count, 1)
        XCTAssertEqual(result.settleGroups.first?.phrase, "3 fees to agree")
        XCTAssertEqual(result.categorySummary, "3 fees to agree · 1 holding up an invoice")
        XCTAssertEqual(result.items.map(\.detail), ["Worked · blocks invoicing", "Booked · today", "Booked · tomorrow"])
        XCTAssertEqual(result.items.map(\.blocksInvoicing), [true, false, false])
        XCTAssertEqual(result.items.first?.standaloneDetail, "No fee yet · Worked · blocks invoicing")
    }

    func testInvoicingAndReceiptsAreLeftToOtherPages() {
        let ready = job("Ready", status: "completed", start: "2026-10-10")
        let draft = job("Drafted", status: "completed", start: "2026-10-10", billing: .draft(invoiceID: UUID()))
        let billing = EventBillingFact.sent(invoiceID: UUID(), reference: "INV-1", currency: "EUR", total: 1_000, balance: 500, dueDay: "2026-10-01", otherEvents: 0)
        let owed = job("Paid late", status: "completed", start: "2026-09-10", billing: billing)
        let review = job("Review", status: "completed", start: "2026-10-10", billing: .review(message: "Check", invoiceID: nil))
        XCTAssertTrue(summary([ready, draft, owed, review]).items.isEmpty)
    }

    func testDistantScheduleGapsWaitButMoneyDoesNot() {
        let distant = job("Season finale", status: "tentative", start: "2027-03-01", sessions: [session("Race", day: "2027-03-01")])
        XCTAssertTrue(summary([distant]).items.isEmpty)
        let unknownFee = job("Season finale", start: "2027-03-01", fee: .value(FeeValue(currency: "EUR")))
        XCTAssertEqual(summary([unknownFee]).items.map(\.item.kind), [.feeUnknown])
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
