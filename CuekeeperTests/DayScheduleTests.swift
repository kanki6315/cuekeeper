import XCTest
@testable import Cuekeeper

final class DayScheduleTests: XCTestCase {
    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    private var calendar: Calendar { var value = Calendar(identifier: .gregorian); value.timeZone = TimeZone(identifier: "America/New_York")!; return value }
    private let eventID = UUID()
    private func event(_ status: String = "booked") -> ScheduleEvent { ScheduleEvent(id: eventID, title: "Race weekend", client: "Client", startDay: "2026-11-01", endDay: "2026-11-01", status: status) }
    private func session(_ start: String?, end: String? = nil, call: String? = nil, confirmed: Bool = true, coverage: String = "covering", day: String = "") -> ScheduleSession {
        ScheduleSession(id: UUID(), eventID: eventID, title: "Session", day: day, start: start.map(date), end: end.map(date), call: call.map(date), zone: "America/New_York", confirmed: confirmed, coverage: coverage)
    }
    func testTodayIncludesOvernightAndEntireDSTDayButNotNextMidnight() {
        let prior = session("2026-11-01T03:00:00Z", end: "2026-11-01T05:00:00Z")
        let late = session("2026-11-02T04:30:00Z", end: "2026-11-02T04:59:00Z")
        let tomorrow = session("2026-11-02T05:00:00Z")
        let schedule = DaySchedule(events: [event()], sessions: [tomorrow, late, prior])
        XCTAssertEqual(schedule.today(at: date("2026-11-01T16:00:00Z"), calendar: calendar).map(\.id), [prior.id, late.id])
    }
    func testNextCallRequiresBookedConfirmedCoveredWorkAndUsesCallOrder() {
        let tentative = session("2026-11-01T17:00:00Z", call: "2026-11-01T16:10:00Z", confirmed: false)
        let undecided = session("2026-11-01T18:00:00Z", call: "2026-11-01T16:15:00Z", coverage: "undecided")
        let next = session("2026-11-01T20:00:00Z", call: "2026-11-01T16:30:00Z")
        let other = session("2026-11-01T19:00:00Z", call: "2026-11-01T17:00:00Z")
        var schedule = DaySchedule(events: [event()], sessions: [tentative, undecided, other, next])
        let now = date("2026-11-01T16:00:00Z")
        XCTAssertEqual(schedule.nextCommitment(at: now, calendar: calendar)?.id, next.id)
        schedule.events = [event("tentative")]
        XCTAssertNil(schedule.nextCommitment(at: now, calendar: calendar))
    }
    func testWidgetsRetainInProgressButExcludeFinishedAndNotCovering() {
        let running = session("2026-11-01T15:00:00Z", end: "2026-11-01T17:00:00Z")
        let finished = session("2026-11-01T13:00:00Z", end: "2026-11-01T14:00:00Z")
        let excluded = session("2026-11-01T18:00:00Z", coverage: "notCovering")
        let schedule = DaySchedule(events: [event()], sessions: [finished, running, excluded])
        XCTAssertEqual(schedule.remaining(at: date("2026-11-01T16:00:00Z"), calendar: calendar).map(\.id), [running.id])
    }
    func testIncompleteScheduleAndCancelledEvent() throws {
        let now = date("2026-11-01T16:00:00Z")
        var schedule = DaySchedule(events: [event()], sessions: [])
        XCTAssertEqual(schedule.unscheduledEvents(at: now, calendar: calendar).count, 1)
        schedule.sessions = [session(nil, confirmed: false, day: "2026-11-01")]
        XCTAssertEqual(schedule.today(at: now, calendar: calendar).count, 1)
        XCTAssertNil(schedule.nextCommitment(at: now, calendar: calendar))
        XCTAssertTrue(schedule.unscheduledEvents(at: now, calendar: calendar).isEmpty)
        XCTAssertEqual(try JSONDecoder().decode(DaySchedule.self, from: JSONEncoder().encode(schedule)), schedule)
        schedule.events = [event("cancelled")]
        XCTAssertTrue(schedule.today(at: now, calendar: calendar).isEmpty)
    }
}

