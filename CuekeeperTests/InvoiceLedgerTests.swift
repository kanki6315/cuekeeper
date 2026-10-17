import CoreData
import XCTest
@testable import Cuekeeper

final class InvoiceLedgerTests: XCTestCase {
    private let today = "2026-10-16"

    private func entry(_ title: String, client: String = "Apex Media", currency: String = "USD", total: Int64 = 100_000, received: Int64 = 0,
                       state: LedgerEntry.State, sent: String = "2026-09-01", due: String = "", created: String = "2026-08-30",
                       settled: String = "", kind: LedgerEntry.Kind = .invoice) -> LedgerEntry {
        LedgerEntry(recordID: UUID(), kind: kind, title: title, clientName: client, detail: "Event", currency: currency, total: total, received: received,
                    state: state, sentDay: state == .draft ? "" : sent, dueDay: due, createdDay: created, settledDay: settled,
                    sent: state != .draft && state != .void && kind == .invoice)
    }

    private var sample: InvoiceLedger {
        InvoiceLedger(entries: [
            entry("APX-2207", total: 315_000, state: .overdue, due: "2026-10-01"),
            entry("INV-0406", client: "Velocity TV", total: 240_000, received: 60_000, state: .overdue, due: "2026-09-20"),
            entry("INV-0409", client: "Northside Sports", currency: "EUR", total: 130_000, state: .unpaid, due: "2026-10-30"),
            entry("INV-0411", client: "Trackside Radio", currency: "EUR", total: 35_000, state: .review("Edited on two devices")),
            entry("Draft", total: 110_000, state: .draft, created: "2026-10-09"),
            entry("INV-0405", client: "Northside Sports", currency: "EUR", total: 95_000, received: 95_000, state: .paid, settled: "2026-10-03"),
            entry("Direct payment", client: "Velocity TV", total: 25_000, received: 25_000, state: .direct, settled: "2026-10-06", kind: .directPayment),
            entry("INV-0402", client: "Velocity TV", total: 60_000, state: .void, settled: "2026-09-04"),
            entry("INV-0371", client: "Northside Sports", currency: "EUR", total: 120_000, received: 120_000, state: .paid, sent: "2025-11-20", settled: "2025-12-14")
        ], today: today, displayed: ["USD", "EUR"])
    }

    func testOwedSplitsByCurrencyAndCountsSentReviewInvoices() {
        let owed = sample.owed()
        XCTAssertEqual(owed.map(\.currency), ["USD", "EUR"])
        XCTAssertEqual(owed[0].owed, 315_000 + 180_000)
        XCTAssertEqual(owed[0].overdue, 315_000 + 180_000)
        XCTAssertEqual(owed[1].owed, 130_000 + 35_000)
        XCTAssertEqual(owed[1].overdue, 0)
        XCTAssertEqual(sample.owed(client: "Northside Sports").map(\.owed), [130_000])
    }

    func testSectionsOrderAttentionUnpaidDraftsThenHistoryByMonth() {
        let sections = sample.sections(LedgerFilter())
        XCTAssertEqual(sections.map(\.title), ["Needs attention", "Unpaid", "Drafts", "October 2026", "September 2026", "December 2025"])
        // Overdue sorts by due date; the review item has none and goes last.
        XCTAssertEqual(sections[0].entries.map(\.title), ["INV-0406", "APX-2207", "INV-0411"])
        XCTAssertEqual(sections[3].entries.map(\.title), ["Direct payment", "INV-0405"])
        XCTAssertEqual(sections[3].meta, "Received $250.00 · €950.00")
        XCTAssertEqual(sections[4].meta, "", "voided invoices are not money received")
    }

