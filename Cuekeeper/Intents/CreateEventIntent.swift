import AppIntents
import CoreData
import Foundation

extension BookingStatus: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Booking status" }
    static var caseDisplayRepresentations: [BookingStatus: DisplayRepresentation] {
        [.tentative: "Tentative", .booked: "Booked", .completed: "Completed", .cancelled: "Cancelled"]
    }
}

extension WorkArrangement: AppEnum {
    static var typeDisplayRepresentation: TypeDisplayRepresentation { "Work arrangement" }
    static var caseDisplayRepresentations: [WorkArrangement: DisplayRepresentation] {
        [.unspecified: "Unspecified", .remote: "Remote", .onSite: "On-site", .hybrid: "Hybrid"]
    }
}

struct CreateEventIntent: AppIntent {
    static var title: LocalizedStringResource = "Create Event"
    static var description = IntentDescription("Create one event and its first job in Cuekeeper. Dates are inclusive. Creates the basic event, then opens it in Cuekeeper for additional details.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    static let supportedModes: IntentModes = .foreground(.deferred)
    static var isDiscoverable: Bool = false
    @Dependency private var handoff: EventEditorHandoff
    @Dependency private var persistence: PersistenceController
    @Parameter(title: "Start date", kind: .date, requestValueDialog: "What date does the event start?")
    var startDate: Date
    @Parameter(title: "End date", description: "Last day, inclusive. Omit for a one-day event.", kind: .date)
    var endDate: Date?
    @Parameter(title: "Title") var eventTitle: String?
    @Parameter(title: "Client") var client: String?
    @Parameter(title: "Project") var project: String?
    @Parameter(title: "Championships") var championships: [String]?
    @Parameter(title: "Roles") var roles: [String]?
    @Parameter(title: "Booking status", default: .tentative) var bookingStatus: BookingStatus
    @Parameter(title: "Work arrangement", default: .unspecified) var workArrangement: WorkArrangement
    @Parameter(title: "Location") var location: String?
    @Parameter(title: "Event timezone", description: "An IANA timezone, such as Europe/London. Optional for an all-day event.")
    var timeZoneID: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Create an event on \(\.$startDate)") {
            \.$endDate; \.$eventTitle; \.$client; \.$project; \.$championships
            \.$roles; \.$bookingStatus; \.$workArrangement; \.$location; \.$timeZoneID
        }
    }

    func makeDraft() -> EventCreationDraft {
        var draft = EventCreationDraft()
        draft.events[0].details.name = eventTitle ?? ""
        draft.events[0].details.startDate = startDate
        draft.events[0].details.endDate = endDate ?? startDate
        draft.shared.clientName = (client ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        draft.shared.projectName = (project ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        draft.shared.seriesNames = Set((championships ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        draft.shared.roleNames = Set((roles ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        draft.shared.bookingStatus = bookingStatus
        draft.shared.workArrangement = workArrangement
        draft.shared.location = (location ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        draft.events[0].timeZoneID = (timeZoneID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return draft
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if let endDate, Day.string(from: endDate) < Day.string(from: startDate) {
            throw $endDate.needsValueError("What is the last day? It must be on or after the start date.")
        }
        let draft = makeDraft()
        if !draft.events[0].timeZoneID.isEmpty && TimeZone(identifier: draft.events[0].timeZoneID) == nil {
            throw $timeZoneID.needsValueError("Which timezone? Use a timezone such as Europe/London or America/New_York.")
        }
        try await persistence.waitUntilLoaded()
        _ = try handoff.create(draft, in: persistence.container.viewContext)
        return .result(dialog: "Created your event. Add the remaining details in Cuekeeper.")
    }
}
