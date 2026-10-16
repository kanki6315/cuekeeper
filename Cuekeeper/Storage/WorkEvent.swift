import CoreData
import Foundation

@objc(WorkEvent)
final class WorkEvent: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var ownerJobID: UUID?
    @NSManaged var title: String
    @NSManaged var startDay: String
    @NSManaged var endDay: String
    @NSManaged var location: String
    @NSManaged var trackPlaceID: String
    @NSManaged var timeZoneID: String
    @NSManaged var notes: String
    @NSManaged var bookings: Set<Job>?
}

extension Job {
    // Each Job is one client event. Historical shared metadata remains readable;
    // editing promotes only this job to its own metadata record.
    var eventStartDay: String { event?.startDay ?? startDay }
    var eventEndDay: String { event?.endDay ?? endDay }
    var eventLocation: String { event?.location ?? location }
    var eventTrackPlaceID: String { event?.trackPlaceID ?? trackPlaceID }
    var eventTimeZoneID: String {
        let stored = event?.timeZoneID ?? timeZoneID
        if !stored.isEmpty { return stored }
        // Recover a common timezone for older records that only stored it on sessions.
        let legacy = Set((sessions ?? []).filter { $0.deletedAt == nil }.map(\.timeZoneID).filter { !$0.isEmpty })
        return legacy.count == 1 ? legacy.first! : ""
    }
    var hasWorkTimeZone: Bool { workArrangement == "remote" || workArrangement == "hybrid" }
    var workTimeZoneID: String { hasWorkTimeZone ? timeZoneID : eventTimeZoneID }
    var eventNotes: String { event?.notes ?? "" }
    var eventKey: NSManagedObjectID { objectID }
    var eventBookings: [Job] { [self] }
    var eventSeriesNames: [String] { seriesNames.sorted() }
    var eventSessions: [WorkSession] {
        activeSessions.sorted { ($0.eventDay, $0.startTime ?? .distantFuture, $0.title) < ($1.eventDay, $1.startTime ?? .distantFuture, $1.title) }
    }
    var eventTitle: String {
        let custom = event?.title ?? name
        if !custom.isEmpty { return custom }
        let place = eventLocation.isEmpty ? "Event" : eventLocation
        return "\(place) · \(eventDateDescription)"
    }
    var eventDateDescription: String {
        guard let start = Day.date(from: eventStartDay), let end = Day.date(from: eventEndDay) else { return "Dates to come" }
        return eventStartDay == eventEndDay ? start.formatted(date: .abbreviated, time: .omitted) : "\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))"
    }
    var displayName: String {
        if !name.isEmpty { return name }
        return "\(client?.name ?? "Client to add") · \(eventTitle)"
    }
}

struct EventBookingDraft: Identifiable, Equatable {
    let id: NSManagedObjectID
    var draft: JobDraft
    let baseline: JobDraft
    var newRole = ""
    var changed: Bool { draft != baseline || !newRole.isEmpty }
    init(job: Job) {
        id = job.objectID
        draft = JobDraft(job: job)
        baseline = draft
    }
}

struct EventDraft: Equatable {
    var title = ""
    var startDate = Date()
    var endDate = Date()
    var location = ""
    var trackPlaceID = ""
    var timeZoneID = ""
    var notes = ""

