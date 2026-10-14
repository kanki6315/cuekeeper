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
    static var description = IntentDescription("Create one event and its first job in Cuekeeper. Dates are inclusive. Confirm the details before saving; add sessions and financial details in Cuekeeper afterward.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

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
    @Parameter(title: "Timezone", description: "An IANA timezone, such as Europe/London. Optional for an all-day event.")
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
        draft.shared.timeZoneID = (timeZoneID ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return draft
    }

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        if let endDate, Day.string(from: endDate) < Day.string(from: startDate) {
            throw $endDate.needsValueError("What is the last day? It must be on or after the start date.")
        }
        var draft = makeDraft()
        if !draft.shared.timeZoneID.isEmpty && TimeZone(identifier: draft.shared.timeZoneID) == nil {
            throw $timeZoneID.needsValueError("Which timezone? Use a timezone such as Europe/London or America/New_York.")
        }
        try await persistence.waitUntilLoaded()
        let context = persistence.container.viewContext
        let request = NSFetchRequest<Client>(entityName: "Client")
        request.predicate = NSPredicate(format: "name ==[cd] %@", draft.shared.clientName)
        if let client = try context.fetch(request).first { draft.shared.fee?.currency = client.defaultCurrency }
        let title = draft.resolvedEvents()[0].displayTitle
        try await draft.confirmAndSave(in: context) { summary in
            // Empty conditions means confirmation is always requested, not only for low-confidence input.
            try await requestConfirmation(dialog: IntentDialog("Create this event? \(summary)"))
        }
        return .result(dialog: "Created \(title) in Cuekeeper.")
    }
}

struct CuekeeperShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: CreateEventIntent(), phrases: [
            "Create an event in \(.applicationName)",
            "Add an event in \(.applicationName)",
            "Create a booking in \(.applicationName)",
            "Create a new \(.applicationName) event",
            "Create a \(.applicationName) event",
            "Add a new event in \(.applicationName)"
        ], shortTitle: "Create Event", systemImageName: "calendar.badge.plus")
    }
}

extension EventCreationDraft {
    var creationSummary: String {
        let event = resolvedEvents()[0]
        var parts = [event.displayTitle,
                     "Start: \(event.details.startDate.formatted(date: .complete, time: .omitted))",
                     "End: \(event.details.endDate.formatted(date: .complete, time: .omitted))",
                     "Booking: \(shared.bookingStatus.title)"]
        for (label, value) in [("Client", shared.clientName), ("Project", shared.projectName),
                               ("Championships", shared.seriesNames.sorted().joined(separator: ", ")),
                               ("Roles", shared.roleNames.sorted().joined(separator: ", ")),
                               ("Location", shared.location), ("Timezone", shared.timeZoneID)] where !value.isEmpty {
            parts.append("\(label): \(value)")
        }
        if shared.workArrangement != .unspecified { parts.append("Work: \(shared.workArrangement.title)") }
        return parts.joined(separator: ". ")
    }

    @MainActor
    func confirmAndSave(in context: NSManagedObjectContext, confirm: (String) async throws -> Void) async throws {
        guard events.count == 1 else { throw RecordError.invalid("Create one event at a time with Siri.") }
        try await confirm(creationSummary)
        try Task.checkCancellation()
        try save(in: context)
    }
}
