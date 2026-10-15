import CoreData
import CryptoKit
import Foundation
import ZIPFoundation

enum BackupTemporaryFiles {
    /// Call synchronously at process launch, before any backup work can begin.
    /// Never run on scene activation: a live export or upload may still own these files.
    /// Attempt every removal even if one fails; report failures so they are not silent.
    static func removeInterruptedBackups(in directory: URL = FileManager.default.temporaryDirectory) throws -> [URL] {
        let manager = FileManager.default
        let children = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let uuid = "[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}"
        let pattern = "^(?:(?:CuekeeperBackup-|CloudBackup-)\(uuid)|DownloadedBackup-\(uuid)\\.zip)$"
        var failures: [URL] = []
        for child in children where child.lastPathComponent.range(of: pattern, options: .regularExpression) != nil {
            do { try manager.removeItem(at: child) }
            catch { failures.append(child) }
        }
        return failures
    }
}

final class BackupControl: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    let report: @Sendable (String, Double?) -> Void
    init(report: @escaping @Sendable (String, Double?) -> Void = { _, _ in }) { self.report = report }
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func check() throws {
        lock.lock(); let value = cancelled; lock.unlock()
        if value { throw CancellationError() }
    }
}

struct BackupFile {
    let workspace: BackupWorkspace
    let url: URL
    let date: Date
    let events: Int
    let receipts: Int
    let bytes: Int64
}

