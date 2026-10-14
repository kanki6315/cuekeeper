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
    // Legacy jobs remain virtual single-booking events until explicitly edited/grouped.
    // No startup backfill: simultaneous iCloud upgrades cannot create duplicate events.
    var eventStartDay: String { event?.startDay ?? startDay }
    var eventEndDay: String { event?.endDay ?? endDay }
    var eventLocation: String { event?.location ?? location }
    var eventTrackPlaceID: String { event?.trackPlaceID ?? trackPlaceID }
    var eventTimeZoneID: String { event?.timeZoneID ?? timeZoneID }
    var eventNotes: String { event?.notes ?? "" }
    var eventKey: NSManagedObjectID { event?.objectID ?? objectID }
    var eventBookings: [Job] {
        (event.map { Array($0.bookings ?? []) } ?? [self]).sorted {
            ($0.client?.name ?? "", $0.id?.uuidString ?? "") < ($1.client?.name ?? "", $1.id?.uuidString ?? "")
        }
    }
    var eventSessions: [WorkSession] {
        eventBookings.flatMap(\.activeSessions).sorted { ($0.day, $0.startTime ?? .distantFuture, $0.title) < ($1.day, $1.startTime ?? .distantFuture, $1.title) }
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
              baseline: EventDraft? = nil, firstBooking: JobDraft? = nil) throws -> NSManagedObjectID {
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
        let event = anchor.event ?? WorkEvent(entity: NSEntityDescription.entity(forEntityName: "WorkEvent", in: writer)!, insertInto: writer)
        let isNew = event.id == nil
        if isNew { event.id = UUID() }
        // A concurrent promotion must not silently merge a different event.
        for (key, value) in values where isNew || baseline?.values[key] != value { event.setValue(value, forKey: key) }
        guard event.startDay <= event.endDay else { throw JobDraft.ValidationError.invalidDates }
        anchor.event = event
        try writer.save(); context.refreshAllObjects()
        return anchor.objectID
    }

    /// Attach an existing booking without replacing IDs, sessions or financial revisions.
    static func attach(_ bookingID: NSManagedObjectID, to anchorID: NSManagedObjectID, in context: NSManagedObjectContext) throws {
        let writer = isolatedWriter(context)
        let anchor = try writer.existingObject(with: anchorID) as! Job
        let booking = try writer.existingObject(with: bookingID) as! Job
        guard anchor != booking, booking.event == nil else { throw RecordError.invalid("This booking is already part of an event.") }
        let event: WorkEvent
        if let existing = anchor.event { event = existing }
        else {
            event = WorkEvent(entity: NSEntityDescription.entity(forEntityName: "WorkEvent", in: writer)!, insertInto: writer); event.id = UUID()
            for (key, value) in EventDraft(anchor: anchor).values { event.setValue(value, forKey: key) }
            anchor.event = event
        }
        booking.event = event
        try writer.save(); context.refreshAllObjects()
    }
}

extension JobDraft {
    @discardableResult
    func saveBooking(in context: NSManagedObjectContext, anchorID: NSManagedObjectID,
                     editing: NSManagedObjectID? = nil, baseline: JobDraft? = nil) throws -> NSManagedObjectID {
        guard !clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RecordError.invalid("Choose a client.") }
        let writer = isolatedWriter(context)
        let anchor = try writer.existingObject(with: anchorID) as! Job
        let booking = try stage(in: writer, editing: editing, baseline: baseline)
        if editing == nil {
            if anchor.event == nil {
                let event = WorkEvent(entity: NSEntityDescription.entity(forEntityName: "WorkEvent", in: writer)!, insertInto: writer); event.id = UUID()
                event.title = anchor.name; event.startDay = anchor.startDay; event.endDay = anchor.endDay
                event.location = anchor.location; event.trackPlaceID = anchor.trackPlaceID
                event.timeZoneID = anchor.timeZoneID; event.notes = ""
                anchor.event = event
            }
            booking.event = anchor.event
        }
        try writer.save(); context.refreshAllObjects()
        return booking.objectID
    }
}
