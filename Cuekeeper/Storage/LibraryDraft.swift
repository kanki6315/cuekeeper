import CoreData
import Foundation

/// Editable text for a client's invoicing details; terms stay text until saved.
struct InvoicingDraft: Equatable {
    var billingName = ""
    var email = ""
    var address = ""
    var terms = ""
    var taxID = ""
    init(_ value: ClientInvoicing = ClientInvoicing()) {
        billingName = value.billingName; email = value.email; address = value.address
        terms = value.termsDays.map(String.init) ?? ""; taxID = value.taxID
    }
    func value() throws -> ClientInvoicing {
        let trimmed = terms.trimmingCharacters(in: .whitespacesAndNewlines)
        var days: Int?
        if !trimmed.isEmpty {
            guard let parsed = Int(trimmed) else { throw RecordError.invalid("Enter payment terms as a number of days.") }
            days = parsed
        }
        let value = ClientInvoicing(billingName: billingName.trimmingCharacters(in: .whitespacesAndNewlines), email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                                    address: address.trimmingCharacters(in: .whitespacesAndNewlines), termsDays: days, taxID: taxID.trimmingCharacters(in: .whitespacesAndNewlines))
        try value.validate()
        return value
    }
}

struct LibraryDraft: Equatable {
    var name = ""
    var contact = ""
    var notes = ""
    var currency = UserDefaults.standard.string(forKey: "defaultCurrency") ?? "USD"
    var invoicing = InvoicingDraft()
    init(record: NSManagedObject? = nil) {
        name = record?.value(forKey: "name") as? String ?? ""
        if let client = record as? Client {
            contact = client.contact
            notes = client.notes
            currency = client.defaultCurrency
            invoicing = InvoicingDraft(client.invoicing)
        }
    }

    func save(entity: String, editing id: NSManagedObjectID?, baseline: LibraryDraft, in context: NSManagedObjectContext) throws {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw JobDraft.ValidationError.nameRequired }
        let invoicingValue = entity == "Client" ? try invoicing.value() : nil
        let writer = isolatedWriter(context)
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
            if let invoicingValue, id == nil || invoicing != baseline.invoicing {
                record.setValue(String(decoding: try JSONEncoder().encode(invoicingValue), as: UTF8.self), forKey: "invoicingJSON")
            }
        }
        try writer.save()
        context.refreshAllObjects()
    }
}
