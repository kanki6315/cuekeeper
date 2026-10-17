import CoreData
import CryptoKit
import Foundation

/// Portable data, not a copy of the live SQLite store or CloudKit bookkeeping.
/// UUIDs preserve invoice snapshots and immutable financial revision identities.
struct BackupArchive: Codable {
    var format = "com.cuekeeper.backup"
    var version = 2
    /// Data model the records were written with. Archives made before this field
    /// existed omit it; their model is inferred from the records' shape.
    var model: Int? = BackupSchema.current
    var createdAt = Date()
    var records: [Record]
    /// Extra copies of records that exist in differing versions awaiting review,
    /// so a backup never has to wait for a choice. Each shares its key with a record.
    /// Older app versions ignore this list.
    var conflicts: [Record] = []
    var workspace: BackupWorkspace? = nil
    enum CodingKeys: String, CodingKey { case format, version, model, createdAt, records, conflicts }
    init(format: String = "com.cuekeeper.backup", version: Int = 2, model: Int? = BackupSchema.current, createdAt: Date = Date(),
         records: [Record], conflicts: [Record] = [], workspace: BackupWorkspace? = nil) {
        self.format = format; self.version = version; self.model = model; self.createdAt = createdAt
        self.records = records; self.conflicts = conflicts; self.workspace = workspace
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        format = try container.decode(String.self, forKey: .format)
        version = try container.decode(Int.self, forKey: .version)
        model = try container.decodeIfPresent(Int.self, forKey: .model)
        createdAt = try container.decode(Date.self, forKey: .createdAt)
        records = try container.decode([Record].self, forKey: .records)
        conflicts = try container.decodeIfPresent([Record].self, forKey: .conflicts) ?? []
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
    /// Replacement IDs derive from the record's content and bookings, never from
    /// store-specific object IDs, so every store holding the same metadata derives
    /// the same identity and cross-store restores do not add copies.
    static func eventArchiveIDs(in context: NSManagedObjectContext) throws -> [NSManagedObjectID: UUID] {
        let events = try context.fetch(NSFetchRequest<WorkEvent>(entityName: "WorkEvent"))
        let groups = Dictionary(grouping: events.filter { $0.id != nil }, by: { $0.id! })
        var reserved = Set(groups.keys)
        var result: [NSManagedObjectID: UUID] = [:]
        for id in groups.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
            guard let group = groups[id], group.count > 1 else { continue }
            let ordered = try group.map { ($0, try eventContent($0)) }.sorted { left, right in
                // Keep the owning job's current metadata under its original ID.
                let leftOwns = left.0.bookings?.contains { $0.id == id } ?? false
                let rightOwns = right.0.bookings?.contains { $0.id == id } ?? false
                if leftOwns != rightOwns { return leftOwns }
                // Equal content is interchangeable, so ties need no store-specific order.
                return left.1 < right.1
            }
            for (event, content) in ordered.dropFirst() {
                guard !event.objectID.isTemporaryID else {
                    throw RecordError.invalid("Save your current changes before backing up.")
                }
                var salt = 0
                var replacement: UUID
                repeat {
                    replacement = derivedEventID(id, content: content, salt: salt)
                    salt += 1
                } while reserved.contains(replacement)
                reserved.insert(replacement)
                result[event.objectID] = replacement
            }
        }
        return result
    }

