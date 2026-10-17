import CoreData
import Foundation
import CryptoKit

struct ExpenseValue: Codable, Equatable {
    static let categories = ["Travel", "Accommodation", "Meals", "Parking", "Equipment", "Software", "Other"]
    static let currencies = CurrencyPreferences.supported
    var merchant = ""
    var day = ""
    var amount = ""
    var currency = ""
    var tax = ""
    var category = "Other"
    var reimbursable = false
    var notes = ""
    var capture: ExpenseCaptureInput?
    var discarded: Bool?
    /// A business cost that recurs monthly. Each month is its own expense; the next one is offered once due.
    var repeatsMonthly: Bool?
    /// Shared by every month of a repeating business cost.
    var seriesID: UUID?
    /// Formatted only when the amount is valid for a supported currency, so a bad value is never shown as zero.
    static func displayAmount(_ amount: String, currency: String) -> String? {
        guard currencies.contains(currency), let value = try? Money.parse(amount, currency: currency) else { return nil }
        return Money.format(value, currency: currency)
    }
    func validate() throws {
        guard !merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RecordError.invalid("Enter the merchant shown on the receipt.") }
        guard let date = Day.date(from: day), Day.string(from: date) == day else { throw RecordError.invalid("Choose the receipt date.") }
        guard Self.currencies.contains(currency) else { throw RecordError.invalid("Choose the receipt currency.") }
        guard let total = try Money.parse(amount, currency: currency), total > 0 else { throw RecordError.invalid("Enter a total greater than zero.") }
        if let tax = try Money.parse(tax, currency: currency), tax > total { throw RecordError.invalid("Tax cannot exceed the receipt total.") }
        guard Self.categories.contains(category) else { throw RecordError.invalid("Choose an expense category.") }
    }
}

@objc(Expense)
final class Expense: NSManagedObject, Identifiable {
    @NSManaged var id: UUID?
    @NSManaged var createdAt: Date?
    @NSManaged var updatedAt: Date?
    @NSManaged var photo: Data?
    @NSManaged var valueJSON: String
    @NSManaged var revision: String
    @NSManaged var isDraft: Bool
    @NSManaged var job: Job?
    var value: ExpenseValue { (try? JSONDecoder().decode(ExpenseValue.self, from: Data(valueJSON.utf8))) ?? ExpenseValue() }

