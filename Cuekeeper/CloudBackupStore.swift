import CloudKit
import Foundation

/// Separate custom zone: Core Data sync never modifies or deletes these snapshots.
protocol CloudBacking {
    func list() async throws -> [CloudBackupStore.Entry]
    func save(data: Data, date: Date, events: Int) async throws
    func load(_ entry: CloudBackupStore.Entry) async throws -> Data
    func delete(_ entry: CloudBackupStore.Entry) async throws
}

struct CloudBackupStore: CloudBacking {
    static let zoneID = CKRecordZone.ID(zoneName: "CuekeeperBackups", ownerName: CKCurrentUserDefaultName)
    let zoneID: CKRecordZone.ID
    var indexID: CKRecord.ID { CKRecord.ID(recordName: "backup-index", zoneID: zoneID) }
    init(zoneID: CKRecordZone.ID = Self.zoneID) { self.zoneID = zoneID }
    static let maximumBackups = 50
    var database: CKDatabase { CKContainer(identifier: "iCloud.com.arjunakankipati.cuekeeper").privateCloudDatabase }

    struct Entry: Identifiable {
        let id: CKRecord.ID
        let date: Date
        let bytes: Int64
        let events: Int
    }
    private func prepare() async throws {
        guard try await CKContainer(identifier: "iCloud.com.arjunakankipati.cuekeeper").accountStatus() == .available else {
            throw RecordError.invalid("Sign in to iCloud in device Settings to use backups.")
        }
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
    }
    private func index() async throws -> CKRecord {
        do { return try await database.record(for: indexID) }
        catch let error as CKError where error.code == .unknownItem {
            let record = CKRecord(recordType: "CuekeeperBackupIndex", recordID: indexID)
            record["backupNames"] = [String]() as CKRecordValue
            return record
        }
    }
    func list() async throws -> [Entry] {
        try await prepare()
        let index = try await index()
        let ids = (index["backupNames"] as? [String] ?? []).map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        guard !ids.isEmpty else { return [] }
        let results = try await database.records(for: ids, desiredKeys: ["savedAt", "byteCount", "eventCount"])
        return try ids.map { id in
            guard let result = results[id] else { throw RecordError.invalid("Couldn’t load a backup. Refresh and try again.") }
            let record = try result.get()
            guard let date = record["savedAt"] as? Date, let bytes = record["byteCount"] as? Int64,
                  let events = record["eventCount"] as? Int64 else { throw RecordError.invalid("This backup’s details could not be read.") }
            return Entry(id: id, date: date, bytes: bytes, events: Int(events))
        }.sorted { $0.date > $1.date }
    }
    func save(data: Data, date: Date, events: Int) async throws {
        try await prepare()
        let file = FileManager.default.temporaryDirectory.appending(path: "cuekeeper-backup-\(UUID()).json")
        #if os(iOS)
        try data.write(to: file, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: file, options: .atomic)
        #endif
        defer { try? FileManager.default.removeItem(at: file) }
        let id = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
        for attempt in 0..<3 {
            let index = try await index()
            var names = index["backupNames"] as? [String] ?? []
            guard names.count < Self.maximumBackups else { throw RecordError.invalid("You have 50 backups. Delete an older backup before creating another.") }
            names.append(id.recordName); index["backupNames"] = names as CKRecordValue
            let backup = CKRecord(recordType: "CuekeeperBackup", recordID: id)
            backup["savedAt"] = date as CKRecordValue
            backup["byteCount"] = Int64(data.count) as CKRecordValue
            backup["eventCount"] = Int64(events) as CKRecordValue
            backup["payload"] = CKAsset(fileURL: file)
            do {
                try await modify(saving: [index, backup], deleting: [])
                return
            } catch {
                // A simultaneous backup on another device must not replace its index.
                if attempt == 2 || !Self.isConflict(error) { throw error }
            }
        }
    }
    func load(_ entry: Entry) async throws -> Data {
        let record = try await database.record(for: entry.id)
        guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL else {
            throw RecordError.invalid("This backup has no readable data. Choose another backup.")
        }
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 100 * 1024 * 1024 else { throw RecordError.invalid("This backup is too large to restore on this device.") }
        return try Data(contentsOf: url)
    }
    func delete(_ entry: Entry) async throws {
        for attempt in 0..<3 {
            let index = try await index()
            let names = index["backupNames"] as? [String] ?? []
            guard names.contains(entry.id.recordName) else { return }
            index["backupNames"] = names.filter { $0 != entry.id.recordName } as CKRecordValue
            do { try await modify(saving: [index], deleting: [entry.id]); return }
            catch { if attempt == 2 || !Self.isConflict(error) { throw error } }
        }
    }
    private func modify(saving: [CKRecord], deleting: [CKRecord.ID]) async throws {
        let result = try await database.modifyRecords(saving: saving, deleting: deleting, savePolicy: .ifServerRecordUnchanged, atomically: true)
        for record in saving {
            guard let saved = result.saveResults[record.recordID] else { throw RecordError.invalid("iCloud did not confirm the backup operation. Refresh before trying again.") }
            _ = try saved.get()
        }
        for id in deleting {
            guard let deleted = result.deleteResults[id] else { throw RecordError.invalid("iCloud did not confirm deletion. Refresh and try again.") }
            _ = try deleted.get()
        }
    }
    private static func isConflict(_ error: Error) -> Bool {
        guard let error = error as? CKError else { return false }
        if error.code == .serverRecordChanged { return true }
        return error.partialErrorsByItemID?.values.contains(where: isConflict) ?? false
    }
    /// Called only by the signed Development schema helper. Disposable zone;
    /// verifies real assets, concurrent index updates, download, and deletion.
    static func verifyDevelopmentBackups() async throws {
        let store = Self(zoneID: CKRecordZone.ID(zoneName: "BackupVerification-\(UUID())", ownerName: CKCurrentUserDefaultName))
        do {
            let first = Data("first backup".utf8), second = Data("second backup".utf8)
            async let a: Void = store.save(data: first, date: Date(), events: 1)
            async let b: Void = store.save(data: second, date: Date(), events: 2)
            _ = try await (a, b)
            let entries = try await store.list()
            guard entries.count == 2 else { throw RecordError.invalid("Concurrent backups were not both retained.") }
            for entry in entries {
                let data = try await store.load(entry)
                guard data == (entry.events == 1 ? first : second) else { throw RecordError.invalid("Backup download differs from its original.") }
                try await store.delete(entry)
            }
            guard try await store.list().isEmpty else { throw RecordError.invalid("Backup deletion did not complete.") }
            _ = try await store.database.deleteRecordZone(withID: store.zoneID)
        } catch {
            _ = try? await store.database.deleteRecordZone(withID: store.zoneID)
            throw error
        }
    }
    static func initializeDevelopmentSchema() async throws {
        let store = Self()
        try await store.prepare()
        // Use disposable names, never the real index or a user's backup.
        let index = CKRecord(recordType: "CuekeeperBackupIndex", recordID: CKRecord.ID(recordName: "schema-\(UUID())", zoneID: zoneID))
        index["backupNames"] = ["schema-example"] as CKRecordValue
        let backup = CKRecord(recordType: "CuekeeperBackup", recordID: CKRecord.ID(recordName: "schema-\(UUID())", zoneID: zoneID))
        let file = FileManager.default.temporaryDirectory.appending(path: "schema-\(UUID()).json")
        try Data("{}".utf8).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        backup["payload"] = CKAsset(fileURL: file)
        backup["savedAt"] = Date() as CKRecordValue
        backup["byteCount"] = Int64(2) as CKRecordValue
        backup["eventCount"] = Int64(0) as CKRecordValue
        try await store.modify(saving: [index, backup], deleting: [])
        try await store.modify(saving: [], deleting: [index.recordID, backup.recordID])
    }
}
