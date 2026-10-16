import CoreData
import XCTest
@testable import Cuekeeper

final class EventDetailSummaryTests: XCTestCase {
    private let london = TimeZone(identifier: "Europe/London")!
    private let newYork = TimeZone(identifier: "America/New_York")!
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    /// Thursday before a Friday–Sunday weekend.
    private var now: Date { date("2026-10-15T12:00:00Z") }

    private func session(_ title: String, day: String, start: String? = nil, end: String? = nil, call: String? = nil,
                         confirmed: Bool = true, coverage: String = "covering") -> EventSessionFact {
        EventSessionFact(id: UUID(), title: title, day: day, start: start.map(date), end: end.map(date), call: call.map(date),
                         confirmed: confirmed, coverage: coverage)
    }
    private func facts(status: String = "booked", client: Bool = true, sessions: [EventSessionFact] = [],
                       fee: EventFeeFact = .value(FeeValue(amount: 180_000, currency: "EUR", agreement: "agreed")),
                       billing: EventBillingFact = .notInvoiced, expenses: [EventExpenseFact] = [],
                       workZone: TimeZone? = nil, start: String = "2026-10-16", end: String = "2026-10-18") -> EventDetailFacts {
        EventDetailFacts(bookingStatus: status, hasClient: client, startDay: start, endDay: end, eventZone: london,
                         workZone: workZone, sessions: sessions, fee: fee, billing: billing, expenseDrafts: expenses)
    }
    private func kinds(_ facts: EventDetailFacts, at time: Date? = nil) -> [OpenItem.Kind] {
        EventDetailSummary(facts: facts, now: time ?? now).openItems.map(\.kind)
    }

    // MARK: Schedule

    func testDaysGroupByEventDayInTimeOrderWithUndatedSessionsLast() {
        let race = session("Race", day: "2026-10-18", start: "2026-10-18T13:00:00Z")
        let sprint = session("Sprint", day: "2026-10-17", start: "2026-10-17T15:30:00Z")
        let qualifying = session("Qualifying", day: "2026-10-17", start: "2026-10-17T13:00:00Z", coverage: "notCovering")
        let undated = session("Feature", day: "")
        let summary = EventDetailSummary(facts: facts(sessions: [undated, race, sprint, qualifying]), now: now)
        XCTAssertEqual(summary.days.map(\.key), ["2026-10-17", "2026-10-18", ""])
        XCTAssertEqual(summary.days[0].sessions.map(\.title), ["Qualifying", "Sprint"])
        XCTAssertEqual(summary.days[0].coveringCount, 1)
    }

    func testOvernightSessionStaysOnItsStartingEventDay() {
        // 23:30–01:30 London: the adapter supplies the event-zone start day.
        let overnight = session("Night race", day: "2026-10-17", start: "2026-10-17T22:30:00Z", end: "2026-10-18T00:30:00Z")
        let summary = EventDetailSummary(facts: facts(sessions: [overnight]), now: now)
        XCTAssertEqual(summary.days.map(\.key), ["2026-10-17"])
    }

    func testNextCallUsesCallTimeWithinSevenDaysAndSkipsNotCovering() {
        let skipped = session("Practice 2", day: "2026-10-16", start: "2026-10-16T14:00:00Z", call: "2026-10-16T13:00:00Z", coverage: "notCovering")
        let practice = session("Practice 1", day: "2026-10-16", start: "2026-10-16T10:30:00Z", call: "2026-10-16T09:30:00Z")
        let summary = EventDetailSummary(facts: facts(sessions: [skipped, practice]), now: now)
        XCTAssertEqual(summary.nextCall?.session.title, "Practice 1")
        XCTAssertEqual(summary.nextCall?.at, date("2026-10-16T09:30:00Z"))
        XCTAssertEqual(summary.nextCall?.isCallTime, true)
    }