    static func capture(_ photo: Data, jobID: NSManagedObjectID, in context: NSManagedObjectContext) throws -> NSManagedObjectID {
        let id = try insertPhoto(photo, jobID: jobID, writer: isolatedWriter(context))
        context.refreshAllObjects()
        return id
    }
    static func replacePhoto(_ photo: Data, id: NSManagedObjectID, revision: String, in context: NSManagedObjectContext) throws {
        try updatePhoto(photo, id: id, revision: revision, writer: isolatedWriter(context))
        context.refreshAllObjects()
    }
    /// Only values and permanent object IDs cross queues. Refresh UI objects after commit.
    /// A nil event starts a business-cost receipt that belongs to no event.
    @MainActor static func capturePhoto(_ photo: Data, jobID: NSManagedObjectID?, in context: NSManagedObjectContext) async throws -> NSManagedObjectID {
        let writer = photoWriter(context)
        let id = try await writer.perform { try insertPhoto(photo, jobID: jobID, writer: writer) }
        context.refreshAllObjects()
        return id
    }
    @MainActor static func replacePhotoAsync(_ photo: Data, id: NSManagedObjectID, revision: String, in context: NSManagedObjectContext) async throws {
        let writer = photoWriter(context)
        try await writer.perform { try updatePhoto(photo, id: id, revision: revision, writer: writer) }
        context.refreshAllObjects()
    }
    @MainActor private static func photoWriter(_ context: NSManagedObjectContext) -> NSManagedObjectContext {
        let writer = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        writer.persistentStoreCoordinator = context.persistentStoreCoordinator
        // Do not overwrite a concurrent revision committed after validation.
        writer.mergePolicy = NSErrorMergePolicy
        return writer
    }
    private static func insertPhoto(_ photo: Data, jobID: NSManagedObjectID?, writer: NSManagedObjectContext) throws -> NSManagedObjectID {
        guard !photo.isEmpty, photo.count <= 12 * 1024 * 1024 else { throw RecordError.invalid("Choose a receipt image smaller than 12 MB.") }
        var job: Job?
        if let jobID {
            guard let event = try writer.existingObject(with: jobID) as? Job, event.deletedAt == nil else { throw RecordError.invalid("This event was deleted. Restore it before adding expenses.") }
            job = event
        }
        let record = Expense(context: writer)
        record.id = UUID(); record.createdAt = Date(); record.updatedAt = Date(); record.revision = UUID().uuidString
        record.photo = photo; record.job = job; record.isDraft = true
        record.valueJSON = String(decoding: try JSONEncoder().encode(ExpenseValue()), as: UTF8.self)
        try writer.save()
        return record.objectID
    }
    private static func updatePhoto(_ photo: Data, id: NSManagedObjectID, revision: String, writer: NSManagedObjectContext) throws {
        guard !photo.isEmpty, photo.count <= 12 * 1024 * 1024 else { throw RecordError.invalid("Choose a receipt image smaller than 12 MB.") }
        let record = try writer.existingObject(with: id) as! Expense
        guard record.isDraft, record.revision == revision, record.job?.deletedAt == nil else {
            throw RecordError.invalid("This draft changed or its event was deleted. Close and reopen it before replacing the photo.")
        }
        record.photo = photo
        record.updatedAt = Date(); record.revision = UUID().uuidString
        try writer.save()
    }
    /// `business` saves a cost that belongs to no event: it is never reimbursable and needs no photo.
    static func save(_ value: ExpenseValue, id: NSManagedObjectID, revision: String, confirmed: Bool = true, jobID: NSManagedObjectID? = nil,
                     business: Bool = false, in context: NSManagedObjectContext) throws {
        if confirmed { try value.validate() }
        let writer = isolatedWriter(context)
        let record = try writer.existingObject(with: id) as! Expense
        guard record.revision == revision else { throw RecordError.invalid("This expense changed on another device. Close and reopen it before saving.") }
        guard record.value.discarded != true, record.job?.deletedAt == nil else { throw RecordError.invalid("This expense or its event was removed. Reopen the expense list before editing.") }
        if business {
            if record.job != nil, try !record.activeInvoices(index: InvoiceIndex(in: writer)).isEmpty {
                throw RecordError.invalid("This receipt is on an invoice. Void that invoice before making it a business cost.")
            }
            record.job = nil
        } else if let jobID {
            guard let job = try writer.existingObject(with: jobID) as? Job, job.deletedAt == nil else { throw RecordError.invalid("Choose an active event.") }
            record.job = job
        }
        if confirmed && !business {
            guard record.job != nil else { throw RecordError.invalid("Choose an event before completing this expense.") }
            guard record.photo != nil else { throw RecordError.invalid("Attach a receipt photo before completing this expense.") }
        }
        var value = business ? value.asBusiness(id: record.id) : value.asEventReceipt
        // Capture evidence is immutable even when the reviewed form changes.
        value.capture = record.value.capture; value.discarded = record.value.discarded
        record.valueJSON = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        record.isDraft = !confirmed; record.updatedAt = Date(); record.revision = UUID().uuidString
        try writer.save(); context.refreshAllObjects()
    }
}


