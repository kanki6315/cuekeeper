import CoreData
import Foundation

struct EventOutline: Identifiable, Equatable {
    var id = UUID()
    var details = JobDraft()
    /// Sessions keep their wall-clock times when the place changes the zone.
    var timeZoneID = TimeZone.home.identifier {
        didSet {
            guard oldValue != timeZoneID else { return }
            sessions = sessions.map { $0.rezoned(from: oldValue, to: timeZoneID) }
        }
    }
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
    var shared: JobDraft = {
        var draft = JobDraft()
        let home = UserDefaults.standard.string(forKey: "homeTimeZone") ?? TimeZone.current.identifier
        draft.timeZoneID = TimeZone(identifier: home) == nil ? "" : home
        return draft
    }()
    var payment = PaymentDraft()

    func resolvedEvents() -> [EventOutline] {
        events.map { event in
            var result = event
            result.details.clientName = shared.clientName
            result.details.projectName = shared.projectName
            if event.usesSharedSeries { result.details.seriesNames = shared.seriesNames }
            result.details.roleNames = shared.roleNames
            result.details.workArrangement = shared.workArrangement
            // An event without a zone uses the home zone, and saving persists it.
            let zone = TimeZone.effective(event.timeZoneID)
            result.timeZoneID = zone.identifier
            result.details.timeZoneID = shared.worksRemotely ? shared.timeZoneID : zone.identifier
            result.sessions = event.sessions.map { session in
                var value = session; value.timeZoneID = zone.identifier
                if let start = value.startTime { value.day = Day.string(from: start, timeZone: zone) }
                return value
            }
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
                guard event.timeZoneID.isEmpty || TimeZone(identifier: event.timeZoneID) != nil else { throw JobDraft.ValidationError.invalidTimeZone }
                var booking = event.details
                booking.name = ""
                // The venue belongs to the event; remote and hybrid bookings keep where the user works.
                if shared.worksRemotely {
                    booking.location = shared.location; booking.trackPlaceID = ""
                }
                let job = try booking.stage(in: writer)
                let grouped = WorkEvent(entity: NSEntityDescription.entity(forEntityName: "WorkEvent", in: writer)!, insertInto: writer)
                grouped.id = UUID(); grouped.ownerJobID = job.id
                grouped.title = event.displayTitle
                grouped.startDay = job.startDay; grouped.endDay = job.endDay
                grouped.location = event.details.location.trimmingCharacters(in: .whitespacesAndNewlines)
                grouped.trackPlaceID = event.details.trackPlaceID
                grouped.timeZoneID = event.timeZoneID; grouped.notes = event.notes
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
        guard let source = resolvedEvents().first(where: { $0.id == sourceID }) else { return }
        var updated = events
        for index in updated.indices where targets.contains(updated[index].id) && updated[index].id != sourceID {
            let destination = updated[index]
            let copies = try source.sessions.map { try $0.copied(from: source.details.startDate, to: destination.details.startDate, includingTimes: includingTimes, destinationTimeZoneID: destination.timeZoneID) }
            updated[index].sessions.append(contentsOf: copies.map { session in
                var value = session; value.timeZoneID = destination.timeZoneID
                if let start = value.startTime, let zone = TimeZone(identifier: destination.timeZoneID) { value.day = Day.string(from: start, timeZone: zone) }
                return value
            })
        }
        events = updated
    }
}

/// Zones follow the most recently chosen place. Lookups can finish out of order,
/// so a result applies only if no newer choice or edit happened since it began.
struct PlaceSelection: Equatable {
    private(set) var revision = 0
    private(set) var pending = false
    private(set) var failed = false

    mutating func begin() -> Int { revision += 1; pending = true; failed = false; return revision }
    mutating func cancel() { revision += 1; pending = false; failed = false }
    /// Returns the zone to apply, or nil when the result is stale or missing.
    mutating func finish(_ token: Int, zone: TimeZone?) -> TimeZone? {
        guard token == revision else { return nil }
        pending = false; failed = zone == nil
        return zone
    }
}

extension SessionDraft {
    /// Preserve local clock times across daylight-saving changes, rejecting nonexistent times.
    func copied(from sourceDate: Date, to destinationDate: Date, includingTimes: Bool, destinationTimeZoneID: String? = nil) throws -> SessionDraft {
        var copy = self
        copy.id = UUID()
        copy.scheduleStatus = "tentative"; copy.coverage = "undecided"
        guard includingTimes else {
            copy.day = Day.string(from: destinationDate)
            copy.startTime = nil; copy.endTime = nil; copy.callTime = nil
            return copy
        }
        try validate()
        let zone = TimeZone.effective(timeZoneID)
        let delta = Day.days(from: Day.string(from: sourceDate), to: Day.string(from: destinationDate))!
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
        else if let shifted = Day.adding(days: delta, to: day) { copy.day = shifted }
        if let destinationTimeZoneID, destinationTimeZoneID != timeZoneID {
            guard let targetZone = TimeZone(identifier: destinationTimeZoneID) else {
                throw RecordError.invalid("Choose the destination event timezone before copying times.")
            }
            var target = Calendar(identifier: .gregorian); target.timeZone = targetZone
            func convert(_ date: Date?) throws -> Date? {
                guard let date else { return nil }
                let components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
                guard let result = target.date(from: components),
                      target.dateComponents([.year, .month, .day, .hour, .minute, .second], from: result) == components else {
                    throw RecordError.invalid("A copied time falls in a daylight-saving clock change. Copy without times and enter it manually.")
                }
                return result
            }
            copy.startTime = try convert(copy.startTime); copy.endTime = try convert(copy.endTime); copy.callTime = try convert(copy.callTime)
            copy.timeZoneID = destinationTimeZoneID
        }
        try copy.validate()
        return copy
    }
}
