import CoreData
import Foundation

@objc(Job)
final class Job: NSManagedObject {
    @NSManaged var deletedAt: Date?
    @NSManaged var recoveryDiscardedAt: Date?
    @NSManaged var id: UUID?
    @NSManaged var name: String
    @NSManaged var event: WorkEvent?
    @NSManaged var startDay: String
    @NSManaged var endDay: String
    @NSManaged var bookingStatus: String
    @NSManaged var createdAt: Date?
    @NSManaged var workArrangement: String
    @NSManaged var location: String
    @NSManaged var trackPlaceID: String
    @NSManaged var timeZoneID: String
    @NSManaged var notes: String
    @NSManaged var project: WorkProject?
    @NSManaged var series: WorkSeries?
    @NSManaged var additionalSeries: Set<WorkSeries>?
    var allSeries: Set<WorkSeries> { (additionalSeries ?? []).union(series.map { [$0] } ?? []) }
    var seriesNames: [String] { allSeries.map(\.name).sorted() }
    @NSManaged var client: Client?
    @NSManaged var roles: Set<WorkRole>?
    @NSManaged var expenses: Set<Expense>?
    @NSManaged var payments: Set<PaymentRecord>?
    @NSManaged var feeRevisions: Set<FeeRevision>?
    @NSManaged var sessions: Set<WorkSession>?
    var activeSessions: [WorkSession] { (sessions ?? []).filter { $0.deletedAt == nil }.sorted { ($0.eventDay, $0.startTime ?? .distantFuture, $0.name) < ($1.eventDay, $1.startTime ?? .distantFuture, $1.name) } }
    /// Keep a synced tombstone so calendar cleanup and financial history survive deletion.
    static func remove(_ objectID: NSManagedObjectID, in context: NSManagedObjectContext) throws {
        let writer = isolatedWriter(context)
        let job = try writer.existingObject(with: objectID) as! Job
        if job.deletedAt == nil { job.deletedAt = Date(); job.recoveryDiscardedAt = nil }
        try writer.save()
        context.refreshAllObjects()
    }

    var roleNames: [String] { (roles ?? []).map(\.name).sorted() }
}

/// "1 session", "2 sessions".
func counted(_ n: Int, _ one: String, _ many: String) -> String { "\(n) \(n == 1 ? one : many)" }

extension TimeZone {
    /// The zone of the user's home location, used whenever an event has no zone of its own.
    static var home: TimeZone {
        UserDefaults.standard.string(forKey: "homeTimeZone").flatMap(TimeZone.init(identifier:)) ?? .current
    }

    /// A stored zone when valid, otherwise the home zone.
    static func effective(_ identifier: String) -> TimeZone { TimeZone(identifier: identifier) ?? .home }

    /// The instant that reads the same wall-clock date and time in `zone` as `date` reads here.
    /// A time skipped by a daylight-saving change in `zone` moves forward to the next valid time.
    func sameWallClock(_ date: Date, in zone: TimeZone) -> Date {
        guard zone != self else { return date }
        var source = Calendar(identifier: .gregorian); source.timeZone = self
        var target = Calendar(identifier: .gregorian); target.timeZone = zone
        return target.date(from: source.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)) ?? date
    }
}

