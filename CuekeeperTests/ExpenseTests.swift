import CoreData
import FoundationModels
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
    func testAsyncPhotoWritesUsePrivateQueueAndRefreshUIObjects() async throws {
        let context = try await context()
        let jobID = try JobDraft(name: "Receipt background writes").save(in: context)
        let saved = expectation(description: "Photo transactions save off the main thread")
        saved.expectedFulfillmentCount = 2
        let observer = NotificationCenter.default.addObserver(forName: .NSManagedObjectContextDidSave, object: nil, queue: nil) { notification in
            guard let writer = notification.object as? NSManagedObjectContext,
                  writer.concurrencyType == .privateQueueConcurrencyType else { return }
            XCTAssertFalse(Thread.isMainThread)
            saved.fulfill()
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        let photo = Data(repeating: 42, count: 12 * 1024 * 1024)
        let id = try await Expense.capturePhoto(photo, jobID: jobID, in: context)
        XCTAssertFalse(id.isTemporaryID)
        let expense = try XCTUnwrap(context.existingObject(with: id) as? Expense)
        XCTAssertEqual(expense.photo, photo)
        let revision = expense.revision
        try await Expense.replacePhotoAsync(Data([4, 5, 6]), id: id, revision: revision, in: context)
        XCTAssertEqual(expense.photo, Data([4, 5, 6]))
        XCTAssertNotEqual(expense.revision, revision)
        do {
            try await Expense.replacePhotoAsync(Data([7]), id: id, revision: revision, in: context)
            XCTFail("Stale replacement must fail")
        } catch { XCTAssertEqual(expense.photo, Data([4, 5, 6])) }
        do {
            _ = try await Expense.capturePhoto(Data(repeating: 0, count: photo.count + 1), jobID: jobID, in: context)
            XCTFail("Oversized receipt must fail")
        } catch { XCTAssertEqual(try context.count(for: NSFetchRequest<Expense>(entityName: "Expense")), 1) }
        await fulfillment(of: [saved], timeout: 5)
    }

    func testPhotoBackupRoundTrip() async throws {
        let source = try await context()
        let jobID = try JobDraft(name: "Weekend").save(in: source)
        let destination = try await context()
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
    func testWiderCurrenciesAndDisplayFallbacks() throws {
        var value = valid; value.currency = "JPY"; value.amount = "1200"; value.tax = ""
        XCTAssertNoThrow(try value.validate())
        value.amount = "1200.50"; XCTAssertThrowsError(try value.validate())
        value.currency = "KWD"; value.amount = "12.345"; XCTAssertNoThrow(try value.validate())
        value.currency = "SEK"; value.amount = "89.90"; XCTAssertNoThrow(try value.validate())
        XCTAssertNil(ExpenseValue.displayAmount("abc", currency: "USD"))
        XCTAssertNil(ExpenseValue.displayAmount("12.50", currency: ""))
        XCTAssertNil(ExpenseValue.displayAmount("12.50", currency: "JPY"))
        XCTAssertEqual(ExpenseValue.displayAmount("1234.5", currency: "USD"), Money.format(123450, currency: "USD"))
        // An amount captured without a currency is kept for review; saving checks it against the chosen currency.
        XCTAssertEqual(ExpenseCaptureInput(merchant: "Shop", amount: "12.345").draft.amount, "12.345")
        XCTAssertEqual(ExpenseCaptureInput(merchant: "Shop", amount: "12.345", currency: "jpy").draft.amount, "")
        XCTAssertEqual(ReceiptFields(merchant: "Shop", day: "", amount: "4500", currency: "JPY", tax: "", category: "Meals").expense.amount, "4500")
    }

    func testCancelledRecognitionStops() async throws {
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 800, height: 400), format: format).image { renderer in
            UIColor.white.setFill(); renderer.fill(CGRect(x: 0, y: 0, width: 800, height: 400))
            ("TOTAL EUR 24.50" as NSString).draw(in: CGRect(x: 40, y: 40, width: 720, height: 320), withAttributes: [.font: UIFont.systemFont(ofSize: 40), .foregroundColor: UIColor.black])
        }
        let data = try XCTUnwrap(image.pngData())
        let task = Task { try await ReceiptExtractor.recognize(data) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled recognition returned text") } catch {}
    }

    private var contextOverflow: Error {
        LanguageModelError.contextSizeExceeded(.init(contextSize: 4096, tokenCount: 5000, debugDescription: "test overflow"))
    }

    func testReceiptCloudAvailability() throws {
        XCTAssertNoThrow(try ReceiptExtractor.validateCloudAvailability(.available))
        XCTAssertThrowsError(try ReceiptExtractor.validateCloudAvailability(.unavailable(.systemNotReady))) { error in
            XCTAssertEqual(error.localizedDescription, "Apple Private Cloud Compute is not ready yet. Try again later or enter the details below using the attached photo.")
        }
    }

    func testReceiptIneligibleCloudDevicePreservesManualEntryMessage() async {
        do {
            _ = try await ReceiptExtractor.extract(text: "Receipt", onDevice: { _ in throw self.contextOverflow },
                inCloud: { _ in
                    try ReceiptExtractor.validateCloudAvailability(.unavailable(.deviceNotEligible))
                    XCTFail("Ineligible devices must not proceed to a cloud request")
                    return self.valid
                }, progress: { _ in })
            XCTFail("Expected ineligible-device error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This device cannot use Apple Private Cloud Compute to read this receipt. Enter the details below using the attached photo.")
            XCTAssertFalse(error.localizedDescription.localizedCaseInsensitiveContains("try again"))
        }
    }

    func testReceiptStaysOnDeviceWhenItFits() async throws {
        let result = try await ReceiptExtractor.extract(text: "TOTAL 24.50", onDevice: { _ in self.valid }, inCloud: { _ in
            XCTFail("A receipt that fits must not be sent to PCC")
            return self.valid
        }, progress: { _ in })
        XCTAssertEqual(result.location, .device)
        XCTAssertEqual(result.expense, valid)
    }

    func testReceiptOverflowRetriesFullTextInCloudOnce() async throws {
        let text = String(repeating: "Item 123.45\n", count: 1500)
        var phases: [ReceiptExtractor.ProcessingLocation] = []
        var cloudCalls = 0
        let result = try await ReceiptExtractor.extract(text: text, onDevice: { received in
            XCTAssertEqual(received, text)
            throw self.contextOverflow
        }, inCloud: { received in
            cloudCalls += 1
            XCTAssertEqual(received, text)
            return self.valid
        }, progress: { phases.append($0) })
        XCTAssertEqual(cloudCalls, 1)
        XCTAssertEqual(phases, [.device, .privateCloudCompute])
        XCTAssertEqual(result.location, .privateCloudCompute)
        XCTAssertEqual(result.expense, valid)
        XCTAssertTrue(result.location.completionMessage.contains("Private Cloud Compute"))
    }

    func testReceiptOtherErrorsDoNotTriggerCloud() async {
        do {
            _ = try await ReceiptExtractor.extract(text: "Receipt", onDevice: { _ in
                throw RecordError.invalid("Model unavailable")
            }, inCloud: { _ in
                XCTFail("Only context overflow should trigger PCC")
                return self.valid
            }, progress: { _ in })
            XCTFail("Expected error")
        } catch { XCTAssertEqual(error.localizedDescription, "Model unavailable") }
    }

    func testReceiptCloudOverflowUsesFriendlyMessage() async {
        do {
            _ = try await ReceiptExtractor.extract(text: "Receipt", onDevice: { _ in throw self.contextOverflow },
                inCloud: { _ in throw self.contextOverflow }, progress: { _ in })
            XCTFail("Expected error")
        } catch {
            XCTAssertEqual(error.localizedDescription, "This receipt is too long to read automatically. Enter the details below using the attached photo.")
        }
    }

    func testReceiptCloudFailuresUseFriendlyMessages() async {
        let errors: [(Error, String)] = [
            (PrivateCloudComputeLanguageModel.Error.networkFailure(.init(debugDescription: "raw network error")), "Check your internet connection"),
            (PrivateCloudComputeLanguageModel.Error.quotaLimitReached(.init(debugDescription: "raw quota error")), "usage limit"),
            (PrivateCloudComputeLanguageModel.Error.serviceUnavailable(.init(debugDescription: "raw service error")), "unavailable right now")
        ]
        for (failure, expected) in errors {
            do {
                _ = try await ReceiptExtractor.extract(text: "Receipt", onDevice: { _ in throw self.contextOverflow },
                    inCloud: { _ in throw failure }, progress: { _ in })
                XCTFail("Expected error")
            } catch { XCTAssertTrue(error.localizedDescription.contains(expected), error.localizedDescription) }
        }
    }

    func testReceiptCancellationBeforeFallbackDoesNotSendToCloud() async {
        let task = Task {
            try await ReceiptExtractor.extract(text: "Receipt", onDevice: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
                throw self.contextOverflow
            }, inCloud: { _ in
                XCTFail("Cancelled requests must not reach PCC")
                return self.valid
            }, progress: { _ in })
        }
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
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
