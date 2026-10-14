import CoreData
import Foundation

@objc(WorkEvent)
final class WorkEvent: NSManagedObject {
    @NSManaged var id: UUID?
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
    var eventTimeZoneID: String { event?.timeZoneID ?? timeZoneID }
    var eventNotes: String { event?.notes ?? "" }
    var eventKey: NSManagedObjectID { objectID }
    var eventBookings: [Job] { [self] }
    var eventSeriesNames: [String] { seriesNames.sorted() }
    var eventSessions: [WorkSession] {
        activeSessions.sorted { ($0.day, $0.startTime ?? .distantFuture, $0.title) < ($1.day, $1.startTime ?? .distantFuture, $1.title) }
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
        // An owned metadata record uses the job UUID. This also detaches old
        // grouped records when the other clients have not yet downloaded.
        let prior = EventDraft(anchor: anchor)
        let isNew = anchor.event == nil || anchor.event?.id != anchor.id || (anchor.event?.bookings?.count ?? 0) > 1
        let event: WorkEvent
        if isNew {
            event = WorkEvent(entity: NSEntityDescription.entity(forEntityName: "WorkEvent", in: writer)!, insertInto: writer)
            event.id = anchor.id
            for (key, value) in prior.values { event.setValue(value, forKey: key) }
        } else { event = anchor.event! }
        // A concurrent promotion must not silently merge a different event.
        for (key, value) in values where baseline == nil || baseline?.values[key] != value { event.setValue(value, forKey: key) }
        guard event.startDay <= event.endDay else { throw JobDraft.ValidationError.invalidDates }
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
