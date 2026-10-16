import Foundation
import CoreData

struct CalendarEntry: Equatable, Sendable {
    let key: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var timeZoneID: String
    var notes: String
    var location: String
    var url: URL { URL(string: "cuekeeper://calendar/\(key)")! }
}

/// Every known record has a key, even when it is ineligible. Unknown remote events
/// are left alone while a new device is still downloading its Core Data records.
struct CalendarPlan: Sendable {
    var desired: [String: CalendarEntry] = [:]
    var knownKeys: Set<String> = []
    var bounds: [Date] = []

    init(jobs: [Job], historicalEventIDs: [UUID] = []) {
        knownKeys.formUnion(historicalEventIDs.map { "event/\($0.uuidString)" })
        for job in jobs {
            guard let id = job.id else { continue }
            let legacyKey = "job/\(id.uuidString)"
            knownKeys.insert(legacyKey)
            // Retire old grouped placeholders; every client event has its own job key.
            if let oldID = job.event?.id { knownKeys.insert("event/\(oldID.uuidString)") }
            let key = legacyKey
            var calendar = Calendar(identifier: .gregorian)
            let zone = TimeZone.effective(job.eventTimeZoneID)
            calendar.timeZone = zone
            if let start = Day.date(from: job.eventStartDay, timeZone: zone),
               let last = Day.date(from: job.eventEndDay, timeZone: zone),
               let end = calendar.date(byAdding: .day, value: 1, to: last) {
                bounds += [start, end]
                if job.deletedAt == nil && job.bookingStatus != "cancelled" {
                    desired[key] = CalendarEntry(key: key, title: job.eventTitle + (job.client.map { " · " + $0.name } ?? ""), start: start, end: end, allDay: true,
                                                 timeZoneID: zone.identifier, notes: job.event == nil ? "Cuekeeper · \(job.bookingStatus.capitalized)\n\(job.notes)" : job.eventBookings.map { "\($0.client?.name ?? "Client to add") · \($0.bookingStatus.capitalized)" }.joined(separator: "\n") + "\n" + job.eventNotes, location: job.eventLocation)
                }
            }
            for session in job.sessions ?? [] {
                guard let id = session.id else { continue }
                let key = "session/\(id.uuidString)"
                knownKeys.insert(key)
                if let start = session.startTime { bounds.append(start) }
                if let end = session.endTime { bounds.append(end) }
                if session.calendarEligible, let start = session.startTime, let end = session.endTime {
                    desired[key] = CalendarEntry(key: key, title: "\(job.displayName) · \(session.title)", start: start, end: end, allDay: false,
                                                 timeZoneID: session.eventTimeZoneID, notes: session.notes, location: job.eventLocation)
                }
            }
        }
    }
    static func key(from url: URL?) -> String? {
        guard let url, url.scheme == "cuekeeper", url.host == "calendar" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, ["job", "session", "event"].contains(parts[0]), UUID(uuidString: parts[1]) != nil else { return nil }
        return parts.joined(separator: "/")
    }
}

/// Retained by the app while its persistent store is opening.
struct CalendarLink: Identifiable {
    let id: String
    private let kind: String
    private let recordID: UUID

    init?(url: URL) {
        guard let key = CalendarPlan.key(from: url) else { return nil }
        let parts = key.split(separator: "/")
        guard let recordID = UUID(uuidString: String(parts[1])) else { return nil }
        id = key
        kind = String(parts[0])
        self.recordID = recordID
    }

    enum Destination {
        case job(Job)
        case session(WorkSession)
    }

    func resolve(in context: NSManagedObjectContext) throws -> Destination? {
        if kind == "session" {
            let request = NSFetchRequest<WorkSession>(entityName: "WorkSession")
            request.predicate = NSPredicate(format: "id == %@ AND deletedAt == nil AND job != nil AND job.deletedAt == nil", recordID as NSUUID)
            request.fetchLimit = 1
            return try context.fetch(request).first.map(Destination.session)
        }
        let request = NSFetchRequest<Job>(entityName: "Job")
        // Older grouped calendar entries refer to WorkEvent rather than Job.
        request.predicate = NSPredicate(format: kind == "event" ? "event.id == %@ AND deletedAt == nil" : "id == %@ AND deletedAt == nil", recordID as NSUUID)
        request.sortDescriptors = [NSSortDescriptor(key: "id", ascending: true)]
        request.fetchLimit = 1
        return try context.fetch(request).first.map(Destination.job)
    }
}
