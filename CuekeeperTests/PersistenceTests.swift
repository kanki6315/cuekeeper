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

    private func openStore() async throws -> PersistenceController {
        let store = PersistenceController(storeURL: directory.appending(path: "test.sqlite"), cloudEnabled: false)
        for _ in 0..<100 {
            if store.isLoaded { openedStores.append(store); return store }
            if let error = store.loadError { throw NSError(domain: error, code: 1) }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "Store timed out", code: 2)
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
        XCTAssertThrowsError(try JobDraft(name: " \n ").save(in: store.container.viewContext))
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
        edit.name = " "
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
        filter.status = "booked"
        filter.client = "North Sports"
        filter.role = "Producer"
        filter.usesDates = true
        filter.start = Day.date(from: "2026-10-15")!
        filter.end = Day.date(from: "2026-10-20")!
        XCTAssertTrue(filter.includes(job, query: "north"))
        filter.start = Day.date(from: "2026-10-16")!
        XCTAssertFalse(filter.includes(job))
        filter.usesDates = false
        filter.status = "cancelled"
        XCTAssertFalse(filter.includes(job))
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
