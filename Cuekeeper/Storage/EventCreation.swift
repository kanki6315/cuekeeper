import CoreData
import Foundation

struct EventOutline: Identifiable, Equatable {
    var id = UUID()
    var details = JobDraft()
    var usesSharedSeries = true
    var seriesOverrideInitialized = false
    var sessions: [SessionDraft] = []
    var notes = ""
    var displayTitle: String {
        let custom = details.name.trimmingCharacters(in: .whitespacesAndNewlines)
        if !custom.isEmpty { return custom }
        let subject = [details.location, details.projectName, details.clientName].first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } ?? "Event"
        return "\(subject) · \(details.startDate.formatted(date: .abbreviated, time: .omitted))"
    }
}

/// The entire season is committed together; failures leave the editable draft intact.
struct EventCreationDraft: Equatable {
    var events = [EventOutline()]
    var shared = JobDraft()
    var payment = PaymentDraft()

    func resolvedEvents() -> [EventOutline] {
        events.map { event in
            var result = event
            result.details.clientName = shared.clientName
            result.details.projectName = shared.projectName
            if event.usesSharedSeries { result.details.seriesNames = shared.seriesNames }
            result.details.roleNames = shared.roleNames
            result.details.workArrangement = shared.workArrangement
            result.details.timeZoneID = shared.timeZoneID
            if result.details.location.isEmpty { result.details.location = shared.location; result.details.trackPlaceID = shared.trackPlaceID }
            result.details.bookingStatus = shared.bookingStatus
            result.details.fee = shared.fee
            return result
        }
    }

    @discardableResult
    func save(in context: NSManagedObjectContext) throws -> [NSManagedObjectID] {
        guard !events.isEmpty else { throw RecordError.invalid("Add at least one event.") }
        let writer = isolatedWriter(context)
        do {
            var ids: [NSManagedObjectID] = []
            for event in resolvedEvents() {
                var booking = event.details
                booking.name = ""
                let job = try booking.stage(in: writer)
                let grouped = WorkEvent(entity: NSEntityDescription.entity(forEntityName: "WorkEvent", in: writer)!, insertInto: writer)
                grouped.id = UUID(); grouped.title = event.displayTitle
                grouped.startDay = job.startDay; grouped.endDay = job.endDay
                grouped.location = job.location; grouped.trackPlaceID = job.trackPlaceID
                grouped.timeZoneID = job.timeZoneID; grouped.notes = event.notes
                job.event = grouped
                try writer.obtainPermanentIDs(for: [job, grouped])
                let id = job.objectID
                for session in event.sessions { try session.save(in: context, jobID: id, transaction: writer) }
                ids.append(id)
            }
            if events.count == 1 && !payment.amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try payment.save(in: context, jobID: ids[0], transaction: writer)
            }
            try writer.save()
            context.refreshAllObjects()
            return ids
        } catch { writer.rollback(); throw error }
    }

    mutating func copySessions(from sourceID: UUID, to targets: Set<UUID>, includingTimes: Bool) throws {
        guard let source = events.first(where: { $0.id == sourceID }) else { return }
        var updated = events
        for index in updated.indices where targets.contains(updated[index].id) && updated[index].id != sourceID {
            let destination = updated[index]
            let copies = try source.sessions.map { try $0.copied(from: source.details.startDate, to: destination.details.startDate, includingTimes: includingTimes) }
            updated[index].sessions.append(contentsOf: copies)
        }
        events = updated
    }
}

extension SessionDraft {
    /// Preserve local clock times across daylight-saving changes, rejecting nonexistent times.
    func copied(from sourceDate: Date, to destinationDate: Date, includingTimes: Bool) throws -> SessionDraft {
        var copy = self
        copy.scheduleStatus = "tentative"; copy.coverage = "undecided"
        copy.links = links.map { var link = $0; link.id = UUID(); return link }
        guard includingTimes else {
            copy.day = Day.string(from: destinationDate)
            copy.startTime = nil; copy.endTime = nil; copy.callTime = nil
            return copy
        }
        let zone = TimeZone(identifier: timeZoneID) ?? .current
        var civil = Calendar(identifier: .gregorian); civil.timeZone = TimeZone(secondsFromGMT: 0)!
        let source = Day.date(from: Day.string(from: sourceDate), timeZone: civil.timeZone)!
        let destination = Day.date(from: Day.string(from: destinationDate), timeZone: civil.timeZone)!
        let delta = civil.dateComponents([.day], from: source, to: destination).day!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        func shift(_ date: Date?) throws -> Date? {
            guard let date else { return nil }
            guard let result = calendar.date(byAdding: .day, value: delta, to: date),
                  calendar.dateComponents([.hour, .minute], from: date) == calendar.dateComponents([.hour, .minute], from: result) else {
                throw RecordError.invalid("A copied time falls in a daylight-saving clock change. Copy without times and enter it manually.")
            }
            return result
        }
        copy.startTime = try shift(startTime); copy.endTime = try shift(endTime); copy.callTime = try shift(callTime)
        if let start = copy.startTime { copy.day = Day.string(from: start, timeZone: zone) }
        else if let date = Day.date(from: day, timeZone: zone), let shifted = try shift(date) { copy.day = Day.string(from: shifted, timeZone: zone) }
        try copy.validate()
        return copy
    }
}
