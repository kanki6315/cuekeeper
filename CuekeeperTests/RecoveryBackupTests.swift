import CloudKit
import CoreData
import XCTest
import UIKit
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
    func testLaunchRemovesInterruptedBackupArtifactsOnly() throws {
        let manager = FileManager.default
        let staleNames = ["CuekeeperBackup-\(UUID())", "CloudBackup-\(UUID())", "DownloadedBackup-\(UUID()).zip"]
        for name in staleNames.prefix(2) {
            let receipts = folder.appendingPathComponent(name).appendingPathComponent("receipts")
            try manager.createDirectory(at: receipts, withIntermediateDirectories: true)
            try Data("private receipt".utf8).write(to: receipts.appendingPathComponent("receipt.jpg"))
        }
        try Data("partial zip".utf8).write(to: folder.appendingPathComponent(staleNames[2]))
        let keptNames = ["unrelated.tmp", "\(UUID()).zip", "CuekeeperBackup-not-a-uuid",
                         "CloudBackup-not-a-uuid", "DownloadedBackup-\(UUID()).zip.extra", "Cuekeeper-export.zip"]
        for name in keptNames { try Data("keep".utf8).write(to: folder.appendingPathComponent(name)) }

        XCTAssertTrue(try BackupTemporaryFiles.removeInterruptedBackups(in: folder).isEmpty)
        for name in staleNames { XCTAssertFalse(manager.fileExists(atPath: folder.appendingPathComponent(name).path)) }
        for name in keptNames { XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent(name)), Data("keep".utf8)) }
        XCTAssertTrue(try BackupTemporaryFiles.removeInterruptedBackups(in: folder).isEmpty)
    }

    func testLaunchCleanupDoesNotFollowBackupSymlinks() throws {
        let target = folder.appendingPathComponent("keep")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let receipt = target.appendingPathComponent("receipt.jpg")
        try Data("keep".utf8).write(to: receipt)
        let link = folder.appendingPathComponent("CuekeeperBackup-\(UUID())")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        XCTAssertTrue(try BackupTemporaryFiles.removeInterruptedBackups(in: folder).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: link.path))
        XCTAssertEqual(try Data(contentsOf: receipt), Data("keep".utf8))
    }
    private func fixture(_ context: NSManagedObjectContext) throws -> Job {
        var draft = JobDraft(name: "Broadcast weekend")
        draft.clientName = "Network"; draft.roleNames = ["Commentator"]; draft.fee?.amount = "100"
        let id = try draft.save(in: context)
        let job = try XCTUnwrap(context.existingObject(with: id) as? Job)
        var session = SessionDraft(day: job.startDay, timeZoneID: "Europe/London")
        session.startTime = Date(); session.endTime = Date().addingTimeInterval(3600)
        session.scheduleStatus = "confirmed"; session.coverage = "covering"
        let sessionID = try session.save(in: context, jobID: id)
        // Links can no longer be added in the app, but existing records must still round-trip.
        let link = NSEntityDescription.insertNewObject(forEntityName: "BroadcastLink", into: context)
        link.setValue(UUID(), forKey: "id"); link.setValue("https://example.com/live", forKey: "url")
        link.setValue(context.object(with: sessionID), forKey: "session"); try context.save()
        var invoice = InvoiceDraft(clientID: job.client!.id!, currency: "USD")
        invoice.value.reference = "INV-RECOVERY"; invoice.value.status = "sent"; invoice.value.sentDay = Day.string(from: Date())
        invoice.value.lines = [BilledLine(jobID: job.id!, jobName: job.displayName, amount: 10000)]
        let invoiceID = try invoice.save(in: context)
        try PaymentDraft(amount: "25").save(in: context, invoiceID: invoiceID)
        return job
    }
    func testBackupFilesRemainAccessibleAfterLock() async throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The simulator does not expose iOS Data Protection attributes; run on a physical device.")
        #else
        let source = try await context(); let job = try fixture(source)
        _ = try Expense.capture(Data(repeating: 73, count: 4096), jobID: job.objectID, in: source)
        let snapshot = try BackupArchive.capture(in: source)
        let file = try snapshot.writePackage()
        let decoded = try BackupArchive.readPackage(file.url, model: source.persistentStoreCoordinator!.managedObjectModel)
        for workspace in [try XCTUnwrap(snapshot.workspace), file.workspace, try XCTUnwrap(decoded.workspace)] {
            let descendants = try XCTUnwrap(FileManager.default.enumerator(at: workspace.url, includingPropertiesForKeys: nil))
            let urls = [workspace.url] + descendants.allObjects.compactMap { $0 as? URL }
            for url in urls {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType,
                               .completeUntilFirstUserAuthentication, url.lastPathComponent)
            }
        }
        #endif
    }

    func testBackgroundTimeEndsExactlyOnceOnCompletionAndExpiration() {
        for expires in [false, true] {
            var expire: (@MainActor () -> Void)?
            var ended: [UIBackgroundTaskIdentifier] = []
            let control = BackupControl()
            let identifier = UIBackgroundTaskIdentifier(rawValue: 42)
            let background = BackupBackgroundTask(begin: { _, handler in
                expire = handler
                return identifier
            }, end: { ended.append($0) }, expiration: { control.cancel() })
            XCTAssertTrue(ended.isEmpty)
            if expires { expire?() }
            XCTAssertEqual(background.expired, expires)
            if expires { XCTAssertThrowsError(try control.check()) }
            else { XCTAssertNoThrow(try control.check()) }
            background.finish()
            background.finish()
            XCTAssertEqual(ended, [identifier])
        }
    }

    func testUnavailableBackgroundTimeDoesNotEndInvalidIdentifier() {
        let background = BackupBackgroundTask(begin: { _, _ in .invalid },
                                              end: { _ in XCTFail("No assertion was granted") },
                                              expiration: {})
        background.finish()
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

    func testWorkflowReportsCommittedRestoreAfterAccountInvalidation() async throws {
        let source = try await context(); _ = try fixture(source)
        let target = try await context()
        let coordinator = target.persistentStoreCoordinator!
        let workflow = BackupWorkflow()
        workflow.archive = try BackupArchive.capture(in: source)
        var activity = SyncActivity(); activity.enabled = false
        let invalidated = expectation(description: "Account changed after save")
        let restored = expectation(description: "Committed restore still reports success")
        let observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave, object: nil, queue: nil) { notification in
            guard let writer = notification.object as? NSManagedObjectContext,
                  writer.persistentStoreCoordinator === coordinator else { return }
            // Run before the worker returns, so cancellation deterministically
            // lands between the persistent save and the workflow's completion.
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    workflow.invalidate()
                    invalidated.fulfill()
                }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        workflow.restore(context: target, syncActivity: { activity }) { result in
            XCTAssertGreaterThan(result.added, 0)
            restored.fulfill()
        }
        await fulfillment(of: [invalidated, restored], timeout: 5)
        XCTAssertFalse(workflow.busy)
        XCTAssertNil(workflow.error)
        XCTAssertTrue(workflow.notice?.hasPrefix("Restore complete.") == true)
        XCTAssertEqual(try target.count(for: NSFetchRequest<Job>(entityName: "Job")), 1)
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
        XCTAssertEqual(job.activeSessions.first?.links?.first?.url, "https://example.com/live")
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

    /// Replaying the old relationship models the second offline device's view
    /// before its independently inserted metadata arrives through CloudKit.
    private func conflictingPromotions(in context: NSManagedObjectContext, job: Job) throws -> [WorkEvent] {
        try EventDraft(anchor: job).save(in: context, anchorID: job.objectID)
        let legacy = try XCTUnwrap(job.event)
        legacy.id = UUID(); legacy.ownerJobID = nil
        try context.save()
        var first = EventDraft(anchor: job); first.notes = "Device A notes"
        try first.save(in: context, anchorID: job.objectID)
        let a = try XCTUnwrap(job.event)
        job.event = legacy
        try context.save()
        var second = EventDraft(anchor: job); second.notes = "Device B notes"
        try second.save(in: context, anchorID: job.objectID)
        let b = try XCTUnwrap(job.event)
        // Existing data from pre-V13 devices used the job ID on both inserts.
        a.id = job.id; a.ownerJobID = nil
        b.id = job.id; b.ownerJobID = nil
        try context.save()
        XCTAssertNotEqual(a.objectID, b.objectID)
        XCTAssertEqual(a.id, b.id)
        return [a, b]
    }

    func testBackupPreservesBothOfflinePromotionsAndRestoresIdempotently() async throws {
        let source = try await context(); let job = try fixture(source)
        let promotions = try conflictingPromotions(in: source, job: job)
        let archive = try BackupArchive.capture(in: source)
        let repeated = try BackupArchive.capture(in: source)
        XCTAssertEqual(Set(archive.records.map(\.key)), Set(repeated.records.map(\.key)))
        XCTAssertEqual(promotions[0].id, promotions[1].id, "Capture must not mutate synced ownership IDs")
        let target = try await context()
        let decoded = try BackupArchive.decode(archive.encoded(), model: target.persistentStoreCoordinator!.managedObjectModel)
        _ = try decoded.restore(in: target)
        let events = try target.fetch(NSFetchRequest<WorkEvent>(entityName: "WorkEvent"))
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(events.contains { $0.notes == "Device A notes" })
        XCTAssertTrue(events.contains { $0.notes == "Device B notes" })
        let restored = try XCTUnwrap(target.fetch(NSFetchRequest<Job>(entityName: "Job")).first)
        XCTAssertEqual(restored.event?.notes, "Device B notes")
        XCTAssertEqual(restored.event?.id, restored.id)
        XCTAssertEqual(try decoded.restore(in: target).added, 0)
        XCTAssertEqual(try decoded.restore(in: source).added, 0)
    }

    func testOlderBackupRestoresDespiteLivePromotionDuplicates() async throws {
        let context = try await context(); let job = try fixture(context)
        let archive = try BackupArchive.capture(in: context)
        _ = try conflictingPromotions(in: context, job: job)
        try Job.remove(job.objectID, in: context)
        XCTAssertEqual(try archive.restore(in: context).recovered, 1)
        XCTAssertEqual(job.event?.notes, "Device B notes")
        XCTAssertEqual(try context.count(for: NSFetchRequest<WorkEvent>(entityName: "WorkEvent")), 3)
    }

    func testIndependentOfflinePromotionsHaveUniqueIDsAndReuseOwnedMetadata() async throws {
        let first = try await context(); let job = try fixture(first)
        try EventDraft(anchor: job).save(in: first, anchorID: job.objectID)
        job.event!.id = UUID(); job.event!.ownerJobID = nil
        try first.save()
        let snapshot = try BackupArchive.capture(in: first)
        let second = try await context()
        _ = try snapshot.restore(in: second)
        let other = try XCTUnwrap(second.fetch(NSFetchRequest<Job>(entityName: "Job")).first)
        var a = EventDraft(anchor: job); a.notes = "Offline A"
        var b = EventDraft(anchor: other); b.notes = "Offline B"
        try a.save(in: first, anchorID: job.objectID)
        try b.save(in: second, anchorID: other.objectID)
        let aID = try XCTUnwrap(job.event?.id)
        let bID = try XCTUnwrap(other.event?.id)
        XCTAssertNotEqual(aID, bID)
        XCTAssertNotEqual(aID, job.id); XCTAssertNotEqual(bID, other.id)
        XCTAssertEqual(job.event?.ownerJobID, job.id)
        XCTAssertEqual(other.event?.ownerJobID, other.id)
        a.notes = "Next edit"; try a.save(in: first, anchorID: job.objectID)
        XCTAssertEqual(job.event?.id, aID)
        XCTAssertEqual(try first.count(for: NSFetchRequest<WorkEvent>(entityName: "WorkEvent")), 2)
        // Merge the other device's archive: both identities survive independently.
        let otherArchive = try BackupArchive.capture(in: second)
        _ = try otherArchive.restore(in: first)
        let events = try first.fetch(NSFetchRequest<WorkEvent>(entityName: "WorkEvent"))
        XCTAssertEqual(events.count, 3)
        XCTAssertTrue(events.contains { $0.id == bID && $0.notes == "Offline B" })
        XCTAssertEqual(job.event?.id, aID)
        XCTAssertEqual(try otherArchive.restore(in: first).added, 0)
        _ = try BackupArchive.capture(in: first)
    }

    func testPreOwnershipFieldBackupRestoresAndEditsLegacyOwnedRecordInPlace() async throws {
        let source = try await context(); let job = try fixture(source)
        try EventDraft(anchor: job).save(in: source, anchorID: job.objectID)
        job.event!.id = job.id; job.event!.ownerJobID = nil
        try source.save()
        var oldArchive = try BackupArchive.capture(in: source)
        for index in oldArchive.records.indices where oldArchive.records[index].key.entity == "WorkEvent" {
            oldArchive.records[index].attributes.removeValue(forKey: "ownerJobID")
        }
        let target = try await context()
        let decoded = try BackupArchive.decode(oldArchive.encoded(), model: target.persistentStoreCoordinator!.managedObjectModel)
        _ = try decoded.restore(in: target)
        let restored = try XCTUnwrap(target.fetch(NSFetchRequest<Job>(entityName: "Job")).first)
        XCTAssertNil(restored.event?.ownerJobID)
        let metadataID = try XCTUnwrap(restored.event?.objectID)
        var edit = EventDraft(anchor: restored); edit.notes = "Edited after upgrade"
        try edit.save(in: target, anchorID: restored.objectID)
        XCTAssertEqual(restored.event?.objectID, metadataID)
        XCTAssertEqual(restored.event?.id, job.id)
        XCTAssertEqual(restored.event?.ownerJobID, restored.id)
        XCTAssertEqual(try decoded.restore(in: target).added, 0)
        // No other missing attribute is accepted as an older schema.
        oldArchive.records[0].attributes.removeValue(forKey: "id")
        XCTAssertThrowsError(try oldArchive.validate(model: target.persistentStoreCoordinator!.managedObjectModel))
    }

    func testDuplicateEventMetadataKeepsDistinctBookingRelationships() async throws {
        let source = try await context(); let first = try fixture(source)
        try EventDraft(anchor: first).save(in: source, anchorID: first.objectID)
        let firstEvent = try XCTUnwrap(first.event)
        let secondID = try JobDraft(name: "Other booking").save(in: source)
        let second = try XCTUnwrap(source.existingObject(with: secondID) as? Job)
        try EventDraft(anchor: second).save(in: source, anchorID: secondID)
        second.event!.id = firstEvent.id
        firstEvent.notes = "First metadata"; second.event!.notes = "Second metadata"
        try source.save()
        let archive = try BackupArchive.capture(in: source)
        let target = try await context()
        _ = try archive.restore(in: target)
        let jobs = try target.fetch(NSFetchRequest<Job>(entityName: "Job"))
        let a = try XCTUnwrap(jobs.first { $0.id == first.id })
        let b = try XCTUnwrap(jobs.first { $0.id == second.id })
        XCTAssertEqual(a.event?.notes, "First metadata")
        XCTAssertEqual(b.event?.notes, "Second metadata")
        XCTAssertNotEqual(a.event, b.event)
        XCTAssertEqual(a.event?.bookings, Set([a]))
        XCTAssertEqual(b.event?.bookings, Set([b]))
        XCTAssertEqual(try archive.restore(in: source).added, 0)
    }

    func testLiveFinancialDuplicateStillRejectsBackupAndRestore() async throws {
        let context = try await context(); _ = try fixture(context)
        let archive = try BackupArchive.capture(in: context)
        let payment = try XCTUnwrap(context.fetch(NSFetchRequest<PaymentRecord>(entityName: "PaymentRecord")).first)
        let duplicate = NSEntityDescription.insertNewObject(forEntityName: "PaymentRecord", into: context)
        for name in payment.entity.attributesByName.keys {
            duplicate.setValue(payment.value(forKey: name), forKey: name)
        }
        duplicate.setValue(payment.value(forKey: "invoice"), forKey: "invoice")
        try context.save()
        XCTAssertThrowsError(try BackupArchive.capture(in: context))
        XCTAssertThrowsError(try archive.restore(in: context))
        XCTAssertFalse(context.hasChanges)
        XCTAssertEqual(try context.count(for: NSFetchRequest<PaymentRecord>(entityName: "PaymentRecord")), 2)
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

final class CloudBackupListingTests: XCTestCase {
    func testUnreadableEntriesDoNotHideHealthyBackups() throws {
        let ids = (0..<5).map { CKRecord.ID(recordName: "backup-\($0)", zoneID: CloudBackupStore.zoneID) }
        let healthy = CKRecord(recordType: "CuekeeperBackup", recordID: ids[0])
        healthy["savedAt"] = Date() as CKRecordValue
        healthy["byteCount"] = Int64(123) as CKRecordValue
        healthy["eventCount"] = Int64(2) as CKRecordValue
        let malformed = CKRecord(recordType: "CuekeeperBackup", recordID: ids[1])
        let entries = CloudBackupStore.entries(ids: ids, results: [
            ids[0]: .success(healthy), ids[1]: .success(malformed),
            ids[2]: .failure(CKError(.unknownItem)), ids[3]: .failure(CKError(.networkFailure))
        ])
        XCTAssertEqual(Set(entries.map(\.id)), Set(ids))
        XCTAssertEqual(entries.filter(\.canRestore).map(\.id), [ids[0]])
        XCTAssertEqual(entries.first?.bytes, 123)
        XCTAssertTrue(entries.filter { !$0.canRestore }.allSatisfy { $0.issue != nil })
    }

    func testInvalidSizesAndEventCountsCannotBeRestored() {
        let id = CKRecord.ID(recordName: "invalid", zoneID: CloudBackupStore.zoneID)
        let record = CKRecord(recordType: "CuekeeperBackup", recordID: id)
        record["savedAt"] = Date() as CKRecordValue
        for (bytes, events) in [(Int64(0), Int64(1)), (BackupLimits.archive + 1, 1), (1, -1)] {
            record["byteCount"] = bytes as CKRecordValue
            record["eventCount"] = events as CKRecordValue
            XCTAssertFalse(CloudBackupStore.entries(ids: [id], results: [id: .success(record)])[0].canRestore)
        }
    }

    func testDeletionDiscoversOrphanPartsWithoutManifest() throws {
        let store = CloudBackupStore()
        let root = CKRecord.ID(recordName: "damaged", zoneID: store.zoneID)
        let ids = store.deletionCandidates(root)
        XCTAssertEqual(ids.count, 33)
        XCTAssertEqual(ids.last?.recordName, "damaged-part-31")
        XCTAssertTrue(ids.allSatisfy { $0.zoneID == store.zoneID })
        var results: [CKRecord.ID: Result<CKRecord, Error>] = Dictionary(uniqueKeysWithValues:
            ids.map { ($0, .failure(CKError(.unknownItem))) })
        // Even if the root and manifest are gone, all surviving parts are removed.
        for id in [ids[1], ids[32]] {
            results[id] = .success(CKRecord(recordType: "CuekeeperBackup", recordID: id))
        }
        XCTAssertEqual(try CloudBackupStore.existingDeletionIDs(ids, results: results), [ids[1], ids[32]])
        results[ids[1]] = .failure(CKError(.networkFailure))
        XCTAssertThrowsError(try CloudBackupStore.existingDeletionIDs(ids, results: results))
        results[ids[1]] = nil
        XCTAssertThrowsError(try CloudBackupStore.existingDeletionIDs(ids, results: results))
    }
}
