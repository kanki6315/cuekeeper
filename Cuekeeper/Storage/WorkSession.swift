import CoreData
import Foundation

@objc(WorkSession)
final class WorkSession: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var name: String
    @NSManaged var day: String
    @NSManaged var startTime: Date?
    @NSManaged var endTime: Date?
    @NSManaged var callTime: Date?
    @NSManaged var timeZoneID: String
    @NSManaged var scheduleStatus: String
    @NSManaged var coverage: String
    @NSManaged var overridesRoles: Bool
    @NSManaged var notes: String
    @NSManaged var deletedAt: Date?
    @NSManaged var recoveryDiscardedAt: Date?
    @NSManaged var series: WorkSeries?
    @NSManaged var overridesSeries: Bool
    var effectiveSeries: WorkSeries? { overridesSeries ? series : (job?.allSeries.count == 1 ? job?.allSeries.first : nil) }
    var effectiveSeriesNames: [String] { effectiveSeries.map { [$0.name] } ?? [] }
    @NSManaged var job: Job?
    @NSManaged var roles: Set<WorkRole>?
    var eventTimeZoneID: String { job?.eventTimeZoneID ?? timeZoneID }
    var eventDay: String {
        guard let startTime, let zone = TimeZone(identifier: eventTimeZoneID) else { return day }
        return Day.string(from: startTime, timeZone: zone)
    }
    var title: String { name.isEmpty ? "Session" : name }
    var roleNames: [String] { overridesRoles ? (roles ?? []).map(\.name).sorted() : job?.roleNames ?? [] }
    var calendarEligible: Bool {
        deletedAt == nil && job != nil && job?.deletedAt == nil && job?.bookingStatus != "cancelled" && scheduleStatus == "confirmed"
            && coverage == "covering" && startTime != nil && endTime != nil
            && endTime! > startTime! && TimeZone(identifier: eventTimeZoneID) != nil
    }
    func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        formatter.timeZone = TimeZone.effective(eventTimeZoneID)
        return formatter.string(from: date)
    }
    var localScheduleDescription: String? {
        guard let job, job.hasWorkTimeZone, job.workTimeZoneID != eventTimeZoneID,
              let zone = TimeZone(identifier: job.workTimeZoneID) else { return nil }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .short; formatter.timeZone = zone
        var parts: [String] = []
        if let startTime { parts.append(formatter.string(from: startTime)) }
        if let endTime { parts.append("– " + formatter.string(from: endTime)) }
        if let callTime { parts.append("· Call " + formatter.string(from: callTime)) }
        guard !parts.isEmpty else { return nil }
        return "Your time: " + parts.joined(separator: " ") + " · " + zone.identifier.replacingOccurrences(of: "_", with: " ")
    }
    var scheduleDescription: String {
        guard let startTime, let endTime else { return day.isEmpty ? "Date and times to come" : "\(day) · Times to come" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        formatter.timeZone = TimeZone.effective(eventTimeZoneID)
        return "\(formatter.string(from: startTime)) – \(formatter.string(from: endTime)) · \(eventTimeZoneID.replacingOccurrences(of: "_", with: " "))"
    }
}

