import CoreData
import Foundation

@objc(Job)
final class Job: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var name: String
    @NSManaged var startDay: String
    @NSManaged var endDay: String
    @NSManaged var bookingStatus: String
    @NSManaged var createdAt: Date?
    @NSManaged var workArrangement: String
    @NSManaged var location: String
    @NSManaged var timeZoneID: String
    @NSManaged var notes: String
    @NSManaged var client: Client?
    @NSManaged var roles: Set<WorkRole>?
    @NSManaged var feeRevisions: Set<FeeRevision>?
    @NSManaged var sessions: Set<WorkSession>?
    var activeSessions: [WorkSession] { (sessions ?? []).filter { $0.deletedAt == nil }.sorted { ($0.day, $0.startTime ?? .distantFuture, $0.name) < ($1.day, $1.startTime ?? .distantFuture, $1.name) } }
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

enum BookingStatus: String, CaseIterable {
    case tentative, booked, completed, cancelled
    var title: String { rawValue.capitalized }
}

enum WorkArrangement: String, CaseIterable {
    case unspecified, remote, onSite, hybrid
    var title: String { self == .onSite ? "On-site" : rawValue.capitalized }
}

struct JobDraft: Equatable {
    var name = ""
    var startDate = Date()
    var endDate = Date()
    var bookingStatus = BookingStatus.tentative
    var clientName = ""
    var roleNames: Set<String> = []
    var workArrangement = WorkArrangement.unspecified
    var location = ""
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
        roleNames = Set(job.roleNames)
        workArrangement = WorkArrangement(rawValue: job.workArrangement) ?? .unspecified
        location = job.location
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
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.nameRequired }
        let start = Day.string(from: startDate)
        let end = Day.string(from: endDate)
        guard start <= end else { throw ValidationError.invalidDates }
        guard timeZoneID.isEmpty || TimeZone(identifier: timeZoneID) != nil else { throw ValidationError.invalidTimeZone }
        // Isolate each save: a failed edit cannot leak partial changes into the UI context.
        let writer = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        writer.persistentStoreCoordinator = context.persistentStoreCoordinator
        writer.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
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
             "location": $0.location, "timeZoneID": $0.timeZoneID, "notes": $0.notes]
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
        try writer.save()
        context.performAndWait { context.refreshAllObjects() }
        return job.objectID
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
    var usesDates = false
    var start = Date()
    var end = Date()
    var isActive: Bool { !status.isEmpty || !client.isEmpty || !role.isEmpty || usesDates }

    func includes(_ job: Job, query: String = "") -> Bool {
        let search = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return (search.isEmpty || job.name.localizedCaseInsensitiveContains(search)
                || (job.client?.name.localizedCaseInsensitiveContains(search) ?? false))
            && (status.isEmpty || job.bookingStatus == status)
            && (client.isEmpty || job.client?.name == client)
            && (role.isEmpty || job.roleNames.contains(role))
            && (!usesDates || (job.endDay >= Day.string(from: start) && job.startDay <= Day.string(from: end)))
    }
}
