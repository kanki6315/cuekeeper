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
        draft.events[1].sessions = []
        let ids = try draft.save(in: context)
        let first = try XCTUnwrap(context.existingObject(with: ids[0]) as? Job)
        let second = try XCTUnwrap(context.existingObject(with: ids[1]) as? Job)
        XCTAssertEqual(Set(first.seriesNames), ["Main", "Support"])
        XCTAssertEqual(first.allSeries, second.allSeries)
        XCTAssertEqual(try first.currentFee().amount, 15000)
        XCTAssertEqual(first.activeSessions.count, 1)
        XCTAssertNil(first.activeSessions.first?.effectiveSeries)
        XCTAssertTrue(first.name.hasPrefix("Championship season"))
        var filter = JobFilter(); filter.series = "Support"
        XCTAssertTrue(filter.includes(first))
        var edit = JobDraft(job: first); let baseline = edit
        edit.seriesNames = ["Support"]
        try edit.save(in: context, editing: first.objectID, baseline: baseline)
        XCTAssertEqual(first.seriesNames, ["Support"])
        XCTAssertEqual(second.seriesNames.count, 2)
    }

    func testSessionCopyPreservesWallTimeAcrossDSTAndAppends() throws {
        var draft = EventCreationDraft()
        let sourceDate = try XCTUnwrap(Day.date(from: "2026-03-01"))
        let destinationDate = try XCTUnwrap(Day.date(from: "2026-03-15"))
        draft.events[0].details.startDate = sourceDate
        var session = SessionDraft(day: "2026-03-01", timeZoneID: "America/New_York")
        let formatter = ISO8601DateFormatter()
        session.startTime = formatter.date(from: "2026-03-01T15:00:00Z")
        session.endTime = formatter.date(from: "2026-03-01T16:00:00Z")
        session.scheduleStatus = "confirmed"; session.coverage = "covering"
        draft.events[0].sessions = [session]
        var destination = EventOutline(); destination.details.startDate = destinationDate
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
        state.offline = true; XCTAssertEqual(state.message, "Offline — changes saved on this device")
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

    func testV2ThroughV6StoresMigrateWithRelationshipsAndFeeHistory() async throws {
        let modelURL = try XCTUnwrap(Bundle(for: Job.self).url(forResource: "Cuekeeper", withExtension: "momd"))
        for version in 2...6 {
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
                let championship = NSEntityDescription.insertNewObject(forEntityName: "WorkSeries", into: oldContext)
                championship.setValue(UUID(), forKey: "id"); championship.setValue("Existing championship", forKey: "name")
                job.setValue(championship, forKey: "series")
            }
            try oldContext.save(); oldContext.reset(); try coordinator.remove(oldStore)
            let migrated = try await openStore(fileName: fileName)
            let saved = try XCTUnwrap(migrated.container.viewContext.fetch(NSFetchRequest<Job>(entityName: "Job")).first)
            XCTAssertNil(saved.project)
            if version >= 6 { XCTAssertEqual(saved.seriesNames, ["Existing championship"]) }
            else { XCTAssertNil(saved.series) }
            XCTAssertEqual(saved.id, jobID); XCTAssertEqual(saved.client?.name, "Existing client")
            if version >= 3 { XCTAssertEqual(saved.activeSessions.first?.sortedLinks.first?.url, "https://example.com/old") }
            if version >= 4 { XCTAssertEqual(try saved.currentFee().amount, 12345) }
            XCTAssertEqual(try saved.directPaid(), 0)
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