    init() {}
    init(anchor: Job) {
        title = anchor.event?.title ?? anchor.name
        startDate = Day.date(from: anchor.eventStartDay) ?? Date()
        endDate = Day.date(from: anchor.eventEndDay) ?? startDate
        location = anchor.eventLocation; trackPlaceID = anchor.eventTrackPlaceID
        timeZoneID = anchor.eventTimeZoneID; notes = anchor.eventNotes
    }
    private var values: [String: String] {
        ["title": title.trimmingCharacters(in: .whitespacesAndNewlines), "startDay": Day.string(from: startDate),
         "endDay": Day.string(from: endDate), "location": location, "trackPlaceID": trackPlaceID,
         "timeZoneID": timeZoneID, "notes": notes]
    }
    @discardableResult
    func save(in context: NSManagedObjectContext, anchorID: NSManagedObjectID? = nil,
              baseline: EventDraft? = nil, firstBooking: JobDraft? = nil, bookings: [EventBookingDraft] = [], newBookings: [JobDraft] = []) throws -> NSManagedObjectID {
        guard newBookings.isEmpty, bookings.allSatisfy({ $0.id == anchorID }) else {
            throw RecordError.invalid("Each event has one client. Create a separate event for another client.")
        }
        guard startDate <= endDate || Day.string(from: startDate) == Day.string(from: endDate) else { throw JobDraft.ValidationError.invalidDates }
        guard timeZoneID.isEmpty || TimeZone(identifier: timeZoneID) != nil else { throw JobDraft.ValidationError.invalidTimeZone }
        let writer = isolatedWriter(context)
        let anchor: Job
        if let anchorID { anchor = try writer.existingObject(with: anchorID) as! Job }
        else {
            guard var booking = firstBooking, !booking.clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw RecordError.invalid("Choose a client for the first booking.")
            }
            booking.startDate = startDate; booking.endDate = endDate
            anchor = try booking.stage(in: writer)
        }
        guard anchor.deletedAt == nil else { throw RecordError.invalid("This event has been deleted.") }
        // Ownership is separate from record identity so independent offline
        // promotions get distinct UUIDs. Older owned records used the job UUID;
        // keep recognizing them without mistaking a partly downloaded legacy
        // group for an owned record.
        let prior = EventDraft(anchor: anchor)
        let owner = anchor.event.flatMap { $0.ownerJobID ?? $0.id }
        let isNew = anchor.event == nil || owner != anchor.id || (anchor.event?.bookings?.count ?? 0) > 1
        let event: WorkEvent
        if isNew {
            event = WorkEvent(entity: NSEntityDescription.entity(forEntityName: "WorkEvent", in: writer)!, insertInto: writer)
            event.id = UUID()
            event.ownerJobID = anchor.id
            for (key, value) in prior.values { event.setValue(value, forKey: key) }
        } else {
            event = anchor.event!
            event.ownerJobID = anchor.id
        }
        // A concurrent promotion must not silently merge a different event.
        for (key, value) in values where baseline == nil || baseline?.values[key] != value { event.setValue(value, forKey: key) }
        guard event.startDay <= event.endDay else { throw JobDraft.ValidationError.invalidDates }
        // Zones only come from places now: never clear a valid zone, and give a zoneless event the home zone.
        if TimeZone(identifier: event.timeZoneID) == nil {
            event.timeZoneID = TimeZone(identifier: prior.timeZoneID) == nil ? TimeZone.home.identifier : prior.timeZoneID
        }
        anchor.event = event
        for entry in bookings where entry.changed {
            let existing = try writer.existingObject(with: entry.id) as! Job
            guard existing.event == event else { throw RecordError.invalid("This booking is no longer part of this event. Reopen the editor to review it.") }
            guard !entry.draft.clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RecordError.invalid("Choose a client for each booking.") }
            var updated = entry.draft
            let role = entry.newRole.trimmingCharacters(in: .whitespacesAndNewlines)
            if !role.isEmpty { updated.roleNames.insert(role) }
            _ = try updated.stage(in: writer, editing: entry.id, baseline: entry.baseline)
        }
        if prior.timeZoneID != event.timeZoneID {
            let timed = anchor.activeSessions.filter { $0.startTime != nil || $0.endTime != nil || $0.callTime != nil }
            guard timed.isEmpty || TimeZone(identifier: event.timeZoneID) != nil else {
                throw RecordError.invalid("Choose an event timezone while sessions have times.")
            }
            for session in anchor.activeSessions {
                session.timeZoneID = event.timeZoneID
                if let start = session.startTime, let zone = TimeZone(identifier: event.timeZoneID) {
                    session.day = Day.string(from: start, timeZone: zone)
                }
            }
        }
        try writer.save(); context.refreshAllObjects()
        return anchor.objectID
    }

    /// Attach an existing booking without replacing IDs, sessions or financial revisions.
    static func attach(_ bookingID: NSManagedObjectID, to anchorID: NSManagedObjectID, in context: NSManagedObjectContext) throws {
        throw RecordError.invalid("Events cannot be linked. Keep each client in a separate event.")
    }
}

extension JobDraft {
    @discardableResult
    func saveBooking(in context: NSManagedObjectContext, anchorID: NSManagedObjectID,
                     editing: NSManagedObjectID? = nil, baseline: JobDraft? = nil) throws -> NSManagedObjectID {
        guard editing == anchorID else { throw RecordError.invalid("Each event has one client. Create a separate event for another client.") }
        guard !clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RecordError.invalid("Choose a client.") }
        return try save(in: context, editing: anchorID, baseline: baseline)
    }
}
