import CloudKit
import Foundation

enum BackupLimits {
    static let archive: Int64 = 512 * 1024 * 1024
    static let metadata = 32 * 1024 * 1024
    static let receipt = 12 * 1024 * 1024
    static let records = 200_000
    static let cloudPart = 16 * 1024 * 1024
    static func requireSpace(_ bytes: Int64, at url: URL = FileManager.default.temporaryDirectory) throws {
        let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        if let available = values.volumeAvailableCapacityForImportantUsage, available < bytes + 16 * 1024 * 1024 {
            throw RecordError.invalid("Not enough free device storage for this backup. Free some space and try again.")
        }
    }
}

/// Separate custom zone: Core Data sync never modifies or deletes these snapshots.
protocol CloudBacking {
    func list() async throws -> [CloudBackupStore.Entry]
    /// Newest restorable backup, or nil when there are none.
    func latestDate() async throws -> Date?
    func save(file: URL, date: Date, events: Int) async throws
    func load(_ entry: CloudBackupStore.Entry) async throws -> URL
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
        let date: Date?
        let bytes: Int64?
        let events: Int?
        var issue: String? = nil
        var canRestore: Bool { issue == nil }
        var title: String { date?.formatted(date: .abbreviated, time: .shortened) ?? "Unavailable backup" }
        var details: String {
            if let issue { return issue }
            guard let events, let bytes else { return "Backup details unavailable." }
            return "\(counted(events, "event", "events")) · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))"
        }
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
        return Self.entries(ids: ids, results: results)
    }
    /// Read-only: unlike `list()`, never creates the backup zone.
    func latestDate() async throws -> Date? {
        let index: CKRecord
        do { index = try await database.record(for: indexID) }
        catch let error as CKError where error.code == .unknownItem || error.code == .zoneNotFound { return nil }
        let ids = (index["backupNames"] as? [String] ?? []).map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        guard !ids.isEmpty else { return nil }
        let results = try await database.records(for: ids, desiredKeys: ["savedAt", "byteCount", "eventCount"])
        return Self.entries(ids: ids, results: results).filter(\.canRestore).compactMap(\.date).max()
    }
    static func entries(ids: [CKRecord.ID], results: [CKRecord.ID: Result<CKRecord, Error>]) -> [Entry] {
        ids.map { id in
            guard let result = results[id], case .success(let record) = result else {
                return Entry(id: id, date: nil, bytes: nil, events: nil,
                             issue: "Couldn’t load this backup. Refresh to retry, or delete it.")
            }
            let date = record["savedAt"] as? Date
            let bytes = record["byteCount"] as? Int64
            let events = (record["eventCount"] as? Int64).flatMap { Int(exactly: $0) }
            guard let date, let bytes, bytes > 0, bytes <= BackupLimits.archive,
                  let events, events >= 0 else {
                return Entry(id: id, date: date, bytes: nil, events: nil,
                             issue: "This backup’s details could not be read. You can delete it.")
            }
            return Entry(id: id, date: date, bytes: bytes, events: events)
        }.sorted {
            if $0.date != $1.date { return ($0.date ?? .distantPast) > ($1.date ?? .distantPast) }
            return $0.id.recordName < $1.id.recordName
        }
    }
    private struct CloudManifest: Codable {
        var format = "com.cuekeeper.cloud-backup"
        var version = 2
        let parts: Int
        let bytes: Int64
    }
    private func partID(_ root: CKRecord.ID, _ index: Int) -> CKRecord.ID {
        CKRecord.ID(recordName: "\(root.recordName)-part-\(index)", zoneID: zoneID)
    }
    func save(file: URL, date: Date, events: Int) async throws {
        try await prepare()
        let bytes = Int64(try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0)
        guard bytes > 0, bytes <= BackupLimits.archive else { throw RecordError.invalid("This backup exceeds the 512 MB limit.") }
        try BackupLimits.requireSpace(bytes)
        let workspace = try BackupWorkspace()
        let folder = workspace.url
        // Keep CKAsset source files alive until CloudKit has finished with them.
        defer { withExtendedLifetime(workspace) {} }
        let id = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
        let count = Int((bytes + Int64(BackupLimits.cloudPart) - 1) / Int64(BackupLimits.cloudPart))
        let reader = try FileHandle(forReadingFrom: file); defer { try? reader.close() }
        var pieces: [CKRecord] = []
        // File IO stays off the UI actor through this nonisolated async implementation.
        for i in 0..<count {
            try Task.checkCancellation()
            let data = try reader.read(upToCount: BackupLimits.cloudPart) ?? Data()
            guard !data.isEmpty else { throw RecordError.invalid("The prepared backup is incomplete.") }
            let url = folder.appendingPathComponent("part-\(i)")
            try data.write(to: url)
            let part = CKRecord(recordType: "CuekeeperBackup", recordID: partID(id, i))
            part["payload"] = CKAsset(fileURL: url)
            pieces.append(part)
        }
        let manifestURL = folder.appendingPathComponent("manifest.json")
        try JSONEncoder().encode(CloudManifest(parts: count, bytes: bytes)).write(to: manifestURL)
        for attempt in 0..<3 {
            try Task.checkCancellation()
            let index = try await index()
            var names = index["backupNames"] as? [String] ?? []
            guard names.count < Self.maximumBackups else { throw RecordError.invalid("You have 50 backups. Delete an older backup before creating another.") }
            names.append(id.recordName); index["backupNames"] = names as CKRecordValue
            let backup = CKRecord(recordType: "CuekeeperBackup", recordID: id)
            backup["savedAt"] = date as CKRecordValue
            backup["byteCount"] = bytes as CKRecordValue
            backup["eventCount"] = Int64(events) as CKRecordValue
            backup["payload"] = CKAsset(fileURL: manifestURL)
            do {
                // Parts and catalog entry commit together: incomplete uploads are never listed.
                try await modify(saving: [index, backup] + pieces, deleting: [])
                return
            } catch {
                if attempt == 2 || !Self.isConflict(error) { throw error }
            }
        }
    }
    private func manifest(_ entry: Entry) async throws -> CloudManifest {
        let record = try await database.record(for: entry.id)
        guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL,
              (try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) <= 4096 else {
            throw RecordError.invalid("This backup has no readable catalog.")
        }
        let value = try JSONDecoder().decode(CloudManifest.self, from: Data(contentsOf: url))
        guard value.format == "com.cuekeeper.cloud-backup", value.version == 2,
              value.bytes > 0, value.bytes <= BackupLimits.archive, value.bytes == entry.bytes,
              value.parts == Int((value.bytes + Int64(BackupLimits.cloudPart) - 1) / Int64(BackupLimits.cloudPart)) else {
            throw RecordError.invalid("This backup catalog is invalid.")
        }
        return value
    }
    /// Caller owns the returned temporary file and must remove it after use.
    func load(_ entry: Entry) async throws -> URL {
        guard entry.canRestore else { throw RecordError.invalid("Refresh this backup’s details before restoring it.") }
        let value = try await manifest(entry)
        try BackupLimits.requireSpace(value.bytes)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("DownloadedBackup-\(UUID()).zip")
        guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                             attributes: BackupWorkspace.protectionAttributes) else {
            throw RecordError.invalid("Couldn’t create the temporary backup download.")
        }
        var success = false
        defer { if !success { try? FileManager.default.removeItem(at: file) } }
        let writer = try FileHandle(forWritingTo: file); defer { try? writer.close() }
        var total: Int64 = 0
        for i in 0..<value.parts {
            try Task.checkCancellation()
            let record = try await database.record(for: partID(entry.id, i))
            guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL,
                  Int64(try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) == min(Int64(BackupLimits.cloudPart), value.bytes - total) else {
                throw RecordError.invalid("A backup part is missing or damaged. Nothing was restored.")
            }
            let reader = try FileHandle(forReadingFrom: url); defer { try? reader.close() }
            while let data = try reader.read(upToCount: 256 * 1024), !data.isEmpty {
                try Task.checkCancellation(); total += Int64(data.count)
                guard total <= value.bytes else { throw RecordError.invalid("A backup part is too large.") }
                try writer.write(contentsOf: data)
            }
        }
        guard total == value.bytes else { throw RecordError.invalid("The backup download is incomplete.") }
        success = true
        return file
    }
    func delete(_ entry: Entry) async throws {
        try await prepare()
        // Part names are deterministic and bounded by the archive limit. Discover
        // existing records without downloading or trusting a damaged manifest.
        let candidates = deletionCandidates(entry.id)
        let results = try await database.records(for: candidates, desiredKeys: [])
        let ids = try Self.existingDeletionIDs(candidates, results: results)
        for attempt in 0..<3 {
            let index = try await index()
            let names = index["backupNames"] as? [String] ?? []
            guard names.contains(entry.id.recordName) else { return }
            index["backupNames"] = names.filter { $0 != entry.id.recordName } as CKRecordValue
            do { try await modify(saving: [index], deleting: ids); return }
            catch { if attempt == 2 || !Self.isConflict(error) { throw error } }
        }
    }
    func deletionCandidates(_ root: CKRecord.ID) -> [CKRecord.ID] {
        let maximumParts = Int((BackupLimits.archive + Int64(BackupLimits.cloudPart) - 1) / Int64(BackupLimits.cloudPart))
        return [root] + (0..<maximumParts).map { partID(root, $0) }
    }
    static func existingDeletionIDs(_ ids: [CKRecord.ID], results: [CKRecord.ID: Result<CKRecord, Error>]) throws -> [CKRecord.ID] {
        try ids.compactMap { id in
            guard let result = results[id] else { throw RecordError.invalid("Couldn’t check this backup. Refresh and try again.") }
            switch result {
            case .success: return id
            case .failure(let error):
                if let error = error as? CKError, error.code == .unknownItem { return nil }
                // Transient failures must not remove the index and orphan assets.
                throw error
            }
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
            let first = Data(repeating: 73, count: BackupLimits.cloudPart + 1024), second = Data("second backup".utf8)
            let firstURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).zip")
            let secondURL = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).zip")
            try first.write(to: firstURL); try second.write(to: secondURL)
            defer { try? FileManager.default.removeItem(at: firstURL); try? FileManager.default.removeItem(at: secondURL) }
            async let a: Void = store.save(file: firstURL, date: Date(), events: 1)
            async let b: Void = store.save(file: secondURL, date: Date(), events: 2)
            _ = try await (a, b)
            let entries = try await store.list()
            guard entries.count == 2 else { throw RecordError.invalid("Concurrent backups were not both retained.") }
            for entry in entries {
                let url = try await store.load(entry)
                defer { try? FileManager.default.removeItem(at: url) }
                let data = try Data(contentsOf: url)
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
