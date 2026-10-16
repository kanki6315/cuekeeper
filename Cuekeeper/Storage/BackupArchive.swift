import CoreData
import CryptoKit
import Foundation

/// Portable data, not a copy of the live SQLite store or CloudKit bookkeeping.
/// UUIDs preserve invoice snapshots and immutable financial revision identities.
struct BackupArchive: Codable {
    var format = "com.cuekeeper.backup"
    var version = 2
    var createdAt = Date()
    var records: [Record]
    var workspace: BackupWorkspace? = nil
    enum CodingKeys: String, CodingKey { case format, version, createdAt, records }
    init(format: String = "com.cuekeeper.backup", version: Int = 2, createdAt: Date = Date(), records: [Record], workspace: BackupWorkspace? = nil) {
        self.format = format; self.version = version; self.createdAt = createdAt; self.records = records; self.workspace = workspace
    }
    /// Pre-V14 archives may contain broadcast links, which V14 removed.
    /// Drop those records and their session relationship so older backups still restore.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        version = try container.decode(Int.self, forKey: .version)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        records = try container.decode([Record].self, forKey: .records).compactMap { record in
            guard record.key.entity != "BroadcastLink" else { return nil }
            var record = record
            if record.key.entity == "WorkSession" { record.relationships["links"] = nil }
            return record
        }
    }
    struct Attachment: Codable, Equatable {
        var path: String
        var bytes: Int64
        var sha256: String
    }

    struct Key: Codable, Hashable { var entity: String; var id: UUID }
    struct Record: Codable {
        var key: Key
        var attributes: [String: Value]
        var relationships: [String: [Key]]
    }
    enum Value: Codable, Equatable {
        case attachment(Attachment), null, string(String), uuid(UUID), date(Date), integer(Int64), boolean(Bool)
        var object: Any? {
            switch self {
            case .attachment: return nil
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
            case .binaryDataAttributeType: throw RecordError.invalid("Receipt data must be stored as an attachment.")
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
            case (.attachment, .binaryDataAttributeType), (.string, .stringAttributeType), (.uuid, .UUIDAttributeType), (.date, .dateAttributeType),
                 (.integer, .integer64AttributeType), (.boolean, .booleanAttributeType): return true
            default: return false
            }
        }
    }

    private static func key(_ object: NSManagedObject, eventIDs: [NSManagedObjectID: UUID] = [:]) throws -> Key {
        guard let entity = object.entity.name, let id = object.value(forKey: "id") as? UUID else {
            throw RecordError.invalid("Some records are still incomplete. Let iCloud finish syncing, then try again.")
        }
        return Key(entity: entity, id: eventIDs[object.objectID] ?? id)
    }

    /// Legacy WorkEvent IDs were ownership markers, not unique record identities:
    /// two offline promotions can create separate records with the same job UUID.
    /// Preserve every record and its actual relationships without changing live
    /// ownership IDs. Other entities (especially financial history) stay strict.
    private static func eventArchiveIDs(in context: NSManagedObjectContext) throws -> [NSManagedObjectID: UUID] {
        let events = try context.fetch(NSFetchRequest<WorkEvent>(entityName: "WorkEvent"))
        let groups = Dictionary(grouping: events.filter { $0.id != nil }, by: { $0.id! })
        var reserved = Set(groups.keys)
        var result: [NSManagedObjectID: UUID] = [:]
        for id in groups.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let group = groups[id], group.count > 1 else { continue }
            let ordered = group.sorted { left, right in
                // Keep the owning job's current metadata under its original ID.
                let leftOwns = left.bookings?.contains { $0.id == id } ?? false
                let rightOwns = right.bookings?.contains { $0.id == id } ?? false
                if leftOwns != rightOwns { return leftOwns }
                return left.objectID.uriRepresentation().absoluteString < right.objectID.uriRepresentation().absoluteString
            }
            for event in ordered.dropFirst() {
                guard !event.objectID.isTemporaryID else {
                    throw RecordError.invalid("Save your current changes before backing up.")
                }
                var salt = 0
                var replacement: UUID
                repeat {
                    let seed = "com.cuekeeper.backup.WorkEvent/\(id)/\(event.objectID.uriRepresentation().absoluteString)/\(salt)"
                    var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
                    bytes[6] = (bytes[6] & 0x0f) | 0x80
                    bytes[8] = (bytes[8] & 0x3f) | 0x80
                    replacement = bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress!) as UUID }
                    salt += 1
                } while reserved.contains(replacement)
                reserved.insert(replacement)
                result[event.objectID] = replacement
            }
        }
        return result
    }

    static func capture(in context: NSManagedObjectContext, control: BackupControl = BackupControl()) throws -> Self {
        let reader = context
        let workspace = try BackupWorkspace()
        var attachmentBytes: Int64 = 0
        let originalGeneration = reader.queryGenerationToken
        try reader.setQueryGenerationFrom(.current)
        defer { try? reader.setQueryGenerationFrom(originalGeneration) }
        let eventIDs = try eventArchiveIDs(in: reader)
        let model = reader.persistentStoreCoordinator!.managedObjectModel
        var records: [Record] = []
        for entity in model.entities.sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) {
            guard let name = entity.name else { continue }
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            request.fetchBatchSize = 50
            for object in try reader.fetch(request) {
                try autoreleasepool {
                    try control.check()
                    guard records.count < BackupLimits.records else { throw RecordError.invalid("This daybook has too many records for a backup.") }
                    var attributes: [String: Value] = [:]
                    var relationships: [String: [Key]] = [:]
                    for (name, attribute) in entity.attributesByName {
                        if attribute.attributeType == .binaryDataAttributeType, let data = object.value(forKey: name) as? Data {
                            guard !data.isEmpty, data.count <= BackupLimits.receipt else { throw RecordError.invalid("A receipt exceeds the 12 MB image limit.") }
                            attachmentBytes += Int64(data.count)
                            guard attachmentBytes <= BackupLimits.archive else { throw RecordError.invalid("Receipt images exceed the 512 MB backup limit.") }
                            let path = "receipts/\(try key(object).id.uuidString)-\(name).jpg"
                            try BackupLimits.requireSpace(Int64(data.count))
                            try data.write(to: workspace.url.appendingPathComponent(path), options: .atomic)
                            attributes[name] = .attachment(Attachment(path: path, bytes: Int64(data.count), sha256: BackupFiles.digest(data)))
                        } else {
                            attributes[name] = try Value(object.value(forKey: name), attribute: attribute)
                        }
                    }
                    for (name, relationship) in entity.relationshipsByName {
                        let related = relationship.isToMany ? Array((object.value(forKey: name) as? Set<NSManagedObject>) ?? []) : (object.value(forKey: name) as? NSManagedObject).map { [$0] } ?? []
                        relationships[name] = try related.map { try key($0, eventIDs: eventIDs) }.sorted { $0.id.uuidString < $1.id.uuidString }
                    }
                    let archiveKey = try key(object, eventIDs: eventIDs)
                    attributes["id"] = .uuid(archiveKey.id)
                    records.append(Record(key: archiveKey, attributes: attributes, relationships: relationships))
                    reader.refresh(object, mergeChanges: false)
                    if records.count % 50 == 0 { control.report("Preparing records · \(records.count) read", nil) }
                }
            }
        }
        let archive = Self(records: records.sorted { ($0.key.entity, $0.key.id.uuidString) < ($1.key.entity, $1.key.id.uuidString) }, workspace: workspace)
        try archive.validate(model: model)
        return archive
    }

    // Convenience for small model fixtures; production uses URLs end to end.
    func encoded() throws -> Data {
        let file = try writePackage()
        return try Data(contentsOf: file.url)
    }
    static func decode(_ data: Data, model: NSManagedObjectModel) throws -> Self {
        let file = try BackupWorkspace()
        let url = file.url.appendingPathComponent("import.zip")
        try data.write(to: url)
        return try readPackage(url, model: model)
    }

    func validate(model: NSManagedObjectModel) throws {
        guard format == "com.cuekeeper.backup", version == 2, records.count <= BackupLimits.records else {
            throw RecordError.invalid("This is not a supported Cuekeeper backup. Update Cuekeeper if it was made with a newer version.")
        }
        let keys = Set(records.map(\.key))
        guard keys.count == records.count else { throw RecordError.invalid("The backup contains duplicate record identities.") }
        let indexed = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
        for record in records {
            // Pre-V13 archives lack only the new optional ownership field, and pre-V15
            // archives lack client invoicing details. Restored records keep the defaults.
            guard let entity = model.entitiesByName[record.key.entity],
                  Set(record.attributes.keys).isSubset(of: Set(entity.attributesByName.keys)),
                  Set(entity.attributesByName.keys).subtracting(record.attributes.keys).isSubset(
                    of: record.key.entity == "WorkEvent" ? ["ownerJobID"] : record.key.entity == "Client" ? ["invoicingJSON"] : []),
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
    func restore(in context: NSManagedObjectContext, control: BackupControl = BackupControl()) throws -> RestoreResult {
        let writer = context
        guard !writer.hasChanges else { throw RecordError.invalid("Save your current changes before restoring a backup.") }
        var committed = false
        defer { if !committed { writer.rollback() } }
        try verifyAttachments(control: control)
        try BackupLimits.requireSpace(attachments.reduce(0) { $0 + $1.bytes } * 2)
        try validate(model: writer.persistentStoreCoordinator!.managedObjectModel)
        let eventIDs = try Self.eventArchiveIDs(in: writer)
        var objects: [Key: NSManagedObject] = [:]
        var inserted = Set<Key>()
        var result = RestoreResult()
        for entity in writer.persistentStoreCoordinator!.managedObjectModel.entities {
            guard let name = entity.name else { continue }
            for object in try writer.fetch(NSFetchRequest<NSManagedObject>(entityName: name)) {
                let key = try Self.key(object, eventIDs: eventIDs)
                guard objects[key] == nil else { throw RecordError.invalid("Duplicate records need review before restoring a backup.") }
                objects[key] = object
            }
        }
        for (offset, record) in records.enumerated() {
            try control.check()
            if offset % 50 == 0 { control.report("Restoring records", Double(offset) / Double(max(1, records.count))) }
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
                for (name, value) in record.attributes {
                    if case .attachment(let attachment) = value {
                        guard let workspace else { throw RecordError.invalid("Receipt files are missing.") }
                        object.setValue(try Data(contentsOf: workspace.url.appendingPathComponent(attachment.path), options: .alwaysMapped), forKey: name)
                    } else { object.setValue(value.object, forKey: name) }
                }
                objects[record.key] = object; inserted.insert(record.key); result.added += 1
            }
        }
        for record in records where inserted.contains(record.key) {
            try control.check()
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
            try control.check()
            let object = objects[record.key]!
            if object.value(forKey: "deletedAt") != nil {
                object.setValue(nil, forKey: "deletedAt")
                object.setValue(nil, forKey: "recoveryDiscardedAt")
                result.recovered += 1
            }
        }
        try control.check()
        control.report("Saving restored records…", nil)
        try control.check()
        try writer.save()
        committed = true
        context.refreshAllObjects()
        return result
    }
}