    func testNextCallFallsBackToStartAndRespectsTheHeroWindow() {
        let race = session("Race", day: "2026-10-18", start: "2026-10-18T13:00:00Z")
        XCTAssertEqual(EventDetailSummary(facts: facts(sessions: [race]), now: now).nextCall?.isCallTime, false)
        let eightDaysBefore = date("2026-10-10T12:00:00Z")
        XCTAssertNil(EventDetailSummary(facts: facts(sessions: [race]), now: eightDaysBefore).nextCall)
        let started = date("2026-10-18T13:05:00Z")
        XCTAssertNil(EventDetailSummary(facts: facts(sessions: [race]), now: started).nextCall)
        XCTAssertNil(EventDetailSummary(facts: facts(status: "cancelled", sessions: [race]), now: now).nextCall)
    }

    func testRemoteWorkOffersYourTimeFirstAndOnSiteUsesTrackTime() {
        let remote = EventDetailSummary(facts: facts(workZone: newYork), now: now)
        XCTAssertTrue(remote.offersTimeChoice)
        XCTAssertEqual(remote.defaultTimeChoice, .yours)
        XCTAssertEqual(remote.zone(for: .yours), newYork)
        XCTAssertEqual(remote.zone(for: .track), london)

        let sameZone = EventDetailSummary(facts: facts(workZone: london), now: now)
        XCTAssertFalse(sameZone.offersTimeChoice)
        XCTAssertEqual(sameZone.defaultTimeChoice, .track)

        let onSite = EventDetailSummary(facts: facts(), now: now)
        XCTAssertFalse(onSite.offersTimeChoice)
        XCTAssertEqual(onSite.zone(for: .yours), london)
    }

    // MARK: Open items

    func testSettledUpcomingEventHasNoOpenItems() {
        let race = session("Race", day: "2026-10-18", start: "2026-10-18T13:00:00Z")
        let summary = EventDetailSummary(facts: facts(sessions: [race]), now: now)
        XCTAssertTrue(summary.openItems.isEmpty)
        XCTAssertEqual(summary.defaultTab, .schedule)
        XCTAssertEqual(summary.count(in: .money), 0)
    }

    func testTentativeBookingAsksToConfirmUntilTheEventIsPast() {
        XCTAssertEqual(kinds(facts(status: "tentative")), [.tentativeBooking])
        XCTAssertEqual(EventDetailSummary(facts: facts(status: "tentative"), now: now).openItems.first?.action, .markBooked)
        XCTAssertEqual(kinds(facts(status: "tentative"), at: date("2026-10-19T12:00:00Z")), [])
    }

    func testEachSessionRaisesOnlyItsMostFundamentalGap() {
        let noTime = session("Sprint", day: "2026-10-17", coverage: "undecided")
        let unconfirmed = session("Qualifying", day: "2026-10-17", start: "2026-10-17T13:00:00Z", confirmed: false, coverage: "undecided")
        let undecided = session("Race", day: "2026-10-18", start: "2026-10-18T13:00:00Z", coverage: "undecided")
        let skipped = session("Practice 2", day: "2026-10-16", coverage: "notCovering")
        let summary = EventDetailSummary(facts: facts(sessions: [undecided, skipped, noTime, unconfirmed]), now: now)
        XCTAssertEqual(summary.openItems.map(\.kind), [.sessionConfirmation, .sessionTime, .sessionCoverage])
        XCTAssertEqual(summary.openItems[1].title, "Sprint has no time")
        XCTAssertTrue(summary.openItems[1].detail?.hasSuffix("coverage undecided") == true)
        XCTAssertEqual(summary.openItems[1].action, .editSession(noTime.id))
        XCTAssertTrue(summary.openItems.allSatisfy { $0.tab == .schedule })
        XCTAssertEqual(summary.count(in: .schedule), 3)
    }

    func testSessionGapsStopOnceTheEventIsCompleted() {
        let noTime = session("Sprint", day: "2026-10-17")
        XCTAssertEqual(kinds(facts(status: "completed", sessions: [noTime])), [.readyToInvoice])
    }

    func testMissingClientBelongsToDetails() {
        let summary = EventDetailSummary(facts: facts(client: false), now: now)
        XCTAssertEqual(summary.openItems.map(\.kind), [.clientMissing])
        XCTAssertEqual(summary.openItems.first?.tab, .details)
        XCTAssertEqual(summary.openItems.first?.action, .editEvent)
    }

