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
    @NSManaged var job: Job?
    @NSManaged var roles: Set<WorkRole>?
    @NSManaged var links: Set<BroadcastLink>?
    var title: String { name.isEmpty ? "Session" : name }
    var roleNames: [String] { overridesRoles ? (roles ?? []).map(\.name).sorted() : job?.roleNames ?? [] }
    var sortedLinks: [BroadcastLink] { (links ?? []).sorted { ($0.label, $0.url) < ($1.label, $1.url) } }
    var calendarEligible: Bool {
        deletedAt == nil && job?.bookingStatus != "cancelled" && scheduleStatus == "confirmed"
            && coverage == "covering" && startTime != nil && endTime != nil
            && endTime! > startTime! && TimeZone(identifier: timeZoneID) != nil
    }
    func formattedTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        return formatter.string(from: date)
    }
    var scheduleDescription: String {
        guard let startTime, let endTime else { return day.isEmpty ? "Date and times to come" : "\(day) · Times to come" }
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        formatter.timeZone = TimeZone(identifier: timeZoneID) ?? .current
        return "\(formatter.string(from: startTime)) – \(formatter.string(from: endTime)) · \(timeZoneID.replacingOccurrences(of: "_", with: " "))"
    }
}

@objc(BroadcastLink)
final class BroadcastLink: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var label: String
    @NSManaged var url: String
    @NSManaged var notes: String
    @NSManaged var session: WorkSession?
}

struct LinkDraft: Equatable, Identifiable {
    var id = UUID()
    var label = ""
    var url = ""
    var notes = ""
    var validURL: URL? {
        guard let value = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["https", "http"].contains(value.scheme?.lowercased() ?? ""),
              let host = value.host, !host.isEmpty else { return nil }
        return value
    }
}

struct SessionDraft: Equatable {
    var name = ""
    var day = ""
    var startTime: Date?
    var endTime: Date?
    var callTime: Date?
    var timeZoneID = ""
    var scheduleStatus = "tentative"
    var coverage = "undecided"
    var overridesRoles = false
    var roleNames: Set<String> = []
    var notes = ""
    var links: [LinkDraft] = []

    init(job: Job) { day = job.startDay; timeZoneID = job.timeZoneID }
    init(session: WorkSession) {
        name = session.name; day = session.day; startTime = session.startTime; endTime = session.endTime
        callTime = session.callTime; timeZoneID = session.timeZoneID; scheduleStatus = session.scheduleStatus
        coverage = session.coverage; overridesRoles = session.overridesRoles
        roleNames = Set((session.roles ?? []).map(\.name)); notes = session.notes
        links = session.sortedLinks.map { LinkDraft(id: $0.id ?? UUID(), label: $0.label, url: $0.url, notes: $0.notes) }
    }
    func validate() throws {
        if !day.isEmpty && Day.date(from: day) == nil { throw RecordError.invalid("Choose a valid session date.") }
        if !timeZoneID.isEmpty && TimeZone(identifier: timeZoneID) == nil { throw RecordError.invalid("Choose a valid timezone.") }
        if startTime != nil || endTime != nil || callTime != nil {
            guard TimeZone(identifier: timeZoneID) != nil else { throw RecordError.invalid("Choose a timezone before adding times.") }
        }
        if let startTime, let endTime, endTime <= startTime { throw RecordError.invalid("The end must be after the start. For overnight sessions, choose the following date.") }
        if scheduleStatus == "confirmed" && (startTime == nil || endTime == nil) {
            throw RecordError.invalid("Add start and end times before confirming the schedule.")
        }
        guard ["tentative", "confirmed"].contains(scheduleStatus), ["undecided", "covering", "notCovering"].contains(coverage) else {
            throw RecordError.invalid("Choose a valid schedule and coverage status.")
        }
        for link in links where link.validURL == nil { throw RecordError.invalid("Enter a complete http or https address for each broadcast link.") }
    }
    @discardableResult
    func save(in context: NSManagedObjectContext, jobID: NSManagedObjectID, editing id: NSManagedObjectID? = nil, baseline: SessionDraft? = nil) throws -> NSManagedObjectID {
        try validate()
        let writer = isolatedWriter(context)
        let job = try writer.existingObject(with: jobID) as! Job
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
        assign("timeZoneID", timeZoneID, baseline?.timeZoneID)
        assign("scheduleStatus", scheduleStatus, baseline?.scheduleStatus)
        assign("coverage", coverage, baseline?.coverage)
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
        if baseline?.links != links {
            // Retain stable link identities; untouched remote additions survive this editor.
            let oldIDs = Set(baseline?.links.map(\.id) ?? [])
            let newIDs = Set(links.map(\.id))
            for link in session.links ?? [] where oldIDs.contains(link.id ?? UUID()) && !newIDs.contains(link.id ?? UUID()) { writer.delete(link) }
            for value in links {
                let previous = baseline?.links.first { $0.id == value.id }
                if previous == value { continue }
                let link = session.links?.first { $0.id == value.id } ?? BroadcastLink(entity: NSEntityDescription.entity(forEntityName: "BroadcastLink", in: writer)!, insertInto: writer)
                link.id = value.id; link.session = session
                link.label = value.label; link.url = value.validURL!.absoluteString; link.notes = value.notes
            }
        }
        // Recheck the merged result before persisting independent incoming changes.
        var merged = SessionDraft(session: session)
        if let start = merged.startTime, let zone = TimeZone(identifier: merged.timeZoneID) {
            merged.day = Day.string(from: start, timeZone: zone); session.day = merged.day
        }
        try merged.validate()
        try writer.save(); context.refreshAllObjects()
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
