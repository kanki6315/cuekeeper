import CoreData
import Foundation

/// Portable data, not a copy of the live SQLite store or CloudKit bookkeeping.
/// UUIDs preserve invoice snapshots and immutable financial revision identities.
struct BackupArchive: Codable {
    var format = "com.cuekeeper.backup"
    var version = 1
    var createdAt = Date()
    var records: [Record]

    struct Key: Codable, Hashable { var entity: String; var id: UUID }
    struct Record: Codable {
        var key: Key
        var attributes: [String: Value]
        var relationships: [String: [Key]]
    }
    enum Value: Codable, Equatable {
        case null, string(String), uuid(UUID), date(Date), integer(Int64), boolean(Bool)
        var object: Any? {
            switch self {
            case .null: return nil
            case .string(let value): return value
            case .uuid(let value): return value
            case .date(let value): return value
            case .integer(let value): return value
            case .boolean(let value): return value
            }
        }
        init(_ object: Any?, attribute: NSAttributeDescription) throws {
            guard let object else { self = .null; return }
            switch attribute.attributeType {
            case .stringAttributeType: self = .string(object as! String)
            case .UUIDAttributeType: self = .uuid(object as! UUID)
            case .dateAttributeType: self = .date(object as! Date)
            case .integer64AttributeType: self = .integer((object as! NSNumber).int64Value)
            case .booleanAttributeType: self = .boolean((object as! NSNumber).boolValue)
            default: throw RecordError.invalid("This app version cannot back up \(attribute.name).")
            }
        }
        func matches(_ attribute: NSAttributeDescription) -> Bool {
            switch (self, attribute.attributeType) {
            case (.null, _): return attribute.isOptional
            case (.string, .stringAttributeType), (.uuid, .UUIDAttributeType), (.date, .dateAttributeType),
                 (.integer, .integer64AttributeType), (.boolean, .booleanAttributeType): return true
            default: return false
            }
        }
    }

    private static func key(_ object: NSManagedObject) throws -> Key {
        guard let entity = object.entity.name, let id = object.value(forKey: "id") as? UUID else {
            throw RecordError.invalid("Some records are still incomplete. Let iCloud finish syncing, then try again.")
        }
        return Key(entity: entity, id: id)
    }

