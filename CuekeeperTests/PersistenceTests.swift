import CoreData
import XCTest
@testable import Cuekeeper

@MainActor
final class PersistenceTests: XCTestCase {
    private var directory: URL!
    private var openedStores: [PersistenceController] = []
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        for controller in openedStores {
            controller.container.viewContext.reset()
            for store in controller.container.persistentStoreCoordinator.persistentStores {
                try controller.container.persistentStoreCoordinator.remove(store)
            }
        }
        openedStores.removeAll()
        try FileManager.default.removeItem(at: directory)
    }

    private func openStore(fileName: String = "test.sqlite") async throws -> PersistenceController {
        let store = PersistenceController(storeURL: directory.appending(path: fileName), cloudEnabled: false)
        for _ in 0..<100 {
            if store.isLoaded { openedStores.append(store); return store }
            if let error = store.loadError { throw NSError(domain: error, code: 1) }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "Store timed out", code: 2)
    }

    func testDeletingInvoicedJobKeepsInvoiceAndPaymentHistory() async throws {
        let store = try await openStore(); let context = store.container.viewContext
        var draft = JobDraft(name: "Invoiced event")
        draft.clientName = "Client"; draft.fee?.amount = "100"
        let id = try draft.save(in: context)
        let job = try XCTUnwrap(context.existingObject(with: id) as? Job)
        var draftInvoice = InvoiceDraft(clientID: job.client!.id!, currency: "USD")
        draftInvoice.value.status = "sent"; draftInvoice.value.reference = "INV-DELETE"
        draftInvoice.value.sentDay = Day.string(from: Date())
        draftInvoice.value.lines = [BilledLine(jobID: job.id!, jobName: job.displayName, amount: 10000)]
        let invoiceID = try draftInvoice.save(in: context)
        try PaymentDraft(amount: "25").save(in: context, invoiceID: invoiceID)
        try Job.remove(id, in: context)
        let invoice = try XCTUnwrap(context.existingObject(with: invoiceID) as? Invoice)
        XCTAssertEqual(try invoice.currentValue(), draftInvoice.value)
        XCTAssertEqual(try invoice.balance(), 7500)
        XCTAssertEqual(try invoice.paid(), 2500)
        XCTAssertNil(invoice.issue(in: context))
    }

    func testDeletingJobHidesItAndRetiresCalendarEntriesWhileKeepingPayments() async throws {
        let store = try await openStore()
        let context = store.container.viewContext
        var draft = JobDraft(name: "Delete me")
        draft.clientName = "Client"
        draft.bookingStatus = .booked
        draft.fee?.amount = "100"
        let id = try draft.save(in: context)
        let job = try XCTUnwrap(context.existingObject(with: id) as? Job)
        var session = SessionDraft(day: job.startDay, timeZoneID: "Europe/London")
        session.startTime = Date(); session.endTime = Date().addingTimeInterval(3600)
        session.scheduleStatus = "confirmed"; session.coverage = "covering"
        try session.save(in: context, jobID: id)
        try PaymentDraft(amount: "50").save(in: context, jobID: id)
        let before = CalendarPlan(jobs: [job])
        XCTAssertEqual(before.desired.count, 2)
        let baseline = JobDraft(job: job)
        try Job.remove(id, in: context)
        XCTAssertNotNil(job.deletedAt)
        XCTAssertFalse(JobFilter().includes(job))
        XCTAssertEqual(try job.directPaid(), 5000)
        XCTAssertEqual(job.client?.name, "Client")
        let after = CalendarPlan(jobs: [job])
        XCTAssertTrue(after.desired.isEmpty)
        XCTAssertEqual(after.knownKeys, before.knownKeys)
        XCTAssertEqual(after.bounds, before.bounds)
        let request = NSFetchRequest<Job>(entityName: "Job")
        request.predicate = NSPredicate(format: "deletedAt == nil")
        XCTAssertTrue(try context.fetch(request).isEmpty)
        XCTAssertThrowsError(try baseline.save(in: context, editing: id, baseline: baseline))
        XCTAssertThrowsError(try session.save(in: context, jobID: id))
        context.reset()
        let reloaded = try XCTUnwrap(context.existingObject(with: id) as? Job)
        XCTAssertNotNil(reloaded.deletedAt)
        XCTAssertEqual(try reloaded.directPaid(), 5000)
    }

    func testEventTimezoneControlsSessionsAndRemoteDisplayWithoutMovingInstants() async throws {
        let store = try await openStore(); let context = store.container.viewContext
        var creation = EventCreationDraft()
        creation.events[0].timeZoneID = "Europe/London"
        creation.shared.clientName = "Broadcast"
        creation.shared.workArrangement = .remote
        creation.shared.timeZoneID = "America/New_York"
        let formatter = ISO8601DateFormatter()
        let start = try XCTUnwrap(formatter.date(from: "2026-10-15T00:30:00Z"))
        var draft = SessionDraft(day: "2026-10-15", timeZoneID: "Asia/Tokyo")
        draft.startTime = start; draft.endTime = start.addingTimeInterval(3600)
        draft.callTime = start.addingTimeInterval(-1800)
        draft.scheduleStatus = "confirmed"; draft.coverage = "covering"
        creation.events[0].sessions = [draft]
        let id = try XCTUnwrap(creation.save(in: context).first)
        let job = try XCTUnwrap(context.existingObject(with: id) as? Job)
        let session = try XCTUnwrap(job.activeSessions.first)
        XCTAssertEqual(session.eventTimeZoneID, "Europe/London")
        XCTAssertEqual(job.workTimeZoneID, "America/New_York")
        XCTAssertTrue(session.localScheduleDescription?.contains("America/New York") == true)
        XCTAssertEqual(session.startTime, start)
        // A stale session editor cannot reinstate a per-session timezone.
        let baseline = SessionDraft(session: session)
        var changed = baseline; changed.timeZoneID = "Asia/Tokyo"; changed.notes = "Updated"
        try changed.save(in: context, jobID: id, editing: session.objectID, baseline: baseline)
        XCTAssertEqual(session.timeZoneID, "Europe/London")
        let original = EventDraft(anchor: job)
        var event = original; event.timeZoneID = "America/Los_Angeles"
        try event.save(in: context, anchorID: id, baseline: original)
        XCTAssertEqual(session.startTime, start)
        XCTAssertEqual(session.endTime, draft.endTime)
        XCTAssertEqual(session.callTime, draft.callTime)
        XCTAssertEqual(session.day, "2026-10-14")
        XCTAssertEqual(session.eventTimeZoneID, "America/Los_Angeles")
        let entry = try XCTUnwrap(CalendarPlan(jobs: [job]).desired.values.first { !$0.allDay })
        XCTAssertEqual(entry.timeZoneID, "America/Los_Angeles"); XCTAssertEqual(entry.start, start)
        var cleared = EventDraft(anchor: job); cleared.timeZoneID = ""
        XCTAssertThrowsError(try cleared.save(in: context, anchorID: id))
        for arrangement in [WorkArrangement.hybrid, .onSite, .remote] {
            let before = JobDraft(job: job); var work = before; work.workArrangement = arrangement
            try work.save(in: context, editing: id, baseline: before)
            XCTAssertEqual(job.workTimeZoneID, arrangement == .onSite ? "America/Los_Angeles" : "America/New_York")
            XCTAssertEqual(session.localScheduleDescription == nil, arrangement == .onSite)
            XCTAssertEqual(session.startTime, start)
        }
        let reopened = try await openStore()
        let restored = try XCTUnwrap(reopened.container.viewContext.existingObject(with: id) as? Job)
        XCTAssertEqual(restored.eventTimeZoneID, "America/Los_Angeles")
        XCTAssertEqual(restored.activeSessions.first?.startTime, start)
    }

    func testLegacyCommonTimezoneBecomesEventDefaultAndMissingZoneRejectsTimes() async throws {
        let store = try await openStore(); let context = store.container.viewContext
        var booking = JobDraft(); booking.clientName = "Legacy"
        let id = try booking.save(in: context)
        let job = try XCTUnwrap(context.existingObject(with: id) as? Job)
        let legacy = WorkSession(entity: NSEntityDescription.entity(forEntityName: "WorkSession", in: context)!, insertInto: context)
        legacy.id = UUID(); legacy.job = job; legacy.timeZoneID = "Europe/London"
        try context.save()
        XCTAssertEqual(job.eventTimeZoneID, "Europe/London")
        XCTAssertEqual(SessionDraft(job: job).timeZoneID, "Europe/London")
        let event = EventDraft(anchor: job)
        try event.save(in: context, anchorID: id)
        XCTAssertEqual(job.event?.timeZoneID, "Europe/London")
        var creation = EventCreationDraft(); creation.shared.clientName = "No zone"
        var session = SessionDraft(day: "2026-10-14", timeZoneID: "Asia/Tokyo")
        session.startTime = Date(); creation.events[0].sessions = [session]
        XCTAssertThrowsError(try creation.save(in: context))
        XCTAssertEqual(try context.count(for: NSFetchRequest<Job>(entityName: "Job")), 1)
    }

    func testCopiesUseDestinationEventTimezoneAndRejectDSTGapAtomically() throws {
        var draft = EventCreationDraft()
        draft.events[0].timeZoneID = "Europe/London"
        draft.events[0].details.startDate = Day.date(from: "2026-03-01")!
        var session = SessionDraft(day: "2026-03-01", timeZoneID: "Europe/London")
        session.startTime = ISO8601DateFormatter().date(from: "2026-03-01T02:30:00Z")
        session.endTime = session.startTime!.addingTimeInterval(3600)
        draft.events[0].sessions = [session]
        var target = EventOutline(); target.timeZoneID = "America/New_York"
        target.details.startDate = Day.date(from: "2026-03-08")!
        draft.events.append(target)
        XCTAssertThrowsError(try draft.copySessions(from: draft.events[0].id, to: [target.id], includingTimes: true))
        XCTAssertTrue(draft.events[1].sessions.isEmpty)
        draft.events[1].details.startDate = Day.date(from: "2026-03-15")!
        try draft.copySessions(from: draft.events[0].id, to: [target.id], includingTimes: true)
        XCTAssertEqual(draft.events[1].sessions[0].timeZoneID, "America/New_York")
        XCTAssertEqual(draft.events[1].sessions[0].startTime, ISO8601DateFormatter().date(from: "2026-03-15T06:30:00Z"))
    }

    func testSingleClientEventRejectsAdditionalClientsAndLinksAtomically() async throws {
        let store = try await openStore(); let context = store.container.viewContext
        var first = JobDraft(); first.clientName = "Original"
        let id = try EventDraft().save(in: context, firstBooking: first)
        let anchor = try context.existingObject(with: id) as! Job
        let baseline = EventDraft(anchor: anchor)
        var edited = baseline; edited.title = "Must not save"
        var added = JobDraft(); added.clientName = "New client"
        XCTAssertThrowsError(try edited.save(in: context, anchorID: id, baseline: baseline, newBookings: [added]))
        XCTAssertThrowsError(try added.saveBooking(in: context, anchorID: id))
        let otherID = try EventDraft().save(in: context, firstBooking: added)
        XCTAssertThrowsError(try EventDraft.attach(otherID, to: id, in: context))
        context.refreshAllObjects()
        XCTAssertEqual(anchor.event?.title, baseline.title)
        XCTAssertEqual(anchor.eventBookings.count, 1)
        XCTAssertEqual(try context.count(for: NSFetchRequest<Job>(entityName: "Job")), 2)
    }

    /// Build a pre-existing grouped record without calling production creation APIs.
    private func legacyClient(_ draft: JobDraft, anchor: Job, in context: NSManagedObjectContext) throws -> NSManagedObjectID {
        let id = try draft.save(in: context)
        let job = try context.existingObject(with: id) as! Job
        if anchor.event == nil { try EventDraft(anchor: anchor).save(in: context, anchorID: anchor.objectID) }
        anchor.event!.id = UUID() // historical groups did not use a job-owned ID
        job.event = anchor.event
        try context.save()
        return id
    }

    func testUnifiedEventEditSavesBookingsProjectsAndFeeHistoryAtomically() async throws {
        let store = try await openStore()
        let context = store.container.viewContext
        var first = JobDraft(); first.clientName = "First client"
        let id = try EventDraft().save(in: context, firstBooking: first)
        let anchor = try context.existingObject(with: id) as! Job
        let baseline = EventDraft(anchor: anchor)
        var event = baseline; event.location = "New venue"
        var entries = anchor.eventBookings.map(EventBookingDraft.init(job:))
        let index = try XCTUnwrap(entries.firstIndex { $0.id == id })
        let priorRevisions = anchor.feeRevisions?.count ?? 0
        entries[index].draft.projectName = "New project"
        entries[index].draft.fee?.amount = "1250"
        entries[index].newRole = "Producer"
        entries[index].draft.fee?.amount = "invalid"
        XCTAssertThrowsError(try event.save(in: context, anchorID: id, baseline: baseline, bookings: entries))
        context.refreshAllObjects()
        XCTAssertEqual(anchor.eventLocation, baseline.location)
        XCTAssertNil(anchor.project)
        XCTAssertEqual(anchor.feeRevisions?.count ?? 0, priorRevisions)
        entries[index].draft.fee?.amount = "1250"
        try event.save(in: context, anchorID: id, baseline: baseline, bookings: entries)
        XCTAssertEqual(anchor.eventLocation, "New venue")
        XCTAssertEqual(anchor.project?.name, "New project")
        XCTAssertTrue(anchor.roleNames.contains("Producer"))
        XCTAssertEqual(try anchor.currentFee().amount, 125000)
        XCTAssertEqual(anchor.feeRevisions?.count ?? 0, priorRevisions + 1)
        XCTAssertEqual(anchor.eventBookings.count, 1)
        let fresh = EventDraft(anchor: anchor)
        let unchanged = anchor.eventBookings.map(EventBookingDraft.init(job:))
        try fresh.save(in: context, anchorID: id, baseline: fresh, bookings: unchanged)
        XCTAssertEqual(anchor.feeRevisions?.count ?? 0, priorRevisions + 1)
    }

    func testSiriCreatesOnceAndEnrichmentEditsSameEvent() async throws {
        let store = try await openStore()
        let context = store.container.viewContext
        let start = Day.date(from: "2026-11-06")!
        let draft = try SiriEventDraft.make(title: "IMSA esports", start: start, end: nil, allDay: true,
                                           location: "Remote", notes: "Production briefing")
        let handoff = EventEditorHandoff()
        let id = try handoff.create(draft, in: context)
        let request = try XCTUnwrap(handoff.pending)
        XCTAssertEqual(request.jobID, id)
        let job = try XCTUnwrap(context.existingObject(with: id) as? Job)
        let eventID = try XCTUnwrap(job.event?.objectID)
        XCTAssertEqual(job.eventTitle, "IMSA esports")
        XCTAssertEqual(job.eventNotes, "Production briefing")
        XCTAssertEqual(try context.count(for: NSFetchRequest<Job>(entityName: "Job")), 1)
        XCTAssertEqual(try context.count(for: NSFetchRequest<WorkEvent>(entityName: "WorkEvent")), 1)
        XCTAssertThrowsError(try handoff.create(draft, in: context))
        XCTAssertEqual(handoff.pending?.id, request.id)

        let original = JobDraft(job: job)
        var enriched = original
        enriched.clientName = "ESPN"; enriched.roleNames = ["Commentator"]
        let updated = try enriched.saveBooking(in: context, anchorID: id, editing: id, baseline: original)
        XCTAssertEqual(updated, id)
        let originalEvent = EventDraft(anchor: job)
        var eventEdit = originalEvent; eventEdit.location = "Studio"
        try eventEdit.save(in: context, anchorID: id, baseline: originalEvent)
        XCTAssertEqual(job.event?.objectID, eventID)
        XCTAssertEqual(job.client?.name, "ESPN")
        XCTAssertEqual(job.eventLocation, "Studio")
        handoff.close(id: request.id)
        XCTAssertNil(handoff.pending)
        XCTAssertEqual(try context.count(for: NSFetchRequest<Job>(entityName: "Job")), 1)
        XCTAssertEqual(try context.count(for: NSFetchRequest<WorkEvent>(entityName: "WorkEvent")), 1)
        let reopened = try await openStore()
        XCTAssertEqual(try reopened.container.viewContext.count(for: NSFetchRequest<WorkEvent>(entityName: "WorkEvent")), 1)
    }

    func testSiriClosingEditorKeepsBasicEventAndFailedSaveDoesNotRoute() async throws {
        let store = try await openStore()
        let context = store.container.viewContext
        let handoff = EventEditorHandoff()
        var invalid = EventCreationDraft()
        invalid.events[0].details.startDate = Day.date(from: "2026-11-08")!
        invalid.events[0].details.endDate = Day.date(from: "2026-11-06")!
        XCTAssertThrowsError(try handoff.create(invalid, in: context))
        XCTAssertNil(handoff.pending)
        XCTAssertEqual(try context.count(for: NSFetchRequest<WorkEvent>(entityName: "WorkEvent")), 0)
        let id = try handoff.create(EventCreationDraft(), in: context)
        let request = try XCTUnwrap(handoff.pending)
        handoff.close(id: request.id)
        let job = try XCTUnwrap(context.existingObject(with: id) as? Job)
        XCTAssertNotNil(job.event)
        XCTAssertEqual(try context.count(for: NSFetchRequest<WorkEvent>(entityName: "WorkEvent")), 1)
        XCTAssertEqual(try context.count(for: NSFetchRequest<Job>(entityName: "Job")), 1)
    }

    func testSiriDateMappingAcrossDSTAndTimedSessions() throws {
        let zone = TimeZone(identifier: "America/New_York")!
        let start = Day.date(from: "2026-10-31", timeZone: zone)!
        let end = Day.date(from: "2026-11-03", timeZone: zone)!
        let allDay = try SiriEventDraft.make(title: "Weekend", start: start, end: end, allDay: true, timeZone: zone)
        XCTAssertEqual(Day.string(from: allDay.events[0].details.startDate), "2026-10-31")
        XCTAssertEqual(Day.string(from: allDay.events[0].details.endDate), "2026-11-02")
        let timedStart = start.addingTimeInterval(23 * 3600)
        let timedEnd = timedStart.addingTimeInterval(4 * 3600)
        let timed = try SiriEventDraft.make(title: "Overnight", start: timedStart, end: timedEnd, allDay: false, timeZone: zone)
        let session = try XCTUnwrap(timed.events[0].sessions.first)
        XCTAssertEqual(session.startTime, timedStart)
        XCTAssertEqual(session.endTime, timedEnd)
        XCTAssertEqual(session.timeZoneID, zone.identifier)
        XCTAssertEqual(session.scheduleStatus, "tentative")
        XCTAssertEqual(session.coverage, "undecided")
        XCTAssertEqual(Day.string(from: timed.events[0].details.endDate), "2026-11-01")
        let incomplete = try SiriEventDraft.make(title: "Call", start: timedStart, end: nil, allDay: false)
        XCTAssertNil(incomplete.events[0].sessions.first?.endTime)
        XCTAssertThrowsError(try SiriEventDraft.make(title: "Invalid", start: end, end: start, allDay: true))
    }

    func testEventClientsKeepIndependentBillingAndSurviveReopen() async throws {
        let store = try await openStore(); let context = store.container.viewContext
        var event = EventDraft(); event.location = "Silverstone"; event.timeZoneID = "Europe/London"
        var first = JobDraft(); first.clientName = "Client A"; first.fee?.amount = "500"
        let firstID = try event.save(in: context, firstBooking: first)
        let a = try XCTUnwrap(context.existingObject(with: firstID) as? Job)
        XCTAssertTrue(a.name.isEmpty); XCTAssertTrue(a.eventTitle.contains("Silverstone"))
        var second = JobDraft(); second.clientName = "Client B"; second.fee?.amount = "300"; second.fee?.currency = "EUR"
        let secondID = try legacyClient(second, anchor: a, in: context)
        let b = try XCTUnwrap(context.existingObject(with: secondID) as? Job)
        XCTAssertEqual(a.event, b.event); XCTAssertEqual(a.eventBookings.count, 1)
        XCTAssertEqual(try a.currentFee().amount, 50000); XCTAssertEqual(try b.currentFee().amount, 30000)
        XCTAssertEqual(try b.currentFee().currency, "EUR")
        var session = SessionDraft(job: a); session.name = "Qualifying"; session.overridesSeries = true; session.seriesName = "Series A"
        try session.save(in: context, jobID: firstID)
        session.name = "Race"; session.seriesName = "Series B"
        try session.save(in: context, jobID: secondID)
        XCTAssertEqual(a.eventSessions.count, 1)
        XCTAssertNotEqual(a.eventKey, b.eventKey)
        let plan = CalendarPlan(jobs: [a, b])
        XCTAssertEqual(plan.desired.values.filter(\.allDay).count, 2)
        XCTAssertTrue(plan.knownKeys.contains("job/\(a.id!.uuidString)"))
        XCTAssertTrue(plan.knownKeys.contains("job/\(b.id!.uuidString)"))
        var invoice = InvoiceDraft(clientID: a.client!.id!, currency: "USD")
        invoice.value.status = "sent"; invoice.value.reference = "EVENT-1"; invoice.value.sentDay = Day.string(from: Date())
        invoice.value.lines = [BilledLine(jobID: a.id!, jobName: a.displayName, amount: 50000)]
        let invoiceID = try invoice.save(in: context)
        try PaymentDraft(amount: "100").save(in: context, invoiceID: invoiceID)
        let feeCount = a.feeRevisions?.count
        let before = EventDraft(anchor: a); var edited = before; edited.location = "Brands Hatch"
        try edited.save(in: context, anchorID: firstID, baseline: before)
        XCTAssertEqual(b.eventLocation, "Silverstone")
        XCTAssertNotEqual(a.event, b.event); XCTAssertEqual(a.feeRevisions?.count, feeCount)
        let savedInvoice = try XCTUnwrap(context.existingObject(with: invoiceID) as? Invoice)
        XCTAssertEqual(try savedInvoice.currentValue().lines.first?.jobID, a.id)
        XCTAssertTrue(try savedInvoice.currentValue().lines.first!.jobName.contains("Silverstone"))
        let reopened = try await openStore()
        let all = try reopened.container.viewContext.fetch(NSFetchRequest<Job>(entityName: "Job"))
        XCTAssertEqual(all.count, 2); XCTAssertEqual(all.first?.eventBookings.count, 1)
        XCTAssertEqual(all.first(where: { $0.client?.name == "Client A" })?.eventLocation, "Brands Hatch")
        XCTAssertEqual(all.first(where: { $0.client?.name == "Client B" })?.eventLocation, "Silverstone")
    }

    func testSplittingLegacyRecordsPreservesIdentityHistoryAndCalendarCleanup() async throws {
        let store = try await openStore(); let context = store.container.viewContext
        let a = try billingJob("Original A", amount: "100", in: context)
        var other = JobDraft(); other.clientName = "B"; other.fee?.amount = "200"
        let id = try legacyClient(other, anchor: a, in: context)
        let b = try context.existingObject(with: id) as! Job
        let historicalID = try XCTUnwrap(a.event?.id)
        let originalID = b.id; let feeIDs = Set((b.feeRevisions ?? []).compactMap(\.id))
        let sessionID = try SessionDraft(job: b).save(in: context, jobID: b.objectID)
        try PaymentDraft(amount: "50").save(in: context, jobID: b.objectID)
        let baseline = EventDraft(anchor: b)
        var edit = baseline; edit.title = "Independent B"; edit.notes = "B notes"
        try edit.save(in: context, anchorID: b.objectID, baseline: baseline)
        XCTAssertNotEqual(a.event, b.event)
        XCTAssertEqual(b.id, originalID)
        XCTAssertEqual(Set((b.feeRevisions ?? []).compactMap(\.id)), feeIDs)
        XCTAssertEqual(b.activeSessions.first?.objectID, sessionID)
        XCTAssertEqual(try b.directPaid(), 5000)
        XCTAssertEqual(b.eventTitle, "Independent B")
        XCTAssertNotEqual(a.eventNotes, "B notes")
        try EventDraft(anchor: a).save(in: context, anchorID: a.objectID)
        let historical = try context.fetch(NSFetchRequest<WorkEvent>(entityName: "WorkEvent")).compactMap(\.id)
        let plan = CalendarPlan(jobs: [a, b], historicalEventIDs: historical)
        XCTAssertTrue(plan.knownKeys.contains("event/\(historicalID.uuidString)"))
        XCTAssertNil(plan.desired["event/\(historicalID.uuidString)"])
        XCTAssertEqual(plan.desired.values.filter(\.allDay).count, 2)
        // Reopening an old draft changes only edited fields on this client's record.
        var stale = baseline; stale.location = "B venue"
        try stale.save(in: context, anchorID: b.objectID, baseline: baseline)
        XCTAssertEqual(b.eventTitle, "Independent B")
        XCTAssertEqual(b.eventLocation, "B venue")
    }

    func testLegacyMetadataIsIsolatedEvenBeforeOtherClientsDownload() async throws {
        let store = try await openStore(); let context = store.container.viewContext
        var first = JobDraft(); first.clientName = "A"
        var details = EventDraft(); details.title = "Old weekend"; details.notes = "Shared briefing"
        let id = try details.save(in: context, firstBooking: first)
        let a = try context.existingObject(with: id) as! Job
        let historical = try XCTUnwrap(a.event)
        historical.id = UUID(); try context.save()
        // Only A has arrived on this device; cardinality alone cannot identify an old group.
        let baseline = EventDraft(anchor: a)
        var edited = baseline; edited.title = "A only"
        try edited.save(in: context, anchorID: id, baseline: baseline)
        XCTAssertNotEqual(a.event, historical)
        XCTAssertEqual(historical.title, "Old weekend")
        var next = JobDraft(); next.clientName = "B"
        let bID = try next.save(in: context)
        let b = try context.existingObject(with: bID) as! Job
        b.event = historical; try context.save()
        XCTAssertEqual(b.eventTitle, "Old weekend")
        XCTAssertEqual(b.eventNotes, "Shared briefing")
        XCTAssertEqual(a.eventTitle, "A only")
        XCTAssertEqual(a.eventNotes, "Shared briefing")
    }

    func testEventSaveIsAtomicAndConcurrentUnrelatedEditsSurvive() async throws {
        let store = try await openStore(); let context = store.container.viewContext
        var booking = JobDraft(); booking.clientName = "Client"; booking.fee?.amount = "invalid"
        XCTAssertThrowsError(try EventDraft().save(in: context, firstBooking: booking))
        XCTAssertEqual(try context.count(for: NSFetchRequest<WorkEvent>(entityName: "WorkEvent")), 0)
        XCTAssertEqual(try context.count(for: NSFetchRequest<Job>(entityName: "Job")), 0)
        XCTAssertEqual(try context.count(for: NSFetchRequest<Client>(entityName: "Client")), 0)
        booking.fee?.amount = "100"
        let id = try EventDraft().save(in: context, firstBooking: booking)
        let job = try XCTUnwrap(context.existingObject(with: id) as? Job)
        let initial = EventDraft(anchor: job)
        var first = initial; first.location = "New location"
        try first.save(in: context, anchorID: id, baseline: initial)
        var second = initial; second.notes = "New shared notes"
        try second.save(in: context, anchorID: id, baseline: initial)
        XCTAssertEqual(job.eventLocation, "New location"); XCTAssertEqual(job.eventNotes, "New shared notes")
    }

    func testSessionBatchMovesAcrossDSTAndRejectsOtherClientEvents() async throws {
        let store = try await openStore(); let context = store.container.viewContext
        var booking = JobDraft(); booking.clientName = "A"; booking.fee?.amount = "100"; booking.seriesName = "Inherited series"
        var event = EventDraft(); event.timeZoneID = "America/New_York"
        let aID = try event.save(in: context, firstBooking: booking)
        let a = try XCTUnwrap(context.existingObject(with: aID) as? Job)
        booking.clientName = "B"; booking.fee?.amount = "200"; booking.seriesName = "Other series"
        let bID = try EventDraft().save(in: context, firstBooking: booking)
        var draft = SessionDraft(job: a); draft.timeZoneID = "America/New_York"
        let zone = TimeZone(identifier: draft.timeZoneID)!
        draft.day = "2026-10-31"; draft.startTime = Day.date(from: draft.day, timeZone: zone)!.addingTimeInterval(12 * 3600)
        draft.endTime = draft.startTime!.addingTimeInterval(3600); draft.callTime = draft.startTime!.addingTimeInterval(-1800)
        draft.scheduleStatus = "confirmed"; draft.coverage = "covering"; draft.links = [LinkDraft(url: "https://example.com/feed")]
        let id = try draft.save(in: context, jobID: aID)
        XCTAssertThrowsError(try SessionBatchChange(day: "2026-11-01", bookingID: bID).save(ids: [id], anchorID: aID, in: context))
        try SessionBatchChange(day: "2026-11-01").save(ids: [id], anchorID: aID, in: context)
        let session = try XCTUnwrap(context.existingObject(with: id) as? WorkSession)
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        XCTAssertEqual(calendar.component(.hour, from: session.startTime!), 12)
        XCTAssertEqual(session.day, "2026-11-01"); XCTAssertEqual(session.job?.objectID, aID)
        XCTAssertEqual(session.effectiveSeries?.name, "Inherited series"); XCTAssertEqual(session.sortedLinks.count, 1)
        XCTAssertEqual(try a.currentFee().amount, 10000); XCTAssertEqual(try session.job?.currentFee().amount, 10000)
        let outsider = try billingJob("Elsewhere", amount: "1", in: context)
        XCTAssertThrowsError(try SessionBatchChange(series: "Changed", bookingID: outsider.objectID).save(ids: [id], anchorID: aID, in: context))
        XCTAssertEqual(session.effectiveSeries?.name, "Inherited series")
        XCTAssertEqual(CalendarPlan(jobs: [a, session.job!]).desired["session/\(session.id!.uuidString)"]?.location, a.eventLocation)
    }

    func testTrackSelectionSavesDuplicatesAndPreservesConcurrentChanges() async throws {
        let store = try await openStore(); let context = store.container.viewContext
        var draft = JobDraft(name: "Race weekend")
        draft.location = "Enter at gate 4"; draft.trackPlaceID = "track-one"
        let job = try XCTUnwrap(context.existingObject(with: draft.save(in: context)) as? Job)
        XCTAssertEqual(JobDraft(job: job).trackPlaceID, "track-one")
        XCTAssertEqual(JobDraft.duplicate(job).trackPlaceID, "track-one")
        let baseline = JobDraft(job: job)
        var trackEdit = baseline; trackEdit.trackPlaceID = "track-two"
        try trackEdit.save(in: context, editing: job.objectID, baseline: baseline)
        var notesEdit = baseline; notesEdit.notes = "New preparation"
        try notesEdit.save(in: context, editing: job.objectID, baseline: baseline)
        XCTAssertEqual(job.trackPlaceID, "track-two")
        XCTAssertEqual(job.location, "Enter at gate 4")
        let beforeClear = JobDraft(job: job)
        var cleared = beforeClear; cleared.trackPlaceID = ""
        try cleared.save(in: context, editing: job.objectID, baseline: beforeClear)
        XCTAssertEqual(job.trackPlaceID, "")
    }

    func testV8GroupedEventMigratesToV9AndAcceptsWizardSeries() async throws {
        let modelURL = try XCTUnwrap(Bundle(for: Job.self).url(forResource: "Cuekeeper", withExtension: "momd"))
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL.appending(path: "CuekeeperV8.mom")))
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let oldStore = try coordinator.addPersistentStore(type: .sqlite, at: directory.appending(path: "grouped-v8.sqlite"))
        let old = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType); old.persistentStoreCoordinator = coordinator
        let event = NSEntityDescription.insertNewObject(forEntityName: "WorkEvent", into: old)
        let eventID = UUID(); event.setValue(eventID, forKey: "id"); event.setValue("Existing weekend", forKey: "title")
        event.setValue("2026-11-01", forKey: "startDay"); event.setValue("2026-11-02", forKey: "endDay")
        event.setValue("track-123", forKey: "trackPlaceID")
        for name in ["A", "B"] {
            let booking = NSEntityDescription.insertNewObject(forEntityName: "Job", into: old)
            booking.setValue(UUID(), forKey: "id"); booking.setValue(name, forKey: "name"); booking.setValue(event, forKey: "event")
        }
        try old.save(); old.reset(); try coordinator.remove(oldStore)
        let migrated = try await openStore(fileName: "grouped-v8.sqlite"); let context = migrated.container.viewContext
        let jobs = try context.fetch(NSFetchRequest<Job>(entityName: "Job"))
        let first = try XCTUnwrap(jobs.first)
        XCTAssertEqual(jobs.count, 2); XCTAssertEqual(first.event?.id, eventID)
        XCTAssertEqual(first.eventBookings.count, 1); XCTAssertEqual(first.eventTrackPlaceID, "track-123")
        XCTAssertEqual(first.eventStartDay, "2026-11-01"); XCTAssertTrue(first.allSeries.isEmpty)
        var edit = JobDraft(job: first); let baseline = edit; edit.seriesNames = ["Main", "Support"]
        try edit.save(in: context, editing: first.objectID, baseline: baseline)
        XCTAssertEqual(first.eventSeriesNames, ["Main", "Support"])
        XCTAssertEqual(first.event?.id, eventID)
    }

    func testSeasonCreationIsAtomicAndReusesMultipleSeries() async throws {
        let store = try await openStore(); let context = store.container.viewContext
        var draft = EventCreationDraft()
        draft.shared.projectName = "Championship season"
        draft.shared.seriesNames = ["Main", "Support"]
        draft.shared.fee?.amount = "150"
        draft.events.append(EventOutline())
        draft.events[0].sessions = [SessionDraft(day: "2026-10-14")]
        var invalid = SessionDraft(day: "2026-10-15")
        invalid.scheduleStatus = "confirmed"
        draft.events[1].sessions = [invalid]
        XCTAssertThrowsError(try draft.save(in: context))
        XCTAssertEqual(try context.count(for: NSFetchRequest<Job>(entityName: "Job")), 0)
        XCTAssertEqual(try context.count(for: NSFetchRequest<WorkSeries>(entityName: "WorkSeries")), 0)
        XCTAssertEqual(try context.count(for: NSFetchRequest<WorkEvent>(entityName: "WorkEvent")), 0)
        draft.events[1].sessions = []
        let ids = try draft.save(in: context)
        let first = try XCTUnwrap(context.existingObject(with: ids[0]) as? Job)
        let second = try XCTUnwrap(context.existingObject(with: ids[1]) as? Job)
        XCTAssertEqual(Set(first.seriesNames), ["Main", "Support"])
        XCTAssertEqual(first.allSeries, second.allSeries)
        XCTAssertEqual(try first.currentFee().amount, 15000)
        XCTAssertEqual(first.activeSessions.count, 1)
        XCTAssertNil(first.activeSessions.first?.effectiveSeries)
        XCTAssertTrue(first.name.isEmpty)
        XCTAssertTrue(first.eventTitle.hasPrefix("Championship season"))
        XCTAssertNotNil(first.event); XCTAssertNotEqual(first.event, second.event)
        XCTAssertEqual(first.eventSeriesNames, ["Main", "Support"])
        XCTAssertEqual(CalendarPlan(jobs: [first, second]).desired.values.filter(\.allDay).count, 2)
        var filter = JobFilter(); filter.series = "Support"
        XCTAssertTrue(filter.includes(first))
        var edit = JobDraft(job: first); let baseline = edit
        edit.seriesNames = ["Support"]
        try edit.save(in: context, editing: first.objectID, baseline: baseline)
        XCTAssertEqual(first.seriesNames, ["Support"])
        XCTAssertEqual(second.seriesNames.count, 2)
    }

    func testWizardPaymentFailureRollsBackAndValidReceiptPersists() async throws {
        let store = try await openStore(); let context = store.container.viewContext
        var draft = EventCreationDraft()
        draft.shared.fee?.amount = "200"
        draft.payment.amount = "-1"
        XCTAssertThrowsError(try draft.save(in: context))
        XCTAssertEqual(try context.count(for: NSFetchRequest<Job>(entityName: "Job")), 0)
        XCTAssertEqual(try context.count(for: NSFetchRequest<PaymentRecord>(entityName: "PaymentRecord")), 0)
        draft.payment.amount = "50"
        let id = try XCTUnwrap(draft.save(in: context).first)
        let job = try XCTUnwrap(context.existingObject(with: id) as? Job)
        XCTAssertEqual(try job.directPaid(), 5000)
        XCTAssertEqual(try job.currentFee().amount, 20000)
    }

    func testSessionCopyPreservesWallTimeAcrossDSTAndAppends() throws {
        var draft = EventCreationDraft()
        let sourceDate = try XCTUnwrap(Day.date(from: "2026-03-01"))
        let destinationDate = try XCTUnwrap(Day.date(from: "2026-03-15"))
        draft.events[0].details.startDate = sourceDate
        draft.events[0].timeZoneID = "America/New_York"
        var session = SessionDraft(day: "2026-03-01", timeZoneID: "America/New_York")
        let formatter = ISO8601DateFormatter()
        session.startTime = formatter.date(from: "2026-03-01T15:00:00Z")
        session.endTime = formatter.date(from: "2026-03-01T16:00:00Z")
        session.scheduleStatus = "confirmed"; session.coverage = "covering"
        draft.events[0].sessions = [session]
        var destination = EventOutline(); destination.details.startDate = destinationDate
        destination.timeZoneID = "America/New_York"
        destination.sessions = [SessionDraft(day: "2026-03-15")]
        draft.events.append(destination)
        try draft.copySessions(from: draft.events[0].id, to: [destination.id], includingTimes: true)
        XCTAssertEqual(draft.events[1].sessions.count, 2)
        let copy = draft.events[1].sessions[1]
        XCTAssertEqual(copy.startTime, formatter.date(from: "2026-03-15T14:00:00Z"))
        XCTAssertEqual(copy.scheduleStatus, "tentative")
        XCTAssertEqual(copy.coverage, "undecided")
        XCTAssertEqual(draft.events[0].sessions[0], session)
        try draft.copySessions(from: draft.events[0].id, to: [destination.id], includingTimes: false)
        XCTAssertNil(draft.events[1].sessions[2].startTime)
        XCTAssertEqual(draft.events[1].sessions[2].day, "2026-03-15")
    }

    func testProjectsSeriesInheritanceAndIndependentFees() async throws {
        let store = try await openStore(); let context = store.container.viewContext
        var first = JobDraft(name: "Daytona")
        first.projectName = "IMSA"; first.seriesName = "Main championship"; first.clientName = "Production company"
        first.fee?.amount = "100"
        let job = try XCTUnwrap(context.existingObject(with: first.save(in: context)) as? Job)
        var second = first; second.name = "Sebring"; second.projectName = "imsa"; second.fee?.amount = "200"
        let other = try XCTUnwrap(context.existingObject(with: second.save(in: context)) as? Job)
        XCTAssertEqual(job.project, other.project); XCTAssertEqual(job.series, other.series)
        XCTAssertEqual(try job.currentFee().amount, 10000); XCTAssertEqual(try other.currentFee().amount, 20000)
        let sessionID = try SessionDraft(job: job).save(in: context, jobID: job.objectID)
        let session = try XCTUnwrap(context.existingObject(with: sessionID) as? WorkSession)
        XCTAssertEqual(session.effectiveSeries, job.series)
        var override = SessionDraft(session: session); let baseline = override
        override.overridesSeries = true; override.seriesName = "AEC"
        try override.save(in: context, jobID: job.objectID, editing: sessionID, baseline: baseline)
        XCTAssertEqual(session.effectiveSeries?.name, "AEC")
        let reopened = SessionDraft(session: session)
        XCTAssertTrue(reopened.overridesSeries)
        XCTAssertEqual(reopened.seriesName, "AEC")
        var notesOnly = reopened; notesOnly.notes = "Updated preparation"
        try notesOnly.save(in: context, jobID: job.objectID, editing: sessionID, baseline: reopened)
        XCTAssertEqual(session.effectiveSeries?.name, "AEC")
        XCTAssertEqual(job.series?.name, "Main championship")
        var filter = JobFilter(); filter.project = "IMSA"; filter.series = "AEC"
        XCTAssertTrue(filter.includes(job)); XCTAssertFalse(filter.includes(other))
        XCTAssertTrue(JobFilter().includes(job, query: "AEC"))
        let duplicate = JobDraft.duplicate(job)
        XCTAssertEqual(duplicate.projectName, "IMSA"); XCTAssertEqual(duplicate.seriesName, "Main championship")
        let original = JobDraft(job: job)
        var renamed = LibraryDraft(record: job.project); renamed.name = "IMSA coverage"
        try renamed.save(entity: "WorkProject", editing: job.project?.objectID, baseline: LibraryDraft(record: job.project), in: context)
        var edit = original; edit.notes = "Unrelated change"
        try edit.save(in: context, editing: job.objectID, baseline: original)
        XCTAssertEqual(job.project?.name, "IMSA coverage")
        XCTAssertEqual(other.project?.name, "IMSA coverage")
        var cleared = JobDraft(job: job); let beforeClear = cleared; cleared.projectName = ""
        try cleared.save(in: context, editing: job.objectID, baseline: beforeClear)
        XCTAssertNil(job.project); XCTAssertNotNil(other.project)
    }

    func testSyncFeedbackTracksOverlappingTransfersAndFailureRecovery() {
        var state = SyncActivity()
        XCTAssertEqual(state.message, "Connecting to iCloud…"); XCTAssertTrue(state.isBusy)
        state.checkingAccount = false
        XCTAssertEqual(state.message, "Waiting for iCloud updates"); XCTAssertFalse(state.isBusy)
        let incoming = UUID(), outgoing = UUID()
        state.record(id: incoming, kind: .receiving, ended: false, succeeded: false, error: nil)
        state.record(id: outgoing, kind: .sending, ended: false, succeeded: false, error: nil)
        XCTAssertTrue(state.isBusy)
        state.record(id: outgoing, kind: .sending, ended: true, succeeded: true, error: nil)
        XCTAssertEqual(state.message, "Receiving changes…")
        state.record(id: incoming, kind: .receiving, ended: true, succeeded: false, error: "Unavailable")
        XCTAssertTrue(state.needsAttention); XCTAssertFalse(state.receivedImport)
        state.offline = true; XCTAssertEqual(state.message, "iCloud needs attention")
        state.offline = false
        state.record(id: UUID(), kind: .sending, ended: true, succeeded: true, error: nil)
        XCTAssertTrue(state.needsAttention)
        state.record(id: UUID(), kind: .receiving, ended: true, succeeded: true, error: nil)
        XCTAssertNil(state.message); XCTAssertTrue(state.receivedImport)
        state.enabled = false; state.offline = true; XCTAssertNil(state.message)
    }

    private func billingJob(_ name: String, amount: String, currency: String = "USD", in context: NSManagedObjectContext) throws -> Job {
        var draft = JobDraft(name: name); draft.clientName = "Studio Network"
        draft.fee?.amount = amount; draft.fee?.currency = currency
        return try XCTUnwrap(context.existingObject(with: draft.save(in: context)) as? Job)
    }

    func testInvoiceConcurrentEditsPreserveBothVersionsAndRejectStaleSave() async throws {
        let store = try await openStore(); let context = store.container.viewContext
        let job = try billingJob("Conflict invoice", amount: "100", in: context)
        var initial = InvoiceDraft(clientID: job.client!.id!, currency: "USD")
        initial.value.lines = [BilledLine(jobID: job.id!, jobName: job.name, amount: 10000)]
        let id = try initial.save(in: context)
        let invoice = try XCTUnwrap(context.existingObject(with: id) as? Invoice)
        let ancestor = try XCTUnwrap(try invoice.heads().first?.id)
        var first = try InvoiceDraft(invoice: invoice); first.value.notes = "First edit"
        try first.save(in: context, editing: id)
        let second = InvoiceRevision(entity: NSEntityDescription.entity(forEntityName: "InvoiceRevision", in: context)!, insertInto: context)
        second.id = UUID(); second.createdAt = Date(); second.invoice = invoice
        var alternate = initial.value; alternate.notes = "Second edit"
        second.parentsJSON = String(decoding: try JSONEncoder().encode([ancestor]), as: UTF8.self)
        second.valueJSON = String(decoding: try JSONEncoder().encode(alternate), as: UTF8.self)
        try context.save()
        XCTAssertEqual(try invoice.heads().count, 2); XCTAssertThrowsError(try invoice.currentValue())
        let resolved = InvoiceDraft(value: alternate, parents: Set(try invoice.heads().compactMap(\.id)))
        try resolved.save(in: context, editing: id)
        XCTAssertEqual(try invoice.currentValue().notes, "Second edit")
        XCTAssertEqual(invoice.revisions?.count, 4)
        XCTAssertThrowsError(try first.save(in: context, editing: id))
    }

    func testV2ThroughV10StoresMigrateWithRelationshipsAndFeeHistory() async throws {
        let modelURL = try XCTUnwrap(Bundle(for: Job.self).url(forResource: "Cuekeeper", withExtension: "momd"))
        for version in 2...10 {
            let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL.appending(path: "CuekeeperV\(version).mom")))
            let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
            let fileName = "migration-\(version).sqlite"
            let oldStore = try coordinator.addPersistentStore(type: .sqlite, at: directory.appending(path: fileName))
            let oldContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            oldContext.persistentStoreCoordinator = coordinator
            let job = NSEntityDescription.insertNewObject(forEntityName: "Job", into: oldContext)
            let jobID = UUID(); job.setValue(jobID, forKey: "id"); job.setValue("Existing job", forKey: "name")
            job.setValue("2026-10-12", forKey: "startDay"); job.setValue("2026-10-13", forKey: "endDay")
            let client = NSEntityDescription.insertNewObject(forEntityName: "Client", into: oldContext)
            client.setValue(UUID(), forKey: "id"); client.setValue("Existing client", forKey: "name"); job.setValue(client, forKey: "client")
            if version >= 3 {
                let session = NSEntityDescription.insertNewObject(forEntityName: "WorkSession", into: oldContext)
                session.setValue(UUID(), forKey: "id"); session.setValue("Existing session", forKey: "name"); session.setValue(job, forKey: "job")
                let link = NSEntityDescription.insertNewObject(forEntityName: "BroadcastLink", into: oldContext)
                link.setValue(UUID(), forKey: "id"); link.setValue("https://example.com/old", forKey: "url"); link.setValue(session, forKey: "session")
            }
            if version >= 4 {
                let fee = NSEntityDescription.insertNewObject(forEntityName: "FeeRevision", into: oldContext)
                fee.setValue(UUID(), forKey: "id"); fee.setValue(Date(), forKey: "createdAt"); fee.setValue(job, forKey: "job")
                fee.setValue(String(decoding: try JSONEncoder().encode(FeeValue(amount: 12345)), as: UTF8.self), forKey: "valueJSON")
            }
            if version >= 6 {
                let project = NSEntityDescription.insertNewObject(forEntityName: "WorkProject", into: oldContext)
                project.setValue(UUID(), forKey: "id"); project.setValue("Existing project", forKey: "name"); job.setValue(project, forKey: "project")
                let series = NSEntityDescription.insertNewObject(forEntityName: "WorkSeries", into: oldContext)
                series.setValue(UUID(), forKey: "id"); series.setValue("Existing series", forKey: "name"); job.setValue(series, forKey: "series")
            }
            if version >= 7 { job.setValue("existing-track", forKey: "trackPlaceID") }
            if version >= 5 {
                let invoice = NSEntityDescription.insertNewObject(forEntityName: "Invoice", into: oldContext)
                invoice.setValue(UUID(), forKey: "id"); invoice.setValue(client, forKey: "client")
                var value = InvoiceValue(clientID: client.value(forKey: "id") as! UUID)
                value.lines = [BilledLine(jobID: jobID, jobName: "Historical invoice label", amount: 12345)]
                let revision = NSEntityDescription.insertNewObject(forEntityName: "InvoiceRevision", into: oldContext)
                revision.setValue(UUID(), forKey: "id"); revision.setValue(invoice, forKey: "invoice")
                revision.setValue(String(decoding: try JSONEncoder().encode(value), as: UTF8.self), forKey: "valueJSON")
                let payment = NSEntityDescription.insertNewObject(forEntityName: "PaymentRecord", into: oldContext)
                payment.setValue(UUID(), forKey: "id"); payment.setValue(1000, forKey: "amount")
                payment.setValue(invoice, forKey: "invoice"); payment.setValue(Date(), forKey: "receivedAt"); payment.setValue(Date(), forKey: "createdAt")
            }
            try oldContext.save(); oldContext.reset(); try coordinator.remove(oldStore)
            let migrated = try await openStore(fileName: fileName)
            let saved = try XCTUnwrap(migrated.container.viewContext.fetch(NSFetchRequest<Job>(entityName: "Job")).first)
            XCTAssertNil(saved.event); XCTAssertEqual(saved.eventTitle, "Existing job")
            XCTAssertEqual(saved.project?.name, version >= 6 ? "Existing project" : nil)
            XCTAssertEqual(saved.series?.name, version >= 6 ? "Existing series" : nil)
            XCTAssertEqual(saved.trackPlaceID, version >= 7 ? "existing-track" : "")
            XCTAssertEqual(saved.id, jobID); XCTAssertEqual(saved.client?.name, "Existing client")
            if version >= 3 { XCTAssertEqual(saved.activeSessions.first?.sortedLinks.first?.url, "https://example.com/old") }
            if version >= 4 { XCTAssertEqual(try saved.currentFee().amount, 12345) }
            XCTAssertEqual(try saved.directPaid(), 0)
            if version >= 5 {
                let invoice = try XCTUnwrap(migrated.container.viewContext.fetch(NSFetchRequest<Invoice>(entityName: "Invoice")).first)
                XCTAssertEqual(try invoice.currentValue().lines.first?.jobID, jobID)
                XCTAssertEqual(try invoice.currentValue().lines.first?.jobName, "Historical invoice label")
                XCTAssertEqual(try invoice.balance(), 11345)
            }
        }
    }

    func testGroupedInvoiceSnapshotsAndPartialPayments() async throws {
        let store = try await openStore(); let context = store.container.viewContext
        let first = try billingJob("First", amount: "500", in: context)
        let second = try billingJob("Second", amount: "300", in: context)
        let euro = try billingJob("Euro", amount: "100", currency: "EUR", in: context)
        var draft = InvoiceDraft(clientID: first.client!.id!, currency: "USD")
        draft.value.reference = "INV-100"; draft.value.status = "sent"; draft.value.sentDay = "2026-01-01"; draft.value.dueDay = "2026-01-31"
        draft.value.lines = [BilledLine(jobID: first.id!, jobName: first.name, amount: 50000), BilledLine(jobID: second.id!, jobName: second.name, amount: 30000)]
        var mixed = draft; mixed.value.lines.append(BilledLine(jobID: euro.id!, jobName: euro.name, amount: 10000))
        XCTAssertThrowsError(try mixed.save(in: context))
        let id = try draft.save(in: context)
        let invoice = try XCTUnwrap(context.existingObject(with: id) as? Invoice)
        XCTAssertEqual(try invoice.currentValue().total(), 80000)
        try PaymentDraft(amount: "200", note: "Part one").save(in: context, invoiceID: id)
        try PaymentDraft(amount: "100", note: "Part two").save(in: context, invoiceID: id)
        XCTAssertEqual(try invoice.paid(), 30000); XCTAssertEqual(try invoice.balance(), 50000)
        XCTAssertTrue(invoice.overdue)
        XCTAssertEqual(try first.directPaid(), 0); XCTAssertEqual(try second.directPaid(), 0)
        XCTAssertEqual(first.billingSummary(in: context), second.billingSummary(in: context))
        var fee = try FeeDraft(job: first); fee.amount = "900"
        try fee.save(in: context, jobID: first.objectID)
        XCTAssertEqual(try invoice.currentValue().total(), 80000)
        var edit = try InvoiceDraft(invoice: invoice); edit.value.lines[0].amount = 90000
        XCTAssertThrowsError(try edit.save(in: context, editing: id))
        edit = try InvoiceDraft(invoice: invoice); edit.value.notes = "Follow up next week"
        try edit.save(in: context, editing: id)
        XCTAssertEqual(invoice.revisions?.count, 2)
        XCTAssertThrowsError(try PaymentDraft(amount: "10").save(in: context, jobID: first.objectID))
        XCTAssertThrowsError(try draft.save(in: context))
        var void = try InvoiceDraft(invoice: invoice); void.value.status = "void"
        XCTAssertThrowsError(try void.save(in: context, editing: id))
        XCTAssertEqual(try invoice.balance(), 50000)
    }

    func testDirectPaymentsCorrectionsAndCurrencyHistory() async throws {
        let store = try await openStore(); let context = store.container.viewContext
        let job = try billingJob("Direct", amount: "", currency: "EUR", in: context)
        try PaymentDraft(amount: "25.55", note: "Deposit").save(in: context, jobID: job.objectID)
        XCTAssertEqual(try job.directPaid(), 2555)
        let payment = try XCTUnwrap(job.payments?.first)
        var fee = try FeeDraft(job: job); fee.currency = "USD"
        XCTAssertThrowsError(try fee.save(in: context, jobID: job.objectID))
        try PaymentLedger.reverse(payment, in: context)
        XCTAssertEqual(try job.directPaid(), 0); XCTAssertEqual(job.payments?.count, 2)
        XCTAssertThrowsError(try PaymentLedger.reverse(payment, in: context))
        // Two devices can reverse the same receipt offline; it counts only once.
        let duplicate = PaymentRecord(entity: NSEntityDescription.entity(forEntityName: "PaymentRecord", in: context)!, insertInto: context)
        duplicate.id = UUID(); duplicate.reversesID = payment.id; duplicate.amount = -payment.amount
        duplicate.currency = payment.currency; duplicate.job = job; duplicate.createdAt = Date(); duplicate.receivedAt = Date()
        try context.save()
        XCTAssertEqual(try job.directPaid(), 0)
        try PaymentDraft(amount: "30.10").save(in: context, jobID: job.objectID)
        XCTAssertEqual(try job.directPaid(), 3010)
        XCTAssertEqual(job.payments?.count, 4)
        XCTAssertThrowsError(try PaymentDraft(amount: "-10").save(in: context, jobID: job.objectID))
    }

    func testSyncedDuplicateBillingCanBeDetectedAndVoided() async throws {
        let store = try await openStore(); let context = store.container.viewContext
        let job = try billingJob("Shared job", amount: "100", in: context)
        var draft = InvoiceDraft(clientID: job.client!.id!, currency: "USD")
        draft.value.reference = "A"; draft.value.status = "sent"; draft.value.sentDay = "2026-01-01"
        draft.value.lines = [BilledLine(jobID: job.id!, jobName: job.name, amount: 10000)]
        let firstID = try draft.save(in: context)
        let first = try XCTUnwrap(context.existingObject(with: firstID) as? Invoice)
        // Simulate an independently created invoice arriving through CloudKit.
        let other = Invoice(entity: NSEntityDescription.entity(forEntityName: "Invoice", in: context)!, insertInto: context)
        other.id = UUID(); other.createdAt = Date(); other.client = job.client
        let revision = InvoiceRevision(entity: NSEntityDescription.entity(forEntityName: "InvoiceRevision", in: context)!, insertInto: context)
        var value = draft.value; value.reference = "B"
        revision.id = UUID(); revision.createdAt = Date(); revision.invoice = other
        revision.parentsJSON = "[]"; revision.valueJSON = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try context.save()
        XCTAssertEqual(try job.activeInvoices(in: context).count, 2)
        XCTAssertNotNil(first.issue(in: context))
        XCTAssertThrowsError(try PaymentDraft(amount: "10").save(in: context, invoiceID: firstID))
        var void = try InvoiceDraft(invoice: other); void.value.status = "void"
        try void.save(in: context, editing: other.objectID)
        XCTAssertEqual(other.revisions?.count, 2)
        XCTAssertEqual(try other.balance(), 0)
        XCTAssertNil(first.issue(in: context))
        XCTAssertEqual(try job.activeInvoices(in: context).count, 1)
        try PaymentDraft(amount: "10").save(in: context, invoiceID: firstID)
        XCTAssertEqual(try first.balance(), 9000)
    }

    func testFeesKeepUnknownZeroBreakdownAndHistoryDistinct() async throws {
        let store = try await openStore(); let context = store.container.viewContext
        let id = try JobDraft(name: "Fee test").save(in: context)
        let job = try XCTUnwrap(context.existingObject(with: id) as? Job)
        XCTAssertNil(try job.currentFee().amount)
        var draft = try FeeDraft(job: job); draft.amount = "0"; draft.currency = "EUR"; draft.agreement = "agreed"
        draft.lines = [FeeLine(description: "Days", quantity: "2.5", rate: "100.01"), FeeLine(description: "Adjustment", quantity: "1", rate: "-0.03")]
        try draft.save(in: context, jobID: id)
        XCTAssertEqual(try job.currentFee().amount, 0)
        XCTAssertEqual(try job.currentFee().total(), 25000)
        XCTAssertEqual(try job.currentFee().currency, "EUR")
        XCTAssertEqual(job.feeRevisions?.count, 2)
        let stale = draft
        draft = try FeeDraft(job: job); draft.amount = "300.12"
        try draft.save(in: context, jobID: id)
        XCTAssertThrowsError(try stale.save(in: context, jobID: id))
        XCTAssertEqual(try job.currentFee().amount, 30012)
        let duplicateID = try JobDraft.duplicate(job).save(in: context)
        let duplicate = try XCTUnwrap(context.existingObject(with: duplicateID) as? Job)
        XCTAssertEqual(try duplicate.currentFee().amount, 30012)
        XCTAssertEqual(duplicate.feeRevisions?.count, 1)
        XCTAssertNotEqual(try duplicate.feeHeads().first?.id, try job.feeHeads().first?.id)
        XCTAssertEqual(try Money.parse("0.10"), 10)
        XCTAssertThrowsError(try Money.parse("1.001"))
        XCTAssertThrowsError(try Money.parse("NaN"))
        XCTAssertThrowsError(try Money.parse("999999999999999999999"))
    }

    func testConcurrentFeeVersionsRequireExplicitResolution() async throws {
        let store = try await openStore(); let context = store.container.viewContext
        let id = try JobDraft(name: "Concurrent fee").save(in: context)
        let job = try XCTUnwrap(context.existingObject(with: id) as? Job)
        let ancestor = try XCTUnwrap(try job.feeHeads().first?.id)
        // Two immutable revisions arriving independently through sync share an ancestor.
        for amount: Int64 in [10000, 20000] {
            let revision = FeeRevision(entity: NSEntityDescription.entity(forEntityName: "FeeRevision", in: context)!, insertInto: context)
            revision.id = UUID(); revision.createdAt = Date(); revision.job = job
            revision.parentsJSON = String(decoding: try JSONEncoder().encode([ancestor]), as: UTF8.self)
            revision.valueJSON = String(decoding: try JSONEncoder().encode(FeeValue(amount: amount)), as: UTF8.self)
        }
        try context.save()
        XCTAssertEqual(try job.feeHeads().count, 2)
        XCTAssertThrowsError(try job.currentFee())
        let resolution = FeeDraft(value: FeeValue(amount: 15000), parents: Set(try job.feeHeads().compactMap(\.id)))
        try resolution.save(in: context, jobID: id)
        XCTAssertEqual(try job.currentFee().amount, 15000)
        XCTAssertEqual(job.feeRevisions?.count, 4)
        XCTAssertEqual(try job.feeHeads().count, 1)
    }

    func testSessionsPersistIncompleteAndOvernightSchedulesWithLinks() async throws {
        let store = try await openStore()
        let context = store.container.viewContext
        var jobDraft = JobDraft(name: "Overnight broadcast")
        jobDraft.roleNames = ["Producer"]
        let jobID = try jobDraft.save(in: context)
        let job = try XCTUnwrap(context.existingObject(with: jobID) as? Job)
        var draft = SessionDraft(job: job)
        draft.name = "Late show"
        let sessionID = try draft.save(in: context, jobID: jobID)
        let session = try XCTUnwrap(context.existingObject(with: sessionID) as? WorkSession)
        XCTAssertNil(session.startTime)
        XCTAssertEqual(session.roleNames, ["Producer"])
        XCTAssertFalse(session.calendarEligible)
        draft.timeZoneID = "America/New_York"
        draft.startTime = ISO8601DateFormatter().date(from: "2026-11-01T03:30:00Z")!
        draft.endTime = ISO8601DateFormatter().date(from: "2026-11-01T08:00:00Z")!
        draft.callTime = draft.startTime!.addingTimeInterval(-1800)
        draft.scheduleStatus = "confirmed"; draft.coverage = "covering"
        draft.links = [LinkDraft(label: "Replay", url: "https://example.com/replay", notes: "Final segment")]
        try draft.save(in: context, jobID: jobID, editing: sessionID)
        XCTAssertTrue(session.calendarEligible)
        XCTAssertEqual(session.day, "2026-10-31")
        // Both civil dates use the session zone, even when the device is in another zone.
        XCTAssertTrue(session.compactSchedule.contains(session.shortDate(draft.startTime!)))
        XCTAssertTrue(session.compactSchedule.contains(session.shortDate(draft.endTime!)))
        XCTAssertNotEqual(session.shortDate(draft.startTime!), session.shortDate(draft.endTime!))
        XCTAssertEqual(session.sortedLinks.first?.notes, "Final segment")
        XCTAssertEqual(session.endTime!.timeIntervalSince(session.startTime!), 16200)
        context.reset()
        let reopened = try XCTUnwrap(context.existingObject(with: sessionID) as? WorkSession)
        XCTAssertEqual(reopened.sortedLinks.first?.url, "https://example.com/replay")
        var editedJob = JobDraft(job: try XCTUnwrap(context.existingObject(with: jobID) as? Job))
        editedJob.roleNames = ["Presenter"]
        try editedJob.save(in: context, editing: jobID)
        XCTAssertEqual(reopened.roleNames, ["Presenter"])
        var override = SessionDraft(session: reopened)
        override.overridesRoles = true; override.roleNames = ["Commentator"]
        try override.save(in: context, jobID: jobID, editing: sessionID)
        XCTAssertEqual(reopened.roleNames, ["Commentator"])
        editedJob.bookingStatus = .cancelled
        try editedJob.save(in: context, editing: jobID)
        XCTAssertFalse(reopened.calendarEligible)
    }

    func testSessionValidationAndIndependentEditMerging() async throws {
        let store = try await openStore(); let context = store.container.viewContext
        let jobID = try JobDraft(name: "Coverage").save(in: context)
        let job = try XCTUnwrap(context.existingObject(with: jobID) as? Job)
        var draft = SessionDraft(job: job)
        draft.scheduleStatus = "confirmed"
        XCTAssertThrowsError(try draft.save(in: context, jobID: jobID))
        draft.scheduleStatus = "tentative"; draft.startTime = Date()
        XCTAssertThrowsError(try draft.save(in: context, jobID: jobID))
        draft.timeZoneID = "UTC"; draft.endTime = draft.startTime!.addingTimeInterval(-1)
        XCTAssertThrowsError(try draft.save(in: context, jobID: jobID))
        draft.endTime = draft.startTime!.addingTimeInterval(3600)
        draft.links = [LinkDraft(url: "javascript:alert(1)")]
        XCTAssertThrowsError(try draft.save(in: context, jobID: jobID))
        XCTAssertEqual(try context.count(for: NSFetchRequest<WorkSession>(entityName: "WorkSession")), 0)
        draft.links = []
        let id = try draft.save(in: context, jobID: jobID)
        let session = try XCTUnwrap(context.existingObject(with: id) as? WorkSession)
        let baseline = SessionDraft(session: session)
        var first = baseline; first.notes = "Incoming notes"
        try first.save(in: context, jobID: jobID, editing: id, baseline: baseline)
        var second = baseline; second.name = "New name"
        try second.save(in: context, jobID: jobID, editing: id, baseline: baseline)
        XCTAssertEqual(session.notes, "Incoming notes")
        XCTAssertEqual(session.name, "New name")
        XCTAssertFalse(context.hasChanges)
    }

    func testJobSurvivesStoreReopenWithoutCloud() async throws {
        let first = try await openStore()
        let start = try XCTUnwrap(Day.date(from: "2026-10-12"))
        let end = try XCTUnwrap(Day.date(from: "2026-10-14"))
        try JobDraft(name: "  Courtside Live  ", startDate: start, endDate: end).save(in: first.container.viewContext)
        let original = try XCTUnwrap(first.container.viewContext.fetch(NSFetchRequest<Job>(entityName: "Job")).first)
        let id = original.id
        first.container.viewContext.reset()
        for store in first.container.persistentStoreCoordinator.persistentStores {
            try first.container.persistentStoreCoordinator.remove(store)
        }
        let second = try await openStore()
        let jobs = try second.container.viewContext.fetch(NSFetchRequest<Job>(entityName: "Job"))
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].id, id)
        XCTAssertNotNil(id)
        XCTAssertEqual(jobs[0].name, "Courtside Live")
        XCTAssertEqual(jobs[0].startDay, "2026-10-12")
        XCTAssertEqual(jobs[0].endDay, "2026-10-14")
        XCTAssertEqual(jobs[0].bookingStatus, "tentative")
    }

    func testInvalidDraftsDoNotInsertRecords() async throws {
        let store = try await openStore()
        let start = try XCTUnwrap(Day.date(from: "2026-10-14"))
        let end = try XCTUnwrap(Day.date(from: "2026-10-12"))
        XCTAssertThrowsError(try EventDraft().save(in: store.container.viewContext, firstBooking: JobDraft()))
        XCTAssertThrowsError(try JobDraft(name: "Bad dates", startDate: start, endDate: end).save(in: store.container.viewContext))
        XCTAssertEqual(try store.container.viewContext.count(for: NSFetchRequest<Job>(entityName: "Job")), 0)
        XCTAssertFalse(store.container.viewContext.hasChanges)
    }

    func testEditingAndReuseAndDuplication() async throws {
        let store = try await openStore()
        let context = store.container.viewContext
        var draft = JobDraft(name: "Match coverage")
        draft.clientName = "Broadcast Co"
        draft.roleNames = ["Commentator", "Producer"]
        draft.workArrangement = .remote
        draft.location = "Home studio"
        draft.timeZoneID = "America/New_York"
        draft.notes = "Preparation notes"
        let id = try draft.save(in: context)
        let job = try XCTUnwrap(context.existingObject(with: id) as? Job)
        let originalID = job.id
        let originalDate = job.createdAt
        var edit = JobDraft(job: job)
        edit.bookingStatus = .completed
        edit.name = "Final coverage"
        try edit.save(in: context, editing: id)
        XCTAssertEqual(job.id, originalID)
        XCTAssertEqual(job.createdAt, originalDate)
        XCTAssertEqual(job.bookingStatus, "completed")
        XCTAssertEqual(job.notes, "Preparation notes")
        XCTAssertEqual(job.roleNames, ["Commentator", "Producer"])
        var copy = JobDraft.duplicate(job)
        XCTAssertEqual(copy.bookingStatus, .tentative)
        XCTAssertEqual(copy.notes, "")
        XCTAssertEqual(copy.clientName, "Broadcast Co")
        copy.startDate = try XCTUnwrap(Day.date(from: "2027-01-01"))
        copy.endDate = copy.startDate
        let copyID = try copy.save(in: context)
        let duplicate = try XCTUnwrap(context.existingObject(with: copyID) as? Job)
        XCTAssertNotEqual(duplicate.id, originalID)
        XCTAssertEqual(duplicate.client, job.client)
        XCTAssertEqual(try context.count(for: NSFetchRequest<Client>(entityName: "Client")), 1)
        XCTAssertEqual(try context.count(for: NSFetchRequest<WorkRole>(entityName: "WorkRole")), 2)
        edit.endDate = edit.startDate.addingTimeInterval(-86400)
        XCTAssertThrowsError(try edit.save(in: context, editing: id))
        XCTAssertEqual(job.name, "Final coverage")
    }

    func testEditingDoesNotOverwriteUnchangedFieldsFromAnotherSave() async throws {
        let store = try await openStore()
        let context = store.container.viewContext
        let id = try JobDraft(name: "Original").save(in: context)
        let job = try XCTUnwrap(context.existingObject(with: id) as? Job)
        let baseline = JobDraft(job: job)
        var incoming = baseline
        incoming.notes = "Updated elsewhere"
        try incoming.save(in: context, editing: id)
        var local = baseline
        local.name = "Local name"
        try local.save(in: context, editing: id, baseline: baseline)
        XCTAssertEqual(job.notes, "Updated elsewhere")
        XCTAssertEqual(job.name, "Local name")
    }

    func testLibraryRenameUpdatesJobsAndRejectsDuplicateNames() async throws {
        let store = try await openStore()
        let context = store.container.viewContext
        var draft = JobDraft(name: "Live show")
        draft.clientName = "Old client"
        let id = try draft.save(in: context)
        let job = try XCTUnwrap(context.existingObject(with: id) as? Job)
        let client = try XCTUnwrap(job.client)
        let baseline = LibraryDraft(record: client)
        var edit = baseline
        edit.name = "New client"
        edit.contact = "Production desk"
        edit.currency = "EUR"
        try edit.save(entity: "Client", editing: client.objectID, baseline: baseline, in: context)
        XCTAssertEqual(job.client?.name, "New client")
        XCTAssertEqual(job.client?.contact, "Production desk")
        XCTAssertEqual(job.client?.defaultCurrency, "EUR")
        var duplicate = LibraryDraft()
        duplicate.name = "NEW CLIENT"
        XCTAssertThrowsError(try duplicate.save(entity: "Client", editing: nil, baseline: LibraryDraft(), in: context))
        XCTAssertEqual(try context.count(for: NSFetchRequest<Client>(entityName: "Client")), 1)
    }

    func testCombinedFiltersAndClientSearch() async throws {
        let store = try await openStore()
        let context = store.container.viewContext
        var draft = JobDraft(name: "Coverage", startDate: Day.date(from: "2026-10-10")!, endDate: Day.date(from: "2026-10-15")!)
        draft.clientName = "North Sports"
        draft.roleNames = ["Producer"]
        draft.bookingStatus = .booked
        let id = try draft.save(in: context)
        let job = try XCTUnwrap(context.existingObject(with: id) as? Job)
        var filter = JobFilter()
        filter.client = "North Sports"
        filter.role = "Producer"
        filter.usesDates = true
        filter.start = Day.date(from: "2026-10-15")!
        filter.end = Day.date(from: "2026-10-20")!
        XCTAssertTrue(filter.includes(job, query: "north"))
        filter.start = Day.date(from: "2026-10-16")!
        XCTAssertFalse(filter.includes(job))
        filter.usesDates = false
        job.bookingStatus = "cancelled"
        XCTAssertTrue(filter.includes(job))
    }

    func testV1StoreMigratesWithoutLosingJobs() async throws {
        let modelURL = try XCTUnwrap(Bundle(for: Job.self).url(forResource: "Cuekeeper", withExtension: "momd"))
        let oldModel = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL.appending(path: "Cuekeeper.mom")))
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: oldModel)
        let url = directory.appending(path: "test.sqlite")
        let oldStore = try coordinator.addPersistentStore(type: .sqlite, at: url)
        let oldContext = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        oldContext.persistentStoreCoordinator = coordinator
        let record = NSEntityDescription.insertNewObject(forEntityName: "Job", into: oldContext)
        let id = UUID()
        record.setValue(id, forKey: "id")
        record.setValue("Existing beta job", forKey: "name")
        record.setValue("2026-10-12", forKey: "startDay")
        record.setValue("2026-10-14", forKey: "endDay")
        try oldContext.save()
        oldContext.reset()
        try coordinator.remove(oldStore)
        let migrated = try await openStore()
        let job = try XCTUnwrap(migrated.container.viewContext.fetch(NSFetchRequest<Job>(entityName: "Job")).first)
        XCTAssertEqual(job.id, id)
        XCTAssertEqual(job.name, "Existing beta job")
        XCTAssertEqual(job.startDay, "2026-10-12")
        XCTAssertEqual(job.workArrangement, "unspecified")
        XCTAssertEqual(job.notes, "")
        XCTAssertNil(job.client)
        XCTAssertTrue(job.roleNames.isEmpty)
    }

    func testCivilDatesRetainTheirDayAcrossTimeZonesAndDST() throws {
        for zone in ["America/New_York", "Europe/London", "Pacific/Auckland"] {
            let timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            for day in ["2026-03-08", "2026-11-01", "2026-12-31"] {
                let localDate = try XCTUnwrap(Day.date(from: day, timeZone: timeZone))
                XCTAssertEqual(Day.string(from: localDate, timeZone: timeZone), day)
            }
        }
    }
}
