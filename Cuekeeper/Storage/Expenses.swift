import CoreData
import Foundation

struct ExpenseValue: Codable, Equatable {
    static let categories = ["Travel", "Accommodation", "Meals", "Parking", "Equipment", "Other"]
    // The first version uses two-decimal currencies, matching Money's exact minor units.
    static let currencies = ["USD", "EUR", "GBP", "CAD", "AUD", "NZD", "CHF"]
    var merchant = ""
    var day = ""
    var amount = ""
    var currency = ""
    var tax = ""
    var category = "Other"
    var reimbursable = false
    var notes = ""
    func validate() throws {
        guard !merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RecordError.invalid("Enter the merchant shown on the receipt.") }
        guard let date = Day.date(from: day), Day.string(from: date) == day else { throw RecordError.invalid("Enter the receipt date as YYYY-MM-DD.") }
        guard let total = try Money.parse(amount), total > 0 else { throw RecordError.invalid("Enter a total greater than zero.") }
        guard Self.currencies.contains(currency) else { throw RecordError.invalid("Choose the receipt currency.") }
        if let tax = try Money.parse(tax), tax > total { throw RecordError.invalid("Tax cannot exceed the receipt total.") }
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
        guard !photo.isEmpty, photo.count <= 12 * 1024 * 1024 else { throw RecordError.invalid("Choose a receipt image smaller than 12 MB.") }
        let writer = isolatedWriter(context)
        guard let job = try writer.existingObject(with: jobID) as? Job, job.deletedAt == nil else { throw RecordError.invalid("This event was deleted. Restore it before adding expenses.") }
        let record = Expense(context: writer)
        record.id = UUID(); record.createdAt = Date(); record.updatedAt = Date(); record.revision = UUID().uuidString
        record.photo = photo; record.job = job; record.isDraft = true
        record.valueJSON = String(decoding: try JSONEncoder().encode(ExpenseValue()), as: UTF8.self)
        try writer.save(); context.refreshAllObjects()
        return record.objectID
    }
    static func replacePhoto(_ photo: Data, id: NSManagedObjectID, revision: String, in context: NSManagedObjectContext) throws {
        guard !photo.isEmpty, photo.count <= 12 * 1024 * 1024 else { throw RecordError.invalid("Choose a receipt image smaller than 12 MB.") }
        let writer = isolatedWriter(context)
        let record = try writer.existingObject(with: id) as! Expense
        guard record.isDraft, record.revision == revision, let job = record.job, job.deletedAt == nil else {
            throw RecordError.invalid("This draft changed or its event was deleted. Close and reopen it before replacing the photo.")
        }
        record.photo = photo
        record.valueJSON = String(decoding: try JSONEncoder().encode(ExpenseValue()), as: UTF8.self)
        record.updatedAt = Date(); record.revision = UUID().uuidString
        try writer.save(); context.refreshAllObjects()
    }
    static func save(_ value: ExpenseValue, id: NSManagedObjectID, revision: String, confirmed: Bool = true, in context: NSManagedObjectContext) throws {
        if confirmed { try value.validate() }
        let writer = isolatedWriter(context)
        let record = try writer.existingObject(with: id) as! Expense
        guard record.revision == revision else { throw RecordError.invalid("This expense changed on another device. Close and reopen it before saving.") }
        guard record.job?.deletedAt == nil, record.job != nil, record.photo != nil else { throw RecordError.invalid("The event or receipt is unavailable. Wait for sync or restore the event.") }
        record.valueJSON = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        record.isDraft = !confirmed; record.updatedAt = Date(); record.revision = UUID().uuidString
        try writer.save(); context.refreshAllObjects()
    }
}
