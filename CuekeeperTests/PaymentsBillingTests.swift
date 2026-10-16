import CoreData
import XCTest
@testable import Cuekeeper

@MainActor
final class PaymentsBillingTests: XCTestCase {
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
        stores = []; try FileManager.default.removeItem(at: folder)
    }
    private func context() async throws -> NSManagedObjectContext {
        let store = PersistenceController(storeURL: folder.appending(path: "\(UUID()).sqlite"), cloudEnabled: false)
        stores.append(store); try await store.waitUntilLoaded(); return store.container.viewContext
    }

    private func completedJob(_ name: String, client: String = "Northside", amount: Int64 = 65_000, currency: String = "EUR", in context: NSManagedObjectContext) throws -> Job {
        var draft = JobDraft(name: name)
        draft.clientName = client
        draft.bookingStatus = .completed
        draft.fee?.currency = currency
        draft.fee?.amount = Money.text(amount, currency: currency)
        return try XCTUnwrap(context.existingObject(with: try draft.save(in: context)) as? Job)
    }

    private func receipt(for job: Job, amount: String = "25.80", currency: String = "EUR", reimbursable: Bool, finished: Bool = true, in context: NSManagedObjectContext) throws -> Expense {
        let id = try Expense.capture(Data([1, 2, 3]), jobID: job.objectID, in: context)
        let expense = try XCTUnwrap(context.existingObject(with: id) as? Expense)
        let value = ExpenseValue(merchant: "Parking", day: "2026-10-13", amount: amount, currency: currency, category: "Parking", reimbursable: reimbursable)
        try Expense.save(value, id: id, revision: expense.revision, confirmed: finished, in: context)
        return expense
    }

    private func completeDetails(_ client: Client, in context: NSManagedObjectContext) throws {
        try Client.saveInvoicing(ClientInvoicing(billingName: "Northside Sports Media", email: "accounts@example.com", address: "1 Road", termsDays: 30),
                                 client: client.objectID, in: context)
    }

    func testReadinessReadsReimbursableDraftsAndClientDetails() async throws {
        let context = try await context()
        let job = try completedJob("City vs United", in: context)
        var event = EventReadiness(ReadinessFacts(job: job, context: context, index: InvoiceIndex(in: context)), today: "2026-10-16")
        XCTAssertEqual(event.gates[.client], .missing)
        try completeDetails(try XCTUnwrap(job.client), in: context)
        let meal = try receipt(for: job, reimbursable: false, finished: false, in: context)
        event = EventReadiness(ReadinessFacts(job: job, context: context, index: InvoiceIndex(in: context)), today: "2026-10-16")
        XCTAssertEqual(event.gates[.receipts], .missing, "Any draft holds up invoicing until the bookkeeping is done")
        try Expense.save(meal.value, id: meal.objectID, revision: meal.revision, in: context)
        event = EventReadiness(ReadinessFacts(job: job, context: context, index: InvoiceIndex(in: context)), today: "2026-10-16")
        XCTAssertEqual(event.state, .ready, "A finished non-reimbursable receipt never blocks")
        XCTAssertTrue(event.facts.rebillable.isEmpty)
        let fuel = try receipt(for: job, amount: "38.40", reimbursable: true, finished: false, in: context)
        event = EventReadiness(ReadinessFacts(job: job, context: context, index: InvoiceIndex(in: context)), today: "2026-10-16")
        XCTAssertEqual(event.gates[.receipts], .missing)
        try Expense.save(fuel.value, id: fuel.objectID, revision: fuel.revision, in: context)
        event = EventReadiness(ReadinessFacts(job: job, context: context, index: InvoiceIndex(in: context)), today: "2026-10-16")
        XCTAssertEqual(event.state, .ready)
        XCTAssertEqual(event.facts.rebillable.map(\.id), [fuel.id])
    }

    func testRebilledReceiptsSaveOnceAndOnlyWhenEligible() async throws {
        let context = try await context()
        let job = try completedJob("Cup quarter-final", in: context)
        let client = try XCTUnwrap(job.client)
        let parking = try receipt(for: job, reimbursable: true, in: context)
        let meal = try receipt(for: job, amount: "12.00", reimbursable: false, in: context)
        let draftFuel = try receipt(for: job, amount: "38.40", reimbursable: true, finished: false, in: context)
        let usd = try receipt(for: job, amount: "10.00", currency: "USD", reimbursable: true, in: context)

        func invoice(_ expenses: [Expense]) -> InvoiceDraft {
            var draft = InvoiceDraft(clientID: client.id!, currency: "EUR")
            draft.value.lines = [BilledLine(jobID: job.id!, jobName: job.displayName, amount: 65_000)]
            draft.value.expenseLines = expenses.compactMap(InvoiceEditorView.billed)
            return draft
        }
        XCTAssertThrowsError(try invoice([meal]).save(in: context), "Non-reimbursable receipts cannot be billed")
        XCTAssertThrowsError(try invoice([draftFuel]).save(in: context), "Draft receipts cannot be billed")
        XCTAssertThrowsError(try invoice([usd]).save(in: context), "Receipts must match the invoice currency")

        let id = try invoice([parking]).save(in: context)
        let saved = try XCTUnwrap(context.existingObject(with: id) as? Invoice)
        XCTAssertEqual(try saved.currentValue().total(), 67_580)
        XCTAssertEqual(try parking.activeInvoices(index: InvoiceIndex(in: context)).count, 1)
        XCTAssertNil(saved.issue(in: context))

        // The same receipt cannot go on a second active invoice, even with another event.
        let other = try completedJob("City vs United", in: context)
        var second = InvoiceDraft(clientID: client.id!, currency: "EUR")
        second.value.lines = [BilledLine(jobID: other.id!, jobName: other.displayName, amount: 65_000)]
        second.value.expenseLines = [InvoiceEditorView.billed(parking)!]
        XCTAssertThrowsError(try second.save(in: context))

        // Once rebilled it is no longer offered; the unbilled USD receipt still is.
        let facts = ReadinessFacts(job: job, context: context, index: InvoiceIndex(in: context))
        XCTAssertEqual(facts.rebillable.map(\.id), [usd.id])

        // Voiding releases it.
        var void = try InvoiceDraft(invoice: saved)
        void.value.status = "void"
        try void.save(in: context, editing: id)
        XCTAssertTrue(try parking.activeInvoices(index: InvoiceIndex(in: context)).isEmpty)
    }

    func testSentInvoiceKeepsItsReceiptLines() async throws {
        let context = try await context()
        let job = try completedJob("Autumn Classic", in: context)
        let parking = try receipt(for: job, reimbursable: true, in: context)
        var draft = InvoiceDraft(clientID: job.client!.id!, currency: "EUR")
        draft.value.lines = [BilledLine(jobID: job.id!, jobName: job.displayName, amount: 65_000)]
        draft.value.expenseLines = [InvoiceEditorView.billed(parking)!]
        draft.value.status = "sent"; draft.value.reference = "INV-1"; draft.value.sentDay = "2026-10-16"
        let id = try draft.save(in: context)
        let invoice = try XCTUnwrap(context.existingObject(with: id) as? Invoice)
        var edit = try InvoiceDraft(invoice: invoice)
        edit.value.expenseLines = nil
        XCTAssertThrowsError(try edit.save(in: context, editing: id), "Billed receipts are part of a sent invoice's terms")
    }

    func testClientInvoicingSavesAndSurvivesBackupWithoutTheField() async throws {
        let context = try await context()
        let job = try completedJob("Harbour regatta", client: "Velocity TV", in: context)
        let client = try XCTUnwrap(job.client)
        try completeDetails(client, in: context)
        XCTAssertTrue(client.invoicing.isComplete)
        XCTAssertThrowsError(try Client.saveInvoicing(ClientInvoicing(email: "bad"), client: client.objectID, in: context))

        // A pre-V15 archive has no invoicingJSON on clients; it still restores.
        var archive = try BackupArchive.capture(in: context)
        archive.records = archive.records.map { record in
            var record = record
            if record.key.entity == "Client" { record.attributes["invoicingJSON"] = nil }
            return record
        }
        let target = try await self.context()
        XCTAssertGreaterThan(try archive.restore(in: target).added, 0)
        let restored = try XCTUnwrap(target.fetch(NSFetchRequest<Client>(entityName: "Client")).first)
        XCTAssertEqual(restored.invoicingJSON, "")
        XCTAssertFalse(restored.invoicing.isComplete)
    }

    func testLibraryDraftSavesInvoicingDetails() async throws {
        let context = try await context()
        var draft = LibraryDraft()
        draft.name = "Trackside Radio"
        draft.invoicing.billingName = "Trackside Radio Ltd"
        draft.invoicing.email = "pay@example.com"
        draft.invoicing.address = "2 Lane"
        draft.invoicing.terms = "14"
        try draft.save(entity: "Client", editing: nil, baseline: LibraryDraft(), in: context)
        let client = try XCTUnwrap(context.fetch(NSFetchRequest<Client>(entityName: "Client")).first)
        XCTAssertEqual(client.invoicing.termsDays, 14)
        XCTAssertTrue(client.invoicing.isComplete)
        var bad = LibraryDraft(record: client)
        bad.invoicing.terms = "two weeks"
        XCTAssertThrowsError(try bad.save(entity: "Client", editing: client.objectID, baseline: LibraryDraft(record: client), in: context))
    }

    func testPaymentsFixtureSeedsAMonthWithEveryState() async throws {
        let context = try await context()
        do { try DesignFixtures.seedPayments(context) } catch { XCTFail("Seeding failed: \(error.localizedDescription)"); return }
        let jobs = try context.fetch(NSFetchRequest<Job>(entityName: "Job"))
        let month = PaymentsMonth.load(month: String(Day.string(from: Date()).prefix(7)), jobs: jobs,
                                       invoices: try context.fetch(NSFetchRequest<Invoice>(entityName: "Invoice")), context: context, displayed: ["USD", "EUR"])
        let states = Set(month.events.map { "\($0.state)".components(separatedBy: "(").first! })
        for expected in ["ready", "heldUp", "upcoming", "draft", "paid", "directPaid", "noFee"] { XCTAssertTrue(states.contains(expected), expected) }
        XCTAssertEqual(month.earlier.count, 3)
    }

    func testEventPageAsksForInvoicingDetailsBeforeReadyToInvoice() async throws {
        let context = try await context()
        let job = try completedJob("Season launch", in: context)
        var items = EventDetailSummary(facts: EventDetailFacts(job: job, context: context), now: Date()).openItems.map(\.kind)
        XCTAssertTrue(items.contains(.clientDetails)); XCTAssertFalse(items.contains(.readyToInvoice))
        try completeDetails(try XCTUnwrap(job.client), in: context)
        _ = try receipt(for: job, amount: "38.40", reimbursable: true, finished: false, in: context)
        items = EventDetailSummary(facts: EventDetailFacts(job: job, context: context), now: Date()).openItems.map(\.kind)
        XCTAssertFalse(items.contains(.readyToInvoice), "A draft receipt holds the invoice")
        XCTAssertTrue(items.contains(.expenseDraft))
    }
}
