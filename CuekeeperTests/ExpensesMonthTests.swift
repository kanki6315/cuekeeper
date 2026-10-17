import CoreData
import XCTest
@testable import Cuekeeper

@MainActor
final class ExpensesMonthTests: XCTestCase {
    private let apex = UUID(), northside = UUID(), derby = UUID(), weekend = UUID()

    private func fact(_ day: String, _ merchant: String, _ amount: Int64?, _ currency: String = "EUR", state: ExpenseState,
                      job: UUID? = nil, client: UUID? = nil, invoiceable: Bool = false, repeats: Bool = false, series: UUID? = nil,
                      deleted: Bool = false) -> ExpenseFact {
        ExpenseFact(id: UUID(), day: day, merchant: merchant, amount: amount, currency: currency, category: "Travel", state: state,
                    jobID: job, eventTitle: job == nil ? nil : (job == derby ? "City vs United" : "Silverstone weekend"),
                    clientID: client, clientName: client == apex ? "Apex Media" : client == northside ? "Northside Sports" : nil,
                    eventDeleted: deleted, eventInvoiceable: invoiceable, repeats: repeats, seriesID: series)
    }

    func testMonthSplitsMoneyByStateAndListsDaysNewestFirst() {
        let facts = [
            fact("2026-10-13", "Q-Park", 1800, state: .toRebill, job: derby, client: apex, invoiceable: true),
            fact("2026-10-12", "Hotel Arena", 14200, state: .toRebill, job: derby, client: apex, invoiceable: true),
            fact("2026-10-02", "Eurostar", 11800, state: .onInvoice(reference: "INV-031"), job: weekend, client: northside),
            fact("2026-10-02", "Ibis", 8400, state: .paidBack, job: weekend, client: northside),
            fact("2026-10-09", "Dropbox", 1199, state: .business, repeats: true, series: UUID()),
            fact("2026-10-16", "Pret", 1480, "USD", state: .yourCost, job: weekend, client: northside),
            fact("2026-10-15", "Shell", 6410, "USD", state: .toFinish),
            fact("2026-10-14", "Old receipt", 900, state: .yourCost, job: derby, client: apex, deleted: true),
            fact("2026-09-20", "September", 500, state: .yourCost, job: derby, client: apex),
        ]
        let month = ExpensesMonth(month: "2026-10", facts: facts, today: "2026-10-16")
        XCTAssertEqual(month.count, 8)
        XCTAssertEqual(month.currencies.map(\.currency), ["EUR", "USD"])
        XCTAssertEqual(month.currencies[0].amounts, [.toRebill: 16000, .onInvoice: 11800, .paidBack: 8400, .yourCost: 1199])
        XCTAssertEqual(month.currencies[1].amounts, [.yourCost: 1480, .toFinish: 6410])
        XCTAssertEqual(month.days(.all).map(\.day), ["2026-10-16", "2026-10-15", "2026-10-14", "2026-10-13", "2026-10-12", "2026-10-09", "2026-10-02"])
        XCTAssertEqual(month.days(.all).last?.expenses.count, 2)
        XCTAssertEqual(month.days(.business).flatMap(\.expenses).map(\.merchant), ["Dropbox"])
        XCTAssertFalse(month.days(.events).flatMap(\.expenses).contains { $0.merchant == "Dropbox" || $0.merchant == "Shell" })
    }

    func testRebillGroupsByClientAndCurrencyAndCountsEarlierMonths() {
        let facts = [
            fact("2026-10-12", "Hotel Arena", 14200, state: .toRebill, job: derby, client: apex, invoiceable: true),
            fact("2026-10-13", "Q-Park", 1800, state: .toRebill, job: derby, client: apex, invoiceable: true),
            fact("2026-10-03", "Taxi", 2000, "USD", state: .toRebill, job: weekend, client: northside, invoiceable: false),
            fact("2026-09-19", "Hertz", 6400, "USD", state: .toRebill, job: weekend, client: northside),
            fact("2026-08-02", "Autogrill", 2250, "USD", state: .toRebill, job: weekend, client: northside),
            fact("2026-09-19", "Paid", 1000, "USD", state: .paidBack, job: weekend, client: northside),
        ]
        let month = ExpensesMonth(month: "2026-10", facts: facts, today: "2026-10-16")
        XCTAssertEqual(month.rebill.count, 2)
        let apexGroup = month.rebill.first { $0.clientID == apex }
        XCTAssertEqual(apexGroup?.amount, 16000)
        XCTAssertEqual(apexGroup?.receipts.count, 2)
        XCTAssertEqual(apexGroup?.events, ["City vs United"])
        XCTAssertEqual(apexGroup?.canInvoice, true)
        XCTAssertEqual(month.rebill.first { $0.clientID == northside }?.canInvoice, false, "An already invoiced event needs no new invoice button")
        XCTAssertEqual(month.earlier.count, 2)
        XCTAssertEqual(month.earlier.amounts, ["USD": 8650])
        XCTAssertEqual(month.earlier.latestMonth, "2026-09")
    }

