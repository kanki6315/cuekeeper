import CoreData
import XCTest
import UIKit
@testable import Cuekeeper

@MainActor
final class ExpenseTests: XCTestCase {
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
    private var valid: ExpenseValue { ExpenseValue(merchant: "Circuit Parking", day: "2026-10-15", amount: "24.50", currency: "EUR", tax: "4.50", category: "Parking", reimbursable: true) }
    func testDraftConfirmationStaleEditsAndDeletedEvent() async throws {
        let context = try await context()
        let jobID = try JobDraft(name: "Weekend").save(in: context)
        let photo = Data([1, 2, 3])
        let id = try Expense.capture(photo, jobID: jobID, in: context)
        let expense = try XCTUnwrap(context.existingObject(with: id) as? Expense)
        let originalRevision = expense.revision
        XCTAssertTrue(expense.isDraft); XCTAssertEqual(expense.photo, photo)
        XCTAssertThrowsError(try Expense.save(ExpenseValue(), id: id, revision: expense.revision, in: context))
        XCTAssertTrue(expense.isDraft)
        try Expense.save(valid, id: id, revision: expense.revision, in: context)
        XCTAssertFalse(expense.isDraft); XCTAssertEqual(expense.value, valid)
        XCTAssertThrowsError(try Expense.save(valid, id: id, revision: originalRevision, in: context))
        try Job.remove(jobID, in: context)
        XCTAssertEqual(expense.photo, photo)
        XCTAssertThrowsError(try Expense.save(valid, id: id, revision: expense.revision, in: context))
        XCTAssertThrowsError(try Expense.capture(photo, jobID: jobID, in: context))
    }
    func testPhotoBackupRoundTripAndLegacyArchive() async throws {
        let source = try await context()
        let jobID = try JobDraft(name: "Weekend").save(in: source)
        var legacy = try BackupArchive.capture(in: source)
        for index in legacy.records.indices where legacy.records[index].key.entity == "Job" { legacy.records[index].relationships.removeValue(forKey: "expenses") }
        let destination = try await context()
        _ = try legacy.restore(in: destination)
        let photo = Data(repeating: 42, count: 2048)
        let id = try Expense.capture(photo, jobID: jobID, in: source)
        let original = try XCTUnwrap(source.existingObject(with: id) as? Expense)
        try Expense.save(valid, id: id, revision: original.revision, in: source)
        let archive = try BackupArchive.decode(BackupArchive.capture(in: source).encoded(), model: destination.persistentStoreCoordinator!.managedObjectModel)
        _ = try archive.restore(in: destination)
        let restored = try XCTUnwrap(destination.fetch(NSFetchRequest<Expense>(entityName: "Expense")).first)
        XCTAssertEqual(restored.photo, photo); XCTAssertEqual(restored.value, valid)
        XCTAssertEqual(restored.job?.name, "Weekend")
        XCTAssertEqual(try archive.restore(in: destination).added, 0)
    }
    func testDraftCanKeepIncompleteDetails() async throws {
        let context = try await context(); let jobID = try JobDraft(name: "Weekend").save(in: context)
        let id = try Expense.capture(Data([1]), jobID: jobID, in: context)
        let expense = try XCTUnwrap(context.existingObject(with: id) as? Expense)
        let value = ExpenseValue(merchant: "Remember this")
        try Expense.save(value, id: id, revision: expense.revision, confirmed: false, in: context)
        XCTAssertTrue(expense.isDraft); XCTAssertEqual(expense.value.merchant, "Remember this")
    }
    func testReplacementIsAtomicAndRejectsStaleOrConfirmedRecords() async throws {
        let context = try await context(); let jobID = try JobDraft(name: "Weekend").save(in: context)
        let id = try Expense.capture(Data([1]), jobID: jobID, in: context)
        let expense = try XCTUnwrap(context.existingObject(with: id) as? Expense)
        let revision = expense.revision
        XCTAssertThrowsError(try Expense.replacePhoto(Data(), id: id, revision: revision, in: context))
        XCTAssertEqual(expense.photo, Data([1]))
        try Expense.replacePhoto(Data([2]), id: id, revision: revision, in: context)
        XCTAssertEqual(expense.photo, Data([2]))
        XCTAssertThrowsError(try Expense.replacePhoto(Data([3]), id: id, revision: revision, in: context))
        try Expense.save(valid, id: id, revision: expense.revision, in: context)
        XCTAssertThrowsError(try Expense.replacePhoto(Data([3]), id: id, revision: expense.revision, in: context))
    }
    func testValidationAndUntrustedExtraction() throws {
        XCTAssertNoThrow(try valid.validate())
        for amount in ["-1", "0", "NaN", "1,234.56", "12.345"] {
            var value = valid; value.amount = amount; XCTAssertThrowsError(try value.validate())
        }
        var value = valid; value.tax = "25"; XCTAssertThrowsError(try value.validate())
        value = valid; value.day = "2026-02-30"; XCTAssertThrowsError(try value.validate())
        value = valid; value.currency = "$"; XCTAssertThrowsError(try value.validate())
        let extracted = ReceiptFields(merchant: "Shop", day: "not a date", amount: "NaN", currency: "$", tax: "unknown", category: "invented").expense
        XCTAssertEqual(extracted.day, ""); XCTAssertEqual(extracted.amount, ""); XCTAssertEqual(extracted.currency, ""); XCTAssertEqual(extracted.tax, ""); XCTAssertEqual(extracted.category, "Other")
    }
    func testVisionReadsReceiptImageOnDevice() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400), format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
            ("CIRCUIT PARKING\n2026-10-15\nTOTAL EUR 24.50" as NSString).draw(in: CGRect(x: 40, y: 40, width: 720, height: 320), withAttributes: [.font: UIFont.systemFont(ofSize: 40), .foregroundColor: UIColor.black])
        }
        let text = try await ReceiptExtractor.recognize(XCTUnwrap(image.pngData()))
        XCTAssertTrue(text.contains("CIRCUIT PARKING")); XCTAssertTrue(text.contains("24.50"))
    }
    func testShortcutHandoffIsIdempotentAndDoesNotCreateEvents() throws {
        let handoff = EventEditorHandoff()
        try handoff.requestReceiptScan(); try handoff.requestReceiptScan()
        XCTAssertTrue(handoff.scanningReceipt); XCTAssertNil(handoff.pending)
    }
}
