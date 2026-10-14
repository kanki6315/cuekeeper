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
    func testTimeZoneChoicesPreserveDaylightSavingRules() throws {
        let winter = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-01-01T00:00:00Z"))
        let summer = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-01T00:00:00Z"))
        let choices = TimeZoneChoice.grouped(date: winter)
        func choice(_ identifier: String) throws -> TimeZoneChoice {
            try XCTUnwrap(choices.first { $0.identifiers.contains(identifier) })
        }
        XCTAssertEqual(Set(choices.flatMap(\.identifiers)), Set(TimeZone.knownTimeZoneIdentifiers))
        XCTAssertEqual(Set(choices.map(\.label)).count, choices.count)
        let eastern = try choice("America/New_York")
        XCTAssertEqual(eastern.id, try choice("America/Toronto").id)
        XCTAssertNotEqual(try choice("America/Denver").id, try choice("America/Phoenix").id)
        XCTAssertNotEqual(try choice("Europe/London").id, try choice("Africa/Abidjan").id)
        XCTAssertEqual(eastern.identifier(selection: "America/Toronto", search: "", current: ""), "America/Toronto")
        XCTAssertEqual(eastern.identifier(selection: "", search: "New York", current: ""), "America/New_York")
        let zone = try XCTUnwrap(TimeZone(identifier: eastern.identifier(selection: "", search: "", current: "")))
        XCTAssertEqual(zone.secondsFromGMT(for: winter), -18000)
        XCTAssertEqual(zone.secondsFromGMT(for: summer), -14400)
    }

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

    func testAllDayEventUsesFloatingCivilDatesAndRepairsTimedEvents() throws {
        let store = EKEventStore()
        for zoneID in ["America/New_York", "Asia/Tokyo"] {
            let zone = try XCTUnwrap(TimeZone(identifier: zoneID))
            for (first, last) in [("2026-03-08", "2026-03-09"), ("2026-10-14", "2026-10-17"),
                                  ("2026-11-01", "2026-11-02")] {
                let entry = CalendarEntry(key: "job/\(UUID())", title: "All-day job",
                                          start: try XCTUnwrap(Day.date(from: first, timeZone: zone)),
                                          end: try XCTUnwrap(Day.date(from: last, timeZone: zone)),
                                          allDay: true, timeZoneID: zone.identifier, notes: "", location: "")
                let event = EKEvent(eventStore: store)
                // Reproduce the legacy midnight-to-11:59 timed block.
                event.startDate = entry.start
                event.endDate = entry.end.addingTimeInterval(-60)
                event.timeZone = zone
                event.isAllDay = false
                XCTAssertTrue(CalendarController.update(event, from: entry))
                XCTAssertTrue(event.isAllDay)
                XCTAssertNil(event.timeZone)
                XCTAssertEqual(event.startDate, Day.date(from: first, timeZone: .current))
                XCTAssertEqual(event.endDate, Day.date(from: last, timeZone: .current)?.addingTimeInterval(-1))
                XCTAssertFalse(CalendarController.update(event, from: entry), "An unchanged event must not trigger another save")
            }
        }
    }

    func testTimedEventPreservesInstantsAndTimeZone() throws {
        let event = EKEvent(eventStore: EKEventStore())
        let entry = CalendarEntry(key: "session/\(UUID())", title: "Timed session",
                                  start: Date(timeIntervalSince1970: 1791982800),
                                  end: Date(timeIntervalSince1970: 1791986400), allDay: false,
                                  timeZoneID: "America/New_York", notes: "Session notes", location: "Venue")
        event.isAllDay = true
        XCTAssertTrue(CalendarController.update(event, from: entry))
        XCTAssertFalse(event.isAllDay)
        XCTAssertEqual(event.startDate, entry.start)
        XCTAssertEqual(event.endDate, entry.end)
        XCTAssertEqual(event.timeZone?.identifier, entry.timeZoneID)
        XCTAssertFalse(CalendarController.update(event, from: entry))
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
        var jobDraft = JobDraft(name: "Calendar test")
        jobDraft.timeZoneID = "Asia/Tokyo"
        let jobID = try jobDraft.save(in: context)
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
        XCTAssertEqual(events().first?.isAllDay, true)
        XCTAssertNil(events().first?.timeZone)
        XCTAssertEqual(events().first?.startDate, Day.date(from: job.startDay, timeZone: .current))
        let lastDay = try XCTUnwrap(Day.date(from: job.endDay, timeZone: .current))
        let exclusiveEnd = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: lastDay))
        XCTAssertEqual(events().first?.endDate, exclusiveEnd.addingTimeInterval(-1))
        let desired = try XCTUnwrap(CalendarPlan(jobs: [job]).desired.values.first)
        XCTAssertFalse(CalendarController.update(try XCTUnwrap(events().first), from: desired))
        // Existing malformed entries are repaired in place on the next sync.
        let legacy = try XCTUnwrap(events().first)
        legacy.isAllDay = false
        legacy.timeZone = TimeZone(identifier: job.timeZoneID)
        legacy.endDate = legacy.endDate.addingTimeInterval(-60)
        try eventStore.save(legacy, span: .thisEvent)
        await controller.sync()
        XCTAssertEqual(events().first?.isAllDay, true)
        XCTAssertNil(events().first?.timeZone)
        XCTAssertEqual(events().first?.eventIdentifier, originalID)
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
