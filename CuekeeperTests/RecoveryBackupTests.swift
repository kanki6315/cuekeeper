import CoreData
import XCTest
@testable import Cuekeeper

@MainActor
final class RecoveryBackupTests: XCTestCase {
    private var stores: [PersistenceController] = []
    private var folder: URL!
    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        for store in stores {
            store.container.viewContext.reset()
            for persistent in store.container.persistentStoreCoordinator.persistentStores { try store.container.persistentStoreCoordinator.remove(persistent) }
        }
        stores = []
        try FileManager.default.removeItem(at: folder)
    }
    private func context() async throws -> NSManagedObjectContext {
        let store = PersistenceController(storeURL: folder.appending(path: "\(UUID()).sqlite"), cloudEnabled: false)
        stores.append(store); try await store.waitUntilLoaded()
        return store.container.viewContext
    }
    private func fixture(_ context: NSManagedObjectContext) throws -> Job {
        var draft = JobDraft(name: "Broadcast weekend")
        draft.clientName = "Network"; draft.roleNames = ["Commentator"]; draft.fee?.amount = "100"
        let id = try draft.save(in: context)
        let job = try XCTUnwrap(context.existingObject(with: id) as? Job)
        var session = SessionDraft(day: job.startDay, timeZoneID: "Europe/London")
        session.startTime = Date(); session.endTime = Date().addingTimeInterval(3600)
        session.scheduleStatus = "confirmed"; session.coverage = "covering"
        session.links = [LinkDraft(label: "Programme", url: "https://example.com/live", notes: "Feed")]
        try session.save(in: context, jobID: id)
        var invoice = InvoiceDraft(clientID: job.client!.id!, currency: "USD")
        invoice.value.reference = "INV-RECOVERY"; invoice.value.status = "sent"; invoice.value.sentDay = Day.string(from: Date())
        invoice.value.lines = [BilledLine(jobID: job.id!, jobName: job.displayName, amount: 10000)]
        let invoiceID = try invoice.save(in: context)
        try PaymentDraft(amount: "25").save(in: context, invoiceID: invoiceID)
        return job
    }
    func testRestoreEventRetainsSeparatelyDeletedSessionsAndFinancialHistory() async throws {
        let context = try await context(); let job = try fixture(context)
        let session = try XCTUnwrap(job.activeSessions.first)
        session.deletedAt = Date(); try context.save()
        try Job.remove(job.objectID, in: context)
        XCTAssertThrowsError(try Recovery.restore(session.objectID, in: context))
        try Recovery.restore(job.objectID, in: context)
        XCTAssertNil(job.deletedAt); XCTAssertNotNil(session.deletedAt)
        try Recovery.restore(session.objectID, in: context)
        XCTAssertTrue(session.calendarEligible)
        let invoice = try XCTUnwrap(context.fetch(NSFetchRequest<Invoice>(entityName: "Invoice")).first)
        XCTAssertEqual(try invoice.balance(), 7500)
    }
    func testRecoveryDeadlineAndPermanentDiscard() async throws {
        let context = try await context(); let job = try fixture(context)
        try Job.remove(job.objectID, in: context)
        let deletion = try XCTUnwrap(job.deletedAt)
        XCTAssertTrue(Recovery.canRestore(job, now: deletion.addingTimeInterval(Recovery.retention - 1)))
        XCTAssertFalse(Recovery.canRestore(job, now: deletion.addingTimeInterval(Recovery.retention)))
        XCTAssertThrowsError(try Recovery.restore(job.objectID, in: context, now: deletion.addingTimeInterval(Recovery.retention)))
        try Recovery.discard(job.objectID, in: context)
        XCTAssertFalse(Recovery.canRestore(job)); XCTAssertThrowsError(try Recovery.restore(job.objectID, in: context))
        XCTAssertEqual(try context.count(for: NSFetchRequest<PaymentRecord>(entityName: "PaymentRecord")), 1)
    }
    func testBackupRoundTripIntoEmptyStoreAndRepeatedRestore() async throws {
        let source = try await context(); let original = try fixture(source)
        let archive = try BackupArchive.capture(in: source)
        let data = try archive.encoded()
        let target = try await context()
        let decoded = try BackupArchive.decode(data, model: target.persistentStoreCoordinator!.managedObjectModel)
        let first = try decoded.restore(in: target)
        XCTAssertEqual(first.added, archive.records.count)
        let job = try XCTUnwrap(target.fetch(NSFetchRequest<Job>(entityName: "Job")).first)
        XCTAssertEqual(job.id, original.id); XCTAssertEqual(job.client?.name, "Network")
        XCTAssertEqual(job.activeSessions.first?.sortedLinks.first?.url, "https://example.com/live")
        XCTAssertEqual(job.activeSessions.count, 1); XCTAssertEqual(try job.currentFee().amount, 10000)
        let invoice = try XCTUnwrap(target.fetch(NSFetchRequest<Invoice>(entityName: "Invoice")).first)
        XCTAssertEqual(try invoice.balance(), 7500); XCTAssertNil(invoice.issue(in: target))
        let second = try decoded.restore(in: target)
        XCTAssertEqual(second.added, 0); XCTAssertEqual(second.recovered, 0)
        XCTAssertEqual(try target.count(for: NSFetchRequest<PaymentRecord>(entityName: "PaymentRecord")), 1)
    }
    func testRestoreRecoversDeletionWithoutOverwritingNewerEditsOrPayments() async throws {
        let context = try await context(); let job = try fixture(context)
        let archive = try BackupArchive.capture(in: context)
        job.name = "Newer title"; try context.save()
        let invoice = try XCTUnwrap(context.fetch(NSFetchRequest<Invoice>(entityName: "Invoice")).first)
        try PaymentDraft(amount: "10").save(in: context, invoiceID: invoice.objectID)
        try Job.remove(job.objectID, in: context)
        let result = try archive.restore(in: context)
        XCTAssertEqual(result.recovered, 1); XCTAssertEqual(result.added, 0)
        XCTAssertNil(job.deletedAt); XCTAssertEqual(job.name, "Newer title")
        XCTAssertEqual(try invoice.balance(), 6500)
    }
    func testMalformedBackupCannotPartiallyRestore() async throws {
        let source = try await context(); _ = try fixture(source)
        var archive = try BackupArchive.capture(in: source)
        let target = try await context()
        archive.records.removeAll { $0.key.entity == "Client" }
        XCTAssertThrowsError(try archive.restore(in: target))
        XCTAssertEqual(try target.count(for: NSFetchRequest<Job>(entityName: "Job")), 0)
        var duplicate = try BackupArchive.capture(in: source)
        duplicate.records.append(duplicate.records[0])
        XCTAssertThrowsError(try duplicate.restore(in: target))
        XCTAssertEqual(try target.count(for: NSFetchRequest<Job>(entityName: "Job")), 0)
    }
    func testImmutableFinancialConflictRollsBackWholeRestore() async throws {
        let context = try await context(); _ = try fixture(context)
        var archive = try BackupArchive.capture(in: context)
        let payment = try XCTUnwrap(archive.records.firstIndex { $0.key.entity == "PaymentRecord" })
        archive.records[payment].attributes["amount"] = .integer(99999)
        XCTAssertThrowsError(try archive.restore(in: context))
        let invoice = try XCTUnwrap(context.fetch(NSFetchRequest<Invoice>(entityName: "Invoice")).first)
        XCTAssertEqual(try invoice.balance(), 7500)
    }
    func testExplicitBackupCanRecoverAfterRecoveryWasDiscarded() async throws {
        let context = try await context(); let job = try fixture(context)
        let archive = try BackupArchive.capture(in: context)
        try Job.remove(job.objectID, in: context)
        try Recovery.discard(job.objectID, in: context)
        _ = try archive.restore(in: context)
        XCTAssertNil(job.deletedAt); XCTAssertNil(job.recoveryDiscardedAt)
        XCTAssertEqual(job.activeSessions.count, 1)
    }

    func testEncodedBackupRestoresOverOriginalStore() async throws {
        let context = try await context(); _ = try fixture(context)
        let data = try BackupArchive.capture(in: context).encoded()
        let decoded = try BackupArchive.decode(data, model: context.persistentStoreCoordinator!.managedObjectModel)
        let result = try decoded.restore(in: context)
        XCTAssertEqual(result.added, 0)
    }

}
