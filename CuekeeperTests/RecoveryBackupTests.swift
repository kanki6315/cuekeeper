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
        try session.save(in: context, jobID: id)
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

        // While online, setup/export success and a failed import must not unlock restore.
        activity.record(id: UUID(), kind: .setup, ended: true, succeeded: true, error: nil)
        activity.record(id: UUID(), kind: .sending, ended: true, succeeded: true, error: nil)
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

    func testWorkflowAllowsFilesRestoreWithoutUsableICloud() async throws {
        let source = try await context(); _ = try fixture(source)
        let snapshot = try BackupArchive.capture(in: source)
        for offline in [false, true] {
            let target = try await context()
            let workflow = BackupWorkflow(); workflow.archive = snapshot
            var activity = SyncActivity()
            activity.checkingAccount = false
            activity.offline = offline
            activity.accountIssue = offline ? nil : "No iCloud account"
            activity.record(id: UUID(), kind: .receiving, ended: true, succeeded: false, error: "Unavailable")
            let restored = expectation(description: "Restore without usable iCloud")
            workflow.restore(context: target, syncActivity: { activity }) { result in
                XCTAssertGreaterThan(result.added, 0)
                restored.fulfill()
            }
            await fulfillment(of: [restored], timeout: 5)
            XCTAssertNil(workflow.error)
            XCTAssertNoThrow(try BackupArchive.capture(in: target))
        }
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

    /// Simulates CloudKit delivering another device's records: separate objects
    /// carrying the same application UUIDs and relationships.
    @discardableResult
    private func cloudCopy(from source: NSManagedObjectContext, into target: NSManagedObjectContext,
                           author: String? = nil) throws -> [NSManagedObjectID: NSManagedObject] {
        target.transactionAuthor = author
        defer { target.transactionAuthor = nil }
        var copies: [NSManagedObjectID: NSManagedObject] = [:]
        let entities = source.persistentStoreCoordinator!.managedObjectModel.entities
        for entity in entities {
            for object in try source.fetch(NSFetchRequest<NSManagedObject>(entityName: entity.name!)) {
                let copy = NSEntityDescription.insertNewObject(forEntityName: entity.name!, into: target)
                for name in entity.attributesByName.keys { copy.setValue(object.value(forKey: name), forKey: name) }
                copies[object.objectID] = copy
            }
        }
        for (id, copy) in copies {
            let object = try source.existingObject(with: id)
            for (name, relationship) in object.entity.relationshipsByName {
                if relationship.isToMany {
                    let related = (object.value(forKey: name) as? Set<NSManagedObject> ?? []).compactMap { copies[$0.objectID] }
                    copy.mutableSetValue(forKey: name).addObjects(from: related)
                } else if let related = object.value(forKey: name) as? NSManagedObject {
                    copy.setValue(copies[related.objectID], forKey: name)
                }
            }
        }
        try target.save()
        return copies
    }

    /// #3: restore while iCloud cannot deliver (offline, account problem, or before
    /// signing in), then iCloud's copies arrive as separate objects with the same UUIDs.
    func testRestoreBeforeCloudImportReconcilesArrivingCopies() async throws {
        let cloud = try await context(); let job = try fixture(cloud)
        let snapshot = try BackupArchive.capture(in: cloud)
        job.name = "Edited in iCloud"; try Job.remove(job.objectID, in: cloud)
        for conflicting in [false, true] {
            let target = try await context()
            let workflow = BackupWorkflow(); workflow.archive = snapshot
            var activity = SyncActivity(); activity.checkingAccount = false; activity.offline = true
            XCTAssertNil(activity.restoreUnavailableReason); XCTAssertNotNil(activity.restoreCaution)
            let restored = expectation(description: "Offline restore")
            workflow.restore(context: target, syncActivity: { activity }) { _ in restored.fulfill() }
            await fulfillment(of: [restored], timeout: 5)
            let ledger = try XCTUnwrap(RestoreLedger.load(target.persistentStoreCoordinator!))
            XCTAssertEqual(ledger.entries.count, snapshot.records.count)

            let copies = try cloudCopy(from: cloud, into: target)
            if conflicting {
                let payment = try XCTUnwrap(copies.values.first { $0.entity.name == "PaymentRecord" })
                payment.setValue(Int64(9900), forKey: "amount"); try target.save()
            }
            let report = try IdentityReconciliation.reconcile(in: target)
            let count = { (entity: String) in try target.count(for: NSFetchRequest<NSManagedObject>(entityName: entity)) }
            for entity in ["Job", "Client", "WorkSession", "Invoice", "FeeRevision", "InvoiceRevision"] { XCTAssertEqual(try count(entity), 1, entity) }
            let merged = try XCTUnwrap(target.fetch(NSFetchRequest<Job>(entityName: "Job")).first)
            XCTAssertEqual(merged.name, "Edited in iCloud", "iCloud's newer edit wins over the backup")
            XCTAssertNil(merged.deletedAt, "The restore still recovers the deletion the backup did not have")
            XCTAssertEqual(merged.activeSessions.count, 1); XCTAssertEqual(merged.client?.jobs?.count, 1)
            XCTAssertEqual(try merged.currentFee().amount, 10000)
            let invoice = try XCTUnwrap(target.fetch(NSFetchRequest<Invoice>(entityName: "Invoice")).first)
            XCTAssertEqual(invoice.client, merged.client)
            if !conflicting {
                XCTAssertEqual(report, IdentityReconciliation.Report(merged: snapshot.records.count, conflicts: []))
                XCTAssertEqual(try count("PaymentRecord"), 1); XCTAssertEqual(try invoice.balance(), 7500)
                XCTAssertNil(RestoreLedger.load(target.persistentStoreCoordinator!), "Matched records leave the ledger")
                let next = try BackupArchive.decode(BackupArchive.capture(in: target).encoded(), model: target.persistentStoreCoordinator!.managedObjectModel)
                XCTAssertEqual(try next.restore(in: target).added, 0)
                XCTAssertEqual(try snapshot.restore(in: target).added, 0)
            } else {
                // Differing financial history is never combined or discarded.
                XCTAssertEqual(report.conflicts, ["PaymentRecord"]); XCTAssertNotNil(report.message)
                XCTAssertEqual(try count("PaymentRecord"), 2)
                XCTAssertThrowsError(try invoice.balance())
                XCTAssertNotNil(RestoreLedger.load(target.persistentStoreCoordinator!))
                // Backups and restores carry on: both copies travel in the backup for review.
                let backup = try BackupArchive.decode(BackupArchive.capture(in: target).encoded(), model: target.persistentStoreCoordinator!.managedObjectModel)
                XCTAssertEqual(backup.conflicts.map(\.key.entity), ["PaymentRecord"])
                XCTAssertEqual(try snapshot.restore(in: target).added, 0)
                let fresh = try await context()
                _ = try backup.restore(in: fresh)
                XCTAssertEqual(try IdentityReconciliation.conflicts(in: fresh).map(\.entity), ["PaymentRecord"])
                XCTAssertEqual(try backup.restore(in: fresh).added, 0, "Restoring again adds no third copy")
                XCTAssertEqual(try count("PaymentRecord"), 2)
            }
        }
    }

    /// #2/#3: a restored record merges field by field against the values it was
    /// restored with. One-sided edits win silently; only a field both sides changed
    /// is asked about. A deletion made in iCloud after the restore stands.
    func testRestoredCopyMergesThreeWayWithICloud() async throws {
        let cloud = try await context(); let job = try fixture(cloud)
        let snapshot = try BackupArchive.capture(in: cloud)
        let target = try await context()
        _ = try snapshot.restore(in: target)
        let local = try XCTUnwrap(target.fetch(NSFetchRequest<Job>(entityName: "Job")).first)
        local.notes = "Edited offline"; local.location = "Silverstone"; try target.save()
        job.name = "Edited in iCloud"; job.location = "Brands Hatch"
        try XCTUnwrap(job.activeSessions.first).deletedAt = Date(); try cloud.save()
        try cloudCopy(from: cloud, into: target)

        XCTAssertEqual(try IdentityReconciliation.reconcile(in: target).conflicts, ["Job"])
        let conflict = try XCTUnwrap(IdentityReconciliation.conflicts(in: target).first)
        XCTAssertEqual(conflict.fields, ["location"], "Only the field changed on both sides is asked about")
        XCTAssertNotNil(conflict.base); XCTAssertNotNil(conflict.settled["notes"])
        let mine = try XCTUnwrap(conflict.copies.first { $0 != conflict.base })
        try IdentityReconciliation.resolve(conflict, choice: .fields(["location": mine]), in: target)

        let merged = try XCTUnwrap(target.fetch(NSFetchRequest<Job>(entityName: "Job")).first)
        XCTAssertEqual(try target.count(for: NSFetchRequest<Job>(entityName: "Job")), 1)
        XCTAssertEqual(merged.name, "Edited in iCloud"); XCTAssertEqual(merged.notes, "Edited offline")
        XCTAssertEqual(merged.location, "Silverstone")
        let session = try XCTUnwrap(target.fetch(NSFetchRequest<WorkSession>(entityName: "WorkSession")).first)
        XCTAssertEqual(try target.count(for: NSFetchRequest<WorkSession>(entityName: "WorkSession")), 1)
        XCTAssertNotNil(session.deletedAt, "Deleted in iCloud after the restore, so it stays deleted")
        XCTAssertEqual(try XCTUnwrap(target.fetch(NSFetchRequest<Invoice>(entityName: "Invoice")).first).balance(), 7500)
        XCTAssertNil(RestoreLedger.load(target.persistentStoreCoordinator!))
    }

    /// Link differences never ask for review: a payment whose invoice hasn't arrived
    /// combines and keeps the link; a link cleared in iCloud stays cleared.
    func testLinkDifferencesCombineWithoutReview() async throws {
        let cloud = try await context(); let job = try fixture(cloud)
        let snapshot = try BackupArchive.capture(in: cloud)
        let session = try XCTUnwrap(job.activeSessions.first)
        session.job = nil; try cloud.save() // Deliberately detached in iCloud after the backup.
        // Every device keeps the same survivor; check both orders it can take.
        for keepCloudCopies in [false, true] {
            let target = try await context()
            _ = try snapshot.restore(in: target)
            let copies = try cloudCopy(from: cloud, into: target)
            let payment = try XCTUnwrap(copies.values.first { $0.entity.name == "PaymentRecord" })
            payment.setValue(nil, forKey: "invoice"); try target.save()
            let cloudIDs = Set(copies.values.map(\.objectID))
            // #4: while only some copies have uploaded, nothing merges.
            let partly = try IdentityReconciliation.reconcile(in: target, recordName: { cloudIDs.contains($0) ? $0.uriRepresentation().absoluteString : nil })
            XCTAssertEqual(partly.merged, 0)
            let report = try IdentityReconciliation.reconcile(in: target, recordName: {
                (keepCloudCopies == cloudIDs.contains($0) ? "a" : "b") + $0.uriRepresentation().absoluteString
            })
            XCTAssertEqual(report.conflicts, [])
            let kept = try XCTUnwrap(target.fetch(NSFetchRequest<PaymentRecord>(entityName: "PaymentRecord")).first)
            XCTAssertEqual(try target.count(for: NSFetchRequest<PaymentRecord>(entityName: "PaymentRecord")), 1)
            XCTAssertNotNil(kept.invoice, "The combined payment keeps the delivered link")
            XCTAssertEqual(try XCTUnwrap(kept.invoice).balance(), 7500)
            let merged = try XCTUnwrap(target.fetch(NSFetchRequest<WorkSession>(entityName: "WorkSession")).first)
            XCTAssertEqual(try target.count(for: NSFetchRequest<WorkSession>(entityName: "WorkSession")), 1)
            XCTAssertNil(merged.job, "iCloud's deliberate change wins over the backup's link")
            XCTAssertTrue(try XCTUnwrap(target.fetch(NSFetchRequest<Job>(entityName: "Job")).first).activeSessions.isEmpty)
        }
    }

    /// Conflicts nothing can tell apart (no restore ledger) wait for an explicit choice:
    /// events field by field, payments as one whole copy.
    func testReviewedConflictsResolveFieldByFieldAndWholeCopy() async throws {
        let cloud = try await context(); let job = try fixture(cloud)
        let snapshot = try BackupArchive.capture(in: cloud)
        let target = try await context()
        _ = try snapshot.restore(in: target)
        try RestoreLedger.save(nil, target.persistentStoreCoordinator!) // Duplicates from before the ledger existed.
        job.name = "Edited in iCloud"; job.notes = "Pit lane"; try cloud.save()
        let copies = try cloudCopy(from: cloud, into: target)
        let cloudPayment = try XCTUnwrap(copies.values.first { $0.entity.name == "PaymentRecord" })
        cloudPayment.setValue(Int64(9900), forKey: "amount"); try target.save()

        XCTAssertEqual(try IdentityReconciliation.reconcile(in: target).conflicts, ["Job", "PaymentRecord"])
        let conflicts = try IdentityReconciliation.conflicts(in: target)
        let event = try XCTUnwrap(conflicts.first { $0.entity == "Job" })
        let payment = try XCTUnwrap(conflicts.first { $0.entity == "PaymentRecord" })
        XCTAssertEqual(event.fields, ["name", "notes"]); XCTAssertFalse(event.wholeRecord)
        XCTAssertTrue(payment.wholeRecord)
        XCTAssertThrowsError(try IdentityReconciliation.resolve(payment, choice: .fields([:]), in: target))

        // The cloud name with the backup's notes: fields come from the copy chosen for each.
        let edited = try XCTUnwrap(event.copies.first { (try target.existingObject(with: $0) as! Job).name == "Edited in iCloud" })
        let original = try XCTUnwrap(event.copies.first { $0 != edited })
        try IdentityReconciliation.resolve(event, choice: .fields(["name": edited, "notes": original]), in: target)
        XCTAssertThrowsError(try IdentityReconciliation.resolve(event, choice: .keep(edited), in: target), "Stale review")
        let kept = try XCTUnwrap(payment.copies.first { (try target.existingObject(with: $0) as! PaymentRecord).amount == 2500 })
        try IdentityReconciliation.resolve(payment, choice: .keep(kept), in: target)

        XCTAssertTrue(try IdentityReconciliation.conflicts(in: target).isEmpty)
        let merged = try XCTUnwrap(target.fetch(NSFetchRequest<Job>(entityName: "Job")).first)
        XCTAssertEqual(try target.count(for: NSFetchRequest<Job>(entityName: "Job")), 1)
        XCTAssertEqual(merged.name, "Edited in iCloud"); XCTAssertEqual(merged.notes, "")
        XCTAssertEqual(merged.activeSessions.count, 1)
        XCTAssertEqual(try target.count(for: NSFetchRequest<PaymentRecord>(entityName: "PaymentRecord")), 1)
        XCTAssertEqual(try XCTUnwrap(target.fetch(NSFetchRequest<Invoice>(entityName: "Invoice")).first).balance(), 7500)
        XCTAssertEqual(try snapshot.restore(in: target).added, 0)
        XCTAssertNoThrow(try BackupArchive.capture(in: target))
    }

    /// #6: duplicates from before the ledger existed: the copy CloudKit imported
    /// (per change history) wins silently over the one inserted on this device.
    func testOlderDuplicatesUseChangeHistoryToPreferICloud() async throws {
        let cloud = try await context(); let job = try fixture(cloud)
        let snapshot = try BackupArchive.capture(in: cloud)
        let target = try await context()
        _ = try snapshot.restore(in: target)
        try RestoreLedger.save(nil, target.persistentStoreCoordinator!)
        job.name = "Edited in iCloud"; try cloud.save()
        try cloudCopy(from: cloud, into: target, author: IdentityReconciliation.importAuthor)
        XCTAssertEqual(try IdentityReconciliation.reconcile(in: target).conflicts, [])
        let merged = try XCTUnwrap(target.fetch(NSFetchRequest<Job>(entityName: "Job")).first)
        XCTAssertEqual(try target.count(for: NSFetchRequest<Job>(entityName: "Job")), 1)
        XCTAssertEqual(merged.name, "Edited in iCloud")
        XCTAssertEqual(try XCTUnwrap(target.fetch(NSFetchRequest<Invoice>(entityName: "Invoice")).first).balance(), 7500)
    }

    /// Values saved by earlier versions, before newer keys existed, still read in full.
    func testValuesSavedBeforeNewerKeysStillDecode() throws {
        let invoice = #"{"clientID":"DB57AF5C-2582-4160-AA1C-1B6FB899BD74","currency":"USD","reference":"INV-1","status":"sent","sentDay":"2026-10-01","dueDay":"","notes":"","lines":[{"jobID":"B87C2C31-C2E0-4A97-8A09-2A7423292BDD","jobName":"Broadcast","amount":10000}]}"#
        let decoded = try JSONDecoder().decode(InvoiceValue.self, from: Data(invoice.utf8))
        XCTAssertEqual(decoded.reference, "INV-1"); XCTAssertEqual(try decoded.total(), 10000)
        XCTAssertTrue(decoded.expenseLines.isEmpty); XCTAssertFalse(decoded.dueDayAutomatic)
        let expense = #"{"merchant":"Hotel","day":"2026-10-01","amount":"120.00","currency":"USD","tax":"","category":"Accommodation","reimbursable":true,"notes":""}"#
        let receipt = try JSONDecoder().decode(ExpenseValue.self, from: Data(expense.utf8))
        XCTAssertEqual(receipt.merchant, "Hotel"); XCTAssertEqual(receipt.amount, "120.00"); XCTAssertTrue(receipt.reimbursable)
        XCTAssertFalse(receipt.discarded); XCTAssertFalse(receipt.repeatsMonthly)
    }

    /// #11: every data model change since backups began is described by BackupSchema.changes.
    func testBackupSchemaChangesDescribeEveryModelVersion() throws {
        let bundle = Bundle(for: PersistenceController.self)
        func shape(_ version: Int) throws -> [String: (attributes: Set<String>, relationships: Set<String>)] {
            let url = try XCTUnwrap(bundle.url(forResource: "CuekeeperV\(version)", withExtension: "mom", subdirectory: "Cuekeeper.momd"))
            let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: url))
            return Dictionary(uniqueKeysWithValues: model.entities.map { ($0.name!, (Set($0.attributesByName.keys), Set($0.relationshipsByName.keys))) })
        }
        for version in (BackupSchema.oldest + 1)...BackupSchema.current {
            let before = try shape(version - 1), after = try shape(version)
            var found: [String] = []
            for name in Set(before.keys).union(after.keys).sorted() {
                guard let old = before[name] else { found.append("addedEntity \(name)"); continue }
                guard let new = after[name] else { found.append("removedEntity \(name)"); continue }
                found += new.attributes.subtracting(old.attributes).map { "addedAttribute \(name).\($0)" }
                found += old.attributes.subtracting(new.attributes).map { "removedAttribute \(name).\($0)" }
                found += new.relationships.subtracting(old.relationships).map { "addedRelationship \(name).\($0)" }
                found += old.relationships.subtracting(new.relationships).map { "removedRelationship \(name).\($0)" }
            }
            let listed: [String] = BackupSchema.changes.filter { $0.version == version }.map {
                switch $0.change {
                case .addedEntity(let e): return "addedEntity \(e)"
                case .removedEntity(let e): return "removedEntity \(e)"
                case .addedAttribute(let e, let n): return "addedAttribute \(e).\(n)"
                case .addedRelationship(let e, let n): return "addedRelationship \(e).\(n)"
                case .removedRelationship(let e, let n): return "removedRelationship \(e).\(n)"
                }
            }
            XCTAssertEqual(Set(found), Set(listed), "Model \(version) changed without a matching BackupSchema.changes entry")
        }
    }

    /// #25: a failed restore keeps the prepared archive (and its files) for a retry.
    func testFailedRestoreKeepsPreparedArchiveUntilCommitOrDiscard() async throws {
        let source = try await context(); _ = try fixture(source)
        let model = source.persistentStoreCoordinator!.managedObjectModel
        let data = try BackupArchive.capture(in: source).encoded()
        let target = try await context()
        _ = try BackupArchive.decode(data, model: model).restore(in: target)
        let payment = try XCTUnwrap(target.fetch(NSFetchRequest<PaymentRecord>(entityName: "PaymentRecord")).first)
        payment.amount = 1; try target.save()
        let workflow = BackupWorkflow(); workflow.archive = try BackupArchive.decode(data, model: model)
        let files = try XCTUnwrap(workflow.archive?.workspace?.url)
        var activity = SyncActivity(); activity.enabled = false
        let restore = {
            workflow.restore(context: target, syncActivity: { activity })
            while workflow.busy { try await Task.sleep(for: .milliseconds(10)) }
        }
        try await restore()
        XCTAssertNotNil(workflow.error); XCTAssertTrue(workflow.canRetryRestore)
        XCTAssertTrue(FileManager.default.fileExists(atPath: files.path))
        target.delete(payment); try target.save()
        workflow.reviewAgain(); XCTAssertNil(workflow.error)
        try await restore()
        XCTAssertNil(workflow.error); XCTAssertNil(workflow.archive)
        XCTAssertEqual(try XCTUnwrap(target.fetch(NSFetchRequest<Invoice>(entityName: "Invoice")).first).balance(), 7500)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.path))
        workflow.archive = try BackupArchive.decode(data, model: model)
        let discarded = try XCTUnwrap(workflow.archive?.workspace?.url)
        workflow.discardArchive()
        XCTAssertNil(workflow.archive); XCTAssertFalse(FileManager.default.fileExists(atPath: discarded.path))
    }

    /// #18: frozen archives in each supported older shape restore; others are rejected.
    func testVersionedBackupFixturesMigrateAndUnsupportedShapesAreRejected() async throws {
        let model = try await context().persistentStoreCoordinator!.managedObjectModel
        XCTAssertEqual(model.versionIdentifiers, [String(BackupSchema.current)], "List new model changes in BackupSchema.changes")
        func package(_ json: String, _ edit: (inout [String: Any]) -> Void = { _ in }) throws -> URL {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]); edit(&object)
            let records = try JSONSerialization.data(withJSONObject: object)
            let folder = self.folder.appending(path: UUID().uuidString)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try records.write(to: folder.appending(path: "records.json"))
            try JSONEncoder().encode(BackupArchive.Manifest(format: "com.cuekeeper.backup", version: 2, recordsSHA256: BackupFiles.digest(records), receipts: 0))
                .write(to: folder.appending(path: "manifest.json"))
            let url = folder.appending(path: "backup.zip")
            let zip = try Archive(url: url, accessMode: .create)
            for name in ["manifest.json", "records.json"] { try zip.addEntry(with: name, relativeTo: folder) }
            return url
        }
        for fixture in [LegacyBackups.v11, LegacyBackups.v13] {
            let target = try await context()
            let archive = try BackupArchive.readPackage(try package(fixture), model: model)
            XCTAssertFalse(archive.records.contains { $0.key.entity == "BroadcastLink" })
            XCTAssertEqual(try archive.restore(in: target).added, archive.records.count)
            let job = try XCTUnwrap(target.fetch(NSFetchRequest<Job>(entityName: "Job")).first)
            XCTAssertEqual(job.client?.invoicingJSON, ""); XCTAssertNil(job.event?.ownerJobID); XCTAssertEqual(job.event?.id, job.id)
            XCTAssertEqual(job.activeSessions.count, 1); XCTAssertEqual(try job.currentFee().amount, 10000)
            XCTAssertEqual(try XCTUnwrap(target.fetch(NSFetchRequest<Invoice>(entityName: "Invoice")).first).balance(), 7500)
            XCTAssertNoThrow(try BackupArchive.capture(in: target))
        }
        let rejected: [(String, (inout [String: Any]) -> Void, String)] = [
            ("newer", { $0["model"] = BackupSchema.current + 1 }, "Update Cuekeeper"),
            ("declared current with old shape", { $0["model"] = BackupSchema.current }, "Job is missing expenses"),
            ("contradictory shape", { archive in
                var records = archive["records"] as! [[String: Any]]
                let index = records.firstIndex { ($0["key"] as! [String: Any])["entity"] as! String == "Client" }!
                var attributes = records[index]["attributes"] as! [String: Any]
                attributes["invoicingJSON"] = ["string": ["_0": ""]]; records[index]["attributes"] = attributes
                archive["records"] = records
            }, "damaged or was edited"),
        ]
        for (name, edit, message) in rejected {
            XCTAssertThrowsError(try BackupArchive.readPackage(try package(LegacyBackups.v11, edit), model: model), name) { error in
                XCTAssertTrue(error.localizedDescription.contains(message), "\(name): \(error.localizedDescription)")
            }
        }
    }

    func testCrossStoreRestoreOfDuplicateEventMetadataStabilizes() async throws {
        let a = try await context(); let job = try fixture(a)
        _ = try conflictingPromotions(in: a, job: job)
        let b = try await context(); try cloudCopy(from: a, into: b)
        let count = { (context: NSManagedObjectContext) in try context.count(for: NSFetchRequest<WorkEvent>(entityName: "WorkEvent")) }
        XCTAssertEqual(try count(a), 3); XCTAssertEqual(try count(b), 3)
        for _ in 0..<2 {
            _ = try BackupArchive.capture(in: a).restore(in: b)
            _ = try BackupArchive.capture(in: b).restore(in: a)
        }
        XCTAssertEqual(try count(a), 3, "Restoring the same metadata must not add copies")
        XCTAssertEqual(try count(b), 3)
        XCTAssertEqual(Set(try BackupArchive.capture(in: a).records.map(\.key)), Set(try BackupArchive.capture(in: b).records.map(\.key)))
        for context in [a, b] {
            let owner = try XCTUnwrap(context.fetch(NSFetchRequest<Job>(entityName: "Job")).first)
            XCTAssertEqual(owner.event?.notes, "Device B notes")
            XCTAssertEqual(owner.event?.id, owner.id)
            XCTAssertEqual(try context.fetch(NSFetchRequest<WorkEvent>(entityName: "WorkEvent")).filter { $0.notes == "Device A notes" }.count, 1)
        }
        // #10: a store restored before iCloud arrived holds the duplicate under its
        // derived ID; once iCloud's original arrives, that orphan copy is removed.
        let c = try await context()
        _ = try BackupArchive.capture(in: a).restore(in: c)
        try cloudCopy(from: a, into: c)
        _ = try IdentityReconciliation.reconcile(in: c)
        XCTAssertEqual(try count(c), 3)
        XCTAssertEqual(try c.fetch(NSFetchRequest<WorkEvent>(entityName: "WorkEvent")).filter { $0.notes == "Device A notes" }.count, 1)
        XCTAssertEqual(try XCTUnwrap(c.fetch(NSFetchRequest<Job>(entityName: "Job")).first).event?.notes, "Device B notes")
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
        // A model 12 archive: no ownership field, no client invoicing, sessions still had links.
        var oldArchive = try BackupArchive.capture(in: source)
        oldArchive.model = nil
        for index in oldArchive.records.indices {
            switch oldArchive.records[index].key.entity {
            case "WorkEvent": oldArchive.records[index].attributes.removeValue(forKey: "ownerJobID")
            case "Client": oldArchive.records[index].attributes.removeValue(forKey: "invoicingJSON")
            case "WorkSession": oldArchive.records[index].relationships["links"] = []
            default: break
            }
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

    func testIdenticalLiveFinancialDuplicateMergesOnRestore() async throws {
        let context = try await context(); _ = try fixture(context)
        let archive = try BackupArchive.capture(in: context)
        let payment = try XCTUnwrap(context.fetch(NSFetchRequest<PaymentRecord>(entityName: "PaymentRecord")).first)
        let duplicate = NSEntityDescription.insertNewObject(forEntityName: "PaymentRecord", into: context)
        for name in payment.entity.attributesByName.keys {
            duplicate.setValue(payment.value(forKey: name), forKey: name)
        }
        duplicate.setValue(payment.value(forKey: "invoice"), forKey: "invoice")
        try context.save()
        XCTAssertEqual(try BackupArchive.capture(in: context).conflicts.count, 1, "Backups save the copy as it is")
        // Identical copies are one record: restore merges them before matching identities.
        XCTAssertEqual(try archive.restore(in: context).added, 0)
        XCTAssertEqual(try context.count(for: NSFetchRequest<PaymentRecord>(entityName: "PaymentRecord")), 1)
        XCTAssertEqual(try XCTUnwrap(context.fetch(NSFetchRequest<Invoice>(entityName: "Invoice")).first).balance(), 7500)
        XCTAssertNoThrow(try BackupArchive.capture(in: context))
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

/// Archives frozen in the shape older Cuekeeper versions wrote (no `model` field).
private enum LegacyBackups {
    static let v11 = #"{"createdAt":813933733.038917,"format":"com.cuekeeper.backup","records":[{"attributes":{"contact":{"string":{"_0":""}},"defaultCurrency":{"string":{"_0":"USD"}},"id":{"uuid":{"_0":"DB57AF5C-2582-4160-AA1C-1B6FB899BD74"}},"name":{"string":{"_0":"Network"}},"notes":{"string":{"_0":""}}},"key":{"entity":"Client","id":"DB57AF5C-2582-4160-AA1C-1B6FB899BD74"},"relationships":{"invoices":[{"entity":"Invoice","id":"CD54017B-4942-4DBC-BEED-92C00E79D408"}],"jobs":[{"entity":"Job","id":"B87C2C31-C2E0-4A97-8A09-2A7423292BDD"}]}},{"attributes":{"createdAt":{"date":{"_0":813933733.027728}},"id":{"uuid":{"_0":"D2C2B553-8116-496F-A431-F07D505C8580"}},"parentsJSON":{"string":{"_0":"[]"}},"valueJSON":{"string":{"_0":"{\"currency\":\"USD\",\"amount\":10000,\"agreement\":\"unknown\",\"lines\":[]}"}}},"key":{"entity":"FeeRevision","id":"D2C2B553-8116-496F-A431-F07D505C8580"},"relationships":{"job":[{"entity":"Job","id":"B87C2C31-C2E0-4A97-8A09-2A7423292BDD"}]}},{"attributes":{"createdAt":{"date":{"_0":813933733.032361}},"id":{"uuid":{"_0":"CD54017B-4942-4DBC-BEED-92C00E79D408"}}},"key":{"entity":"Invoice","id":"CD54017B-4942-4DBC-BEED-92C00E79D408"},"relationships":{"client":[{"entity":"Client","id":"DB57AF5C-2582-4160-AA1C-1B6FB899BD74"}],"payments":[{"entity":"PaymentRecord","id":"EC153489-1C2C-462D-B451-F593CC3EBF8C"}],"revisions":[{"entity":"InvoiceRevision","id":"6B8D48F9-30DF-417F-9BFE-A17A501F7BB0"}]}},{"attributes":{"createdAt":{"date":{"_0":813933733.032445}},"id":{"uuid":{"_0":"6B8D48F9-30DF-417F-9BFE-A17A501F7BB0"}},"parentsJSON":{"string":{"_0":"[]"}},"valueJSON":{"string":{"_0":"{\"reference\":\"INV-RECOVERY\",\"status\":\"sent\",\"sentDay\":\"2026-10-17\",\"dueDay\":\"\",\"clientID\":\"DB57AF5C-2582-4160-AA1C-1B6FB899BD74\",\"currency\":\"USD\",\"notes\":\"\",\"lines\":[{\"jobName\":\"Broadcast weekend\",\"jobID\":\"B87C2C31-C2E0-4A97-8A09-2A7423292BDD\",\"amount\":10000}]}"}}},"key":{"entity":"InvoiceRevision","id":"6B8D48F9-30DF-417F-9BFE-A17A501F7BB0"},"relationships":{"invoice":[{"entity":"Invoice","id":"CD54017B-4942-4DBC-BEED-92C00E79D408"}]}},{"attributes":{"bookingStatus":{"string":{"_0":"tentative"}},"createdAt":{"date":{"_0":813933733.02702}},"deletedAt":{"null":{}},"endDay":{"string":{"_0":"2026-10-17"}},"id":{"uuid":{"_0":"B87C2C31-C2E0-4A97-8A09-2A7423292BDD"}},"location":{"string":{"_0":""}},"name":{"string":{"_0":"Broadcast weekend"}},"notes":{"string":{"_0":""}},"recoveryDiscardedAt":{"null":{}},"startDay":{"string":{"_0":"2026-10-17"}},"timeZoneID":{"string":{"_0":"Europe/London"}},"trackPlaceID":{"string":{"_0":""}},"workArrangement":{"string":{"_0":"unspecified"}}},"key":{"entity":"Job","id":"B87C2C31-C2E0-4A97-8A09-2A7423292BDD"},"relationships":{"additionalSeries":[],"client":[{"entity":"Client","id":"DB57AF5C-2582-4160-AA1C-1B6FB899BD74"}],"event":[{"entity":"WorkEvent","id":"B87C2C31-C2E0-4A97-8A09-2A7423292BDD"}],"feeRevisions":[{"entity":"FeeRevision","id":"D2C2B553-8116-496F-A431-F07D505C8580"}],"payments":[],"project":[],"roles":[{"entity":"WorkRole","id":"4E4F1464-5AE4-4D3F-9DD4-29366EECD14C"}],"series":[],"sessions":[{"entity":"WorkSession","id":"0112FAA6-5439-4FD4-AB9C-51751EFACC28"}]}},{"attributes":{"amount":{"integer":{"_0":2500}},"createdAt":{"date":{"_0":813933733.033922}},"currency":{"string":{"_0":"USD"}},"id":{"uuid":{"_0":"EC153489-1C2C-462D-B451-F593CC3EBF8C"}},"note":{"string":{"_0":""}},"receivedAt":{"date":{"_0":813933733.032978}},"reversesID":{"null":{}}},"key":{"entity":"PaymentRecord","id":"EC153489-1C2C-462D-B451-F593CC3EBF8C"},"relationships":{"invoice":[{"entity":"Invoice","id":"CD54017B-4942-4DBC-BEED-92C00E79D408"}],"job":[]}},{"attributes":{"endDay":{"string":{"_0":"2026-10-17"}},"id":{"uuid":{"_0":"B87C2C31-C2E0-4A97-8A09-2A7423292BDD"}},"location":{"string":{"_0":""}},"notes":{"string":{"_0":""}},"startDay":{"string":{"_0":"2026-10-17"}},"timeZoneID":{"string":{"_0":"Europe/London"}},"title":{"string":{"_0":"Broadcast weekend"}},"trackPlaceID":{"string":{"_0":""}}},"key":{"entity":"WorkEvent","id":"B87C2C31-C2E0-4A97-8A09-2A7423292BDD"},"relationships":{"bookings":[{"entity":"Job","id":"B87C2C31-C2E0-4A97-8A09-2A7423292BDD"}]}},{"attributes":{"id":{"uuid":{"_0":"4E4F1464-5AE4-4D3F-9DD4-29366EECD14C"}},"name":{"string":{"_0":"Commentator"}}},"key":{"entity":"WorkRole","id":"4E4F1464-5AE4-4D3F-9DD4-29366EECD14C"},"relationships":{"jobs":[{"entity":"Job","id":"B87C2C31-C2E0-4A97-8A09-2A7423292BDD"}],"sessions":[]}},{"attributes":{"callTime":{"null":{}},"coverage":{"string":{"_0":"covering"}},"day":{"string":{"_0":"2026-10-17"}},"deletedAt":{"null":{}},"endTime":{"date":{"_0":813937333.029758}},"id":{"uuid":{"_0":"0112FAA6-5439-4FD4-AB9C-51751EFACC28"}},"name":{"string":{"_0":""}},"notes":{"string":{"_0":""}},"overridesRoles":{"boolean":{"_0":false}},"overridesSeries":{"boolean":{"_0":false}},"recoveryDiscardedAt":{"null":{}},"scheduleStatus":{"string":{"_0":"confirmed"}},"startTime":{"date":{"_0":813933733.029758}},"timeZoneID":{"string":{"_0":"Europe/London"}}},"key":{"entity":"WorkSession","id":"0112FAA6-5439-4FD4-AB9C-51751EFACC28"},"relationships":{"job":[{"entity":"Job","id":"B87C2C31-C2E0-4A97-8A09-2A7423292BDD"}],"links":[{"entity":"BroadcastLink","id":"0B0ADCA5-7000-4000-8000-000000000011"}],"roles":[],"series":[]}},{"attributes":{"id":{"uuid":{"_0":"0B0ADCA5-7000-4000-8000-000000000011"}},"label":{"string":{"_0":"Feed"}},"notes":{"string":{"_0":""}},"url":{"string":{"_0":"https://example.com/live"}}},"key":{"entity":"BroadcastLink","id":"0B0ADCA5-7000-4000-8000-000000000011"},"relationships":{"session":[{"entity":"WorkSession","id":"0112FAA6-5439-4FD4-AB9C-51751EFACC28"}]}}],"version":2}"#
    static let v13 = #"{"createdAt":813933733.038917,"format":"com.cuekeeper.backup","records":[{"attributes":{"contact":{"string":{"_0":""}},"defaultCurrency":{"string":{"_0":"USD"}},"id":{"uuid":{"_0":"DB57AF5C-2582-4160-AA1C-1B6FB899BD74"}},"name":{"string":{"_0":"Network"}},"notes":{"string":{"_0":""}}},"key":{"entity":"Client","id":"DB57AF5C-2582-4160-AA1C-1B6FB899BD74"},"relationships":{"invoices":[{"entity":"Invoice","id":"CD54017B-4942-4DBC-BEED-92C00E79D408"}],"jobs":[{"entity":"Job","id":"B87C2C31-C2E0-4A97-8A09-2A7423292BDD"}]}},{"attributes":{"createdAt":{"date":{"_0":813933733.027728}},"id":{"uuid":{"_0":"D2C2B553-8116-496F-A431-F07D505C8580"}},"parentsJSON":{"string":{"_0":"[]"}},"valueJSON":{"string":{"_0":"{\"currency\":\"USD\",\"amount\":10000,\"agreement\":\"unknown\",\"lines\":[]}"}}},"key":{"entity":"FeeRevision","id":"D2C2B553-8116-496F-A431-F07D505C8580"},"relationships":{"job":[{"entity":"Job","id":"B87C2C31-C2E0-4A97-8A09-2A7423292BDD"}]}},{"attributes":{"createdAt":{"date":{"_0":813933733.032361}},"id":{"uuid":{"_0":"CD54017B-4942-4DBC-BEED-92C00E79D408"}}},"key":{"entity":"Invoice","id":"CD54017B-4942-4DBC-BEED-92C00E79D408"},"relationships":{"client":[{"entity":"Client","id":"DB57AF5C-2582-4160-AA1C-1B6FB899BD74"}],"payments":[{"entity":"PaymentRecord","id":"EC153489-1C2C-462D-B451-F593CC3EBF8C"}],"revisions":[{"entity":"InvoiceRevision","id":"6B8D48F9-30DF-417F-9BFE-A17A501F7BB0"}]}},{"attributes":{"createdAt":{"date":{"_0":813933733.032445}},"id":{"uuid":{"_0":"6B8D48F9-30DF-417F-9BFE-A17A501F7BB0"}},"parentsJSON":{"string":{"_0":"[]"}},"valueJSON":{"string":{"_0":"{\"reference\":\"INV-RECOVERY\",\"status\":\"sent\",\"sentDay\":\"2026-10-17\",\"dueDay\":\"\",\"clientID\":\"DB57AF5C-2582-4160-AA1C-1B6FB899BD74\",\"currency\":\"USD\",\"notes\":\"\",\"lines\":[{\"jobName\":\"Broadcast weekend\",\"jobID\":\"B87C2C31-C2E0-4A97-8A09-2A7423292BDD\",\"amount\":10000}]}"}}},"key":{"entity":"InvoiceRevision","id":"6B8D48F9-30DF-417F-9BFE-A17A501F7BB0"},"relationships":{"invoice":[{"entity":"Invoice","id":"CD54017B-4942-4DBC-BEED-92C00E79D408"}]}},{"attributes":{"bookingStatus":{"string":{"_0":"tentative"}},"createdAt":{"date":{"_0":813933733.02702}},"deletedAt":{"null":{}},"endDay":{"string":{"_0":"2026-10-17"}},"id":{"uuid":{"_0":"B87C2C31-C2E0-4A97-8A09-2A7423292BDD"}},"location":{"string":{"_0":""}},"name":{"string":{"_0":"Broadcast weekend"}},"notes":{"string":{"_0":""}},"recoveryDiscardedAt":{"null":{}},"startDay":{"string":{"_0":"2026-10-17"}},"timeZoneID":{"string":{"_0":"Europe/London"}},"trackPlaceID":{"string":{"_0":""}},"workArrangement":{"string":{"_0":"unspecified"}}},"key":{"entity":"Job","id":"B87C2C31-C2E0-4A97-8A09-2A7423292BDD"},"relationships":{"additionalSeries":[],"client":[{"entity":"Client","id":"DB57AF5C-2582-4160-AA1C-1B6FB899BD74"}],"event":[{"entity":"WorkEvent","id":"B87C2C31-C2E0-4A97-8A09-2A7423292BDD"}],"expenses":[],"feeRevisions":[{"entity":"FeeRevision","id":"D2C2B553-8116-496F-A431-F07D505C8580"}],"payments":[],"project":[],"roles":[{"entity":"WorkRole","id":"4E4F1464-5AE4-4D3F-9DD4-29366EECD14C"}],"series":[],"sessions":[{"entity":"WorkSession","id":"0112FAA6-5439-4FD4-AB9C-51751EFACC28"}]}},{"attributes":{"amount":{"integer":{"_0":2500}},"createdAt":{"date":{"_0":813933733.033922}},"currency":{"string":{"_0":"USD"}},"id":{"uuid":{"_0":"EC153489-1C2C-462D-B451-F593CC3EBF8C"}},"note":{"string":{"_0":""}},"receivedAt":{"date":{"_0":813933733.032978}},"reversesID":{"null":{}}},"key":{"entity":"PaymentRecord","id":"EC153489-1C2C-462D-B451-F593CC3EBF8C"},"relationships":{"invoice":[{"entity":"Invoice","id":"CD54017B-4942-4DBC-BEED-92C00E79D408"}],"job":[]}},{"attributes":{"endDay":{"string":{"_0":"2026-10-17"}},"id":{"uuid":{"_0":"B87C2C31-C2E0-4A97-8A09-2A7423292BDD"}},"location":{"string":{"_0":""}},"notes":{"string":{"_0":""}},"ownerJobID":{"null":{}},"startDay":{"string":{"_0":"2026-10-17"}},"timeZoneID":{"string":{"_0":"Europe/London"}},"title":{"string":{"_0":"Broadcast weekend"}},"trackPlaceID":{"string":{"_0":""}}},"key":{"entity":"WorkEvent","id":"B87C2C31-C2E0-4A97-8A09-2A7423292BDD"},"relationships":{"bookings":[{"entity":"Job","id":"B87C2C31-C2E0-4A97-8A09-2A7423292BDD"}]}},{"attributes":{"id":{"uuid":{"_0":"4E4F1464-5AE4-4D3F-9DD4-29366EECD14C"}},"name":{"string":{"_0":"Commentator"}}},"key":{"entity":"WorkRole","id":"4E4F1464-5AE4-4D3F-9DD4-29366EECD14C"},"relationships":{"jobs":[{"entity":"Job","id":"B87C2C31-C2E0-4A97-8A09-2A7423292BDD"}],"sessions":[]}},{"attributes":{"callTime":{"null":{}},"coverage":{"string":{"_0":"covering"}},"day":{"string":{"_0":"2026-10-17"}},"deletedAt":{"null":{}},"endTime":{"date":{"_0":813937333.029758}},"id":{"uuid":{"_0":"0112FAA6-5439-4FD4-AB9C-51751EFACC28"}},"name":{"string":{"_0":""}},"notes":{"string":{"_0":""}},"overridesRoles":{"boolean":{"_0":false}},"overridesSeries":{"boolean":{"_0":false}},"recoveryDiscardedAt":{"null":{}},"scheduleStatus":{"string":{"_0":"confirmed"}},"startTime":{"date":{"_0":813933733.029758}},"timeZoneID":{"string":{"_0":"Europe/London"}}},"key":{"entity":"WorkSession","id":"0112FAA6-5439-4FD4-AB9C-51751EFACC28"},"relationships":{"job":[{"entity":"Job","id":"B87C2C31-C2E0-4A97-8A09-2A7423292BDD"}],"links":[{"entity":"BroadcastLink","id":"0B0ADCA5-7000-4000-8000-000000000011"}],"roles":[],"series":[]}},{"attributes":{"id":{"uuid":{"_0":"0B0ADCA5-7000-4000-8000-000000000011"}},"label":{"string":{"_0":"Feed"}},"notes":{"string":{"_0":""}},"url":{"string":{"_0":"https://example.com/live"}}},"key":{"entity":"BroadcastLink","id":"0B0ADCA5-7000-4000-8000-000000000011"},"relationships":{"session":[{"entity":"WorkSession","id":"0112FAA6-5439-4FD4-AB9C-51751EFACC28"}]}}],"version":2}"#
}

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
