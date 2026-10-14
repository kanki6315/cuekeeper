import Combine
import CoreData
import Foundation

struct SiriEventDraft {
    static func make(title: String, start: Date, end: Date?, allDay: Bool,
                     location: String = "", notes: String = "", timeZone: TimeZone = .current) throws -> EventCreationDraft {
        if let end, end < start || (!allDay && end == start) {
            throw RecordError.invalid("The event end must follow its start.")
        }
        var civil = Calendar(identifier: .gregorian); civil.timeZone = timeZone
        var last = end ?? start
        // Calendar all-day ranges use an exclusive midnight end; the wizard uses inclusive days.
        if allDay, let end, end > start, end == civil.startOfDay(for: end) {
            last = civil.date(byAdding: .day, value: -1, to: end) ?? end
        }
        var draft = EventCreationDraft()
        draft.events[0].details.name = title
        draft.events[0].details.startDate = Day.date(from: Day.string(from: start, timeZone: timeZone))!
        draft.events[0].details.endDate = Day.date(from: Day.string(from: last, timeZone: timeZone))!
        draft.events[0].notes = notes
        draft.shared.location = location
        draft.shared.timeZoneID = timeZone.identifier
        if !allDay {
            var session = SessionDraft(day: Day.string(from: start, timeZone: timeZone), timeZoneID: timeZone.identifier)
            session.name = title; session.startTime = start; session.endTime = end
            draft.events[0].sessions = [session]
        }
        return draft
    }
}

@MainActor
final class EventEditorHandoff: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let jobID: NSManagedObjectID
        let notices: [String]
    }
    @Published private(set) var pending: Request?

    /// Save exactly once before routing. The editor receives only a permanent ID,
    /// never a creation draft or a continuation tied to Siri's execution lifetime.
    func create(_ draft: EventCreationDraft, in context: NSManagedObjectContext, notices: [String] = []) throws -> NSManagedObjectID {
        guard pending == nil else { throw RecordError.invalid("Close the current event before creating another with Siri.") }
        guard draft.events.count == 1 else { throw RecordError.invalid("Create one event at a time with Siri.") }
        try Task.checkCancellation()
        let ids = try draft.save(in: context)
        let id = ids[0]
        pending = Request(jobID: id, notices: notices)
        return id
    }

    func close(id: UUID) {
        guard pending?.id == id else { return }
        pending = nil
    }
}