/// Placeholder dates are civil dates, not UTC instants. Device travel must not move them.
enum Day {
    static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        formatter(timeZone: timeZone).string(from: date)
    }

    /// The first instant of the civil day. Where local midnight is skipped (e.g. Santiago, Cairo)
    /// that is the first time the day has, such as 01:00. Only a day the zone skipped entirely is nil.
    static func date(from value: String, timeZone: TimeZone = .current) -> Date? {
        guard let parts = components(value) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        var noon = parts; noon.hour = 12
        guard let midday = calendar.date(from: noon) else { return nil }
        let start = calendar.startOfDay(for: midday)
        return string(from: start, timeZone: timeZone) == value ? start : nil
    }

    /// Strict YYYY-MM-DD, validated by its civil components rather than by any local midnight.
    static func components(_ value: String) -> DateComponents? {
        let fields = value.split(separator: "-", omittingEmptySubsequences: false)
        guard fields.count == 3, fields.map(\.count) == [4, 2, 2], fields.allSatisfy({ $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }),
              let year = Int(fields[0]), let month = Int(fields[1]), let day = Int(fields[2]) else { return nil }
        let parts = DateComponents(year: year, month: month, day: day)
        guard let date = utc.date(from: parts), utc.dateComponents([.year, .month, .day], from: date) == parts else { return nil }
        return parts
    }

    /// Civil day arithmetic, independent of any timezone's clock changes.
    static func adding(days: Int, to value: String) -> String? {
        guard let parts = components(value), let date = utc.date(from: parts),
              let result = utc.date(byAdding: .day, value: days, to: date) else { return nil }
        return string(from: result, timeZone: utc.timeZone)
    }

    /// Whole civil days from one day to another; DST transitions never shorten the count.
    static func days(from start: String, to end: String) -> Int? {
        guard let first = components(start).flatMap(utc.date(from:)), let last = components(end).flatMap(utc.date(from:)) else { return nil }
        return utc.dateComponents([.day], from: first, to: last).day
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    /// Reader-facing form of a stored day; falls back to the raw value if it doesn't parse.
    static func display(_ value: String) -> String {
        date(from: value)?.formatted(date: .abbreviated, time: .omitted) ?? value
    }

    private static func formatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }
}

@objc(Client)
final class Client: NSManagedObject {
    @NSManaged var invoices: Set<Invoice>?
    @NSManaged var contact: String
    @NSManaged var notes: String
    @NSManaged var defaultCurrency: String
    @NSManaged var invoicingJSON: String
    @NSManaged var id: UUID?
    @NSManaged var name: String
    @NSManaged var jobs: Set<Job>?
}

@objc(WorkRole)
final class WorkRole: NSManagedObject {
    @NSManaged var sessions: Set<WorkSession>?
    @NSManaged var id: UUID?
    @NSManaged var name: String
    @NSManaged var jobs: Set<Job>?
}

@objc(WorkProject)
final class WorkProject: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var name: String
    @NSManaged var jobs: Set<Job>?
}

@objc(WorkSeries)
final class WorkSeries: NSManagedObject {
    @NSManaged var additionalJobs: Set<Job>?
    @NSManaged var id: UUID?
    @NSManaged var name: String
    @NSManaged var jobs: Set<Job>?
    @NSManaged var sessions: Set<WorkSession>?
}

/// Shared named records are optional; billing remains attached to each job.
func reusableRecord(entity: String, name: String, in context: NSManagedObjectContext) throws -> NSManagedObject? {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }
    let request = NSFetchRequest<NSManagedObject>(entityName: entity)
    request.predicate = NSPredicate(format: "name ==[cd] %@", trimmed)
    if let existing = try context.fetch(request).first { return existing }
    let record = NSEntityDescription.insertNewObject(forEntityName: entity, into: context)
    record.setValue(UUID(), forKey: "id"); record.setValue(trimmed, forKey: "name")
    return record
}

enum BookingStatus: String, CaseIterable, Sendable {
    case tentative, booked, completed, cancelled
    var title: String { rawValue.capitalized }
}

enum WorkArrangement: String, CaseIterable, Sendable {
    case unspecified, remote, onSite, hybrid
    var title: String { self == .onSite ? "On-site" : rawValue.capitalized }
}

struct JobDraft: Equatable {
    var name = ""
    var startDate = Date()
    var endDate = Date()
    var bookingStatus = BookingStatus.tentative
    var clientName = ""
    var projectName = ""
    var seriesName = ""
    var additionalSeriesNames: Set<String> = []
    var seriesNames: Set<String> {
        get { additionalSeriesNames.union(seriesName.isEmpty ? [] : [seriesName]) }
        set { let names = newValue.sorted(); seriesName = names.first ?? ""; additionalSeriesNames = Set(names.dropFirst()) }
    }
    var roleNames: Set<String> = []
    var workArrangement = WorkArrangement.unspecified
    var worksRemotely: Bool { workArrangement == .remote || workArrangement == .hybrid }
    var location = ""
    var trackPlaceID = ""
    var timeZoneID = ""
    var notes = ""
    var fee: FeeDraft? = FeeDraft()

