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
final class EventWizardHandoff: ObservableObject {
    struct Request: Identifiable {
        let id: UUID
        let draft: EventCreationDraft
        let notices: [String]
    }
    @Published private(set) var pending: Request?
    private var completion: CheckedContinuation<NSManagedObjectID, Error>?

    func stage(_ draft: EventCreationDraft, notices: [String] = [], id: UUID = UUID()) throws {
        guard pending == nil else { throw RecordError.invalid("Finish or discard the open Siri event draft before creating another.") }
        pending = Request(id: id, draft: draft, notices: notices)
    }

    func review(_ draft: EventCreationDraft, notices: [String] = []) async throws -> NSManagedObjectID {
        let requestID = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                do {
                    try stage(draft, notices: notices, id: requestID)
                    completion = continuation
                } catch { continuation.resume(throwing: error) }
            }
        } onCancel: {
            Task { @MainActor in self.cancel(id: requestID) }
        }
    }

    func saved(_ objectID: NSManagedObjectID, requestID: UUID) {
        guard pending?.id == requestID else { return }
        let callback = completion; completion = nil; pending = nil
        callback?.resume(returning: objectID)
    }

    func cancel(id: UUID) {
        guard pending?.id == id else { return }
        let callback = completion; completion = nil; pending = nil
        callback?.resume(throwing: CancellationError())
    }
}