    func testFinishListsDraftsAndDueRepeatsOldestFirst() {
        let due = UUID(), notYet = UUID(), stopped = UUID()
        let facts = [
            fact("2026-10-15", "Shell", 6410, "USD", state: .toFinish),
            fact("2026-10-09", "", nil, state: .toFinish, job: weekend, client: northside),
            fact("2026-10-08", "Gone", 100, state: .toFinish, job: derby, client: apex, deleted: true),
            fact("2026-08-14", "Midjourney", 3000, "USD", state: .business, repeats: true, series: due),
            fact("2026-09-14", "Midjourney", 3000, "USD", state: .business, repeats: true, series: due),
            fact("2026-10-01", "Claude Pro", 2000, "USD", state: .business, repeats: true, series: notYet),
            fact("2026-09-04", "Adobe", 5999, "USD", state: .business, repeats: true, series: stopped),
            fact("2026-09-20", "Adobe", 5999, "USD", state: .business, repeats: false, series: stopped),
        ]
        let items = ExpensesMonth.finishItems(facts, today: "2026-10-16")
        XCTAssertEqual(items.map(\.rankDay), ["2026-10-09", "2026-10-14", "2026-10-15"])
        XCTAssertEqual(items.map(\.actionTitle), ["Finish", "Add", "Finish"])
        XCTAssertEqual(items[0].title, "Expense to complete")
        XCTAssertEqual(items[1].title, "Midjourney · $30.00")
        guard case let .repeatDue(_, day) = items[1].kind else { return XCTFail("Expected the due repeat") }
        XCTAssertEqual(day, "2026-10-14")
        XCTAssertTrue(items[2].detail.hasSuffix("No event yet"))
    }

    func testNextMonthKeepsTheDayAndClampsShortMonths() {
        XCTAssertEqual(ExpensesMonth.nextMonth("2026-10-14"), "2026-11-14")
        XCTAssertEqual(ExpensesMonth.nextMonth("2026-01-31"), "2026-02-28")
        XCTAssertEqual(ExpensesMonth.nextMonth("2026-12-05"), "2027-01-05")
    }

    // MARK: Stored business costs

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

    func testBusinessCostSavesWithoutEventOrPhotoAndNeverRebills() async throws {
        let context = try await context()
        var value = ExpenseValue(merchant: "Claude Pro", day: "2026-10-01", amount: "20.00", currency: "USD", category: "Software", reimbursable: true)
        value.repeatsMonthly = true
        let id = try Expense.createBusiness(value, in: context)
        let expense = try XCTUnwrap(context.existingObject(with: id) as? Expense)
        XCTAssertTrue(expense.isBusiness); XCTAssertFalse(expense.isDraft); XCTAssertNil(expense.photo)
        XCTAssertFalse(expense.value.reimbursable); XCTAssertFalse(expense.isRebillable)
        XCTAssertEqual(expense.value.seriesID, expense.id, "A new repeating cost starts its own series")
        XCTAssertEqual(ExpenseFact(expense: expense, index: InvoiceIndex(in: context))?.state, .business)

        // The next month joins the same series.
        var next = expense.value; next.day = "2026-11-01"
        let nextID = try Expense.createBusiness(next, in: context)
        XCTAssertEqual((try context.existingObject(with: nextID) as? Expense)?.value.seriesID, expense.id)
    }

    func testEventReceiptCanBecomeABusinessCost() async throws {
        let context = try await context()
        let jobID = try JobDraft(name: "Weekend").save(in: context)
        let id = try Expense.capture(Data([1, 2, 3]), jobID: jobID, in: context)
        let expense = try XCTUnwrap(context.existingObject(with: id) as? Expense)
        var value = ExpenseValue(merchant: "Apple Store", day: "2026-10-03", amount: "40.00", currency: "EUR", category: "Equipment", reimbursable: true)
        value.repeatsMonthly = false
        try Expense.save(value, id: id, revision: expense.revision, business: true, in: context)
        XCTAssertNil(expense.job); XCTAssertTrue(expense.isBusiness)
        XCTAssertFalse(expense.value.reimbursable); XCTAssertNil(expense.value.repeatsMonthly)
        XCTAssertEqual(expense.photo, Data([1, 2, 3]))

        // An event receipt still needs its event and photo.
        let other = try Expense.capture(Data([4]), jobID: jobID, in: context)
        let otherExpense = try XCTUnwrap(context.existingObject(with: other) as? Expense)
        var receipt = value; receipt.repeatsMonthly = true
        try Expense.save(receipt, id: other, revision: otherExpense.revision, in: context)
        XCTAssertNil(otherExpense.value.repeatsMonthly, "Only business costs repeat")
        XCTAssertTrue(otherExpense.isRebillable)
    }
}