struct SessionDraft: Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var day = ""
    var startTime: Date?
    var endTime: Date?
    var callTime: Date?
    var timeZoneID = ""
    var scheduleStatus = "tentative"
    var coverage = "undecided"
    var overridesSeries = false
    var seriesName = ""
    var overridesRoles = false
    var roleNames: Set<String> = []
    var notes = ""

    init(day: String, timeZoneID: String = "") { self.day = day; self.timeZoneID = timeZoneID }
    init(job: Job) { day = job.eventStartDay; timeZoneID = job.eventTimeZoneID }
    init(session: WorkSession) {
        id = session.id ?? UUID()
        name = session.name; day = session.day; startTime = session.startTime; endTime = session.endTime
        callTime = session.callTime; timeZoneID = session.eventTimeZoneID; scheduleStatus = session.scheduleStatus
        if let startTime, let zone = TimeZone(identifier: timeZoneID) { day = Day.string(from: startTime, timeZone: zone) }
        coverage = session.coverage; overridesRoles = session.overridesRoles
        overridesSeries = session.overridesSeries; seriesName = session.series?.name ?? ""
        roleNames = Set((session.roles ?? []).map(\.name)); notes = session.notes
    }
    func validate() throws {
        if !day.isEmpty && Day.date(from: day) == nil { throw RecordError.invalid("Choose a valid session date.") }
        if !timeZoneID.isEmpty && TimeZone(identifier: timeZoneID) == nil { throw RecordError.invalid("Choose a valid timezone.") }
        if startTime != nil || endTime != nil || callTime != nil {
            guard TimeZone(identifier: timeZoneID) != nil else { throw RecordError.invalid("Choose the event timezone before adding times.") }
        }
        if let startTime, let endTime, endTime <= startTime { throw RecordError.invalid("The end must be after the start. Choose different start and end times.") }
        if scheduleStatus == "confirmed" && (startTime == nil || endTime == nil) {
            throw RecordError.invalid("Add start and end times before confirming the schedule.")
        }
        guard ["tentative", "confirmed"].contains(scheduleStatus), ["undecided", "covering", "notCovering"].contains(coverage) else {
            throw RecordError.invalid("Choose a valid schedule and coverage status.")
        }
    }
    @discardableResult
    func save(in context: NSManagedObjectContext, jobID: NSManagedObjectID, editing id: NSManagedObjectID? = nil, baseline: SessionDraft? = nil, transaction: NSManagedObjectContext? = nil) throws -> NSManagedObjectID {
        let writer = transaction ?? isolatedWriter(context)
        let job = try writer.existingObject(with: jobID) as! Job
        var resolved = self
        resolved.timeZoneID = job.eventTimeZoneID
        guard job.deletedAt == nil else { throw RecordError.invalid("This event has been deleted.") }
        // An event without a zone adopts one once, so stored instants stay tied to a fixed zone:
        // the zone times were entered in (the home zone by default), or a legacy capture's zone.
        let timed = startTime != nil || endTime != nil || callTime != nil
        if TimeZone(identifier: resolved.timeZoneID) == nil && (timed || (job.event == nil && !timeZoneID.isEmpty)) {
            let zone = TimeZone.effective(timeZoneID).identifier
            if let event = job.event { event.timeZoneID = zone } else { job.timeZoneID = zone }
            resolved.timeZoneID = zone
        }
        try resolved.validate()
        let session = try id.map { try writer.existingObject(with: $0) as! WorkSession }
            ?? WorkSession(entity: NSEntityDescription.entity(forEntityName: "WorkSession", in: writer)!, insertInto: writer)
        guard session.deletedAt == nil else { throw RecordError.invalid("This session was removed on another device. Cancel and return to the job.") }
        if session.id == nil { session.id = UUID(); session.job = job }
        func assign<T: Equatable>(_ key: String, _ value: T, _ previous: T?) {
            if previous != value { session.setValue(value, forKey: key) }
        }
        assign("name", name.trimmingCharacters(in: .whitespacesAndNewlines), baseline?.name)
        assign("day", day, baseline?.day)
        assign("startTime", startTime, baseline.map(\.startTime))
        assign("endTime", endTime, baseline.map(\.endTime))
        assign("callTime", callTime, baseline.map(\.callTime))
        session.timeZoneID = resolved.timeZoneID
        assign("scheduleStatus", scheduleStatus, baseline?.scheduleStatus)
        assign("coverage", coverage, baseline?.coverage)
        assign("overridesSeries", overridesSeries, baseline?.overridesSeries)
        if baseline?.seriesName != seriesName {
            session.series = try reusableRecord(entity: "WorkSeries", name: seriesName, in: writer) as? WorkSeries
        }
        assign("overridesRoles", overridesRoles, baseline?.overridesRoles)
        assign("notes", notes, baseline?.notes)
        if baseline?.roleNames != roleNames {
            var roles = Set<WorkRole>()
            for name in roleNames {
                let request = NSFetchRequest<WorkRole>(entityName: "WorkRole")
                request.predicate = NSPredicate(format: "name ==[cd] %@", name)
                let role = try writer.fetch(request).first ?? WorkRole(entity: NSEntityDescription.entity(forEntityName: "WorkRole", in: writer)!, insertInto: writer)
                if role.id == nil { role.id = UUID(); role.name = name }
                roles.insert(role)
            }
            session.roles = roles
        }
        // Recheck the merged result before persisting independent incoming changes.
        var merged = SessionDraft(session: session)
        if let start = merged.startTime, let zone = TimeZone(identifier: merged.timeZoneID) {
            merged.day = Day.string(from: start, timeZone: zone); session.day = merged.day
        }
        try merged.validate()
        if transaction == nil { try writer.save(); context.refreshAllObjects() }
        else { try writer.obtainPermanentIDs(for: [session]) }
        return session.objectID
    }
}