    init(name: String = "", startDate: Date = Date(), endDate: Date = Date()) {
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
        let defaultRole = UserDefaults.standard.string(forKey: "defaultRole")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        roleNames = defaultRole.isEmpty ? [] : [defaultRole]
    }

    init(job: Job) {
        name = job.name
        startDate = Day.date(from: job.startDay) ?? Date()
        endDate = Day.date(from: job.endDay) ?? startDate
        bookingStatus = BookingStatus(rawValue: job.bookingStatus) ?? .tentative
        clientName = job.client?.name ?? ""
        projectName = job.project?.name ?? ""
        seriesName = job.series?.name ?? ""
        additionalSeriesNames = Set((job.additionalSeries ?? []).map(\.name))
        roleNames = Set(job.roleNames)
        workArrangement = WorkArrangement(rawValue: job.workArrangement) ?? .unspecified
        location = job.location
        trackPlaceID = job.trackPlaceID
        timeZoneID = job.timeZoneID
        notes = job.notes
        fee = try? FeeDraft(job: job)
    }

    /// Reuse descriptive details only. New engagements always begin tentative.
    static func duplicate(_ job: Job) -> JobDraft {
        var draft = JobDraft(job: job)
        draft.bookingStatus = .tentative
        draft.startDate = Date()
        draft.endDate = draft.startDate
        draft.notes = ""
        draft.fee?.parentIDs = []
        return draft
    }

    @discardableResult
    func save(in context: NSManagedObjectContext, editing objectID: NSManagedObjectID? = nil, baseline: JobDraft? = nil) throws -> NSManagedObjectID {
        let writer = isolatedWriter(context)
        let job = try stage(in: writer, editing: objectID, baseline: baseline)
        try writer.save()
        context.refreshAllObjects()
        return job.objectID
    }