/// Optional Wallet evidence is retained independently from reviewed expense fields.
/// Only an explicit stable transaction ID is used for deduplication; equal amounts
/// at the same merchant can be distinct purchases.
struct ExpenseCaptureInput: Codable, Equatable {
    var merchant: String = ""
    var amount: String = ""
    var currency: String = ""
    var date: Date?
    var captureKey: String?
    init(merchant: String = "", amount: String = "", currency: String = "", date: Date? = nil, transactionID: String = "") {
        self.merchant = String(merchant.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        self.amount = String(amount.trimmingCharacters(in: .whitespacesAndNewlines).prefix(100))
        self.currency = String(currency.trimmingCharacters(in: .whitespacesAndNewlines).uppercased().prefix(20))
        self.date = date
        let key = transactionID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { captureKey = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined() }
    }
    /// Keeps amounts whose currency is still unknown; saving checks them against the chosen currency.
    static func plausibleAmount(_ amount: String, currency: String) -> Bool {
        (try? Money.parse(amount, decimals: currency.isEmpty ? Money.maxDecimals : Money.decimals(currency))) != nil
    }
    var draft: ExpenseValue {
        var value = ExpenseValue()
        value.merchant = merchant
        if ExpenseValue.currencies.contains(currency) { value.currency = currency }
        if Self.plausibleAmount(amount, currency: value.currency) { value.amount = amount }
        if let date { value.day = Day.string(from: date) }
        value.capture = self
        return value
    }
}

extension Expense {
    struct CaptureResult { let id: UUID; let objectID: NSManagedObjectID; let inserted: Bool }
    /// Call on the main actor with the shared store to serialize local shortcut deliveries.
    @MainActor static func captureBackground(_ input: ExpenseCaptureInput, in context: NSManagedObjectContext) throws -> CaptureResult {
        let writer = isolatedWriter(context)
        if let key = input.captureKey {
            let request = NSFetchRequest<Expense>(entityName: "Expense")
            request.predicate = NSPredicate(format: "valueJSON CONTAINS %@", key)
            if let existing = try writer.fetch(request).first(where: { $0.value.capture?.captureKey == key }), let id = existing.id {
                return CaptureResult(id: id, objectID: existing.objectID, inserted: false)
            }
        }
        let expense = Expense(context: writer)
        let id = UUID(); expense.id = id; expense.createdAt = Date(); expense.updatedAt = Date()
        expense.revision = UUID().uuidString; expense.isDraft = true
        expense.valueJSON = String(decoding: try JSONEncoder().encode(input.draft), as: UTF8.self)
        try writer.save(); context.refreshAllObjects()
        return CaptureResult(id: id, objectID: expense.objectID, inserted: true)
    }
    static func discardDraft(id: NSManagedObjectID, revision: String, in context: NSManagedObjectContext) throws {
        let writer = isolatedWriter(context)
        let expense = try writer.existingObject(with: id) as! Expense
        guard expense.isDraft, expense.revision == revision else { throw RecordError.invalid("This expense changed. Reopen the list before removing it.") }
        var value = expense.value; value.discarded = true
        expense.valueJSON = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        expense.isDraft = false; expense.updatedAt = Date(); expense.revision = UUID().uuidString
        try writer.save(); context.refreshAllObjects()
    }
    var needsCompletion: Bool { isDraft && value.discarded != true && job?.deletedAt == nil }
    /// A finished cost that belongs to no event, such as a software subscription.
    var isBusiness: Bool { !isDraft && job == nil && value.discarded != true }
    /// Saves a business cost entered without a receipt photo, such as the next month of a subscription.
    static func createBusiness(_ value: ExpenseValue, in context: NSManagedObjectContext) throws -> NSManagedObjectID {
        try value.validate()
        let writer = isolatedWriter(context)
        let expense = Expense(context: writer)
        let id = UUID(); expense.id = id; expense.createdAt = Date(); expense.updatedAt = Date()
        expense.revision = UUID().uuidString; expense.isDraft = false
        expense.valueJSON = String(decoding: try JSONEncoder().encode(value.asBusiness(id: id)), as: UTF8.self)
        try writer.save(); context.refreshAllObjects()
        return expense.objectID
    }
}

enum ReceiptField: String, CaseIterable, Identifiable {
    case merchant = "Merchant", day = "Date", amount = "Total", currency = "Currency", tax = "Tax", category = "Category"
    var id: String { rawValue }
    var keyPath: WritableKeyPath<ExpenseValue, String> {
        switch self {
        case .merchant: return \.merchant
        case .day: return \.day
        case .amount: return \.amount
        case .currency: return \.currency
        case .tax: return \.tax
        case .category: return \.category
        }
    }
    /// Reader-facing form of a field value; dates use the device's locale instead of the stored YYYY-MM-DD.
    func display(_ value: String) -> String { self == .day && !value.isEmpty ? Day.display(value) : value }
}

extension ExpenseValue {
    /// Business costs are never rebilled; a repeating one joins (or starts) its series.
    func asBusiness(id: UUID?) -> ExpenseValue {
        var value = self
        value.reimbursable = false
        if value.repeatsMonthly == true { value.seriesID = value.seriesID ?? id ?? UUID() } else { value.repeatsMonthly = nil }
        return value
    }
    /// Event receipts don't repeat.
    var asEventReceipt: ExpenseValue {
        var value = self
        value.repeatsMonthly = nil
        return value
    }
    /// Preserve entered/payment values. Conflicting receipt facts require explicit acceptance.
    mutating func fillBlanks(from receipt: ExpenseValue) -> [ReceiptField] {
        var conflicts: [ReceiptField] = []
        for field in ReceiptField.allCases {
            let current = self[keyPath: field.keyPath], proposed = receipt[keyPath: field.keyPath]
            guard !proposed.isEmpty else { continue }
            if current.isEmpty || (field == .category && current == "Other") { self[keyPath: field.keyPath] = proposed }
            else if current != proposed { conflicts.append(field) }
        }
        return conflicts
    }
}