    func testStatusFilters() {
        let titles = { (status: LedgerStatus) in self.sample.filtered(LedgerFilter(status: status)).map(\.title) }
        XCTAssertEqual(Set(titles(.overdue)), ["APX-2207", "INV-0406"])
        XCTAssertEqual(Set(titles(.owed)), ["APX-2207", "INV-0406", "INV-0409", "INV-0411"])
        XCTAssertEqual(titles(.drafts), ["Draft"])
        XCTAssertEqual(Set(titles(.paid)), ["INV-0405", "Direct payment", "INV-0371"])
        XCTAssertEqual(titles(.voided), ["INV-0402"])
    }

    func testSearchMatchesReferenceClientAndAmount() {
        XCTAssertEqual(sample.filtered(LedgerFilter(query: "0409")).map(\.title), ["INV-0409"])
        XCTAssertEqual(Set(sample.filtered(LedgerFilter(query: "velocity")).map(\.title)), ["INV-0406", "Direct payment", "INV-0402"])
        XCTAssertEqual(sample.filtered(LedgerFilter(query: "3150")).map(\.title), ["APX-2207"])
        XCTAssertEqual(sample.filtered(LedgerFilter(query: "$3,150")).map(\.title), ["APX-2207"])
    }

    func testClientAndYearScopeTotalsSkipDraftsAndVoids() {
        let filter = LedgerFilter(client: "Velocity TV", year: "2026")
        XCTAssertEqual(sample.totals(filter), [LedgerTotals(currency: "USD", billed: 240_000 + 25_000, received: 60_000 + 25_000, owed: 180_000)])
        XCTAssertEqual(sample.totals(LedgerFilter(client: "Northside Sports", year: "2025")),
                       [LedgerTotals(currency: "EUR", billed: 120_000, received: 120_000, owed: 0)])
        XCTAssertEqual(sample.years, ["2026", "2025"])
        XCTAssertEqual(sample.clients, ["Apex Media", "Northside Sports", "Trackside Radio", "Velocity TV"])
    }

    func testYearTotalsDateBillingBySentDayAndReceiptsByReceivedDay() {
        func receipt(_ day: String, _ amount: Int64) -> LedgerReceipt { LedgerReceipt(day: day, amount: amount) }
        var spanning = entry("DEC-1", total: 100_000, received: 100_000, state: .paid, sent: "2025-12-15", settled: "2026-01-10")
        spanning.receipts = [receipt("2025-12-20", 40_000), receipt("2026-01-10", 60_000)]
        var partial = entry("DEC-2", total: 50_000, received: 20_000, state: .unpaid, sent: "2025-12-01")
        partial.receipts = [receipt("2026-02-01", 20_000)] // a reversed receipt is already left out
        let unpaid = entry("JAN-1", total: 30_000, state: .unpaid, sent: "2026-01-05")
        let void = entry("JAN-2", total: 99_000, state: .void, sent: "2026-01-06", settled: "2026-01-07")
        var direct = entry("Direct payment", total: 15_000, received: 15_000, state: .direct, settled: "2026-01-03", kind: .directPayment)
        direct.receipts = [receipt("2025-12-30", 5_000), receipt("2026-01-03", 10_000)]
        let ledger = InvoiceLedger(entries: [spanning, partial, unpaid, void, direct], today: today)

        XCTAssertEqual(ledger.totals(LedgerFilter(year: "2025")), [LedgerTotals(currency: "USD", billed: 150_000 + 5_000, received: 45_000, owed: 30_000)])
        XCTAssertEqual(ledger.totals(LedgerFilter(year: "2026")), [LedgerTotals(currency: "USD", billed: 30_000 + 10_000, received: 90_000, owed: 30_000)])
        XCTAssertEqual(ledger.totals(LedgerFilter()), [LedgerTotals(currency: "USD", billed: 195_000, received: 135_000, owed: 60_000)])
        XCTAssertEqual(Set(ledger.filtered(LedgerFilter(year: "2025")).map(\.title)), ["DEC-1", "DEC-2", "Direct payment"])
        XCTAssertEqual(Set(ledger.filtered(LedgerFilter(year: "2026")).map(\.title)), ["DEC-1", "DEC-2", "JAN-1", "JAN-2", "Direct payment"])
    }

