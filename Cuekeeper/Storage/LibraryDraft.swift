import CoreData
import Foundation

struct LibraryDraft: Equatable {
    var name = ""
    var contact = ""
    var notes = ""
    var currency = "USD"
    init(record: NSManagedObject? = nil) {
        name = record?.value(forKey: "name") as? String ?? ""
        if let client = record as? Client {
            contact = client.contact
            notes = client.notes
            currency = client.defaultCurrency
        }
    }

    func save(entity: String, editing id: NSManagedObjectID?, baseline: LibraryDraft, in context: NSManagedObjectContext) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw JobDraft.ValidationError.nameRequired }
        let writer = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        writer.persistentStoreCoordinator = context.persistentStoreCoordinator
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = NSPredicate(format: "name ==[cd] %@", name)
        if try writer.fetch(request).contains(where: { $0.objectID != id }) {
            throw NSError(domain: "Cuekeeper", code: 1, userInfo: [NSLocalizedDescriptionKey: "That name already exists. Choose a different name or edit the existing record."])
        }
        let record: NSManagedObject
        if let id { record = try writer.existingObject(with: id) }
        else {
            record = NSEntityDescription.insertNewObject(forEntityName: entity, into: writer)
            record.setValue(UUID(), forKey: "id")
        }
        if id == nil || name != baseline.name { record.setValue(name, forKey: "name") }
        if entity == "Client" {
            if id == nil || contact != baseline.contact { record.setValue(contact, forKey: "contact") }
            if id == nil || notes != baseline.notes { record.setValue(notes, forKey: "notes") }
            if id == nil || currency != baseline.currency { record.setValue(currency, forKey: "defaultCurrency") }
        }
        try writer.save()
        context.refreshAllObjects()
    }
}