    static func capture(in context: NSManagedObjectContext) throws -> Self {
        let reader = isolatedWriter(context)
        try reader.setQueryGenerationFrom(.current)
        let model = reader.persistentStoreCoordinator!.managedObjectModel
        var records: [Record] = []
        for entity in model.entities.sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) {
            guard let name = entity.name else { continue }
            for object in try reader.fetch(NSFetchRequest<NSManagedObject>(entityName: name)) {
                var attributes: [String: Value] = [:]
                var relationships: [String: [Key]] = [:]
                for (name, attribute) in entity.attributesByName {
                    attributes[name] = try Value(object.value(forKey: name), attribute: attribute)
                }
                for (name, relationship) in entity.relationshipsByName {
                    let related = relationship.isToMany ? Array((object.value(forKey: name) as? Set<NSManagedObject>) ?? []) : (object.value(forKey: name) as? NSManagedObject).map { [$0] } ?? []
                    relationships[name] = try related.map(key).sorted { $0.id.uuidString < $1.id.uuidString }
                }
                records.append(Record(key: try key(object), attributes: attributes, relationships: relationships))
            }
        }
        let archive = Self(records: records.sorted { ($0.key.entity, $0.key.id.uuidString) < ($1.key.entity, $1.key.id.uuidString) })
        try archive.validate(model: model)
        return archive
    }

    func encoded() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 100 * 1024 * 1024 else { throw RecordError.invalid("This daybook exceeds the 100 MB backup limit.") }
        return data
    }

    static func decode(_ data: Data, model: NSManagedObjectModel) throws -> Self {
        guard data.count <= 100 * 1024 * 1024 else { throw RecordError.invalid("This backup is too large to restore on this device.") }
        let archive = try JSONDecoder().decode(Self.self, from: data)
        try archive.validate(model: model)
        return archive
    }

    func validate(model: NSManagedObjectModel) throws {
        guard format == "com.cuekeeper.backup", version == 1, records.count <= 200_000 else {
            throw RecordError.invalid("This is not a supported Cuekeeper backup. Update Cuekeeper if it was made with a newer version.")
        }
        let keys = Set(records.map(\.key))
        guard keys.count == records.count else { throw RecordError.invalid("The backup contains duplicate record identities.") }
        let indexed = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
        for record in records {
            guard let entity = model.entitiesByName[record.key.entity],
                  Set(record.attributes.keys) == Set(entity.attributesByName.keys),
                  Set(record.relationships.keys) == Set(entity.relationshipsByName.keys),
                  record.attributes["id"] == .uuid(record.key.id) else {
                throw RecordError.invalid("The backup’s records do not match this version of Cuekeeper.")
            }
            for (name, value) in record.attributes {
                guard value.matches(entity.attributesByName[name]!) else { throw RecordError.invalid("The backup contains an invalid \(name) value.") }
            }
            for (name, targets) in record.relationships {
                let relationship = entity.relationshipsByName[name]!
                guard (relationship.isToMany || targets.count <= 1), Set(targets).count == targets.count else { throw RecordError.invalid("The backup contains invalid relationships.") }
                for target in targets {
                    guard keys.contains(target), target.entity == relationship.destinationEntity?.name,
                          let inverse = relationship.inverseRelationship?.name,
                          indexed[target]?.relationships[inverse]?.contains(record.key) == true else {
                        throw RecordError.invalid("The backup is incomplete. A related record is missing.")
                    }
                }
            }
        }
    }

    struct RestoreResult { var added = 0; var recovered = 0 }

    /// Merge missing identities; never roll back live edits or overwrite receipts.
    /// An explicit restore can also recover tombstones from an active backup copy.
    func restore(in context: NSManagedObjectContext) throws -> RestoreResult {
        let writer = isolatedWriter(context)
        try validate(model: writer.persistentStoreCoordinator!.managedObjectModel)
        var objects: [Key: NSManagedObject] = [:]
        var inserted = Set<Key>()
        var result = RestoreResult()
        for entity in writer.persistentStoreCoordinator!.managedObjectModel.entities {
            guard let name = entity.name else { continue }
            for object in try writer.fetch(NSFetchRequest<NSManagedObject>(entityName: name)) {
                let key = try Self.key(object)
                guard objects[key] == nil else { throw RecordError.invalid("Duplicate records need review before restoring a backup.") }
                objects[key] = object
            }
        }
        for record in records {
            if let existing = objects[record.key] {
                if ["FeeRevision", "InvoiceRevision", "PaymentRecord"].contains(record.key.entity) {
                    for (name, value) in record.attributes {
                        guard try Value(existing.value(forKey: name), attribute: existing.entity.attributesByName[name]!) == value else {
                            throw RecordError.invalid("This backup conflicts with existing financial history. Nothing was restored.")
                        }
                    }
                    for (name, targets) in record.relationships {
                        let current = try (existing.value(forKey: name) as? NSManagedObject).map { [try Self.key($0)] } ?? []
                        guard Set(current) == Set(targets) else {
                            throw RecordError.invalid("This backup conflicts with existing financial associations. Nothing was restored.")
                        }
                    }
                }
            } else {
                let object = NSEntityDescription.insertNewObject(forEntityName: record.key.entity, into: writer)
                for (name, value) in record.attributes { object.setValue(value.object, forKey: name) }
                objects[record.key] = object; inserted.insert(record.key); result.added += 1
            }
        }
        for record in records where inserted.contains(record.key) {
            let object = objects[record.key]!
            for (name, keys) in record.relationships {
                let relationship = object.entity.relationshipsByName[name]!
                let targets = keys.compactMap { key -> NSManagedObject? in
                    guard let target = objects[key] else { return nil }
                    // Existing records own their current to-one relationships.
                    if !inserted.contains(key), let inverse = relationship.inverseRelationship, !inverse.isToMany {
                        return nil
                    }
                    return target
                }
                if relationship.isToMany { object.mutableSetValue(forKey: name).addObjects(from: targets) }
                else { object.setValue(targets.first, forKey: name) }
            }
        }
        for record in records where !inserted.contains(record.key) && record.attributes["deletedAt"] == .null {
            let object = objects[record.key]!
            if object.value(forKey: "deletedAt") != nil {
                object.setValue(nil, forKey: "deletedAt")
                object.setValue(nil, forKey: "recoveryDiscardedAt")
                result.recovered += 1
            }
        }
        try writer.save()
        context.refreshAllObjects()
        return result
    }
}