enum BackupFiles {
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func digest(_ url: URL, control: BackupControl) throws -> String {
        let reader = try FileHandle(forReadingFrom: url); defer { try? reader.close() }
        var hash = SHA256()
        while let chunk = try reader.read(upToCount: 256 * 1024), !chunk.isEmpty {
            try control.check(); hash.update(data: chunk)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func bytes(_ url: URL) throws -> Int64 {
        // URL resource values may cache a ZIP's earlier size while entries are appended.
        let reader = try FileHandle(forReadingFrom: url); defer { try? reader.close() }
        let size = try reader.seekToEnd()
        guard size <= UInt64(Int64.max) else { throw RecordError.invalid("This backup file is too large.") }
        return Int64(size)
    }
}

extension BackupArchive {
    struct Manifest: Codable {
        let format: String
        let version: Int
        let recordsSHA256: String
        let receipts: Int
    }
    var attachments: [Attachment] {
        records.flatMap { $0.attributes.values.compactMap { if case .attachment(let a) = $0 { return a }; return nil } }
    }
    func verifyAttachments(control: BackupControl) throws {
        let files = attachments
        guard files.isEmpty || workspace != nil else { throw RecordError.invalid("The receipt files are missing.") }
        guard Set(files.map(\.path)).count == files.count else { throw RecordError.invalid("The backup repeats a receipt file.") }
        var total: Int64 = 0
        for (index, a) in files.enumerated() {
            try control.check()
            guard a.path.range(of: #"^receipts/[A-Fa-f0-9-]{36}-[A-Za-z][A-Za-z0-9]*\.jpg$"#, options: .regularExpression) != nil,
                  a.bytes > 0, a.bytes <= BackupLimits.receipt,
                  a.sha256.range(of: #"^[a-f0-9]{64}$"#, options: .regularExpression) != nil else {
                throw RecordError.invalid("The backup has an invalid receipt reference.")
            }
            total += a.bytes
            guard total <= BackupLimits.archive else { throw RecordError.invalid("This backup exceeds the 512 MB limit.") }
            let file = workspace!.url.appendingPathComponent(a.path)
            guard try BackupFiles.bytes(file) == a.bytes, try BackupFiles.digest(file, control: control) == a.sha256 else {
                throw RecordError.invalid("A receipt is missing or damaged. Nothing was restored.")
            }
            control.report("Checking receipts · \(index + 1) of \(files.count)", Double(index + 1) / Double(files.count))
        }
    }
    func writePackage(control: BackupControl = BackupControl()) throws -> BackupFile {
        try verifyAttachments(control: control)
        let files = attachments
        try BackupLimits.requireSpace(files.reduce(0) { $0 + $1.bytes } + Int64(BackupLimits.metadata))
        let output = try BackupWorkspace()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let recordsData = try encoder.encode(self)
        guard recordsData.count <= BackupLimits.metadata else { throw RecordError.invalid("Backup record details exceed the 32 MB limit.") }
        try recordsData.write(to: output.url.appendingPathComponent("records.json"))
        let manifest = Manifest(format: format, version: 2, recordsSHA256: BackupFiles.digest(recordsData), receipts: attachments.count)
        try encoder.encode(manifest).write(to: output.url.appendingPathComponent("manifest.json"))
        let file = output.url.appendingPathComponent("Cuekeeper-\(ISO8601DateFormatter().string(from: createdAt).replacingOccurrences(of: ":", with: "-" )).zip")
        let zip = try Archive(url: file, accessMode: .create)
        try zip.addEntry(with: "manifest.json", relativeTo: output.url, compressionMethod: .none)
        try zip.addEntry(with: "records.json", relativeTo: output.url, compressionMethod: .none)
        for (index, a) in files.enumerated() {
            try control.check()
            try zip.addEntry(with: a.path, fileURL: workspace!.url.appendingPathComponent(a.path), compressionMethod: .none)
            guard try BackupFiles.bytes(file) <= BackupLimits.archive else { throw RecordError.invalid("This backup exceeds the 512 MB limit.") }
            control.report("Packing receipts · \(index + 1) of \(files.count)", Double(index + 1) / Double(files.count))
        }
        try control.check()
        return BackupFile(workspace: output, url: file, date: createdAt, events: records.filter { $0.key.entity == "Job" }.count,
                          receipts: attachments.count, bytes: try BackupFiles.bytes(file))
    }

    static func readPackage(_ file: URL, model: NSManagedObjectModel, control: BackupControl = BackupControl()) throws -> Self {
        guard try BackupFiles.bytes(file) <= BackupLimits.archive else { throw RecordError.invalid("Choose a Cuekeeper backup smaller than 512 MB.") }
        let zip = try Archive(url: file, accessMode: .read)
        let entries = Array(zip)
        guard entries.count <= BackupLimits.records + 2, Set(entries.map(\.path)).count == entries.count,
              entries.allSatisfy({ $0.type == .file }), let manifestEntry = zip["manifest.json"], let recordsEntry = zip["records.json"],
              manifestEntry.uncompressedSize <= 4096, recordsEntry.uncompressedSize <= BackupLimits.metadata else {
            throw RecordError.invalid("This is not a supported Cuekeeper backup.")
        }
        let workspace = try BackupWorkspace()
        // Each extraction has both a declared-size and an actual streamed-byte bound.
        func extract(_ entry: Entry, limit: Int64) throws -> URL {
            let url = workspace.url.appendingPathComponent(entry.path)
            FileManager.default.createFile(atPath: url.path, contents: nil)
            let writer = try FileHandle(forWritingTo: url); defer { try? writer.close() }
            var bytes: Int64 = 0
            let checksum = try zip.extract(entry, bufferSize: 256 * 1024) { data in
                try control.check(); bytes += Int64(data.count)
                guard bytes <= limit else { throw RecordError.invalid("A backup file exceeds its size limit.") }
                try writer.write(contentsOf: data)
            }
            guard bytes == entry.uncompressedSize, checksum == entry.checksum else { throw RecordError.invalid("A backup file is damaged.") }
            return url
        }
        let manifestURL = try extract(manifestEntry, limit: 4096)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.format == "com.cuekeeper.backup", manifest.version == 2 else { throw RecordError.invalid("This backup format is not supported. Choose a new Cuekeeper ZIP backup.") }
        let recordsURL = try extract(recordsEntry, limit: Int64(BackupLimits.metadata))
        let recordsData = try Data(contentsOf: recordsURL)
        guard BackupFiles.digest(recordsData) == manifest.recordsSHA256 else { throw RecordError.invalid("Backup records are damaged. Nothing was restored.") }
        var archive = try JSONDecoder().decode(Self.self, from: recordsData)
        archive.workspace = workspace
        try archive.validate(model: model)
        let attachments = archive.attachments
        guard manifest.receipts == attachments.count,
              Set(entries.map(\.path)) == Set(["manifest.json", "records.json"] + attachments.map(\.path)),
              Set(attachments.map(\.path)).count == attachments.count else { throw RecordError.invalid("The backup has missing or unexpected files.") }
        // Validate untrusted lengths before summing them (including overflow attempts).
        guard attachments.allSatisfy({ $0.bytes > 0 && $0.bytes <= BackupLimits.receipt }) else {
            throw RecordError.invalid("The backup has an invalid receipt size.")
        }
        let expandedBytes = attachments.reduce(Int64(recordsData.count)) { $0 + $1.bytes }
        guard expandedBytes <= BackupLimits.archive else { throw RecordError.invalid("The expanded backup exceeds 512 MB.") }
        try BackupLimits.requireSpace(expandedBytes)
        var total: Int64 = Int64(recordsData.count)
        for (index, a) in attachments.enumerated() {
            try control.check()
            guard a.path.range(of: #"^receipts/[A-Fa-f0-9-]{36}-[A-Za-z][A-Za-z0-9]*\.jpg$"#, options: .regularExpression) != nil,
                  a.bytes > 0, a.bytes <= BackupLimits.receipt, let entry = zip[a.path], entry.uncompressedSize == a.bytes else {
                throw RecordError.invalid("The backup has an invalid receipt file.")
            }
            total += a.bytes
            guard total <= BackupLimits.archive else { throw RecordError.invalid("The expanded backup exceeds 512 MB.") }
            _ = try extract(entry, limit: a.bytes)
            control.report("Reading receipts · \(index + 1) of \(attachments.count)", Double(index + 1) / Double(attachments.count))
        }
        try archive.verifyAttachments(control: control)
        return archive
    }
}

/// Private contexts have error merge policy: a concurrent edit aborts instead of overwriting it.
enum BackupWorker {
    static func perform<T>(coordinator: NSPersistentStoreCoordinator, control: BackupControl,
                           _ work: @escaping (NSManagedObjectContext) throws -> T) async throws -> T {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.mergePolicy = NSErrorMergePolicy
        context.undoManager = nil
        return try await withTaskCancellationHandler {
            try await context.perform { defer { context.reset() }; try control.check(); return try work(context) }
        } onCancel: { control.cancel() }
    }
}