enum RecordError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

func isolatedWriter(_ context: NSManagedObjectContext) -> NSManagedObjectContext {
    let writer = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
    writer.persistentStoreCoordinator = context.persistentStoreCoordinator
    writer.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
    return writer
}

/// Explicit clock input, resolved on the selected day in the session timezone.
enum SessionTimeInput {
    static func date(_ text: String, on day: Date, zone: TimeZone) -> Date? {
        let input = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let pattern = #"^(\d{1,2})(?::(\d{2}))?\s*(am|pm)?$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: input, range: NSRange(input.startIndex..., in: input)) else { return nil }
        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: input) else { return nil }
            return String(input[range])
        }
        guard var hour = group(1).flatMap(Int.init) else { return nil }
        let minute = group(2).flatMap(Int.init) ?? 0
        guard minute < 60 else { return nil }
        if let period = group(3) {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (period == "pm" ? 12 : 0)
        } else if hour > 23 { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        var components = calendar.dateComponents([.year, .month, .day], from: day)
        components.hour = hour; components.minute = minute; components.second = 0
        guard let date = calendar.date(from: components),
              calendar.component(.hour, from: date) == hour,
              calendar.component(.minute, from: date) == minute else { return nil }
        return date
    }
}

extension SessionDraft {
    /// Keep the initial end aligned with start until a different end has been chosen.
    mutating func setStartTime(_ date: Date?, zone: TimeZone) {
        let usesDefaultEnd = endTime == nil || endTime == startTime
        startTime = date
        if let date {
            day = Day.string(from: date, timeZone: zone)
            if usesDefaultEnd { endTime = date }
        }
        timeZoneID = zone.identifier
        inferEndDate(zone: zone)
    }

    /// Interpret the end clock on the session day, rolling earlier times to the next civil day.
    mutating func inferEndDate(zone: TimeZone) {
        guard let endTime, let anchor = startTime ?? Day.date(from: day, timeZone: zone) else { return }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let endClock = calendar.dateComponents([.hour, .minute], from: endTime)
        let hour = endClock.hour ?? 0
        let minute = endClock.minute ?? 0
        var endDay = calendar.startOfDay(for: anchor)
        if let startTime {
            let startClock = calendar.dateComponents([.hour, .minute], from: startTime)
            if hour * 60 + minute < (startClock.hour ?? 0) * 60 + (startClock.minute ?? 0) {
                endDay = calendar.date(byAdding: .day, value: 1, to: endDay) ?? endDay
            }
        }
        self.endTime = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: endDay,
                                     matchingPolicy: .nextTime, repeatedTimePolicy: .first)
    }

    /// Move the schedule by calendar days, retaining local times and overnight offsets.
    mutating func moveSchedule(to date: Date, zone: TimeZone) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let previous = startTime ?? Day.date(from: day, timeZone: zone) ?? date
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: previous),
                                           to: calendar.startOfDay(for: date)).day ?? 0
        startTime = startTime.flatMap { calendar.date(byAdding: .day, value: days, to: $0) }
        endTime = endTime.flatMap { calendar.date(byAdding: .day, value: days, to: $0) }
        callTime = callTime.flatMap { calendar.date(byAdding: .day, value: days, to: $0) }
        day = Day.string(from: date, timeZone: zone)
        inferEndDate(zone: zone)
    }
}
