import CoreData
import XCTest
import ZIPFoundation
import Darwin
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
    func testWorkflowWaitsForInitialImportThenMergesDownloadedIdentities() async throws {
        let source = try await context(); _ = try fixture(source)
        let snapshot = try BackupArchive.capture(in: source)
        let target = try await context()
        let workflow = BackupWorkflow()
        workflow.archive = snapshot
        var activity = SyncActivity()
        let importID = UUID()

        // Setup/export success, offline status and a failed import must not unlock restore.
        activity.record(id: UUID(), kind: .setup, ended: true, succeeded: true, error: nil)
        activity.record(id: UUID(), kind: .sending, ended: true, succeeded: true, error: nil)
        activity.offline = true
        activity.record(id: importID, kind: .receiving, ended: true, succeeded: false, error: "Offline")
        workflow.restore(context: target, syncActivity: { activity }) { _ in XCTFail("Restore must wait") }
        XCTAssertNotNil(workflow.error)
        XCTAssertNotNil(workflow.archive)
        XCTAssertFalse(workflow.busy)
        XCTAssertEqual(try target.count(for: NSFetchRequest<Job>(entityName: "Job")), 0)

        activity.offline = false
        activity.record(id: importID, kind: .receiving, ended: false, succeeded: false, error: nil)
        workflow.restore(context: target, syncActivity: { activity }) { _ in XCTFail("Import is still running") }
        XCTAssertFalse(workflow.busy)
        XCTAssertEqual(try target.count(for: NSFetchRequest<Job>(entityName: "Job")), 0)

        // Simulate iCloud delivering the same records before its successful completion.
        _ = try snapshot.restore(in: target)
        activity.record(id: importID, kind: .receiving, ended: true, succeeded: true, error: nil)
        let restored = expectation(description: "Restore after initial import")
        workflow.restore(context: target, syncActivity: { activity }) { result in
            XCTAssertEqual(result.added, 0)
            restored.fulfill()
        }
        await fulfillment(of: [restored], timeout: 5)
        XCTAssertNil(workflow.error)
        XCTAssertEqual(try target.count(for: NSFetchRequest<PaymentRecord>(entityName: "PaymentRecord")), 1)
        let invoice = try XCTUnwrap(target.fetch(NSFetchRequest<Invoice>(entityName: "Invoice")).first)
        XCTAssertEqual(try invoice.balance(), 7500)
        XCTAssertNoThrow(try BackupArchive.capture(in: target))
    }

    func testWorkflowAllowsLocalOnlyRestore() async throws {
        let source = try await context(); _ = try fixture(source)
        let target = try await context()
        let workflow = BackupWorkflow()
        workflow.archive = try BackupArchive.capture(in: source)
        var activity = SyncActivity(); activity.enabled = false
        let restored = expectation(description: "Local restore")
        workflow.restore(context: target, syncActivity: { activity }) { result in
            XCTAssertGreaterThan(result.added, 0)
            restored.fulfill()
        }
        await fulfillment(of: [restored], timeout: 5)
        XCTAssertNil(workflow.error)
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

    func testPackageRejectsMissingUnexpectedAndCorruptAttachments() async throws {
        let source = try await context(); let job = try fixture(source)
        _ = try Expense.capture(Data(repeating: 73, count: 4096), jobID: job.objectID, in: source)
        let snapshot = try BackupArchive.capture(in: source)
        let target = try await context(); let model = target.persistentStoreCoordinator!.managedObjectModel
        do {
            let file = try snapshot.writePackage()
            let zip = try Archive(url: file.url, accessMode: .update)
            let entry = try XCTUnwrap(zip[snapshot.attachments[0].path])
            try zip.remove(entry)
            XCTAssertThrowsError(try BackupArchive.readPackage(file.url, model: model))
        }
        do {
            let file = try snapshot.writePackage()
            let zip = try Archive(url: file.url, accessMode: .update)
            try zip.addEntry(with: "../outside.jpg", type: .file, uncompressedSize: Int64(1)) { _, _ in Data([1]) }
            XCTAssertThrowsError(try BackupArchive.readPackage(file.url, model: model))
        }
        do {
            let file = try snapshot.writePackage()
            let zip = try Archive(url: file.url, accessMode: .update)
            let path = snapshot.attachments[0].path
            try zip.remove(try XCTUnwrap(zip[path]))
            try zip.addEntry(with: path, type: .file, uncompressedSize: Int64(4096)) { _, size in Data(repeating: 99, count: size) }
            XCTAssertThrowsError(try BackupArchive.readPackage(file.url, model: model))
        }
        XCTAssertEqual(try target.count(for: NSFetchRequest<Job>(entityName: "Job")), 0)
    }

    func testCancellationAndReceiptDamageLeaveStoreUnchanged() async throws {
        let source = try await context(); let job = try fixture(source)
        _ = try Expense.capture(Data(repeating: 7, count: 1024), jobID: job.objectID, in: source)
        let snapshot = try BackupArchive.capture(in: source)
        let target = try await context()
        let cancelled = BackupControl(); cancelled.cancel()
        XCTAssertThrowsError(try snapshot.restore(in: target, control: cancelled))
        XCTAssertFalse(target.hasChanges)
        let photo = snapshot.workspace!.url.appendingPathComponent(snapshot.attachments[0].path)
        try Data([0]).write(to: photo)
        XCTAssertThrowsError(try snapshot.restore(in: target))
        XCTAssertFalse(target.hasChanges)
        XCTAssertEqual(try target.count(for: NSFetchRequest<Job>(entityName: "Job")), 0)
    }

    func testCancellationDuringRestoreRollsBackInsertedRecords() async throws {
        let source = try await context(); _ = try fixture(source)
        let snapshot = try BackupArchive.capture(in: source)
        let target = try await context()
        // Cancel immediately before the single save, after objects have been inserted.
        let holder = BackupCancellationHolder()
        let control = BackupControl { stage, _ in
            if stage == "Saving restored records…" { holder.control?.cancel() }
        }
        holder.control = control
        XCTAssertThrowsError(try snapshot.restore(in: target, control: control))
        holder.control = nil
        XCTAssertFalse(target.hasChanges)
        XCTAssertEqual(try target.count(for: NSFetchRequest<Job>(entityName: "Job")), 0)
    }

    func testLargeFileLimitIsRejectedBeforeReading() async throws {
        let target = try await context()
        let url = folder.appendingPathComponent("oversized.zip")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: UInt64(BackupLimits.archive + 1)); try writer.close()
        XCTAssertThrowsError(try BackupArchive.readPackage(url, model: target.persistentStoreCoordinator!.managedObjectModel))
    }

    func testReceiptHeavyPackageBeyondOldLimit() async throws {
        let source = try await context(); let jobID = try JobDraft(name: "Receipt volume").save(in: source)
        for i in 0..<128 {
            try autoreleasepool {
                let id = try Expense.capture(Data(repeating: UInt8(i), count: 1024 * 1024), jobID: jobID, in: source)
                source.refresh(try source.existingObject(with: id), mergeChanges: false)
            }
        }
        let started = Date()
        let control = BackupControl()
        let file = try await BackupWorker.perform(coordinator: source.persistentStoreCoordinator!, control: control) {
            try BackupArchive.capture(in: $0, control: control).writePackage(control: control)
        }
        XCTAssertEqual(file.receipts, 128)
        XCTAssertGreaterThan(file.bytes, 100 * 1024 * 1024)
        XCTAssertLessThan(file.bytes, 130 * 1024 * 1024, "Photos must not be base64-expanded in records.json")
        let target = try await context()
        let result = try await BackupWorker.perform(coordinator: target.persistentStoreCoordinator!, control: control) { writer in
            let archive = try BackupArchive.readPackage(file.url, model: writer.persistentStoreCoordinator!.managedObjectModel, control: control)
            return try archive.restore(in: writer, control: control)
        }
        XCTAssertGreaterThan(result.added, 128)
        let expenses = try target.fetch(NSFetchRequest<Expense>(entityName: "Expense"))
        XCTAssertEqual(expenses.count, 128)
        for expense in expenses {
            autoreleasepool {
                XCTAssertEqual(expense.photo?.count, 1024 * 1024)
                target.refresh(expense, mergeChanges: false)
            }
        }
        var usage = rusage(); getrusage(RUSAGE_SELF, &usage)
        print("BACKUP_VOLUME bytes=\(file.bytes) seconds=\(Date().timeIntervalSince(started)) peakRSS=\(usage.ru_maxrss)")
    }

}

private final class BackupCancellationHolder: @unchecked Sendable { var control: BackupControl? }
