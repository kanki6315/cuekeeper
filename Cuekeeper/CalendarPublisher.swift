import CloudKit
import Foundation

/// A single CloudKit record serializes opt-in across devices. No offline claims:
/// calendar publishing waits for the server instead of guessing ownership.
protocol CalendarPublishing {
    func claim(deviceID: String, name: String) async throws
    func verify(deviceID: String) async throws
    func release(deviceID: String) async throws
}

struct CalendarPublisher: CalendarPublishing {
    static let recordType = "CuekeeperCalendarPublisher"
    static let recordID = CKRecord.ID(recordName: "calendar-publisher")
    var database: CKDatabase { CKContainer(identifier: "iCloud.com.arjunakankipati.cuekeeper").privateCloudDatabase }
    let identity: CKRecord.ID
    init(recordID: CKRecord.ID = CalendarPublisher.recordID) {
        identity = recordID
    }

    func record() async throws -> CKRecord {
        do { return try await database.record(for: identity) }
        catch let error as CKError where error.code == .unknownItem {
            return CKRecord(recordType: Self.recordType, recordID: identity)
        }
    }
    func claim(deviceID: String, name: String) async throws {
        let record = try await record()
        let owner = record["ownerID"] as? String ?? ""
        guard owner.isEmpty || owner == deviceID else {
            throw RecordError.invalid("Calendar is managed by \(record["ownerName"] as? String ?? "another device"). Disconnect Calendar there before connecting this device.")
        }
        record["ownerID"] = deviceID as CKRecordValue
        record["ownerName"] = name as CKRecordValue
        try await save(record)
    }
    func verify(deviceID: String) async throws {
        let record = try await record()
        guard record["ownerID"] as? String == deviceID else {
            throw RecordError.invalid("This device is not the calendar manager. Connect it in Calendar settings, or open Cuekeeper on the device managing your calendar.")
        }
    }
    func release(deviceID: String) async throws {
        let record = try await record()
        guard record["ownerID"] as? String == deviceID else { return }
        record["ownerID"] = "" as CKRecordValue; record["ownerName"] = "" as CKRecordValue
        try await save(record)
    }
    private func save(_ record: CKRecord) async throws {
        let results = try await database.modifyRecords(saving: [record], deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
        _ = try results.saveResults[record.recordID]?.get()
    }
    static func verifyDevelopmentCoordination() async throws {
        let publisher = CalendarPublisher(recordID: CKRecord.ID(recordName: "setup-verification-\(UUID())"))
        do {
            func attempt(_ id: String) async -> Bool {
                do { try await publisher.claim(deviceID: id, name: "Schema test"); return true }
                catch { return false }
            }
            async let first = attempt("first")
            async let competing = attempt("competing")
            let wins = await (first, competing)
            guard wins.0 != wins.1 else { throw RecordError.invalid("Exactly one concurrent calendar claim must succeed.") }
            let winner = wins.0 ? "first" : "competing"
            try await publisher.verify(deviceID: winner)
            var refused = false
            do { try await publisher.claim(deviceID: "second", name: "Second test") }
            catch is RecordError { refused = true }
            guard refused else { throw RecordError.invalid("A second calendar publisher was incorrectly accepted.") }
            try await publisher.release(deviceID: winner)
            try await publisher.claim(deviceID: "second", name: "Second test")
            try await publisher.verify(deviceID: "second")
            _ = try await publisher.database.deleteRecord(withID: publisher.identity)
        } catch {
            _ = try? await publisher.database.deleteRecord(withID: publisher.identity)
            throw error
        }
    }
    /// Representative record used only by the Development-only signed helper.
    static func initializeDevelopmentSchema() async throws {
        let database = CalendarPublisher().database
        let record = CKRecord(recordType: recordType)
        record["ownerID"] = "schema-example" as CKRecordValue
        record["ownerName"] = "Schema setup" as CKRecordValue
        let saved = try await database.save(record)
        _ = try await database.deleteRecord(withID: saved.recordID)
    }
}