    func testEmptyMessageNamesTheFilters() {
        let filter = LedgerFilter(status: .paid, client: "Apex Media", year: "2025")
        XCTAssertTrue(sample.sections(filter).isEmpty)
        XCTAssertEqual(sample.emptyMessage(filter), "No paid invoices for Apex Media in 2025.")
        XCTAssertEqual(sample.emptyMessage(LedgerFilter(query: " zzz ")), "No invoices or payments matching “zzz”.")
    }

    func testStatusLines() {
        XCTAssertEqual(entry("A", state: .overdue, due: "2026-10-01").status(today: today), "Overdue 15 days · due Oct 1")
        XCTAssertEqual(entry("B", total: 240_000, received: 60_000, state: .overdue, due: "2026-10-15").status(today: today),
                       "Overdue 1 day · $600.00 of $2,400.00 received")
        XCTAssertEqual(entry("C", state: .unpaid, due: "2026-10-16").status(today: today), "Due today · Oct 16")
        XCTAssertEqual(entry("D", state: .unpaid, due: "2026-10-30").status(today: today), "Due in 14 days · Oct 30")
        XCTAssertEqual(entry("E", state: .unpaid).status(today: today), "No due date")
        XCTAssertEqual(entry("F", state: .paid, settled: "2026-10-03").status(today: today), "Paid Oct 3")
        XCTAssertEqual(entry("G", state: .void, settled: "2026-09-04").shownAmount, 100_000)
    }

    @MainActor
    func testLoadBuildsEntriesFromStore() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = PersistenceController(storeURL: folder.appending(path: "ledger.sqlite"), cloudEnabled: false)
        try await store.waitUntilLoaded()
        defer {
            store.container.viewContext.reset()
            for persistent in store.container.persistentStoreCoordinator.persistentStores { try? store.container.persistentStoreCoordinator.remove(persistent) }
            try? FileManager.default.removeItem(at: folder)
        }
        let context = store.container.viewContext
        func job(_ name: String, amount: Int64) throws -> Job {
            var draft = JobDraft(name: name)
            draft.clientName = "Apex Media"; draft.bookingStatus = .completed
            draft.fee?.currency = "USD"; draft.fee?.amount = Money.text(amount, currency: "USD")
            return try XCTUnwrap(context.existingObject(with: try draft.save(in: context)) as? Job)
        }
        let overdue = try job("Silverstone weekend", amount: 315_000)
        let direct = try job("Podcast guest spot", amount: 25_000)
        var draft = InvoiceDraft(clientID: try XCTUnwrap(overdue.client?.id), currency: "USD")
        draft.value.reference = "APX-2207"; draft.value.status = "sent"; draft.value.sentDay = "2026-09-01"; draft.value.dueDay = "2026-10-01"
        draft.value.lines = [BilledLine(jobID: try XCTUnwrap(overdue.id), jobName: "Silverstone weekend", amount: 315_000)]
        try draft.save(in: context)
        var payment = PaymentDraft(); payment.amount = "250"
        try payment.save(in: context, jobID: direct.objectID)

        let ledger = InvoiceLedger.load(invoices: try context.fetch(NSFetchRequest<Invoice>(entityName: "Invoice")), jobs: [overdue, direct],
                                        context: context, today: today)
        XCTAssertEqual(ledger.entries.count, 2)
        let invoice = try XCTUnwrap(ledger.entries.first { $0.kind == .invoice })
        XCTAssertEqual(invoice.state, .overdue)
        XCTAssertEqual(invoice.remaining, 315_000)
        XCTAssertEqual(invoice.clientName, "Apex Media")
        XCTAssertEqual(invoice.detail, "Silverstone weekend")
        let paid = try XCTUnwrap(ledger.entries.first { $0.kind == .directPayment })
        XCTAssertEqual(paid.state, .direct)
        XCTAssertEqual(paid.total, 25_000)
        XCTAssertEqual(paid.settledDay, Day.string(from: Date()))
    }
}