    func testUnknownFeeDiffersFromZeroFee() {
        let unknown = EventFeeFact.value(FeeValue(amount: nil, currency: "EUR"))
        let zero = EventFeeFact.value(FeeValue(amount: 0, currency: "EUR", agreement: "agreed"))
        XCTAssertEqual(kinds(facts(fee: unknown)), [.feeUnknown])
        XCTAssertEqual(kinds(facts(fee: zero)), [])
        XCTAssertEqual(kinds(facts(status: "tentative", fee: unknown)), [.tentativeBooking])
        XCTAssertEqual(kinds(facts(fee: .conflict)), [.feeConflict])
    }

    func testCompletedEventIsReadyToInvoiceOnlyWithClientAndKnownFee() {
        let completed = EventDetailSummary(facts: facts(status: "completed"), now: date("2026-11-03T12:00:00Z"))
        XCTAssertEqual(completed.openItems.map(\.kind), [.readyToInvoice])
        XCTAssertEqual(completed.openItems.first?.action, .addToInvoice)
        XCTAssertEqual(completed.defaultTab, .money)
        XCTAssertEqual(kinds(facts(status: "completed", client: false)), [.clientMissing])
        XCTAssertEqual(kinds(facts(status: "completed", billing: .directPayments(paid: 180_000, currency: "EUR"))), [])
    }

    func testSingleInvoiceBalanceDrawsAProgressBar() {
        let invoice = UUID()
        let billing = EventBillingFact.sent(invoiceID: invoice, reference: "INV-0412", currency: "EUR", total: 180_000, balance: 90_000, dueDay: "2026-11-19", otherEvents: 0)
        let summary = EventDetailSummary(facts: facts(status: "completed", billing: billing), now: date("2026-11-03T12:00:00Z"))
        XCTAssertEqual(summary.openItems.map(\.kind), [.balanceOwed])
        XCTAssertEqual(summary.openItems.first?.action, .openInvoice(invoice))
        XCTAssertTrue(summary.openItems.first?.detail?.hasPrefix("INV-0412 · due ") == true)
        XCTAssertEqual(summary.invoiceProgress, .single(total: 180_000, paid: 90_000, currency: "EUR"))
    }

    func testGroupedInvoiceNeverSplitsReceiptsPerEvent() {
        let billing = EventBillingFact.sent(invoiceID: UUID(), reference: "INV-0412", currency: "EUR", total: 300_000, balance: 90_000, dueDay: "", otherEvents: 2)
        let summary = EventDetailSummary(facts: facts(status: "completed", billing: billing), now: date("2026-11-03T12:00:00Z"))
        XCTAssertEqual(summary.invoiceProgress, .shared(reference: "INV-0412", otherEvents: 2, total: 300_000, balance: 90_000, currency: "EUR"))
        XCTAssertTrue(summary.openItems.first?.title.hasSuffix("owed on INV-0412") == true)
        XCTAssertEqual(summary.openItems.first?.detail, "Shared with 2 other events")
    }

    func testPaidDraftAndReviewBillingStates() {
        let paid = EventBillingFact.sent(invoiceID: UUID(), reference: "INV-1", currency: "USD", total: 50_000, balance: 0, dueDay: "", otherEvents: 0)
        XCTAssertEqual(kinds(facts(status: "completed", billing: paid)), [])
        let draft = UUID()
        let drafted = EventDetailSummary(facts: facts(status: "completed", billing: .draft(invoiceID: draft)), now: now)
        XCTAssertEqual(drafted.openItems.map(\.action), [.openInvoice(draft)])
        XCTAssertEqual(drafted.invoiceProgress, .draft)
        XCTAssertEqual(kinds(facts(billing: .review(message: "Duplicate", invoiceID: nil))), [.billingReview])
    }

