import CoreData
import EventKit
import XCTest
@testable import Cuekeeper

actor TestCalendarPublisher: CalendarPublishing {
    var owner: String?
    func claim(deviceID: String, name: String) throws {
        guard owner == nil || owner == deviceID else { throw CalendarOwnershipError.managedElsewhere("Test device") }
        owner = deviceID
    }
    func takeOver(deviceID: String, name: String) { owner = deviceID }
    func verify(deviceID: String) throws {
        guard owner == deviceID else { throw CalendarOwnershipError.notOwner(owner: owner == nil ? "" : "Test device") }
    }
    func release(deviceID: String) throws { if owner == deviceID { owner = nil } }
}

@MainActor
final class CalendarTests: XCTestCase {
    func testDeviceIdentitySurvivesReinstallButNotRestoreToAnotherDevice() throws {
        final class Keychain { var id: String?; var locked = false }
        func identity(_ keychain: Keychain) -> CalendarDeviceIdentity {
            CalendarDeviceIdentity(read: { keychain.locked ? .unavailable : keychain.id.map { .found($0) } ?? .missing },
                                   write: { keychain.id = $0; return true })
        }
        func freshDefaults() throws -> UserDefaults {
            let suite = "calendar-identity-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
            return defaults
        }
        // Upgrade: the pre-Keychain ID is kept so the current owner keeps its claim.
        let phone = Keychain(), defaults = try freshDefaults()
        defaults.set("legacy", forKey: CalendarDeviceIdentity.legacyKey)
        XCTAssertEqual(CalendarDeviceIdentity.resolve(defaults: defaults, keychain: identity(phone)), "legacy")
        XCTAssertEqual(phone.id, "legacy")
        // Reinstall wipes defaults but not the Keychain item.
        XCTAssertEqual(CalendarDeviceIdentity.resolve(defaults: try freshDefaults(), keychain: identity(phone)), "legacy")
        // A locked Keychain falls back to the cached copy rather than a new identity.
        phone.locked = true
        XCTAssertEqual(CalendarDeviceIdentity.resolve(defaults: defaults, keychain: identity(phone)), "legacy")
        // Restoring these defaults onto another phone must not copy the identity.
        let restored = try freshDefaults()
        for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("calendar.") { restored.set(value, forKey: key) }
        let newPhone = Keychain()
        let newID = CalendarDeviceIdentity.resolve(defaults: restored, keychain: identity(newPhone))
        XCTAssertNotEqual(newID, "legacy")
        XCTAssertEqual(newPhone.id, newID)
    }

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
        let controller = CalendarController(defaults: defaults, store: eventStore, publisher: publisher, deviceID: "first")
        controller.start(context: context, enabled: true)
        await controller.connect(calendar.calendarIdentifier)
        XCTAssertTrue(controller.connected, controller.status)
        let colleagueKey = "job/\(UUID())"
        func allEvents() -> [EKEvent] {
            eventStore.events(matching: eventStore.predicateForEvents(withStart: Date().addingTimeInterval(-86400 * 2), end: Date().addingTimeInterval(86400 * 8), calendars: [calendar]))
        }
        func events() -> [EKEvent] {
            allEvents().filter { CalendarPlan.key(from: $0.url) != colleagueKey }
        }
        func assertColleaguePreserved(file: StaticString = #filePath, line: UInt = #line) {
            let entries = allEvents().filter { CalendarPlan.key(from: $0.url) == colleagueKey }
            XCTAssertEqual(entries.count, 1, file: file, line: line)
            XCTAssertEqual(entries.first?.title, "Colleague's Cuekeeper entry", file: file, line: line)
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
        let other = CalendarController(defaults: otherDefaults, store: eventStore, publisher: publisher, deviceID: "second")
        other.start(context: context, enabled: true); await other.connect(calendar.calendarIdentifier)
        XCTAssertFalse(other.connected); XCTAssertEqual(events().count, 1)
        XCTAssertNotNil(other.otherOwner)
        // A shared writable calendar can contain another account's Cuekeeper entries.
        let colleague = EKEvent(eventStore: eventStore)
        colleague.calendar = calendar; colleague.title = "Colleague's Cuekeeper entry"
        colleague.startDate = Date(); colleague.endDate = Date().addingTimeInterval(3600)
        colleague.url = URL(string: "cuekeeper://calendar/\(colleagueKey)")
        try eventStore.save(colleague, span: .thisEvent)
        // A replacement device can take over and adopts the existing entries without duplicates.
        await other.takeOver(calendar.calendarIdentifier)
        XCTAssertTrue(other.connected, other.status); XCTAssertNil(other.otherOwner)
        XCTAssertEqual(events().count, 1); XCTAssertEqual(events().first?.eventIdentifier, originalID)
        await controller.sync()
        XCTAssertTrue(controller.status.contains("now manages Calendar"), controller.status)
        // The displaced device disconnects without removing entries the new owner manages.
        await controller.disconnect()
        XCTAssertFalse(controller.connected); XCTAssertEqual(events().count, 1)
        assertColleaguePreserved()
        // Older versions cached unknown URLs. That cache must not authorize deletion.
        var cachedIDs = otherDefaults.dictionary(forKey: "calendar.eventIDs") as? [String: String] ?? [:]
        cachedIDs[colleagueKey] = colleague.eventIdentifier
        otherDefaults.set(cachedIDs, forKey: "calendar.eventIDs")
        await other.disconnect(); XCTAssertFalse(other.connected, other.status)
        XCTAssertTrue(events().isEmpty, "Disconnect must remove the owner's entries")
        assertColleaguePreserved()
        await controller.connect(calendar.calendarIdentifier)
        XCTAssertTrue(controller.connected, controller.status)
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
        assertColleaguePreserved()
        // Switching away also removes only this account's entries.
        draft.bookingStatus = .booked; try draft.save(in: context, editing: jobID)
        await controller.connect(calendar.calendarIdentifier)
        let switchCalendar = EKCalendar(for: .event, eventStore: eventStore)
        switchCalendar.title = "Cuekeeper switch test \(UUID())"
        switchCalendar.source = try XCTUnwrap(eventStore.sources.first { $0.sourceType == .local })
        try eventStore.saveCalendar(switchCalendar, commit: true)
        await controller.connect(switchCalendar.calendarIdentifier)
        XCTAssertEqual(controller.selectedID, switchCalendar.calendarIdentifier, controller.status)
        XCTAssertEqual(events().map(\.title), ["Unmanaged"])
        assertColleaguePreserved()
        await controller.disconnect()
        try eventStore.removeCalendar(switchCalendar, commit: true)
        // Deleting the selected calendar must not prevent switching to a replacement.
        draft.bookingStatus = .booked; try draft.save(in: context, editing: jobID)
        await controller.connect(calendar.calendarIdentifier)
        XCTAssertTrue(controller.connected, controller.status)
        // Ownership verification above resets the store; resolve fresh EventKit objects.
        let selectedCalendar = try XCTUnwrap(eventStore.calendar(withIdentifier: controller.selectedID))
        try eventStore.removeCalendar(selectedCalendar, commit: true)
        let replacement = EKCalendar(for: .event, eventStore: eventStore)
        replacement.title = "Cuekeeper replacement test \(UUID())"
        replacement.source = try XCTUnwrap(eventStore.sources.first { $0.sourceType == .local })
        try eventStore.saveCalendar(replacement, commit: true)
        defer { try? eventStore.removeCalendar(replacement, commit: true) }
        await controller.connect(replacement.calendarIdentifier)
        XCTAssertEqual(controller.selectedID, replacement.calendarIdentifier, controller.status)
        XCTAssertEqual(defaults.string(forKey: "calendar.selected"), replacement.calendarIdentifier)
        let replacementEvents = eventStore.events(matching: eventStore.predicateForEvents(
            withStart: Date().addingTimeInterval(-86400 * 2), end: Date().addingTimeInterval(86400 * 8), calendars: [replacement]))
        XCTAssertEqual(replacementEvents.count, 1, controller.status)
        // Disconnect still clears local state and releases ownership after deletion.
        try eventStore.removeCalendar(replacement, commit: true)
        await controller.disconnect()
        XCTAssertFalse(controller.connected, controller.status)
        XCTAssertNil(defaults.string(forKey: "calendar.selected"))
        XCTAssertNil(defaults.dictionary(forKey: "calendar.eventIDs"))
        let owner = await publisher.owner
        XCTAssertNil(owner)
    }
}
