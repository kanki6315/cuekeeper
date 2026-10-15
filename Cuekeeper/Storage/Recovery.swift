import CoreData
import Foundation

/// Tombstones remain for calendar cleanup and financial history. Ending recovery
/// never physically deletes invoices, receipts, revisions, or their relationships.
enum Recovery {
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    static func deadline(_ record: NSManagedObject) -> Date? {
        (record.value(forKey: "deletedAt") as? Date)?.addingTimeInterval(retention)
    }

    static func canRestore(_ record: NSManagedObject, now: Date = Date()) -> Bool {
        guard record.entity.attributesByName["recoveryDiscardedAt"] != nil,
              record.value(forKey: "recoveryDiscardedAt") == nil,
              let deadline = deadline(record) else { return false }
        return deadline > now
    }

    static func restore(_ id: NSManagedObjectID, in context: NSManagedObjectContext, now: Date = Date()) throws {
        let writer = isolatedWriter(context)
        let record = try writer.existingObject(with: id)
        guard canRestore(record, now: now) else { throw RecordError.invalid("This record is no longer available in Recently Deleted.") }
        if let session = record as? WorkSession {
            guard let job = session.job, job.deletedAt == nil else {
                throw RecordError.invalid("Restore the event before restoring this session.")
            }
        }
        record.setValue(nil, forKey: "deletedAt")
        try writer.save()
        context.refreshAllObjects()
    }

    static func discard(_ id: NSManagedObjectID, in context: NSManagedObjectContext) throws {
        let writer = isolatedWriter(context)
        let record = try writer.existingObject(with: id)
        guard record.value(forKey: "deletedAt") != nil else { throw RecordError.invalid("This record has already been restored.") }
        record.setValue(Date(), forKey: "recoveryDiscardedAt")
        // A discarded event's sessions cannot later be recovered independently.
        if let job = record as? Job {
            for session in job.sessions ?? [] { session.recoveryDiscardedAt = Date() }
        }
        try writer.save()
        context.refreshAllObjects()
    }
}