@MainActor
final class ScheduleCaptureTests: XCTestCase {
    func testCaptureExcludesCancelledSessionsAndRetainsTentativeAndConfirmedSessions() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = PersistenceController(storeURL: folder.appendingPathComponent("test.sqlite"), cloudEnabled: false)
        try await store.waitUntilLoaded()
        defer {
            store.container.viewContext.reset()
            for persistent in store.container.persistentStoreCoordinator.persistentStores { try? store.container.persistentStoreCoordinator.remove(persistent) }
            try? FileManager.default.removeItem(at: folder)
        }
        let context = store.container.viewContext
        var draft = JobDraft(name: "Race weekend")
        draft.timeZoneID = "America/New_York"
        let id = try draft.save(in: context)
        let job = try XCTUnwrap(context.existingObject(with: id) as? Job)
        job.bookingStatus = "booked"
        try context.save()
        let now = ISO8601DateFormatter().date(from: "2026-11-01T16:00:00Z")!
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: draft.timeZoneID)!
        for status in ["tentative", "confirmed"] {
            var row = SessionDraft(job: job)
            row.name = status
            row.scheduleStatus = status
            row.coverage = "covering"
            row.startTime = now.addingTimeInterval(3600)
            row.endTime = now.addingTimeInterval(7200)
            try row.save(in: context, jobID: id)
        }
        let before = try DaySchedule.capture(in: context)
        XCTAssertEqual(Set(before.sessions.map(\.title)), ["tentative", "confirmed"])
        XCTAssertEqual(before.sessions.first { $0.title == "tentative" }?.confirmed, false)
        XCTAssertEqual(before.sessions.first { $0.title == "confirmed" }?.confirmed, true)

        let cancelled = try XCTUnwrap(job.activeSessions.first { $0.scheduleStatus == "confirmed" })
        cancelled.scheduleStatus = "cancelled"
        try context.save()
        let snapshot = try DaySchedule.capture(in: context)
        XCTAssertNotEqual(snapshot, before)
        XCTAssertEqual(snapshot.events, before.events)
        XCTAssertEqual(snapshot.sessions.map(\.title), ["tentative"])
        XCTAssertEqual(snapshot.today(at: now, calendar: calendar).map(\.title), ["tentative"])
        XCTAssertEqual(snapshot.remaining(at: now, calendar: calendar).map(\.title), ["tentative"])
        XCTAssertNil(snapshot.nextCommitment(at: now, calendar: calendar))
    }

    func testCaptureTracksRenamesAndDeletionWithoutFinancialOrPrivateFields() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = PersistenceController(storeURL: folder.appendingPathComponent("test.sqlite"), cloudEnabled: false)
        try await store.waitUntilLoaded()
        defer {
            store.container.viewContext.reset()
            for persistent in store.container.persistentStoreCoordinator.persistentStores { try? store.container.persistentStoreCoordinator.remove(persistent) }
            try? FileManager.default.removeItem(at: folder)
        }
        let context = store.container.viewContext
        var draft = JobDraft(name: "Race weekend")
        draft.clientName = "Network"; draft.timeZoneID = "Europe/London"; draft.notes = "PRIVATE_NOTES"
        draft.fee?.amount = "12345"
        let id = try draft.save(in: context)
        let job = try XCTUnwrap(context.existingObject(with: id) as? Job)
        var row = SessionDraft(job: job)
        row.name = "Qualifying"; row.notes = "PRIVATE_SESSION"
        row.startTime = Date().addingTimeInterval(3600); row.endTime = Date().addingTimeInterval(7200)
        row.links = [LinkDraft(url: "https://example.com/private-feed")]
        try row.save(in: context, jobID: id)
        var snapshot = try DaySchedule.capture(in: context)
        XCTAssertEqual(snapshot.events.first?.title, "Race weekend")
        XCTAssertEqual(snapshot.sessions.count, 1)
        let data = try XCTUnwrap(String(data: JSONEncoder().encode(snapshot), encoding: .utf8))
        for secret in ["PRIVATE_NOTES", "PRIVATE_SESSION", "private-feed", "12345"] { XCTAssertFalse(data.contains(secret)) }
        job.client?.name = "Renamed network"
        try context.save()
        XCTAssertEqual(try DaySchedule.capture(in: context).events.first?.client, "Renamed network")
        try Job.remove(id, in: context)
        snapshot = try DaySchedule.capture(in: context)
        XCTAssertTrue(snapshot.events.isEmpty)
        XCTAssertTrue(snapshot.sessions.isEmpty)
    }
}
