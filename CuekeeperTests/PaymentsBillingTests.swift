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
        edit.value.expenseLines = []
        XCTAssertThrowsError(try edit.save(in: context, editing: id), "Billed receipts are part of a sent invoice's terms")
    }

    func testBilledReceiptEditsStayConsistentWithTheirInvoice() async throws {
        let context = try await context()
        let job = try completedJob("Derby day", in: context)
        let elsewhere = try completedJob("Harbour regatta", client: "Velocity TV", in: context)
        let parking = try receipt(for: job, reimbursable: true, in: context)
        var draft = InvoiceDraft(clientID: job.client!.id!, currency: "EUR")
        draft.value.lines = [BilledLine(jobID: job.id!, jobName: job.displayName, amount: 65_000)]
        draft.value.expenseLines = [InvoiceEditorView.billed(parking)!]
        let id = try draft.save(in: context)
        let invoice = try XCTUnwrap(context.existingObject(with: id) as? Invoice)

        func edit(_ change: (inout ExpenseValue) -> Void, jobID: NSManagedObjectID? = nil) throws {
            var value = parking.value; change(&value)
            try Expense.save(value, id: parking.objectID, revision: parking.revision, jobID: jobID, in: context)
        }
        // Draft and sent invoices both fix the receipt's client, currency and reimbursable flag.
        for status in ["draft", "sent"] {
            if status == "sent" {
                var sent = try InvoiceDraft(invoice: invoice)
                sent.value.status = "sent"; sent.value.reference = "INV-7"; sent.value.sentDay = "2026-10-16"
                try sent.save(in: context, editing: id)
            }
            XCTAssertThrowsError(try edit { $0.currency = "USD" }, status)
            XCTAssertThrowsError(try edit { $0.reimbursable = false }, status)
            XCTAssertThrowsError(try edit({ _ in }, jobID: elsewhere.objectID), status)
        }
        // A corrected total is kept on the receipt; the sent invoice keeps what it billed.
        try edit { $0.amount = "27.30" }
        XCTAssertEqual(try invoice.currentValue().expenseLines.first?.amount, 2_580)
        XCTAssertEqual(ExpenseFact.state(parking, index: InvoiceIndex(in: context)), .onInvoice(reference: "INV-7"))

        // Membership wins over a flag changed elsewhere, such as on another device before sync.
        var synced = parking.value; synced.reimbursable = false
        parking.valueJSON = String(decoding: try JSONEncoder().encode(synced), as: UTF8.self); try context.save()
        XCTAssertEqual(ExpenseFact.state(parking, index: InvoiceIndex(in: context)), .onInvoice(reference: "INV-7"), "Still billed, not your cost")

        // Voiding releases the receipt for any edit.
        var void = try InvoiceDraft(invoice: invoice); void.value.status = "void"
        try void.save(in: context, editing: id)
        try edit { $0.currency = "USD" }
        XCTAssertEqual(ExpenseFact.state(parking, index: InvoiceIndex(in: context)), .yourCost)
    }

    func testLateAndOtherCurrencyReceiptsBillOnTheirOwnInvoice() async throws {
        let context = try await context()
        let job = try completedJob("Cup final", in: context)
        let client = try XCTUnwrap(job.client)
        try completeDetails(client, in: context)
        var original = InvoiceDraft(clientID: client.id!, currency: "EUR")
        original.value.lines = [BilledLine(jobID: job.id!, jobName: job.displayName, amount: 65_000)]
        original.value.status = "sent"; original.value.reference = "INV-1"; original.value.sentDay = "2026-10-14"
        let originalID = try original.save(in: context)
        let sent = try XCTUnwrap(context.existingObject(with: originalID) as? Invoice)
        let late = try receipt(for: job, reimbursable: true, in: context)
        let dollars = try receipt(for: job, amount: "10.00", currency: "USD", reimbursable: true, in: context)

        // Expenses offers an invoice for each currency without the already-billed event, totalled in its own currency.
        let month = ExpensesMonth.load(month: "2026-10", expenses: [late, dollars], context: context, today: "2026-10-16")
        XCTAssertEqual(month.rebill.map(\.currency).sorted(), ["EUR", "USD"])
        XCTAssertTrue(month.rebill.allSatisfy { $0.canInvoice && $0.invoiceableJobs.isEmpty })
        XCTAssertEqual(month.rebill.first { $0.currency == "USD" }?.amount, 1_000)

        // The editor lists them as receipts billed alone, and only in their own currency.
        let events = [EventReadiness(ReadinessFacts(job: job, context: context, index: InvoiceIndex(in: context)), today: "2026-10-16")]
        let euros = InvoiceCandidates(events: events, clientID: client.id!, currency: "EUR")
        XCTAssertTrue(euros.ready.isEmpty)
        XCTAssertEqual(euros.receiptsOnly.flatMap(\.receipts).map(\.id), [late.id])
        XCTAssertEqual(InvoiceCandidates(events: events, clientID: client.id!, currency: "USD").receiptsOnly.flatMap(\.receipts).map(\.id), [dollars.id])

        func receiptsOnly(_ expense: Expense, currency: String) -> InvoiceDraft {
            var draft = InvoiceDraft(clientID: client.id!, currency: currency)
            draft.value.expenseLines = [InvoiceEditorView.billed(expense)!]
            return draft
        }
        XCTAssertThrowsError(try receiptsOnly(dollars, currency: "EUR").save(in: context), "Never converted into the invoice currency")
        let supplementalID = try receiptsOnly(late, currency: "EUR").save(in: context)
        _ = try receiptsOnly(dollars, currency: "USD").save(in: context)
        XCTAssertThrowsError(try receiptsOnly(late, currency: "EUR").save(in: context), "A receipt is billed once")
        XCTAssertEqual(try sent.currentValue(), original.value, "The sent invoice is untouched")
        XCTAssertEqual(try sent.currentValue().total(), 65_000)
        XCTAssertEqual(try XCTUnwrap(context.existingObject(with: supplementalID) as? Invoice).currentValue().total(), 2_580, "No second event fee")
        XCTAssertEqual(try job.activeInvoices(in: context).count, 1)
    }

    func testInvoiceReferencesAreUniquePerClientAmongActiveInvoices() async throws {
        let context = try await context()
        let first = try completedJob("Opening round", in: context)
        let second = try completedJob("Second round", in: context)
        let third = try completedJob("Third round", in: context)
        let other = try completedJob("Regatta", client: "Velocity TV", in: context)
        func invoice(_ job: Job, _ reference: String) -> InvoiceDraft {
            var draft = InvoiceDraft(clientID: job.client!.id!, currency: "EUR")
            draft.value.lines = [BilledLine(jobID: job.id!, jobName: job.displayName, amount: 65_000)]
            draft.value.reference = reference
            return draft
        }
        let firstID = try invoice(first, "INV-1").save(in: context)
        XCTAssertThrowsError(try invoice(second, " inv-1 ").save(in: context), "A draft's reference counts, ignoring case and spaces")
        XCTAssertNoThrow(try invoice(other, "INV-1").save(in: context), "Another client may use the same reference")

        // Independently created on two devices: both records are kept and flagged until one is renamed.
        let secondID = try invoice(second, "INV-2").save(in: context)
        let duplicate = try XCTUnwrap(context.existingObject(with: secondID) as? Invoice)
        let revision = try XCTUnwrap(duplicate.revisions?.first)
        var synced = try XCTUnwrap(revision.value); synced.reference = "INV-1"
        revision.valueJSON = String(decoding: try JSONEncoder().encode(synced), as: UTF8.self); try context.save()
        let original = try XCTUnwrap(context.existingObject(with: firstID) as? Invoice)
        XCTAssertNotNil(original.duplicateReference(index: InvoiceIndex(in: context)))
        XCTAssertNotNil(duplicate.duplicateReference(index: InvoiceIndex(in: context)))
        var notes = try InvoiceDraft(invoice: duplicate); notes.value.notes = "Agreed by phone"
        XCTAssertNoThrow(try notes.save(in: context, editing: secondID), "A synced duplicate stays editable so it can be resolved")
        var renamed = try InvoiceDraft(invoice: duplicate); renamed.value.reference = "INV-2"
        try renamed.save(in: context, editing: secondID)
        XCTAssertNil(original.duplicateReference(index: InvoiceIndex(in: context)))

        // A voided invoice keeps its reference as history and frees it for reuse.
        var void = try InvoiceDraft(invoice: original); void.value.status = "void"
        try void.save(in: context, editing: firstID)
        XCTAssertNoThrow(try invoice(third, "INV-1").save(in: context))
    }

    func testAutomaticDueDatesFollowTheSentDate() {
        let thirty = ClientInvoicing(termsDays: 30), immediate = ClientInvoicing(termsDays: 0)
        var value = InvoiceValue(clientID: UUID())
        value.markSent(today: "2026-10-16", terms: thirty)
        XCTAssertEqual([value.sentDay, value.dueDay], ["2026-10-16", "2026-11-15"])
        value.sentDay = "2026-10-01"; value.followTerms(thirty)
        XCTAssertEqual(value.dueDay, "2026-10-31", "An automatic due date moves with the sent date")
        value.status = "draft"; value.markSent(today: "2026-10-20", terms: thirty)
        XCTAssertEqual([value.sentDay, value.dueDay], ["2026-10-01", "2026-10-31"], "Sending again keeps both dates")
        value.sentDay = "2026-10-05"; value.followTerms(immediate)
        XCTAssertEqual(value.dueDay, "2026-10-05", "Zero-day terms are due on the sent date")
        XCTAssertNoThrow(try { var v = value; v.lines = [BilledLine(jobID: UUID(), jobName: "Final", amount: 1)]; try v.validate() }())

        value.chooseDue("2026-12-01"); value.sentDay = "2026-11-20"; value.followTerms(thirty)
        XCTAssertEqual(value.dueDay, "2026-12-01", "A chosen due date is preserved")
        value.showDue(false, today: "2026-10-16", terms: thirty); value.showDue(true, today: "2026-10-16", terms: thirty)
        value.sentDay = "2026-11-25"; value.followTerms(thirty)
        XCTAssertEqual(value.dueDay, "2026-12-25", "Turning the due date back on follows the terms again")

        var manual = InvoiceValue(clientID: UUID()); manual.dueDay = "2026-10-30"
        manual.markSent(today: "2026-10-16", terms: thirty); manual.sentDay = "2026-10-20"; manual.followTerms(thirty)
        XCTAssertEqual(manual.dueDay, "2026-10-30", "A due date set before sending is kept")
        var noTerms = InvoiceValue(clientID: UUID())
        noTerms.markSent(today: "2026-10-16", terms: ClientInvoicing())
        XCTAssertEqual(noTerms.dueDay, ""); XCTAssertFalse(noTerms.dueDayAutomatic)
    }

    func testTypedAmountsFollowTheLocaleAndRejectAmbiguity() throws {
        let point = Locale(identifier: "en_US"), comma = Locale(identifier: "de_DE")
        let cases: [(String, String, Locale, Int64)] = [
            ("1500", "JPY", point, 1_500), ("1,500", "JPY", point, 1_500), ("1.500", "JPY", comma, 1_500), ("¥1,500", "JPY", point, 1_500),
            ("25.80", "EUR", point, 2_580), ("25,80", "EUR", comma, 2_580), ("25,80", "EUR", point, 2_580), ("25.80", "EUR", comma, 2_580),
            ("1,234.56", "USD", point, 123_456), ("1.234,56", "EUR", comma, 123_456), ("1 234,56", "EUR", comma, 123_456),
            ("1,500", "USD", point, 150_000), ("$1,234.50", "USD", point, 123_450), ("1.234,50 €", "EUR", comma, 123_450), ("EUR 12.00", "EUR", point, 1_200),
            ("1.500", "KWD", point, 1_500), ("1,500", "KWD", comma, 1_500), ("1500", "KWD", point, 1_500_000),
            ("1,234.567", "KWD", point, 1_234_567), ("1.234,567", "KWD", comma, 1_234_567), ("12,5", "KWD", point, 12_500),
            ("1500,000", "KWD", point, 1_500_000), ("1500.000", "KWD", comma, 1_500_000), // Too long to be a thousands group.
        ]
        for (text, currency, locale, expected) in cases {
            XCTAssertEqual(try Money.parseInput(text, currency: currency, locale: locale), expected, "\(text) \(currency) \(locale.identifier)")
            XCTAssertEqual(try Money.parseInput(Money.inputText(expected, currency: currency, locale: locale), currency: currency, locale: locale), expected)
        }
        let rejected: [(String, String, Locale)] = [
            ("1,500", "KWD", point), ("1.500", "KWD", comma), // Could be 1500 or 1.500 dinars.
            ("1.5", "JPY", point), ("1.500", "USD", point), ("1,500", "USD", comma), ("12.3456", "KWD", point),
            ("1,23,456", "USD", point), ("12,34.56", "USD", point), ("£12.00", "USD", point), ("-5", "USD", point), ("12 abc", "USD", point),
        ]
        for (text, currency, locale) in rejected {
            XCTAssertThrowsError(try Money.parseInput(text, currency: currency, locale: locale), "\(text) \(currency) \(locale.identifier)")
        }
        XCTAssertNil(try Money.parseInput("  ", currency: "USD", locale: point))
        // Live breakdown totals read rates as typed; saved rates are read in their stored form.
        let typed = [FeeLine(quantity: "2", rate: "1.250,50"), FeeLine(quantity: "1", rate: "-50,50")]
        XCTAssertEqual(try FeeValue(currency: "EUR", lines: typed).total(typedIn: comma), 245_050)
        XCTAssertEqual(try FeeLine(quantity: "1", rate: "1,500").total(currency: "USD", typedIn: point), 150_000)
        XCTAssertThrowsError(try FeeLine(quantity: "1", rate: "1,500").total(currency: "KWD", typedIn: point))
        XCTAssertEqual(try FeeLine(quantity: "1", rate: "1.500").total(currency: "KWD"), 1_500, "Stored rates keep their stored reading")
        // Stored receipt text is normalized, so a decimal-comma device's entry reads the same everywhere.
        let stored = try ExpenseValue(amount: "1.234,500", currency: "KWD", tax: "0,250").storingAmounts(locale: comma)
        XCTAssertEqual([stored.amount, stored.tax], ["1234.500", "0.250"])
        XCTAssertEqual(stored.editingAmounts(locale: comma).amount, "1234,500")
        XCTAssertThrowsError(try Money.parse("25,80", currency: "EUR"), "Stored text has one form")
        XCTAssertEqual(ExpenseCaptureInput(amount: "24,50", currency: "EUR").draft.amount, "24.50", "Wallet text is stored in that form")
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

    func testDirectPaymentsWithoutAFeeKeepTheirCurrencyAndLeaveTheRestOutstanding() async throws {
        let context = try await context()
        var draft = JobDraft(name: "Training day"); draft.clientName = "Northside"; draft.bookingStatus = .completed; draft.fee = nil
        let job = try XCTUnwrap(context.existingObject(with: try draft.save(in: context)) as? Job)
        let client = try XCTUnwrap(job.client)
        XCTAssertTrue((job.feeRevisions ?? []).isEmpty)
        client.defaultCurrency = "EUR"; try context.save()
        var payment = PaymentDraft(); payment.amount = "100"
        try payment.save(in: context, jobID: job.objectID)
        client.defaultCurrency = "JPY"; try context.save()
        XCTAssertEqual(job.billingSummary(in: context), "Direct payments: €100.00", "Changing defaults never relabels payment history")
        payment.amount = "50.50"
        try payment.save(in: context, jobID: job.objectID)
        XCTAssertEqual(Set((job.payments ?? []).map(\.currency)), ["EUR"])
        func state() -> PaymentState { EventReadiness(ReadinessFacts(job: job, context: context, index: InvoiceIndex(in: context)), today: "2026-10-16").state }
        XCTAssertEqual(state(), .directPartial(received: 15_050, remaining: nil, currency: "EUR"), "No fee saved: nothing says the job is fully paid")

        var fee = try FeeDraft(job: job)
        XCTAssertEqual(fee.currency, "EUR")
        fee.amount = "650"; fee.agreement = "agreed"
        try fee.save(in: context, jobID: job.objectID)
        XCTAssertEqual(state(), .directPartial(received: 15_050, remaining: 49_950, currency: "EUR"))
        let second = try XCTUnwrap(job.payments?.first { $0.amount == 5_050 })
        try PaymentLedger.reverse(second, in: context)
        XCTAssertEqual(state(), .directPartial(received: 10_000, remaining: 55_000, currency: "EUR"))
        var invoice = InvoiceDraft(clientID: client.id!, currency: "EUR")
        invoice.value.lines = [BilledLine(jobID: job.id!, jobName: job.displayName, amount: 55_000)]
        XCTAssertThrowsError(try invoice.save(in: context), "Directly paid work is never invoiced again")
        payment.amount = "550"
        try payment.save(in: context, jobID: job.objectID)
        XCTAssertEqual(state(), .directPaid)
    }

    func testDraftInvoiceKeepsItsBilledCurrencyWhenTheFeeChanges() async throws {
        let context = try await context()
        let job = try completedJob("Cup final", in: context)
        var draft = InvoiceDraft(clientID: try XCTUnwrap(job.client?.id), currency: "EUR")
        draft.value.lines = [BilledLine(jobID: job.id!, jobName: job.displayName, amount: 65_000)]
        try draft.save(in: context)
        var fee = try FeeDraft(job: job); fee.currency = "JPY"; fee.amount = "90000"
        try fee.save(in: context, jobID: job.objectID)
        let month = PaymentsMonth.load(month: String(job.eventStartDay.prefix(7)), jobs: [job], invoices: try context.fetch(NSFetchRequest<Invoice>(entityName: "Invoice")),
                                       context: context, displayed: ["EUR", "JPY"])
        let event = try XCTUnwrap(month.events.first)
        XCTAssertEqual(event.state, .draft)
        XCTAssertEqual(event.amount, 65_000); XCTAssertEqual(event.currency, "EUR")
        XCTAssertEqual(month.currencies.first { $0.currency == "EUR" }?.amounts, [.invoiced: 65_000])
        XCTAssertEqual(month.currencies.first { $0.currency == "JPY" }?.total, 0)
    }

    func testPaymentSaveRefusesAReceiptBilledOnAnInvoiceThatArrivedLater() async throws {
        let context = try await context()
        let job = try completedJob("Derby", in: context)
        let client = try XCTUnwrap(job.client)
        let parking = try receipt(for: job, reimbursable: true, in: context)
        var sent = InvoiceDraft(clientID: client.id!, currency: "EUR")
        sent.value.lines = [BilledLine(jobID: job.id!, jobName: job.displayName, amount: 65_000)]
        sent.value.expenseLines = [BilledExpense(expenseID: parking.id!, label: "Parking", amount: 2_580)]
        sent.value.status = "sent"; sent.value.reference = "INV-1"; sent.value.sentDay = "2026-10-14"
        let invoiceID = try sent.save(in: context)
        XCTAssertNil(try XCTUnwrap(context.existingObject(with: invoiceID) as? Invoice).issue(in: context), "The editor opens with Save enabled")

        // While the editor is open, another device's invoice for a different event syncs in with the same receipt.
        let other = try completedJob("Cup final", in: context)
        let synced = Invoice(entity: NSEntityDescription.entity(forEntityName: "Invoice", in: context)!, insertInto: context)
        synced.id = UUID(); synced.createdAt = Date(); synced.client = client
        var value = InvoiceValue(clientID: client.id!, currency: "EUR")
        value.lines = [BilledLine(jobID: other.id!, jobName: other.displayName, amount: 65_000)]
        value.expenseLines = sent.value.expenseLines
        let revision = InvoiceRevision(entity: NSEntityDescription.entity(forEntityName: "InvoiceRevision", in: context)!, insertInto: context)
        revision.id = UUID(); revision.createdAt = Date(); revision.invoice = synced; revision.parentsJSON = "[]"
        revision.valueJSON = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try context.save()

        var payment = PaymentDraft(); payment.amount = "100"
        XCTAssertThrowsError(try payment.save(in: context, invoiceID: invoiceID))
        XCTAssertEqual(try context.count(for: NSFetchRequest<PaymentRecord>(entityName: "PaymentRecord")), 0)
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
