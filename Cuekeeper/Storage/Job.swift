import CoreData
import Foundation

@objc(Job)
final class Job: NSManagedObject {
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
    @NSManaged var payments: Set<PaymentRecord>?
    @NSManaged var feeRevisions: Set<FeeRevision>?
    @NSManaged var sessions: Set<WorkSession>?
    var activeSessions: [WorkSession] { (sessions ?? []).filter { $0.deletedAt == nil }.sorted { ($0.eventDay, $0.startTime ?? .distantFuture, $0.name) < ($1.eventDay, $1.startTime ?? .distantFuture, $1.name) } }
    var roleNames: [String] { (roles ?? []).map(\.name).sorted() }
}

/// Placeholder dates are civil dates, not UTC instants. Device travel must not move them.
enum Day {
    static func string(from date: Date, timeZone: TimeZone = .current) -> String {
        formatter(timeZone: timeZone).string(from: date)
    }

    static func date(from value: String, timeZone: TimeZone = .current) -> Date? {
        formatter(timeZone: timeZone).date(from: value)
    }

    private static func formatter(timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        return formatter
    }
}

@objc(Client)
final class Client: NSManagedObject {
    @NSManaged var invoices: Set<Invoice>?
    @NSManaged var contact: String
    @NSManaged var notes: String
    @NSManaged var defaultCurrency: String
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
    var location = ""
    var trackPlaceID = ""
    var timeZoneID = ""
    var notes = ""
    var fee: FeeDraft? = FeeDraft()

    init(name: String = "", startDate: Date = Date(), endDate: Date = Date()) {
        self.name = name
        self.startDate = startDate
        self.endDate = endDate
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
    var status = ""
    var client = ""
    var role = ""
    var project = ""
    var series = ""
    var usesDates = false
    var start = Date()
    var end = Date()
    var isActive: Bool { !status.isEmpty || !client.isEmpty || !role.isEmpty || !project.isEmpty || !series.isEmpty || usesDates }

    func includes(_ job: Job, query: String = "") -> Bool {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (search.isEmpty || job.displayName.localizedCaseInsensitiveContains(search)
                || job.eventTitle.localizedCaseInsensitiveContains(search)
                || (job.client?.name.localizedCaseInsensitiveContains(search) ?? false)
                || (job.project?.name.localizedCaseInsensitiveContains(search) ?? false)
                || job.seriesNames.contains { $0.localizedCaseInsensitiveContains(search) }
                || job.activeSessions.contains { $0.effectiveSeriesNames.contains { $0.localizedCaseInsensitiveContains(search) } })
            && (status.isEmpty || job.bookingStatus == status)
            && (client.isEmpty || job.client?.name == client)
            && (project.isEmpty || job.project?.name == project)
            && (series.isEmpty || job.seriesNames.contains(series) || job.activeSessions.contains { $0.effectiveSeriesNames.contains(series) })
            && (role.isEmpty || job.roleNames.contains(role) || job.activeSessions.contains { $0.roleNames.contains(role) })
            && (!usesDates || (job.eventEndDay >= Day.string(from: start) && job.eventStartDay <= Day.string(from: end)))
    }
}