    /// Stage in a caller-owned transaction so event + first booking save atomically.
    func stage(in writer: NSManagedObjectContext, editing objectID: NSManagedObjectID? = nil, baseline: JobDraft? = nil) throws -> Job {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let start = Day.string(from: startDate)
        let end = Day.string(from: endDate)
        guard start <= end else { throw ValidationError.invalidDates }
        guard timeZoneID.isEmpty || TimeZone(identifier: timeZoneID) != nil else { throw ValidationError.invalidTimeZone }
        let job: Job
        if let objectID {
            job = try writer.existingObject(with: objectID) as! Job
        } else {
            job = Job(entity: NSEntityDescription.entity(forEntityName: "Job", in: writer)!, insertInto: writer)
            job.id = UUID()
            job.createdAt = Date()
        }
        guard job.deletedAt == nil else { throw RecordError.invalid("This event has been deleted.") }
        // Apply only changed fields so unrelated incoming sync edits are preserved.
        let original: [String: String]? = baseline.map {
            ["name": $0.name, "startDay": Day.string(from: $0.startDate), "endDay": Day.string(from: $0.endDate),
             "bookingStatus": $0.bookingStatus.rawValue, "workArrangement": $0.workArrangement.rawValue,
             "location": $0.location, "trackPlaceID": $0.trackPlaceID, "timeZoneID": $0.timeZoneID, "notes": $0.notes]
        }
        func assign(_ key: String, _ value: String) {
            guard original?[key] != value else { return }
            if job.value(forKey: key) as? String != value { job.setValue(value, forKey: key) }
        }
        assign("name", trimmed)
        assign("startDay", start)
        assign("endDay", end)
        assign("bookingStatus", bookingStatus.rawValue)
        assign("workArrangement", workArrangement.rawValue)
        assign("location", location.trimmingCharacters(in: .whitespacesAndNewlines))
        assign("trackPlaceID", trackPlaceID)
        assign("timeZoneID", timeZoneID)
        assign("notes", notes)
        guard job.startDay <= job.endDay else { throw ValidationError.invalidDates }
        let clientText = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseline?.clientName != clientName {
            if clientText.isEmpty {
                job.client = nil
            } else {
                let request = NSFetchRequest<Client>(entityName: "Client")
                request.predicate = NSPredicate(format: "name ==[cd] %@", clientText)
                let client = try writer.fetch(request).first ?? Client(entity: NSEntityDescription.entity(forEntityName: "Client", in: writer)!, insertInto: writer)
                if client.id == nil { client.id = UUID(); client.name = clientText }
                job.client = client
            }
        }
        if baseline?.projectName != projectName {
            job.project = try reusableRecord(entity: "WorkProject", name: projectName, in: writer) as? WorkProject
        }
        if baseline?.seriesName != seriesName {
            job.series = try reusableRecord(entity: "WorkSeries", name: seriesName, in: writer) as? WorkSeries
        }
        if baseline?.additionalSeriesNames != additionalSeriesNames {
            job.additionalSeries = Set(try additionalSeriesNames.compactMap { try reusableRecord(entity: "WorkSeries", name: $0, in: writer) as? WorkSeries })
        }
        if baseline?.roleNames != roleNames {
            var selectedRoles = Set<WorkRole>()
            for name in roleNames.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines) }).filter({ !$0.isEmpty }).sorted() {
                let request = NSFetchRequest<WorkRole>(entityName: "WorkRole")
                request.predicate = NSPredicate(format: "name ==[cd] %@", name)
                let role = try writer.fetch(request).first ?? WorkRole(entity: NSEntityDescription.entity(forEntityName: "WorkRole", in: writer)!, insertInto: writer)
                if role.id == nil { role.id = UUID(); role.name = name }
                selectedRoles.insert(role)
            }
            job.roles = selectedRoles
        }
        if let fee, baseline?.fee != fee {
            let changed = try fee.value() != (try? job.currentFee())
            if objectID == nil || changed { try fee.apply(to: job, in: writer) }
        }
        return job
    }

    enum ValidationError: LocalizedError {
        case nameRequired, invalidDates, invalidTimeZone
        var errorDescription: String? {
            switch self {
            case .nameRequired: "Enter a job name."
            case .invalidDates: "The end date must be on or after the start date."
            case .invalidTimeZone: "Choose a valid timezone."
            }
        }
    }
}

struct JobFilter {
    var client = ""
    var role = ""
    var project = ""
    var series = ""
    var usesDates = false
    var start = Date()
    var end = Date()
    var isActive: Bool { !client.isEmpty || !role.isEmpty || !project.isEmpty || !series.isEmpty || usesDates }

    func includes(_ job: Job, query: String = "") -> Bool {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return job.deletedAt == nil && (search.isEmpty || job.displayName.localizedCaseInsensitiveContains(search)
                || job.eventTitle.localizedCaseInsensitiveContains(search)
                || (job.client?.name.localizedCaseInsensitiveContains(search) ?? false)
                || (job.project?.name.localizedCaseInsensitiveContains(search) ?? false)
                || job.seriesNames.contains { $0.localizedCaseInsensitiveContains(search) }
                || job.activeSessions.contains { $0.effectiveSeriesNames.contains { $0.localizedCaseInsensitiveContains(search) } })
            && (client.isEmpty || job.client?.name == client)
            && (project.isEmpty || job.project?.name == project)
            && (series.isEmpty || job.seriesNames.contains(series) || job.activeSessions.contains { $0.effectiveSeriesNames.contains(series) })
            && (role.isEmpty || job.roleNames.contains(role) || job.activeSessions.contains { $0.roleNames.contains(role) })
            && (!usesDates || (job.eventEndDay >= Day.string(from: start) && job.eventStartDay <= Day.string(from: end)))
    }
}