    /// Event metadata's attributes (except its ID) and the jobs booked on it.
    static func eventContent(_ event: WorkEvent) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var values: [String: Value] = [:]
        for (name, attribute) in event.entity.attributesByName where name != "id" {
            values[name] = try Value(event.value(forKey: name), attribute: attribute)
        }
        let bookings = (event.bookings ?? []).compactMap { $0.id?.uuidString }.sorted()
        return String(decoding: try encoder.encode(values), as: UTF8.self) + "/" + bookings.joined(separator: ",")
    }
    static func derivedEventID(_ id: UUID, content: String, salt: Int) -> UUID {
        let seed = "com.cuekeeper.backup.WorkEvent/\(id)/\(content)/\(salt)"
        var bytes = Array(SHA256.hash(data: Data(seed.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return bytes.withUnsafeBufferPointer { NSUUID(uuidBytes: $0.baseAddress!) as UUID }
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
        let recordName = CloudRecordNames.lookup(reader.persistentStoreCoordinator!)
        func rank(_ object: NSManagedObject) -> (Int, String) {
            recordName(object.objectID).map { (0, $0) } ?? (1, object.objectID.uriRepresentation().absoluteString)
        }
        var records: [Record] = [], conflicts: [Record] = []
        /// `copy` 0 is the record; later copies are conflicting versions under the same key.
        func record(_ object: NSManagedObject, copy: Int, toMany: [String: [Key]]) throws -> Record {
            var attributes: [String: Value] = [:]
            var relationships: [String: [Key]] = toMany
            let archiveKey = try key(object, eventIDs: eventIDs)
            for (name, attribute) in object.entity.attributesByName {
                if attribute.attributeType == .binaryDataAttributeType, let data = object.value(forKey: name) as? Data {
                    guard !data.isEmpty, data.count <= BackupLimits.receipt else { throw RecordError.invalid("A receipt exceeds the 12 MB image limit.") }
                    attachmentBytes += Int64(data.count)
                    guard attachmentBytes <= BackupLimits.archive else { throw RecordError.invalid("Receipt images exceed the 512 MB backup limit.") }
                    let path = "receipts/\(archiveKey.id.uuidString)-\(name)\(copy == 0 ? "" : String(copy + 1)).jpg"
                    try BackupLimits.requireSpace(Int64(data.count))
                    try data.write(to: workspace.url.appendingPathComponent(path), options: .atomic)
                    attributes[name] = .attachment(Attachment(path: path, bytes: Int64(data.count), sha256: BackupFiles.digest(data)))
                } else {
                    attributes[name] = try Value(object.value(forKey: name), attribute: attribute)
                }
            }
            for (name, relationship) in object.entity.relationshipsByName where !relationship.isToMany {
                relationships[name] = try (object.value(forKey: name) as? NSManagedObject).map { [try key($0, eventIDs: eventIDs)] } ?? []
            }
            attributes["id"] = .uuid(archiveKey.id)
            return Record(key: archiveKey, attributes: attributes, relationships: relationships)
        }
        for entity in model.entities.sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) {
            guard let name = entity.name else { continue }
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            request.fetchBatchSize = 50
            var groups: [Key: [NSManagedObject]] = [:]
            for object in try reader.fetch(request) { groups[try key(object, eventIDs: eventIDs), default: []].append(object) }
            for archiveKey in groups.keys.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
                try autoreleasepool {
                    try control.check()
                    let copies = groups[archiveKey]!.sorted { rank($0) < rank($1) }
                    guard records.count + conflicts.count + copies.count <= BackupLimits.records else {
                        throw RecordError.invalid("This daybook has too many records for a backup.")
                    }
                    // Related records of every copy belong to the record's key.
                    var toMany: [String: [Key]] = [:]
                    for (name, relationship) in entity.relationshipsByName where relationship.isToMany {
                        let related = copies.flatMap { Array(($0.value(forKey: name) as? Set<NSManagedObject>) ?? []) }
                        toMany[name] = Set(try related.map { try key($0, eventIDs: eventIDs) }).sorted { $0.id.uuidString < $1.id.uuidString }
                    }
                    records.append(try record(copies[0], copy: 0, toMany: toMany))
                    let empty = toMany.mapValues { _ in [Key]() }
                    for (index, copy) in copies.enumerated().dropFirst() { conflicts.append(try record(copy, copy: index, toMany: empty)) }
                    for copy in copies { reader.refresh(copy, mergeChanges: false) }
                    if records.count % 50 == 0 { control.report("Preparing records · \(records.count) read", nil) }
                }
            }
        }
        let archive = Self(records: records.sorted { ($0.key.entity, $0.key.id.uuidString) < ($1.key.entity, $1.key.id.uuidString) },
                           conflicts: conflicts, workspace: workspace)
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

    /// Bring records from a supported older data model to the current one.
    /// Only the changes listed in `BackupSchema.changes` are accepted; any other
    /// missing or extra field is rejected rather than guessed.
    mutating func migrate(model managedModel: NSManagedObjectModel) throws {
        guard managedModel.versionIdentifiers.contains(String(BackupSchema.current)) else {
            throw RecordError.invalid("This build’s backup migrations do not describe its data model.")
        }
        let source = try BackupSchema.sourceModel(of: records + conflicts, declared: model)
        func migrate(_ records: inout [Record]) throws {
            for (version, change) in BackupSchema.changes where version > source {
                switch change {
                case .addedEntity: break
                case .removedEntity(let entity):
                    records.removeAll { $0.key.entity == entity }
                case .removedRelationship(let entity, let name):
                    for index in records.indices where records[index].key.entity == entity { records[index].relationships[name] = nil }
                case .addedRelationship(let entity, let name):
                    for index in records.indices where records[index].key.entity == entity { records[index].relationships[name] = [] }
                case .addedAttribute(let entity, let name):
                    guard let attribute = managedModel.entitiesByName[entity]?.attributesByName[name] else {
                        throw RecordError.invalid("This build’s backup migrations do not describe its data model.")
                    }
                    let value = try Value(attribute.defaultValue, attribute: attribute)
                    for index in records.indices where records[index].key.entity == entity { records[index].attributes[name] = value }
                }
            }
        }
        try migrate(&records); try migrate(&conflicts)
        model = BackupSchema.current
    }

    func validate(model: NSManagedObjectModel) throws {
        guard format == "com.cuekeeper.backup", version == 2, records.count + conflicts.count <= BackupLimits.records else {
            throw RecordError.invalid("This is not a supported Cuekeeper backup. Update Cuekeeper if it was made with a newer version.")
        }
        let keys = Set(records.map(\.key))
        guard keys.count == records.count else { throw RecordError.invalid("The backup contains duplicate record identities.") }
        let indexed = Dictionary(uniqueKeysWithValues: records.map { ($0.key, $0) })
        guard self.model == BackupSchema.current else {
            throw RecordError.invalid("This backup must be migrated before it can be restored.")
        }
        // Conflicting copies share a record's key; they keep only their own single links.
        for (record, isCopy) in records.map({ ($0, false) }) + conflicts.map({ ($0, true) }) {
            // Older shapes are migrated first (`migrate(model:)`); validation is exact.
            guard let entity = model.entitiesByName[record.key.entity],
                  Set(record.attributes.keys) == Set(entity.attributesByName.keys),
                  Set(record.relationships.keys) == Set(entity.relationshipsByName.keys),
                  record.attributes["id"] == .uuid(record.key.id) else {
                throw RecordError.invalid("The backup’s \(record.key.entity) records do not match this version of Cuekeeper.")
            }
            if isCopy, !keys.contains(record.key) { throw RecordError.invalid("The backup has a conflicting copy without its record.") }
            for (name, value) in record.attributes {
                guard value.matches(entity.attributesByName[name]!) else { throw RecordError.invalid("The backup contains an invalid \(name) value.") }
            }
            for (name, targets) in record.relationships {
                let relationship = entity.relationshipsByName[name]!
                guard (relationship.isToMany || targets.count <= 1), Set(targets).count == targets.count,
                      !(isCopy && relationship.isToMany && !targets.isEmpty) else { throw RecordError.invalid("The backup contains invalid relationships.") }
                for target in targets {
                    guard keys.contains(target), target.entity == relationship.destinationEntity?.name,
                          isCopy || (relationship.inverseRelationship.map { indexed[target]?.relationships[$0.name]?.contains(record.key) == true } ?? false) else {
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
        // Merge copies that iCloud delivered after an earlier restore before matching
        // identities. Copies still awaiting review stay; the backup matches either.
        _ = try IdentityReconciliation.run(in: writer)
        let eventIDs = try Self.eventArchiveIDs(in: writer)
        var copies: [Key: [NSManagedObject]] = [:]
        var inserted = Set<Key>()
        var result = RestoreResult()
        for entity in writer.persistentStoreCoordinator!.managedObjectModel.entities {
            guard let name = entity.name else { continue }
            for object in try writer.fetch(NSFetchRequest<NSManagedObject>(entityName: name)) {
                copies[try Self.key(object, eventIDs: eventIDs), default: []].append(object)
            }
        }
        let recordName = CloudRecordNames.lookup(writer.persistentStoreCoordinator!)
        func rank(_ object: NSManagedObject) -> (Int, String) {
            recordName(object.objectID).map { (0, $0) } ?? (1, object.objectID.uriRepresentation().absoluteString)
        }
        var objects = copies.mapValues { $0.min { rank($0) < rank($1) }! }
        for (offset, record) in records.enumerated() {
            try control.check()
            if offset % 50 == 0 { control.report("Restoring records", Double(offset) / Double(max(1, records.count))) }
            if objects[record.key] != nil {
                if IdentityReconciliation.immutable.contains(record.key.entity) {
                    // Any existing copy may match; financial history must equal one of them.
                    func matches(_ existing: NSManagedObject) throws -> Bool {
                        for (name, value) in record.attributes {
                            guard try Value(existing.value(forKey: name), attribute: existing.entity.attributesByName[name]!) == value else { return false }
                        }
                        return true
                    }
                    func linked(_ existing: NSManagedObject) throws -> Bool {
                        for (name, targets) in record.relationships {
                            let current = try (existing.value(forKey: name) as? NSManagedObject).map { [try Self.key($0)] } ?? []
                            guard Set(current) == Set(targets) else { return false }
                        }
                        return true
                    }
                    let candidates = copies[record.key] ?? []
                    guard try candidates.contains(where: matches) else {
                        throw RecordError.invalid("This backup conflicts with existing financial history. Nothing was restored.")
                    }
                    guard try candidates.contains(where: { try matches($0) && linked($0) }) else {
                        throw RecordError.invalid("This backup conflicts with existing financial associations. Nothing was restored.")
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
                objects[record.key] = object; copies[record.key] = [object]; inserted.insert(record.key); result.added += 1
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
        // Conflicting copies come back as copies awaiting review, unless one already exists.
        for record in conflicts {
            try control.check()
            var expected = record.attributes.mapValues { value -> Value in
                if case .attachment(let attachment) = value { return .string(attachment.sha256) }
                return value
            }
            let entity = writer.persistentStoreCoordinator!.managedObjectModel.entitiesByName[record.key.entity]!
            for (name, relationship) in entity.relationshipsByName where !relationship.isToMany {
                expected["→" + name] = .string((record.relationships[name] ?? []).map(\.id.uuidString).joined(separator: ","))
            }
            guard try !(copies[record.key] ?? []).contains(where: { try IdentityReconciliation.values($0) == expected }) else { continue }
            let object = NSEntityDescription.insertNewObject(forEntityName: record.key.entity, into: writer)
            for (name, value) in record.attributes {
                if case .attachment(let attachment) = value {
                    guard let workspace else { throw RecordError.invalid("Receipt files are missing.") }
                    object.setValue(try Data(contentsOf: workspace.url.appendingPathComponent(attachment.path), options: .alwaysMapped), forKey: name)
                } else { object.setValue(value.object, forKey: name) }
            }
            for (name, relationship) in entity.relationshipsByName where !relationship.isToMany {
                object.setValue(record.relationships[name]?.first.flatMap { objects[$0] }, forKey: name)
            }
            copies[record.key, default: []].append(object); result.added += 1
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
        try RestoreLedger.record(inserted.map { objects[$0]! }, in: writer)
        try writer.save()
        committed = true
        context.refreshAllObjects()
        return result
    }
}

/// Data model history for backups. Backups began with model 11. Every model
/// change that alters a backed-up entity must be listed here with the model
/// version that introduced it; `migrate(model:)` refuses to run otherwise.
enum BackupSchema {
    static let current = 15
    static let oldest = 11
    enum Change: Equatable {
        case addedEntity(String), removedEntity(String)
        case addedAttribute(String, String), addedRelationship(String, String), removedRelationship(String, String)
    }
    static let changes: [(version: Int, change: Change)] = [
        (12, .addedEntity("Expense")), (12, .addedRelationship("Job", "expenses")),
        (13, .addedAttribute("WorkEvent", "ownerJobID")),
        (14, .removedEntity("BroadcastLink")), (14, .removedRelationship("WorkSession", "links")),
        (15, .addedAttribute("Client", "invoicingJSON")),
    ]

    /// The declared model, checked against the records, or for older archives
    /// the newest model consistent with every record. Contradictory shapes fail.
    static func sourceModel(of records: [BackupArchive.Record], declared: Int?) throws -> Int {
        if let declared, declared > current {
            throw RecordError.invalid("This backup was made with a newer version of Cuekeeper. Update Cuekeeper, then try again.")
        }
        if let declared, declared < oldest {
            throw RecordError.invalid("This backup’s format is no longer supported. Choose a newer Cuekeeper backup.")
        }
        let candidates = declared.map { [$0] } ?? Array(oldest...current)
        var problem: String?
        for version in candidates.reversed() {
            if let mismatch = mismatch(records, version: version) { problem = problem ?? mismatch } else { return version }
        }
        throw RecordError.invalid("The backup is damaged or was edited: \(problem ?? "its records do not match any Cuekeeper version"). Nothing was restored.")
    }

    private static func mismatch(_ records: [BackupArchive.Record], version: Int) -> String? {
        for (introduced, change) in changes {
            let applies = version >= introduced
            switch change {
            case .addedEntity(let entity) where !applies && records.contains(where: { $0.key.entity == entity }),
                 .removedEntity(let entity) where applies && records.contains(where: { $0.key.entity == entity }):
                return "it contains \(entity) records from a different version"
            case .addedAttribute(let entity, let name):
                if let record = records.first(where: { $0.key.entity == entity && ($0.attributes[name] != nil) != applies }) {
                    return "\(record.key.entity) \(applies ? "is missing" : "has unexpected") \(name)"
                }
            case .addedRelationship(let entity, let name):
                if let record = records.first(where: { $0.key.entity == entity && ($0.relationships[name] != nil) != applies }) {
                    return "\(record.key.entity) \(applies ? "is missing" : "has unexpected") \(name)"
                }
            case .removedRelationship(let entity, let name):
                if let record = records.first(where: { $0.key.entity == entity && ($0.relationships[name] != nil) == applies }) {
                    return "\(record.key.entity) \(applies ? "has unexpected" : "is missing") \(name)"
                }
            default: break
            }
        }
        return nil
    }
}

/// Objects this device inserted from a backup, with the values each was restored
/// with. Kept beside the local store, so it is never synced or backed up.
/// Reconciliation uses it to tell a restored copy from the iCloud copy of the same
/// record, and the restored values as the common starting point of a three-way
/// merge. An entry is dropped once its record is matched, or after 30 days.
struct RestoreLedger: Codable, Equatable {
    struct Entry: Codable, Equatable {
        var restoredAt: Date
        var values: [String: BackupArchive.Value]
    }
    static let retention: TimeInterval = 30 * 24 * 60 * 60
    var entries: [String: Entry] = [:]

    static func url(for coordinator: NSPersistentStoreCoordinator) -> URL? {
        guard let store = coordinator.persistentStores.first(where: { $0.type == NSSQLiteStoreType }), let url = store.url else { return nil }
        return url.appendingPathExtension("restored.json")
    }
    static func load(_ coordinator: NSPersistentStoreCoordinator) -> RestoreLedger? {
        guard let url = url(for: coordinator), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    static func save(_ ledger: RestoreLedger?, _ coordinator: NSPersistentStoreCoordinator) throws {
        guard let url = url(for: coordinator) else { return }
        if let ledger, !ledger.entries.isEmpty {
            try JSONEncoder().encode(ledger).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } else if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
    /// Record restored objects and their values before the restore commits, so a
    /// crash cannot leave restored records untracked. Entries for objects that never
    /// commit are pruned later.
    static func record(_ objects: [NSManagedObject], in context: NSManagedObjectContext) throws {
        guard !objects.isEmpty, let coordinator = context.persistentStoreCoordinator else { return }
        try context.obtainPermanentIDs(for: objects)
        var ledger = load(coordinator) ?? RestoreLedger()
        let now = Date()
        for object in objects {
            ledger.entries[object.objectID.uriRepresentation().absoluteString] =
                Entry(restoredAt: now, values: try IdentityReconciliation.values(object))
        }
        try save(ledger, coordinator)
    }
    /// Drop entries for objects that are gone, were matched, or are past retention.
    static func prune(_ coordinator: NSPersistentStoreCoordinator, in context: NSManagedObjectContext,
                      matched: Set<String> = [], now: Date = Date()) throws {
        guard var ledger = load(coordinator) else { return }
        ledger.entries = ledger.entries.filter { uri, entry in
            guard !matched.contains(uri), now.timeIntervalSince(entry.restoredAt) < retention,
                  let url = URL(string: uri), let id = coordinator.managedObjectID(forURIRepresentation: url),
                  let object = try? context.existingObject(with: id) else { return false }
            return !object.isDeleted
        }
        try save(ledger, coordinator)
    }
}

/// Merges separate objects that carry the same application UUID, as happens when a
/// backup is restored before iCloud has delivered the same records (offline, a
/// temporary account problem, or signing in to iCloud later).
///
/// - Identical copies always merge.
/// - A restored copy and its iCloud copy merge field by field against the values
///   it was restored with: a field changed on one side takes that change; only a
///   field changed differently on both sides needs a person to choose. A deletion
///   made in iCloud before the restore is recovered; one made after it stands.
/// - When no restore ledger exists, the copy iCloud inserted (from change history)
///   wins over a copy inserted on this device.
/// - A link missing from one copy because its record hasn't arrived is not a difference.
/// - Immutable financial history (fee, invoice and payment revisions) merges only
///   when identical; anything else is kept untouched and reported for review.
///
/// The surviving object is the one with the lowest CloudKit record name, so every
/// device that merges a group keeps the same record. A group waits while some of
/// its copies have uploaded and others haven't, so devices never rank differently.
enum IdentityReconciliation {
    struct Report: Equatable {
        var merged = 0
        /// Entity names with copies that differ and need review.
        var conflicts: [String] = []
        var message: String? {
            conflicts.isEmpty ? nil : "Some \(Self.names(conflicts)) records arrived in two different versions. Both are kept until you choose."
        }
        private static func names(_ entities: [String]) -> String {
            let labels = ["PaymentRecord": "payment", "InvoiceRevision": "invoice", "FeeRevision": "fee", "Expense": "receipt",
                          "Job": "event", "WorkSession": "session", "Client": "client"]
            return Set(entities.map { labels[$0] ?? "daybook" }).sorted().joined(separator: ", ")
        }
    }
    static let immutable: Set<String> = ["FeeRevision", "InvoiceRevision", "PaymentRecord"]
    /// Bookkeeping fields: never shown and never a reason to ask; iCloud's value wins.
    static let internalFields: Set<String> = ["ownerJobID", "parentsJSON", "revision", "recoveryDiscardedAt", "createdAt", "updatedAt", "reversesID"]
    /// Transaction author NSPersistentCloudKitContainer uses for records it imports.
    static let importAuthor = "NSCloudKitMirroringDelegate.import"

    /// Copies of one record that differ and need a person to choose.
    struct Conflict: Identifiable, Equatable {
        let entity: String
        let recordID: UUID
        /// One object per distinct version, survivor-ranked first.
        let copies: [NSManagedObjectID]
        /// Fields (attributes and to-one links) a person must choose.
        let fields: [String]
        /// Fields already decided by the three-way merge, and the copy each comes from.
        var settled: [String: NSManagedObjectID] = [:]
        /// The copy unchosen fields come from (iCloud's, when known).
        var base: NSManagedObjectID? = nil
        var id: String { "\(entity)/\(recordID)" }
        /// Financial history is never mixed: keep one whole copy.
        var wholeRecord: Bool { IdentityReconciliation.immutable.contains(entity) || entity == "Expense" }
    }
    enum Choice {
        /// Keep this copy's values and links; the others are removed.
        case keep(NSManagedObjectID)
        /// Take each named field from the chosen copy; other fields follow the merge.
        case fields([String: NSManagedObjectID])
    }
    fileprivate struct Plan {
        var survivor: NSManagedObject; var base: NSManagedObject; var members: [NSManagedObject]
        var overrides: [String: NSManagedObject] = [:]
        /// The base copy's single links win, including links it deliberately cleared.
        var baseLinks = false
    }

    /// Values that identify a version: every attribute and to-one target (plus
    /// WorkEvent bookings, which carry ownership). Receipt photos by digest.
    static func values(_ object: NSManagedObject) throws -> [String: BackupArchive.Value] {
        var values: [String: BackupArchive.Value] = [:]
        for (name, attribute) in object.entity.attributesByName {
            if attribute.attributeType == .binaryDataAttributeType {
                values[name] = (object.value(forKey: name) as? Data).map { .string(BackupFiles.digest($0)) } ?? .null
            } else { values[name] = try BackupArchive.Value(object.value(forKey: name), attribute: attribute) }
        }
        for (name, relationship) in object.entity.relationshipsByName where !relationship.isToMany || object.entity.name == "WorkEvent" {
            let related = relationship.isToMany ? Array(object.value(forKey: name) as? Set<NSManagedObject> ?? [])
                : (object.value(forKey: name) as? NSManagedObject).map { [$0] } ?? []
            values["→" + name] = .string(related.compactMap { ($0.value(forKey: "id") as? UUID)?.uuidString }.sorted().joined(separator: ","))
        }
        return values
    }
    private static func signature(_ values: [String: BackupArchive.Value]) -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return String(decoding: (try? encoder.encode(values)) ?? Data(), as: UTF8.self)
    }
    private static func isLink(_ key: String, _ entity: NSEntityDescription) -> Bool {
        key.hasPrefix("→") && entity.relationshipsByName[String(key.dropFirst())]?.isToMany == false
    }
    private static func field(_ key: String) -> String { key.hasPrefix("→") ? String(key.dropFirst()) : key }

    /// Equal values, except that an empty to-one link matches any link.
    private static func compatible(_ left: [String: BackupArchive.Value], _ right: [String: BackupArchive.Value], entity: NSEntityDescription) -> Bool {
        for key in Set(left.keys).union(right.keys) {
            let a = left[key] ?? .null, b = right[key] ?? .null
            if a == b { continue }
            if isLink(key, entity), a == .string("") || b == .string("") { continue }
            return false
        }
        return true
    }
    private static func rank(_ recordName: @escaping (NSManagedObjectID) -> String?) -> (NSManagedObject) -> (Int, String) {
        { object in recordName(object.objectID).map { (0, $0) } ?? (1, object.objectID.uriRepresentation().absoluteString) }
    }

    /// IDs that more than one object carries, found with a grouped SQLite fetch
    /// rather than by loading every record.
    private static func duplicateIDs(_ entity: String, in context: NSManagedObjectContext) throws -> [UUID] {
        let count = NSExpressionDescription()
        count.name = "count"; count.expression = NSExpression(forFunction: "count:", arguments: [NSExpression(forKeyPath: "id")])
        count.expressionResultType = .integer64AttributeType
        let request = NSFetchRequest<NSDictionary>(entityName: entity)
        request.resultType = .dictionaryResultType
        request.propertiesToFetch = ["id", count]; request.propertiesToGroupBy = ["id"]
        request.predicate = NSPredicate(format: "id != nil")
        return try context.fetch(request).compactMap { row in
            ((row["count"] as? NSNumber)?.intValue ?? 0) > 1 ? row["id"] as? UUID : nil
        }
    }

    /// Which of these objects CloudKit imported, from persistent history. Nil when
    /// the history no longer covers them.
    private static func importedObjects(_ objects: [NSManagedObject], in context: NSManagedObjectContext) -> Set<NSManagedObjectID>? {
        // Only reached for differing duplicates with no ledger, which are rare.
        let ids = Set(objects.map(\.objectID))
        let request = NSPersistentHistoryChangeRequest.fetchHistory(after: .distantPast)
        request.resultType = .transactionsAndChanges
        guard let result = try? context.execute(request) as? NSPersistentHistoryResult,
              let transactions = result.result as? [NSPersistentHistoryTransaction] else { return nil }
        var imported = Set<NSManagedObjectID>(), local = Set<NSManagedObjectID>()
        for transaction in transactions {
            for change in transaction.changes ?? [] where change.changeType == .insert && ids.contains(change.changedObjectID) {
                if transaction.author == importAuthor { imported.insert(change.changedObjectID) } else { local.insert(change.changedObjectID) }
            }
        }
        // Both kinds of insert must be on record, or the history no longer reaches back far enough.
        return imported.isEmpty || local.isEmpty ? nil : imported
    }

    private struct Analysis {
        var plans: [Plan] = []
        var conflicts: [Conflict] = []
        var groups: [String: [NSManagedObject]] = [:]
        var matched: Set<String> = []
    }

    private static func analyze(in context: NSManagedObjectContext, recordName: @escaping (NSManagedObjectID) -> String?,
                                cleanup: Bool = false) throws -> Analysis {
        let coordinator = context.persistentStoreCoordinator!
        let ledger = RestoreLedger.load(coordinator)?.entries ?? [:]
        func entry(_ object: NSManagedObject) -> RestoreLedger.Entry? { ledger[object.objectID.uriRepresentation().absoluteString] }
        let rank = rank(recordName)
        func first(_ objects: [NSManagedObject]) -> NSManagedObject { objects.min { rank($0) < rank($1) }! }
        var analysis = Analysis()
        for entity in coordinator.managedObjectModel.entities.sorted(by: { ($0.name ?? "") < ($1.name ?? "") }) {
            guard let name = entity.name, entity.attributesByName["id"] != nil else { continue }
            let duplicates = try duplicateIDs(name, in: context)
            guard !duplicates.isEmpty else { continue }
            let request = NSFetchRequest<NSManagedObject>(entityName: name)
            request.predicate = NSPredicate(format: "id IN %@", duplicates)
            let groups = Dictionary(grouping: try context.fetch(request)) { $0.value(forKey: "id") as! UUID }
            for id in groups.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                guard let group = groups[id], group.count > 1 else { continue }
                if group.contains(where: { $0.objectID.isTemporaryID }) { throw RecordError.invalid("Save your current changes, then try again.") }
                // Wait while some copies have uploaded and others haven't: a copy that
                // uploads mid-merge could otherwise rank differently on another device.
                let named = group.filter { recordName($0.objectID) != nil }.count
                if named > 0 && named < group.count { continue }

                var valuesByObject: [NSManagedObjectID: [String: BackupArchive.Value]] = [:]
                var bySignature: [String: [NSManagedObject]] = [:]
                for object in group {
                    let found = try Self.values(object); valuesByObject[object.objectID] = found
                    bySignature[signature(found), default: []].append(object)
                }
                let classes = bySignature.keys.sorted().map { bySignature[$0]! }
                func vals(_ object: NSManagedObject) -> [String: BackupArchive.Value] { valuesByObject[object.objectID]! }
                func plan(_ members: [NSManagedObject], base: NSManagedObject? = nil, overrides: [String: NSManagedObject] = [:]) {
                    guard members.count > 1 else { return }
                    let survivor = first(members)
                    analysis.plans.append(Plan(survivor: survivor, base: base ?? survivor, members: members,
                                               overrides: overrides, baseLinks: base != nil))
                    for member in members where entry(member) != nil { analysis.matched.insert(member.objectID.uriRepresentation().absoluteString) }
                }
                func conflict(copies: [NSManagedObject], fields: [String], settled: [String: NSManagedObject] = [:], base: NSManagedObject? = nil) {
                    let found = Conflict(entity: name, recordID: id, copies: copies.sorted { rank($0) < rank($1) }.map(\.objectID),
                                         fields: fields.sorted(), settled: settled.mapValues(\.objectID), base: base?.objectID)
                    analysis.conflicts.append(found); analysis.groups[found.id] = group
                }
                if classes.count == 1 { plan(group); continue }
                // Legacy WorkEvent IDs were ownership markers: identical copies merge, others stay.
                if name == "WorkEvent" { classes.forEach { plan($0) }; continue }

                let editable = !immutable.contains(name)
                let restored = classes.filter { $0.contains { entry($0) != nil } }
                let live = classes.filter { $0.contains { entry($0) == nil } }
                if editable, restored.count == 1, live.count == 1, restored[0] != live[0],
                   let local = restored[0].first(where: { entry($0) != nil }), let snapshot = entry(local),
                   let remote = live[0].first(where: { entry($0) == nil }) {
                    // Three-way merge against the values the record was restored with.
                    let merge = try threeWay(local: local, remote: remote, snapshot: snapshot, entity: entity,
                                             values: vals, in: context, isRestored: { entry($0) != nil })
                    if merge.conflicting.isEmpty {
                        plan(group, base: remote, overrides: merge.overrides)
                    } else {
                        conflict(copies: [local, remote], fields: merge.conflicting, settled: merge.overrides, base: remote)
                    }
                    continue
                }
                if editable, restored.isEmpty, classes.count == 2,
                   let imported = importedObjects(group, in: context) {
                    // No ledger: a copy iCloud imported beside one inserted here is a
                    // restore from before the ledger existed. iCloud's copy wins.
                    let cloud = group.filter { imported.contains($0.objectID) }, here = group.filter { !imported.contains($0.objectID) }
                    if !cloud.isEmpty, !here.isEmpty, Set(cloud.map { signature(vals($0)) }).count == 1 {
                        plan(group, base: first(cloud)); continue
                    }
                }
                // Unknown origin: a missing link is not a difference; anything else is reviewed.
                var combined: [(members: [NSManagedObject], values: [String: BackupArchive.Value])] = []
                for members in classes {
                    let candidate = vals(members[0])
                    if let index = combined.firstIndex(where: { compatible($0.values, candidate, entity: entity) }) {
                        combined[index].members += members
                        for (key, value) in candidate where combined[index].values[key] == .string("") { combined[index].values[key] = value }
                    } else { combined.append((members, candidate)) }
                }
                if combined.count == 1 { plan(group); continue }
                combined.forEach { plan($0.members) }
                let all = combined.map(\.values)
                let keys = Set(all.flatMap(\.keys)).subtracting(["id"])
                let fields = keys.filter { key in Set(all.map { signature([key: $0[key] ?? .null]) }).count > 1 }.map(field)
                conflict(copies: combined.map { first($0.members) }, fields: fields)
            }
        }
        if cleanup {
            let planned = Set(analysis.plans.flatMap { $0.members.map(\.objectID) })
            analysis.plans += try orphanEventPlans(in: context).filter { !$0.members.contains { planned.contains($0.objectID) } }
        }
        return analysis
    }

    /// Per field: the value that wins, and fields changed differently on both sides.
    private static func threeWay(local: NSManagedObject, remote: NSManagedObject, snapshot: RestoreLedger.Entry,
                                 entity: NSEntityDescription, values: (NSManagedObject) -> [String: BackupArchive.Value],
                                 in context: NSManagedObjectContext, isRestored: (NSManagedObject) -> Bool) throws
        -> (overrides: [String: NSManagedObject], conflicting: [String]) {
        let mine = values(local), theirs = values(remote)
        var overrides: [String: NSManagedObject] = [:], conflicting: [String] = []
        for key in Set(mine.keys).union(theirs.keys).subtracting(["id", "deletedAt", "recoveryDiscardedAt"]) {
            let base = snapshot.values[key] ?? .null, a = mine[key] ?? .null, b = theirs[key] ?? .null
            if a == b { continue }
            if a == base {
                // iCloud's change wins, unless its link is only missing because the
                // linked record hasn't been delivered yet.
                if isLink(key, entity), b == .string(""), case .string(let target) = a, let uuid = UUID(uuidString: target),
                   let destination = entity.relationshipsByName[field(key)]?.destinationEntity?.name,
                   try !delivered(destination, uuid, in: context, isRestored: isRestored) {
                    overrides[field(key)] = local
                }
                continue
            }
            if b == base || internalFields.contains(field(key)) {
                if b == base { overrides[field(key)] = local }
                continue
            }
            conflicting.append(field(key))
        }
        // Recover a deletion iCloud made before the restore; one made after it stands.
        if entity.attributesByName["deletedAt"] != nil, local.value(forKey: "deletedAt") == nil,
           snapshot.values["deletedAt"] == .null, let deleted = remote.value(forKey: "deletedAt") as? Date,
           deleted < snapshot.restoredAt {
            overrides["deletedAt"] = local; overrides["recoveryDiscardedAt"] = local
        } else if mine["deletedAt"] != theirs["deletedAt"], theirs["deletedAt"] == snapshot.values["deletedAt"] {
            overrides["deletedAt"] = local; overrides["recoveryDiscardedAt"] = local
        }
        return (overrides, conflicting)
    }

    /// Whether iCloud has delivered a record with this UUID (a copy not from the restore).
    private static func delivered(_ entity: String, _ id: UUID, in context: NSManagedObjectContext,
                                  isRestored: (NSManagedObject) -> Bool) throws -> Bool {
        let request = NSFetchRequest<NSManagedObject>(entityName: entity)
        request.predicate = NSPredicate(format: "id == %@", id as CVarArg)
        return try context.fetch(request).contains { !isRestored($0) }
    }

    /// Event metadata copies a backup restored under a derived ID beside the metadata
    /// they were derived from, with nothing booked on them: the same record twice.
    private static func orphanEventPlans(in context: NSManagedObjectContext) throws -> [Plan] {
        let events = try context.fetch(NSFetchRequest<WorkEvent>(entityName: "WorkEvent"))
        var byDerivedID: [UUID: WorkEvent] = [:]
        for event in events {
            guard let id = event.id else { continue }
            let content = try BackupArchive.eventContent(event)
            for salt in 0..<4 { byDerivedID[BackupArchive.derivedEventID(id, content: content, salt: salt)] = event }
        }
        return try events.compactMap { orphan in
            guard let id = orphan.id, (orphan.bookings ?? []).isEmpty, let original = byDerivedID[id], original !== orphan,
                  try BackupArchive.eventContent(original) == BackupArchive.eventContent(orphan) else { return nil }
            return Plan(survivor: original, base: original, members: [original, orphan])
        }
    }

    /// Phases: values onto each survivor, relationships redirected, then the other copies deleted.
    private static func apply(_ plans: [Plan], in context: NSManagedObjectContext) -> Int {
        var canonical: [NSManagedObjectID: NSManagedObject] = [:]
        for plan in plans { for member in plan.members { canonical[member.objectID] = plan.survivor } }
        func resolve(_ object: NSManagedObject) -> NSManagedObject { canonical[object.objectID] ?? object }
        for plan in plans {
            let survivor = plan.survivor
            // Read every chosen value first: the survivor may itself be a source.
            // (`updateValue` keeps a chosen nil; assigning nil would drop the entry.)
            var chosen: [String: Any?] = [:]
            for name in survivor.entity.attributesByName.keys { chosen.updateValue(plan.base.value(forKey: name), forKey: name) }
            if plan.baseLinks {
                for (name, relationship) in survivor.entity.relationshipsByName where !relationship.isToMany {
                    chosen.updateValue((plan.base.value(forKey: name) as? NSManagedObject).map(resolve), forKey: name)
                }
            }
            for (name, source) in plan.overrides {
                if survivor.entity.attributesByName[name] != nil { chosen.updateValue(source.value(forKey: name), forKey: name) }
                else if let relationship = survivor.entity.relationshipsByName[name], !relationship.isToMany {
                    chosen.updateValue((source.value(forKey: name) as? NSManagedObject).map(resolve), forKey: name)
                }
            }
            for (name, value) in chosen { survivor.setValue(value ?? nil, forKey: name) }
        }
        let linkOwners = Set(plans.filter(\.baseLinks).map(\.survivor.objectID))
        for plan in plans {
            let survivor = plan.survivor
            for redundant in plan.members where redundant !== survivor {
                for (name, relationship) in redundant.entity.relationshipsByName {
                    let related = relationship.isToMany ? Array(redundant.value(forKey: name) as? Set<NSManagedObject> ?? [])
                        : (redundant.value(forKey: name) as? NSManagedObject).map { [$0] } ?? []
                    for target in related.map(resolve) {
                        if let inverse = relationship.inverseRelationship, !inverse.isToMany {
                            // A target whose own to-one already belongs elsewhere keeps it.
                            if let current = target.value(forKey: inverse.name) as? NSManagedObject, resolve(current) !== survivor { continue }
                            // A record whose links were decided by its merge keeps them, even when cleared.
                            if linkOwners.contains(target.objectID) { continue }
                        }
                        if relationship.isToMany { survivor.mutableSetValue(forKey: name).add(target) }
                        else if survivor.value(forKey: name) == nil, plan.overrides[name] == nil, !plan.baseLinks { survivor.setValue(target, forKey: name) }
                    }
                }
            }
        }
        var merged = 0
        for plan in plans {
            for redundant in plan.members where redundant !== plan.survivor { context.delete(redundant); merged += 1 }
        }
        return merged
    }

    /// Mutates `context` without saving; the caller saves (`reconcile` also prunes the ledger).
    static func run(in context: NSManagedObjectContext, recordName: ((NSManagedObjectID) -> String?)? = nil) throws -> Report {
        try run(in: context, recordName: recordName, cleanup: false).report
    }
    private static func run(in context: NSManagedObjectContext, recordName: ((NSManagedObjectID) -> String?)?, cleanup: Bool) throws
        -> (report: Report, matched: Set<String>) {
        guard let coordinator = context.persistentStoreCoordinator else { return (Report(), []) }
        let analysis = try analyze(in: context, recordName: recordName ?? CloudRecordNames.lookup(coordinator), cleanup: cleanup)
        let merged = apply(analysis.plans, in: context)
        return (Report(merged: merged, conflicts: Array(Set(analysis.conflicts.map(\.entity))).sorted()), analysis.matched)
    }

    /// Conflicts left after automatic merging, for review. Read-only.
    static func conflicts(in context: NSManagedObjectContext, recordName: ((NSManagedObjectID) -> String?)? = nil) throws -> [Conflict] {
        guard let coordinator = context.persistentStoreCoordinator else { return [] }
        return try analyze(in: context, recordName: recordName ?? CloudRecordNames.lookup(coordinator)).conflicts
    }

    /// Apply a person's explicit choice to one conflict, merging every copy of the
    /// record into one, and save. Fails if the copies changed since they were reviewed.
    /// The survivor is always the top-ranked copy, so two devices choosing at once
    /// never delete each other's record; at worst the later choice's values win.
    static func resolve(_ conflict: Conflict, choice: Choice, in context: NSManagedObjectContext,
                        recordName: ((NSManagedObjectID) -> String?)? = nil) throws {
        guard let coordinator = context.persistentStoreCoordinator else { return }
        let recordName = recordName ?? CloudRecordNames.lookup(coordinator)
        let analysis = try analyze(in: context, recordName: recordName)
        guard let current = analysis.conflicts.first(where: { $0.id == conflict.id }), current == conflict,
              let members = analysis.groups[conflict.id] else {
            throw RecordError.invalid("These copies changed while you were reviewing. Review them again.")
        }
        func object(_ id: NSManagedObjectID) throws -> NSManagedObject {
            guard let object = members.first(where: { $0.objectID == id }) else { throw RecordError.invalid("Choose one of the copies shown.") }
            return object
        }
        let survivor = members.min { rank(recordName)($0) < rank(recordName)($1) }!
        var plan: Plan
        switch choice {
        case .keep(let id):
            plan = Plan(survivor: survivor, base: try object(id), members: members, baseLinks: true)
        case .fields(let choices):
            guard !conflict.wholeRecord else { throw RecordError.invalid("Payment history can’t be mixed. Keep one whole copy.") }
            plan = Plan(survivor: survivor, base: try object(conflict.base ?? conflict.copies[0]), members: members, baseLinks: true)
            for (field, id) in conflict.settled { plan.overrides[field] = try object(id) }
            for (field, id) in choices { plan.overrides[field] = try object(id) }
        }
        _ = apply([plan], in: context)
        try context.save()
        try RestoreLedger.prune(coordinator, in: context, matched: Set(members.map { $0.objectID.uriRepresentation().absoluteString }))
    }

    /// Run, save and prune the ledger, including copies matched by this pass.
    @discardableResult
    static func reconcile(in context: NSManagedObjectContext, recordName: ((NSManagedObjectID) -> String?)? = nil) throws -> Report {
        let result = try run(in: context, recordName: recordName, cleanup: true)
        if context.hasChanges { try context.save() }
        if let coordinator = context.persistentStoreCoordinator { try RestoreLedger.prune(coordinator, in: context, matched: result.matched) }
        return result.report
    }
}

/// CloudKit record names for mirrored objects, looked up from any context on the
/// container's coordinator. Objects not yet exported have none.
enum CloudRecordNames {
    private static let lock = NSLock()
    nonisolated(unsafe) private static let containers = NSMapTable<NSPersistentStoreCoordinator, NSPersistentCloudKitContainer>.weakToWeakObjects()
    static func register(_ container: NSPersistentCloudKitContainer) {
        lock.withLock { containers.setObject(container, forKey: container.persistentStoreCoordinator) }
    }
    static func lookup(_ coordinator: NSPersistentStoreCoordinator) -> (NSManagedObjectID) -> String? {
        let container = lock.withLock { containers.object(forKey: coordinator) }
        return { id in container?.record(for: id)?.recordID.recordName }
    }
}
