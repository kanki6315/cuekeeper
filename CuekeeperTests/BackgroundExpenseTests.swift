import CoreData
import UserNotifications
import XCTest
@testable import Cuekeeper

@MainActor
final class BackgroundExpenseTests: XCTestCase {
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
    private var payment: ExpenseCaptureInput { ExpenseCaptureInput(merchant: "Circuit Parking", amount: "24.50", currency: "EUR", date: Day.date(from: "2026-10-15"), transactionID: "stable-wallet-id") }
    func testCaptureKeepsPartialDraftAndExplicitIDIsIdempotent() async throws {
        let context = try await context()
        let first = try Expense.captureBackground(payment, in: context)
        XCTAssertTrue(first.inserted)
        let expense = try XCTUnwrap(context.existingObject(with: first.objectID) as? Expense)
        XCTAssertNil(expense.photo); XCTAssertNil(expense.job); XCTAssertTrue(expense.needsCompletion)
        XCTAssertEqual(expense.value.merchant, "Circuit Parking")
        let duplicate = try Expense.captureBackground(payment, in: context)
        XCTAssertFalse(duplicate.inserted); XCTAssertEqual(first.id, duplicate.id)
        XCTAssertThrowsError(try Expense.save(expense.value, id: expense.objectID, revision: expense.revision, in: context))
        var edits = expense.value; edits.notes = "Receipt at home"
        try Expense.save(edits, id: expense.objectID, revision: expense.revision, confirmed: false, in: context)
        XCTAssertEqual(expense.value.notes, "Receipt at home")
        XCTAssertTrue(expense.needsCompletion)
        let empty = try Expense.captureBackground(ExpenseCaptureInput(), in: context)
        let another = try Expense.captureBackground(ExpenseCaptureInput(), in: context)
        XCTAssertNotEqual(empty.id, another.id, "No guessed deduplication when a stable source ID is missing")
    }
    func testCompletionRequiresReceiptAndEventAndKeepsSource() async throws {
        let context = try await context(); let result = try Expense.captureBackground(payment, in: context)
        let expense = try XCTUnwrap(context.existingObject(with: result.objectID) as? Expense)
        let jobID = try JobDraft(name: "Weekend").save(in: context)
        XCTAssertThrowsError(try Expense.save(expense.value, id: expense.objectID, revision: expense.revision, jobID: jobID, in: context))
        XCTAssertNil(expense.job, "Failed saves must not attach the event")
        try Expense.replacePhoto(Data([1,2,3]), id: expense.objectID, revision: expense.revision, in: context)
        XCTAssertEqual(expense.value.capture, payment, "Attaching a photo must retain source details")
        var edited = expense.value; edited.amount = "25"; edited.capture = nil
        try Expense.save(edited, id: expense.objectID, revision: expense.revision, jobID: jobID, in: context)
        XCTAssertFalse(expense.isDraft); XCTAssertEqual(expense.job?.objectID, jobID)
        XCTAssertEqual(expense.value.amount, "25"); XCTAssertEqual(expense.value.capture?.amount, "24.50")
        XCTAssertFalse(try Expense.captureBackground(payment, in: context).inserted)
    }
    func testDiscardAndBackupDoNotResurrectDuplicateCapture() async throws {
        let source = try await context(); let result = try Expense.captureBackground(payment, in: source)
        let expense = try XCTUnwrap(source.existingObject(with: result.objectID) as? Expense)
        try Expense.discardDraft(id: expense.objectID, revision: expense.revision, in: source)
        XCTAssertFalse(expense.needsCompletion); XCTAssertFalse(try Expense.captureBackground(payment, in: source).inserted)
        XCTAssertThrowsError(try Expense.save(expense.value, id: expense.objectID, revision: expense.revision, confirmed: false, in: source))
        let target = try await context()
        let archive = try BackupArchive.decode(BackupArchive.capture(in: source).encoded(), model: target.persistentStoreCoordinator!.managedObjectModel)
        _ = try archive.restore(in: target)
        XCTAssertFalse(try Expense.captureBackground(payment, in: target).inserted)
    }
    func testExtractionFillsBlanksAndKeepsConflictingPaymentFields() {
        var current = payment.draft; current.notes = "Original note"; current.reimbursable = true
        let receipt = ExpenseValue(merchant: "Parking operator", day: "2026-10-15", amount: "26", currency: "GBP", tax: "2", category: "Parking")
        let conflicts = current.fillBlanks(from: receipt)
        XCTAssertEqual(Set(conflicts), Set([.merchant, .amount, .currency]))
        XCTAssertEqual(current.amount, "24.50"); XCTAssertEqual(current.currency, "EUR")
        XCTAssertEqual(current.tax, "2"); XCTAssertEqual(current.category, "Parking")
        XCTAssertEqual(current.capture, payment); XCTAssertEqual(current.notes, "Original note"); XCTAssertTrue(current.reimbursable)
    }
    func testMissingAndMalformedInputRetainsEvidenceWithoutInventingFacts() {
        let input = ExpenseCaptureInput(merchant: " Shop ", amount: "$1,234.56", currency: "$", date: nil)
        let draft = input.draft
        XCTAssertEqual(draft.merchant, "Shop"); XCTAssertEqual(draft.amount, ""); XCTAssertEqual(draft.currency, ""); XCTAssertEqual(draft.day, "")
        XCTAssertEqual(draft.capture?.amount, "$1,234.56")
    }
    func testNotificationsOptInDenialFailureRouteAndCleanup() async throws {
        let suite = "expense-notifications-\(UUID())"; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let fake = FakeExpenseNotifications()
        let service = ExpenseNotifications(delivery: fake, defaults: defaults)
        let context = try await context(); let result = try Expense.captureBackground(payment, in: context)
        await service.notify(id: result.id); XCTAssertTrue(fake.requests.isEmpty)
        fake.allowed = false; fake.status = .denied
        await service.enable(); await service.notify(id: result.id); XCTAssertTrue(fake.requests.isEmpty)
        fake.allowed = true; fake.status = .authorized
        await service.enable(); await service.notify(id: result.id)
        XCTAssertEqual(fake.requests.count, 1)
        let request = try XCTUnwrap(fake.requests.first)
        XCTAssertFalse(request.content.body.contains("24.50"))
        service.open(userInfo: request.content.userInfo); XCTAssertEqual(service.route?.id, result.id)
        service.route = nil; service.open(userInfo: ["expenseID": "invalid"]); XCTAssertNil(service.route)
        fake.fail = true; await service.notify(id: UUID()); XCTAssertNotNil(service.lastError)
        XCTAssertTrue((try context.existingObject(with: result.objectID) as! Expense).needsCompletion)
        fake.extraIdentifiers = ["unrelated-reminder"]
        let expense = try context.existingObject(with: result.objectID) as! Expense
        try Expense.discardDraft(id: expense.objectID, revision: expense.revision, in: context)
        await service.reconcile(in: context)
        XCTAssertTrue(fake.removed.contains(request.identifier)); XCTAssertFalse(fake.removed.contains("unrelated-reminder"))
        await service.disable(); XCTAssertFalse(defaults.bool(forKey: ExpenseNotifications.preference))
    }
}

@MainActor
private final class FakeExpenseNotifications: ExpenseNotificationDelivering {
    var status: UNAuthorizationStatus = .authorized
    var allowed = true
    var fail = false
    var requests: [UNNotificationRequest] = []
    var removed: [String] = []
    var extraIdentifiers: [String] = []
    func authorization() async -> UNAuthorizationStatus { status }
    func requestPermission() async throws -> Bool { allowed }
    func add(_ request: UNNotificationRequest) async throws {
        if fail { throw RecordError.invalid("Synthetic delivery failure") }
        requests.append(request)
    }
    func identifiers() async -> [String] { requests.map(\.identifier) + extraIdentifiers }
    func remove(_ identifiers: [String]) { removed += identifiers }
}
