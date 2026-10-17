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
    func testCalendarLinksResolveRecordsAndRejectUnavailableTargets() throws {
        let modelURL = try XCTUnwrap(Bundle.main.url(forResource: "Cuekeeper", withExtension: "momd"))
        let model = try XCTUnwrap(NSManagedObjectModel(contentsOf: modelURL))
        let container = NSPersistentContainer(name: "Cuekeeper", managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        description.type = NSInMemoryStoreType
        container.persistentStoreDescriptions = [description]
        container.loadPersistentStores { _, error in XCTAssertNil(error) }
        let context = container.viewContext
        let job = Job(entity: NSEntityDescription.entity(forEntityName: "Job", in: context)!, insertInto: context)
        job.id = UUID()
        let event = WorkEvent(entity: NSEntityDescription.entity(forEntityName: "WorkEvent", in: context)!, insertInto: context)
        event.id = UUID()
        job.event = event
        let session = WorkSession(entity: NSEntityDescription.entity(forEntityName: "WorkSession", in: context)!, insertInto: context)
        session.id = UUID()
        session.job = job

        func link(_ kind: String, _ id: UUID) throws -> CalendarLink {
            try XCTUnwrap(CalendarLink(url: XCTUnwrap(URL(string: "cuekeeper://calendar/\(kind)/\(id)"))))
        }
        let jobLink = try link("job", XCTUnwrap(job.id))
        let eventLink = try link("event", XCTUnwrap(event.id))
        let sessionLink = try link("session", XCTUnwrap(session.id))
        for route in [jobLink, eventLink] {
            guard case .job(let resolved) = try route.resolve(in: context) else { return XCTFail("Expected event detail") }
            XCTAssertEqual(resolved, job)
        }
        guard case .session(let resolved) = try sessionLink.resolve(in: context) else { return XCTFail("Expected session detail") }
        XCTAssertEqual(resolved, session)
        XCTAssertNil(try link("job", UUID()).resolve(in: context))
        session.deletedAt = Date()
        XCTAssertNil(try sessionLink.resolve(in: context))
        session.deletedAt = nil
        session.job = nil
        XCTAssertNil(try sessionLink.resolve(in: context))
        session.job = job
        job.deletedAt = Date()
        for route in [jobLink, eventLink, sessionLink] { XCTAssertNil(try route.resolve(in: context)) }

        for url in ["cuekeeper://today", "https://calendar/job/\(UUID())", "cuekeeper://calendar/unknown/\(UUID())",
                    "cuekeeper://calendar/job/not-a-uuid", "cuekeeper://calendar/job/\(UUID())/extra"] {
            XCTAssertNil(CalendarLink(url: try XCTUnwrap(URL(string: url))))
        }
    }

    func testDeviceIdentitySurvivesReinstallButNotRestoreToAnotherDevice() throws {
        final class Keychain { var id: String?; var locked = false; var rejectsWrites = false }
        func identity(_ keychain: Keychain) -> CalendarDeviceIdentity {
            CalendarDeviceIdentity(read: { keychain.locked ? .unavailable : keychain.id.map { .found($0) } ?? .missing },
                                   write: { guard !keychain.rejectsWrites else { return false }; keychain.id = $0; return true })
        }
        func freshDefaults() throws -> UserDefaults {
            let suite = "calendar-identity-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
            return defaults
        }
        func resolve(_ defaults: UserDefaults, _ keychain: Keychain, vendor: String? = "phone") -> String {
            CalendarDeviceIdentity.resolve(defaults: defaults, keychain: identity(keychain), vendor: vendor)
        }
        func restore(_ defaults: UserDefaults) throws -> UserDefaults {
            let restored = try freshDefaults()
            for (key, value) in defaults.dictionaryRepresentation() where key.hasPrefix("calendar.") { restored.set(value, forKey: key) }
            return restored
        }
        // Upgrade: the pre-Keychain ID is kept so the current owner keeps its claim.
        let phone = Keychain(), defaults = try freshDefaults()
        defaults.set("legacy", forKey: CalendarDeviceIdentity.legacyKey)
        XCTAssertEqual(resolve(defaults, phone), "legacy")
        XCTAssertEqual(phone.id, "legacy")
        // Reinstall wipes defaults (and may change the vendor ID) but not the Keychain item.
        XCTAssertEqual(resolve(try freshDefaults(), phone, vendor: "reinstalled"), "legacy")
        // A locked Keychain falls back to the cached copy rather than a new identity.
        phone.locked = true
        XCTAssertEqual(resolve(defaults, phone), "legacy")
        // Restoring these defaults onto another phone must not copy the identity.
        let newPhone = Keychain()
        let newID = resolve(try restore(defaults), newPhone, vendor: "new-phone")
        XCTAssertNotEqual(newID, "legacy")
        XCTAssertEqual(newPhone.id, newID)

        // Missing item and failed writes: repeated launches keep one persisted fallback,
        // which becomes durable once the Keychain accepts it.
        let flaky = Keychain(); flaky.rejectsWrites = true
        let flakyDefaults = try freshDefaults()
        let fallback = resolve(flakyDefaults, flaky)
        XCTAssertNil(flaky.id)
        XCTAssertEqual(resolve(flakyDefaults, flaky), fallback)
        flaky.locked = true
        XCTAssertEqual(resolve(flakyDefaults, flaky), fallback)
        // That fallback must not follow a restore onto another device, locked or not.
        let other = Keychain(); other.rejectsWrites = true
        XCTAssertNotEqual(resolve(try restore(flakyDefaults), other, vendor: "other-phone"), fallback)
        other.locked = true
        XCTAssertNotEqual(resolve(try restore(flakyDefaults), other, vendor: "other-phone"), fallback)
        flaky.locked = false; flaky.rejectsWrites = false
        XCTAssertEqual(resolve(flakyDefaults, flaky), fallback)
        XCTAssertEqual(flaky.id, fallback)
        XCTAssertEqual(resolve(try freshDefaults(), flaky), fallback, "Durable after the write succeeds, so reinstalls keep it")

        // Locked with no cached copy: the new ID is persisted, not regenerated per launch.
        let locked = Keychain(); locked.locked = true
        let lockedDefaults = try freshDefaults()
        let first = resolve(lockedDefaults, locked)
        XCTAssertEqual(resolve(lockedDefaults, locked), first)
        locked.locked = false
        XCTAssertEqual(resolve(lockedDefaults, locked), first)
        XCTAssertEqual(locked.id, first)
    }

    func testCalendarCleanupAndSelectionStates() {
        func message(fullAccess: Bool, _ calendar: (String, Bool)?) -> String? {
            do { try CalendarCleanup.check(fullAccess: fullAccess, calendar: calendar); return nil }
            catch { return error.localizedDescription }
        }
        XCTAssertNil(message(fullAccess: true, ("Work", true)), "Writable")
        XCTAssertNil(message(fullAccess: true, nil), "Missing: nothing left to remove")
        XCTAssertEqual(message(fullAccess: true, ("Holidays", false)), "“Holidays” is read-only, so Cuekeeper’s entries there can’t be removed.")
        XCTAssertNotNil(message(fullAccess: false, nil), "Permission denied hides the calendar; don't treat it as missing")
        let blocked = CalendarSwitchBlocked(reason: "Read-only.").localizedDescription
        XCTAssertTrue(blocked.contains("Switch and Leave Old Entries") && !blocked.contains("removed"), blocked)

        XCTAssertEqual(CalendarController.validSelection("b", connected: "a", available: ["a", "b"]), "b")
        XCTAssertEqual(CalendarController.validSelection("gone", connected: "a", available: ["a"]), "a")
        XCTAssertEqual(CalendarController.validSelection("gone", connected: "also-gone", available: ["c"]), "")
    }

    func testPlaceSelectionAppliesOnlyTheLatestChoice() {
        var selection = PlaceSelection()
        let location = selection.begin()
        let track = selection.begin()
        // The track was chosen last, so a slower location lookup must not win.
        XCTAssertEqual(selection.finish(track, zone: TimeZone(identifier: "America/Vancouver"))?.identifier, "America/Vancouver")
        XCTAssertNil(selection.finish(location, zone: TimeZone(identifier: "America/Los_Angeles")))
        XCTAssertFalse(selection.pending)
        let edited = selection.begin()
        selection.cancel()
        XCTAssertNil(selection.finish(edited, zone: TimeZone(identifier: "Europe/London")))
        XCTAssertFalse(selection.pending)
        let failed = selection.begin()
        XCTAssertNil(selection.finish(failed, zone: nil))
        XCTAssertTrue(selection.failed)
        XCTAssertFalse(selection.pending)
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

    func testSkippedMidnightCivilDatesParseAndKeepTheirPlaceholders() throws {
        // Santiago and Cairo skip 00:00 on these days; the day itself starts at 01:00.
        for (zoneID, day, next) in [("America/Santiago", "2026-09-06", "2026-09-07"), ("Africa/Cairo", "2026-04-24", "2026-04-25")] {
            let zone = try XCTUnwrap(TimeZone(identifier: zoneID))
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
            let start = try XCTUnwrap(Day.date(from: day, timeZone: zone), zoneID)
            XCTAssertEqual(calendar.component(.hour, from: start), 1)
            XCTAssertEqual(Day.string(from: start, timeZone: zone), day)
            XCTAssertEqual(Day.days(from: day, to: next), 1)
            XCTAssertTrue(EventWeatherRequest(placeID: "place", bookingStatus: "booked", arrangement: "onSite", startDay: day, endDay: day)
                .eligible(now: start, timeZone: zone))

            var session = SessionDraft(day: day, timeZoneID: zoneID)
            session.startTime = start.addingTimeInterval(9 * 3600)
            session.moveSchedule(to: try XCTUnwrap(Day.date(from: next, timeZone: zone)), zone: zone)
            XCTAssertEqual(session.day, next)
            XCTAssertEqual(session.startTime.map { Day.string(from: $0, timeZone: zone) }, next, "The times move with the day")

            let container = NSPersistentContainer(name: "Cuekeeper", managedObjectModel: try XCTUnwrap(NSManagedObjectModel(contentsOf: try XCTUnwrap(Bundle.main.url(forResource: "Cuekeeper", withExtension: "momd")))))
            let description = NSPersistentStoreDescription(); description.type = NSInMemoryStoreType
            container.persistentStoreDescriptions = [description]
            container.loadPersistentStores { _, error in XCTAssertNil(error) }
            let job = Job(entity: NSEntityDescription.entity(forEntityName: "Job", in: container.viewContext)!, insertInto: container.viewContext)
            job.id = UUID(); job.name = "Skipped midnight"; job.startDay = day; job.endDay = day; job.timeZoneID = zoneID
            let placeholder = try XCTUnwrap(CalendarPlan(jobs: [job]).desired["job/\(job.id!.uuidString)"], "Kept, so reconciliation won't delete it")
            XCTAssertEqual(placeholder.start, start)
            XCTAssertEqual(placeholder.end, Day.date(from: next, timeZone: zone))
            XCTAssertEqual(placeholder.end.timeIntervalSince(placeholder.start), 23 * 3600)
        }
        // Ordinary DST days, leap days and travel keep their day; impossible dates are still rejected.
        for zoneID in ["America/New_York", "Europe/London", "Australia/Sydney", "America/Santiago"] {
            let zone = try XCTUnwrap(TimeZone(identifier: zoneID))
            for day in ["2026-03-08", "2026-11-01", "2026-04-05", "2028-02-29", "2026-09-06"] {
                XCTAssertEqual(Day.date(from: day, timeZone: zone).map { Day.string(from: $0, timeZone: zone) }, day, "\(zoneID) \(day)")
            }
        }
        for invalid in ["2026-02-29", "2027-02-30", "2026-13-01", "2026-04-31", "2026-00-10", "2026-9-6", "2026-09-06T00", "", "２０２６-09-06"] {
            XCTAssertNil(Day.date(from: invalid), invalid)
            XCTAssertNil(Day.components(invalid), invalid)
        }
        XCTAssertNil(Day.date(from: "2011-12-30", timeZone: TimeZone(identifier: "Pacific/Apia")!), "Samoa skipped the whole day")
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

    func testProviderTextNormalizationDoesNotRepublishUnchangedSource() throws {
        var entry = CalendarEntry(key: "session/\(UUID())", title: "Title ", start: Date(timeIntervalSince1970: 1791982800),
                                  end: Date(timeIntervalSince1970: 1791986400), allDay: false, timeZoneID: "UTC", notes: "Notes\n", location: "Venue ")
        let event = EKEvent(eventStore: EKEventStore())
        XCTAssertTrue(CalendarController.update(event, from: entry))
        let published = entry
        event.title = "Title"; event.notes = "<html><body>Notes</body></html>"; event.location = "Venue"
        for _ in 0..<3 { XCTAssertFalse(CalendarController.update(event, from: entry, lastPublished: published)) }
        entry.start = entry.start.addingTimeInterval(3600); entry.end = entry.end.addingTimeInterval(3600)
        XCTAssertTrue(CalendarController.update(event, from: entry, lastPublished: published))
        XCTAssertEqual(event.notes, "<html><body>Notes</body></html>")
        entry.notes = "Changed in Cuekeeper"
        XCTAssertTrue(CalendarController.update(event, from: entry, lastPublished: published))
        XCTAssertEqual(event.notes, entry.notes)
        XCTAssertEqual(event.title, "Title")
        // A genuinely new entry must be populated even if its source is unchanged.
        let replacement = EKEvent(eventStore: EKEventStore())
        XCTAssertTrue(CalendarController.update(replacement, from: entry))
        XCTAssertEqual(replacement.title, entry.title)
        let state = CalendarPublishedState(calendarID: "calendar-a", entries: ["event-id": entry])
        let reopened = try JSONDecoder().decode(CalendarPublishedState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(reopened.entry(calendarID: "calendar-a", eventID: "event-id"), entry)
        XCTAssertNil(reopened.entry(calendarID: "calendar-b", eventID: "event-id"))
        XCTAssertNil(reopened.entry(calendarID: "calendar-a", eventID: "replacement-id"))
    }

    func testLocalDisconnectNeedsNeitherCalendarAccessNorPublisher() async throws {
        let suite = "local-disconnect-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("unavailable-calendar", forKey: "calendar.selected")
        defaults.set(["key": "id"], forKey: "calendar.eventIDs")
        let publisher = TestCalendarPublisher()
        try await publisher.claim(deviceID: "first", name: "Device")
        let controller = CalendarController(defaults: defaults, publisher: publisher, deviceID: "first")
        controller.disconnectKeepingEntries()
        XCTAssertFalse(controller.connected)
        XCTAssertNil(defaults.string(forKey: "calendar.selected"))
        XCTAssertNil(defaults.dictionary(forKey: "calendar.eventIDs"))
        let owner = await publisher.owner
        XCTAssertEqual(owner, "first", "Local disconnect must not depend on contacting iCloud")
        XCTAssertFalse(CalendarController(defaults: defaults).connected)
        let permit = CalendarSyncPermit()
        permit.cancel()
        var committed = false
        XCTAssertThrowsError(try permit.commit { committed = true })
        XCTAssertFalse(committed)
    }

    func testExternalRoutesRetainDistinctRequestsAndDeduplicateActiveRoutes() {
        let queue = ExternalPresentations()
        let first = ExternalPresentation.expense(UUID())
        let second = ExternalPresentation.receipt
        queue.enqueue(first); queue.enqueue(first); queue.enqueue(second)
        XCTAssertEqual(queue.waiting.map(\.id), [first.id, second.id])
        queue.didPresent(first)
        queue.enqueue(first)
        XCTAssertEqual(queue.waiting.map(\.id), [second.id])
        queue.didClose(first); queue.enqueue(first)
        XCTAssertEqual(queue.waiting.map(\.id), [second.id, first.id])
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
        XCTAssertEqual(events().first?.alarms ?? [], [])
        XCTAssertNil(events().first?.timeZone)
        XCTAssertEqual(events().first?.startDate, Day.date(from: job.startDay, timeZone: .current))
        let lastDay = try XCTUnwrap(Day.date(from: job.endDay, timeZone: .current))
        let exclusiveEnd = try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: lastDay))
        XCTAssertEqual(events().first?.endDate, exclusiveEnd.addingTimeInterval(-1))
        let desired = try XCTUnwrap(CalendarPlan(jobs: [job]).desired.values.first)
        XCTAssertFalse(CalendarController.update(try XCTUnwrap(events().first), from: desired))
        // Simulate provider normalization without changing the ownership marker.
        let normalized = try XCTUnwrap(events().first)
        normalized.notes = "<html><body>Provider-formatted notes</body></html>"
        normalized.title = "Provider-normalized title"
        try eventStore.save(normalized, span: .thisEvent)
        await controller.sync()
        XCTAssertEqual(events().first?.notes, normalized.notes)
        XCTAssertEqual(events().first?.title, "Provider-normalized title")
        XCTAssertNotNil(defaults.data(forKey: "calendar.lastPublished"))
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

    func testTakeoverFindsOldPublicationsAndSwitchCanLeaveEntries() async throws {
        let eventStore = EKEventStore()
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw XCTSkip("Grant Calendar access to the test app with simctl privacy before running the EventKit integration test.")
        }
        let source = try XCTUnwrap(eventStore.sources.first { $0.sourceType == .local })
        func makeCalendar(_ title: String) throws -> EKCalendar {
            let calendar = EKCalendar(for: .event, eventStore: eventStore)
            calendar.title = "\(title) \(UUID())"; calendar.source = source
            try eventStore.saveCalendar(calendar, commit: true)
            return calendar
        }
        let old = try makeCalendar("Cuekeeper takeover test")
        defer { try? eventStore.removeCalendar(old, commit: true) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let persistence = PersistenceController(storeURL: directory.appendingPathComponent("test.sqlite"), cloudEnabled: false)
        for _ in 0..<100 where !persistence.isLoaded { try await Task.sleep(for: .milliseconds(50)) }
        let context = persistence.container.viewContext
        let longAgo = Date(timeIntervalSince1970: try XCTUnwrap(Calendar.current.date(byAdding: .year, value: -3, to: Date())).timeIntervalSince1970.rounded())
        let jobID = try JobDraft(name: "Moved job", startDate: longAgo, endDate: longAgo).save(in: context)
        let job = try XCTUnwrap(context.existingObject(with: jobID) as? Job)
        func defaults() throws -> UserDefaults {
            let suite = "calendar-takeover-\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
            return defaults
        }
        func entries(_ calendar: EKCalendar) -> [EKEvent] {
            // A separate store sees committed changes without invalidating the test's objects.
            let reader = EKEventStore()
            let fresh = reader.calendar(withIdentifier: calendar.calendarIdentifier).map { [$0] } ?? []
            return reader.events(matching: reader.predicateForEvents(withStart: Date().addingTimeInterval(-86400 * 1300), end: Date().addingTimeInterval(86400 * 100), calendars: fresh))
        }
        let publisher = TestCalendarPublisher()
        let first = CalendarController(defaults: try defaults(), store: eventStore, publisher: publisher, deviceID: "first")
        first.start(context: context, enabled: true)
        await first.connect(old.calendarIdentifier)
        XCTAssertEqual(entries(old).map { Calendar.current.isDate($0.startDate, inSameDayAs: longAgo) }, [true], first.status)
        // An unrelated entry at the old date, e.g. a colleague's, must stay untouched.
        let colleague = EKEvent(eventStore: eventStore)
        colleague.calendar = old; colleague.title = "Colleague"
        colleague.startDate = longAgo; colleague.endDate = longAgo.addingTimeInterval(3600)
        colleague.url = URL(string: "cuekeeper://calendar/job/\(UUID())")
        try eventStore.save(colleague, span: .thisEvent)
        // The first device goes away before publishing the job's new date.
        first.disconnectKeepingEntries()
        var draft = JobDraft(job: job); draft.startDate = Date(); draft.endDate = Date()
        try draft.save(in: context, editing: jobID)

        let second = CalendarController(defaults: try defaults(), store: eventStore, publisher: publisher, deviceID: "second")
        second.start(context: context, enabled: true)
        await second.takeOver(old.calendarIdentifier)
        XCTAssertTrue(second.connected, second.status)
        let managed = entries(old).filter { $0.title != "Colleague" }
        XCTAssertEqual(managed.count, 1, "The old publication is adopted rather than duplicated")
        XCTAssertTrue(managed.allSatisfy { Calendar.current.isDateInToday($0.startDate) }, second.status)
        XCTAssertEqual(entries(old).filter { $0.title == "Colleague" }.map(\.startDate), [longAgo])

        // Calendar choices refresh while Settings stays open.
        let next = try makeCalendar("Cuekeeper switch-keep test")
        defer { try? eventStore.removeCalendar(next, commit: true) }
        for _ in 0..<100 where !second.calendars.contains(where: { $0.calendarIdentifier == next.calendarIdentifier }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertTrue(second.calendars.contains { $0.calendarIdentifier == next.calendarIdentifier }, "Added calendar appears")
        // Switching and leaving entries keeps the old calendar's entry and says so.
        await second.connect(next.calendarIdentifier, leavingOldEntries: true)
        XCTAssertEqual(second.selectedID, next.calendarIdentifier, second.status)
        XCTAssertEqual(entries(old).count, 2)
        XCTAssertEqual(entries(next).count, 1)
        XCTAssertTrue(second.status.contains("left in place"), second.status)
        XCTAssertNil(second.blockedSwitch)
        await second.disconnect()
        XCTAssertFalse(second.connected, second.status)
        XCTAssertTrue(entries(next).isEmpty)
        XCTAssertEqual(entries(old).count, 2, "Disconnect removes only the current calendar's entries")
        try eventStore.removeCalendar(try XCTUnwrap(eventStore.calendar(withIdentifier: next.calendarIdentifier)), commit: true)
        for _ in 0..<100 where second.calendars.contains(where: { $0.calendarIdentifier == next.calendarIdentifier }) {
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertFalse(second.calendars.contains { $0.calendarIdentifier == next.calendarIdentifier }, "Removed calendar disappears")
    }
}
