import AppIntents
import CoreData
import Foundation
import GeoToolbox

@AppEntity(schema: .calendar.calendar)
struct CuekeeperCalendarEntity {
    static let defaultQuery = CuekeeperCalendarQuery()
    let id: String
    var title: String
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }
    init(id: String, title: String) { self.id = id; self.title = title }
    static var daybook: Self { Self(id: "daybook", title: "Cuekeeper") }
}

struct CuekeeperCalendarQuery: EntityStringQuery {
    func entities(for identifiers: [String]) async throws -> [CuekeeperCalendarEntity] {
        identifiers.contains("daybook") ? [.daybook] : []
    }
    func entities(matching string: String) async throws -> [CuekeeperCalendarEntity] {
        "Cuekeeper".localizedCaseInsensitiveContains(string) || "daybook".localizedCaseInsensitiveContains(string) ? [.daybook] : []
    }
    func suggestedEntities() async throws -> [CuekeeperCalendarEntity] { [.daybook] }
    func defaultResult() async -> CuekeeperCalendarEntity? { .daybook }
}

@UnionValue
enum SiriEventLocation {
    case place(PlaceDescriptor)
    case text(String)
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Event location" }
    static var caseDisplayRepresentations: [Cases: DisplayRepresentation] { [.place: "Place", .text: "Location"] }
    var textValue: String {
        switch self {
        case .text(let text): return text
        case .place(let place): return place.commonName ?? place.address ?? place.description
        }
    }
}

@UnionValue
enum SiriEventAlarm {
    case relative(Duration)
    case absolute(Date)
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Event reminder" }
    static var caseDisplayRepresentations: [Cases: DisplayRepresentation] { [.relative: "Before event", .absolute: "At a time"] }
}

@AppEnum(schema: .calendar.attendeeStatus)
enum SiriAttendeeStatus: String { case accepted, declined, tentative
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] { [.accepted: "Accepted", .declined: "Declined", .tentative: "Tentative"] }
}
@AppEnum(schema: .calendar.attendeeType)
enum SiriAttendeeType: String { case person
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] { [.person: "Person"] }
}
@AppEnum(schema: .calendar.eventStatus)
enum SiriEventStatus: String { case tentative, confirmed, cancelled
    static var caseDisplayRepresentations: [Self: DisplayRepresentation] { [.tentative: "Tentative", .confirmed: "Confirmed", .cancelled: "Cancelled"] }
}

@AppEntity(schema: .calendar.attendee)
struct SiriAttendeeEntity: TransientAppEntity {
    var person: IntentPerson
    var status: SiriAttendeeStatus?
    var isAttendanceOptional: Bool
    var type: SiriAttendeeType?
    var displayRepresentation: DisplayRepresentation { "Attendee" }
}

@AppEntity(schema: .calendar.event)
struct SiriEventEntity {
    static let defaultQuery = SiriEventQuery()
    let id: UUID
    var calendar: CuekeeperCalendarEntity
    var title: String
    var startDate: Date
    var endDate: Date
    var isAllDay: Bool
    var recurrence: Calendar.RecurrenceRule?
    var note: AttributedString?
    var travelTime: Duration?
    var location: SiriEventLocation?
    var virtualLocation: URL?
    var status: SiriEventStatus?
    var alarms: [SiriEventAlarm]
    var organizers: [IntentPerson]
    var attendees: [SiriAttendeeEntity]
    var displayRepresentation: DisplayRepresentation { DisplayRepresentation(title: "\(title)") }

    @MainActor init(event: WorkEvent) throws {
        guard let id = event.id else { throw RecordError.invalid("The saved event has no identifier.") }
        self.id = id; calendar = .daybook; title = event.title
        let zone = TimeZone(identifier: event.timeZoneID) ?? .current
        startDate = Day.date(from: event.startDay, timeZone: zone) ?? Date()
        var civil = Calendar(identifier: .gregorian); civil.timeZone = zone
        let last = Day.date(from: event.endDay, timeZone: zone) ?? startDate
        endDate = civil.date(byAdding: .day, value: 1, to: last) ?? last
        isAllDay = true; note = event.notes.isEmpty ? nil : AttributedString(event.notes)
        location = event.location.isEmpty ? nil : .text(event.location)
        alarms = []; organizers = []; attendees = []
    }
}

struct SiriEventQuery: EntityQuery {
    @Dependency private var persistence: PersistenceController
    @MainActor func entities(for identifiers: [UUID]) async throws -> [SiriEventEntity] {
        try await persistence.waitUntilLoaded()
        let request = NSFetchRequest<WorkEvent>(entityName: "WorkEvent")
        request.predicate = NSPredicate(format: "id IN %@", identifiers)
        return try persistence.container.viewContext.fetch(request).map { try SiriEventEntity(event: $0) }
    }
}

@AppIntent(schema: .calendar.createEvent)
struct CreateCalendarEventIntent {
    static let supportedModes: IntentModes = .foreground
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    @Dependency private var persistence: PersistenceController
    @Dependency private var handoff: EventWizardHandoff
    var title: String
    var startDate: Date
    var endDate: Date?
    var location: SiriEventLocation?
    var calendar: CuekeeperCalendarEntity
    var isAllDay: Bool
    var recurrence: Calendar.RecurrenceRule?
    var attendees: [SiriAttendeeEntity]
    var note: AttributedString?

    func makeDraft() throws -> EventCreationDraft {
        guard calendar.id == "daybook" else { throw RecordError.invalid("Choose the Cuekeeper calendar.") }
        return try SiriEventDraft.make(title: title, start: startDate, end: endDate, allDay: isAllDay,
                                      location: location?.textValue ?? "", notes: note.map { String($0.characters) } ?? "")
    }

    var importNotices: [String] {
        var notices: [String] = []
        if recurrence != nil { notices.append("Recurrence wasn’t imported. This draft creates one event.") }
        if !attendees.isEmpty { notices.append("Invitees weren’t imported. Cuekeeper won’t send invitations.") }
        return notices
    }

    @MainActor
    func perform() async throws -> some ReturnsValue<SiriEventEntity> {
        let draft = try makeDraft()
        try await persistence.waitUntilLoaded()
        // The schema requires a real saved event as its result. Await the wizard's
        // explicit Create action; never report an unsaved draft as a created event.
        let id = try await handoff.review(draft, notices: importNotices)
        let job = try persistence.container.viewContext.existingObject(with: id) as! Job
        guard let event = job.event else { throw RecordError.invalid("The saved event is unavailable.") }
        return .result(value: try SiriEventEntity(event: event))
    }
}
