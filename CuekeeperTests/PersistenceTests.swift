import CoreData
import XCTest
@testable import Cuekeeper

@MainActor
final class PersistenceTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func openStore() async throws -> PersistenceController {
        let store = PersistenceController(storeURL: directory.appending(path: "test.sqlite"), cloudEnabled: false)
        for _ in 0..<100 {
            if store.isLoaded { return store }
            if let error = store.loadError { throw NSError(domain: error, code: 1) }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "Store timed out", code: 2)
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
