import CoreData
import EventKit
import XCTest
@testable import Cuekeeper

actor TestCalendarPublisher: CalendarPublishing {
    var owner: String?
    func claim(deviceID: String, name: String) throws {
        guard owner == nil || owner == deviceID else { throw RecordError.invalid("Another device manages this calendar.") }
        owner = deviceID
    }
    func verify(deviceID: String) throws {
        guard owner == deviceID else { throw RecordError.invalid("Not the calendar manager") }
    }
    func release(deviceID: String) throws { if owner == deviceID { owner = nil } }
}

@MainActor
final class CalendarTests: XCTestCase {
    func testProjectionPreservesPlaceholdersAndUsesCivilDayBoundaries() throws {
        let modelURL = try XCTUnwrap(Bundle.main.url(forResource: "Cuekeeper", withExtension: "momd"))
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL))
        let container = NSPersistentContainer(name: "Cuekeeper", managedObjectModel: model)
        let description = NSPersistentStoreDescription(); description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in XCTAssertNil(error) }
        let context = container.viewContext
        let job = Job(entity: NSEntityDescription.entity(forEntityName: "Job", in: context)!, insertInto: context)
        job.id = UUID(); job.name = "DST broadcast"; job.startDay = "2026-03-08"; job.endDay = "2026-03-08"
        job.timeZoneID = "America/New_York"
        let session = WorkSession(entity: NSEntityDescription.entity(forEntityName: "WorkSession", in: context)!, insertInto: context)
        session.id = UUID(); session.job = job; session.timeZoneID = "America/New_York"
        session.startTime = ISO8601DateFormatter().date(from: "2026-03-08T06:00:00Z")
        session.endTime = ISO8601DateFormatter().date(from: "2026-03-08T08:00:00Z")
        session.scheduleStatus = "confirmed"; session.coverage = "covering"
        var plan = CalendarPlan(jobs: [job])
        XCTAssertEqual(plan.desired.count, 2)
        let placeholder = try XCTUnwrap(plan.desired.values.first { $0.allDay })
        XCTAssertEqual(placeholder.end.timeIntervalSince(placeholder.start), 23 * 3600)
        XCTAssertEqual(CalendarPlan.key(from: placeholder.url), placeholder.key)
        XCTAssertNil(CalendarPlan.key(from: URL(string: "https://example.com/job/\(job.id!)")))
        session.coverage = "notCovering"
        plan = CalendarPlan(jobs: [job]); XCTAssertEqual(plan.desired.count, 1); XCTAssertEqual(plan.knownKeys.count, 2)
        session.coverage = "covering"; session.scheduleStatus = "tentative"
        XCTAssertEqual(CalendarPlan(jobs: [job]).desired.count, 1)
        session.scheduleStatus = "confirmed"; session.deletedAt = Date()
        XCTAssertEqual(CalendarPlan(jobs: [job]).desired.count, 1)
        job.bookingStatus = "cancelled"
        XCTAssertTrue(CalendarPlan(jobs: [job]).desired.isEmpty)
        XCTAssertEqual(CalendarPlan(jobs: [job]).knownKeys.count, 2)
    }

    func testEventKitReconciliationAndSinglePublisher() async throws {
        let eventStore = EKEventStore()
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw XCTSkip("Grant Calendar access to the test app with simctl privacy before running the EventKit integration test.")
        }
        let source = try XCTUnwrap(eventStore.sources.first { $0.sourceType == .local })
        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        calendar.title = "Cuekeeper integration test \(UUID())"; calendar.source = source
        try eventStore.saveCalendar(calendar, commit: true)
        defer { try? eventStore.removeCalendar(calendar, commit: true) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceController(storeURL: directory.appendingPathComponent("test.sqlite"), cloudEnabled: false)
        for _ in 0..<100 where !persistence.isLoaded { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertTrue(persistence.isLoaded)
        let context = persistence.container.viewContext
        let jobID = try JobDraft(name: "Calendar test").save(in: context)
        let job = try XCTUnwrap(context.existingObject(with: jobID) as? Job)
        let suite = "calendar-test-\(UUID())"; let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let publisher = TestCalendarPublisher()
        let controller = CalendarController(defaults: defaults, store: eventStore, publisher: publisher)
        controller.start(context: context, enabled: true)
        await controller.connect(calendar.calendarIdentifier)
        XCTAssertTrue(controller.connected, controller.status)
        func events() -> [EKEvent] {
            eventStore.events(matching: eventStore.predicateForEvents(withStart: Date().addingTimeInterval(-86400 * 2), end: Date().addingTimeInterval(86400 * 8), calendars: [calendar]))
        }
        XCTAssertEqual(events().count, 1, controller.status)
        let originalID = try XCTUnwrap(events().first?.eventIdentifier)
        await controller.sync(); XCTAssertEqual(events().count, 1)
        var draft = JobDraft(job: job); draft.name = "Updated title"
        try draft.save(in: context, editing: jobID)
        await controller.sync()
        XCTAssertEqual(events().first?.title, "Updated title")
        XCTAssertEqual(events().first?.eventIdentifier, originalID)
        // A second publisher cannot independently populate a calendar from the same records.
        let otherSuite = "calendar-other-\(UUID())"; let otherDefaults = try XCTUnwrap(UserDefaults(suiteName: otherSuite))
        defer { otherDefaults.removePersistentDomain(forName: otherSuite) }
        let other = CalendarController(defaults: otherDefaults, store: eventStore, publisher: publisher)
        other.start(context: context, enabled: true); await other.connect(calendar.calendarIdentifier)
        XCTAssertFalse(other.connected); XCTAssertEqual(events().count, 1)
        var sessionDraft = SessionDraft(job: job)
        sessionDraft.timeZoneID = "UTC"; sessionDraft.startTime = Date(); sessionDraft.endTime = Date().addingTimeInterval(3600)
        sessionDraft.scheduleStatus = "confirmed"; sessionDraft.coverage = "covering"
        let sessionID = try sessionDraft.save(in: context, jobID: jobID)
        await controller.sync(); XCTAssertEqual(events().count, 2)
        sessionDraft.coverage = "notCovering"
        try sessionDraft.save(in: context, jobID: jobID, editing: sessionID)
        await controller.sync(); XCTAssertEqual(events().count, 1)
        let duplicate = EKEvent(eventStore: eventStore); duplicate.calendar = calendar
        duplicate.title = "Duplicate"; duplicate.startDate = Date(); duplicate.endDate = Date().addingTimeInterval(3600)
        duplicate.url = events().first?.url
        try eventStore.save(duplicate, span: .thisEvent)
        await controller.sync(); XCTAssertEqual(events().count, 1)
        let personal = EKEvent(eventStore: eventStore); personal.calendar = calendar; personal.title = "Unmanaged"
        personal.startDate = Date(); personal.endDate = Date().addingTimeInterval(3600)
        try eventStore.save(personal, span: .thisEvent)
        draft.bookingStatus = .cancelled; try draft.save(in: context, editing: jobID)
        await controller.sync()
        XCTAssertEqual(events().map(\.title), ["Unmanaged"])
        await controller.disconnect()
        XCTAssertFalse(controller.connected, controller.status)
        XCTAssertEqual(events().count, 1)
    }
}