    func testExpenseDraftsAreReviewItemsInMoney() {
        let receipt = EventExpenseFact(id: UUID(), merchant: "Fuel, Towcester", amount: 3_840, currency: "EUR")
        let blank = EventExpenseFact(id: UUID(), merchant: "", amount: nil, currency: "")
        let summary = EventDetailSummary(facts: facts(expenses: [receipt, blank]), now: now)
        XCTAssertEqual(summary.openItems.map(\.action), [.reviewExpense(receipt.id), .reviewExpense(blank.id)])
        XCTAssertTrue(summary.openItems[0].detail?.hasPrefix("Fuel, Towcester · ") == true)
        XCTAssertEqual(summary.openItems[1].detail, "Details to confirm")
        XCTAssertEqual(summary.count(in: .money), 2)
    }

    func testCancelledEventKeepsOnlyMoneyItems() {
        let noTime = session("Sprint", day: "2026-10-17")
        let receipt = EventExpenseFact(id: UUID(), merchant: "Hotel", amount: 12_000, currency: "EUR")
        let summary = EventDetailSummary(facts: facts(status: "cancelled", client: false, sessions: [noTime], fee: .conflict, expenses: [receipt]), now: now)
        XCTAssertEqual(summary.openItems.map(\.kind), [.feeConflict, .expenseDraft])
        XCTAssertEqual(summary.defaultTab, .money)
    }

    func testItemsFollowTheBriefOrder() {
        let noTime = session("Sprint", day: "2026-10-17")
        let receipt = EventExpenseFact(id: UUID(), merchant: "Parking", amount: 2_580, currency: "EUR")
        let all = facts(status: "tentative", client: false, sessions: [noTime], fee: .conflict,
                        billing: .review(message: "Duplicate", invoiceID: nil), expenses: [receipt])
        XCTAssertEqual(kinds(all), [.tentativeBooking, .sessionTime, .clientMissing, .feeConflict, .billingReview, .expenseDraft])
    }
}

@MainActor
final class EventDetailFactsTests: XCTestCase {
    func testReadsSessionsFeeAndBillingFromAJob() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = PersistenceController(storeURL: folder.appendingPathComponent("test.sqlite"), cloudEnabled: false)
        try await store.waitUntilLoaded()
        defer {
            store.container.viewContext.reset()
            for persistent in store.container.persistentStoreCoordinator.persistentStores { try? store.container.persistentStoreCoordinator.remove(persistent) }
            try? FileManager.default.removeItem(at: folder)
        }
        let context = store.container.viewContext
        var draft = JobDraft(name: "Silverstone weekend", startDate: ISO8601DateFormatter().date(from: "2026-10-16T12:00:00Z")!,
                             endDate: ISO8601DateFormatter().date(from: "2026-10-18T12:00:00Z")!)
        draft.timeZoneID = "Europe/London"
        draft.bookingStatus = .booked
        let id = try draft.save(in: context)
        let job = try XCTUnwrap(context.existingObject(with: id) as? Job)

        var row = SessionDraft(job: job)
        row.name = "Race"
        row.scheduleStatus = "tentative"
        row.coverage = "covering"
        row.startTime = ISO8601DateFormatter().date(from: "2026-10-18T22:30:00Z")
        row.endTime = ISO8601DateFormatter().date(from: "2026-10-19T00:30:00Z")
        try row.save(in: context, jobID: id)
        context.refreshAllObjects()

        let facts = EventDetailFacts(job: job, context: context)
        XCTAssertEqual(facts.bookingStatus, "booked")
        XCTAssertFalse(facts.hasClient)
        XCTAssertNil(facts.workZone)
        XCTAssertEqual(facts.sessions.map(\.title), ["Race"])
        XCTAssertEqual(facts.sessions.first?.day, "2026-10-18", "Overnight session keeps its London start day")
        XCTAssertEqual(facts.sessions.first?.confirmed, false)
        XCTAssertEqual(facts.billing, .notInvoiced)
        XCTAssertTrue(facts.expenseDrafts.isEmpty)
        if case .value(let fee) = facts.fee { XCTAssertNil(fee.amount) } else { XCTFail("Expected an unknown fee, got \(facts.fee)") }
    }
}
