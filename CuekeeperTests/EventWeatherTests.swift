import CoreLocation
import XCTest
@testable import Cuekeeper

@MainActor
final class EventWeatherTests: XCTestCase {
    private let zone = TimeZone(identifier: "America/New_York")!
    private func date(_ day: String) -> Date { Day.date(from: day, timeZone: zone)! }
    private func request(start: String = "2026-10-13", end: String = "2026-10-13",
                         status: String = "booked", arrangement: String = "onSite", placeID: String = "track") -> EventWeatherRequest {
        EventWeatherRequest(placeID: placeID, bookingStatus: status, arrangement: arrangement, startDay: start, endDay: end)
    }
    private func snapshot(now: Date) -> EventWeatherSnapshot {
        EventWeatherSnapshot(fetchedAt: now, expiresAt: now.addingTimeInterval(3600), timeZoneID: zone.identifier,
            days: (0..<10).map { EventWeatherDay(date: now.addingTimeInterval(Double($0) * 86400), condition: "Clear", symbol: "sun.max", high: 25, low: 15, precipitation: 0.2, wind: 10) },
            hours: (0..<48).map { EventWeatherHour(date: now.addingTimeInterval(Double($0) * 3600), condition: "Clear", symbol: "sun.max", temperature: 20, precipitation: 0.2, wind: 10) },
            legalURL: URL(string: "https://example.com/legal")!, lightMarkURL: URL(string: "https://example.com/light")!, darkMarkURL: URL(string: "https://example.com/dark")!)
    }

    func testEligibilityRequiresBookedOnSiteAndTenVenueLocalDays() {
        let now = date("2026-10-13").addingTimeInterval(12 * 3600)
        XCTAssertTrue(request().eligible(now: now, timeZone: zone))
        XCTAssertTrue(request(start: "2026-10-22", end: "2026-10-22").eligible(now: now, timeZone: zone))
        XCTAssertFalse(request(start: "2026-10-23", end: "2026-10-23").eligible(now: now, timeZone: zone))
        XCTAssertTrue(request(start: "2026-10-11", end: "2026-10-15").eligible(now: now, timeZone: zone))
        XCTAssertFalse(request(start: "2026-10-11", end: "2026-10-12").eligible(now: now, timeZone: zone))
        for status in ["tentative", "completed", "cancelled"] { XCTAssertFalse(request(status: status).eligible(now: now, timeZone: zone)) }
        for arrangement in ["remote", "hybrid", "unspecified"] { XCTAssertFalse(request(arrangement: arrangement).eligible(now: now, timeZone: zone)) }
        XCTAssertFalse(request(placeID: "").eligible(now: now, timeZone: zone))
        XCTAssertFalse(request(start: "bad-date").eligible(now: now, timeZone: zone))
    }

    func testDateLineAndDSTUseCalendarDays() {
        let instant = ISO8601DateFormatter().date(from: "2026-10-13T12:00:00Z")!
        XCTAssertFalse(request().eligible(now: instant, timeZone: TimeZone(secondsFromGMT: 14 * 3600)!))
        XCTAssertTrue(request().eligible(now: instant, timeZone: TimeZone(secondsFromGMT: -12 * 3600)!))
        let beforeDST = date("2026-10-30")
        XCTAssertTrue(request(start: "2026-11-08", end: "2026-11-08").eligible(now: beforeDST, timeZone: zone))
        XCTAssertFalse(request(start: "2026-11-09", end: "2026-11-09").eligible(now: beforeDST, timeZone: zone))
    }

    func testOutdatedForecastStaysVisibleOnlyUntil24Hours() {
        let now = date("2026-10-13"), forecast = snapshot(now: date("2026-10-13"))
        XCTAssertFalse(forecast.isOutdated(at: now))
        XCTAssertTrue(forecast.isOutdated(at: now.addingTimeInterval(3600)))
        XCTAssertTrue(forecast.canDisplay(at: now.addingTimeInterval(86399)))
        XCTAssertFalse(forecast.canDisplay(at: now.addingTimeInterval(86400)))
        XCTAssertFalse(forecast.canDisplay(at: now.addingTimeInterval(-1)))
    }

    func testForecastSelectsEventDaysAndOverlappingSessionHours() {
        let now = date("2026-10-13"), forecast = snapshot(now: date("2026-10-13"))
        XCTAssertEqual(forecast.days(for: request(start: "2026-10-12", end: "2026-10-15"), now: now).count, 3)
        let start = now.addingTimeInterval(23.5 * 3600), end = now.addingTimeInterval(25 * 3600)
        let hours = forecast.hours(from: start, to: end)
        XCTAssertEqual(hours.count, 2)
        XCTAssertEqual(hours.first?.date, now.addingTimeInterval(23 * 3600))
        XCTAssertEqual(hours.last?.date, now.addingTimeInterval(24 * 3600))
    }

    func testCacheReuseAcrossJobsPersistsAcrossRelaunchAndExpires() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "cache.json")
        var now = date("2026-10-13"); var calls = 0
        let location = CLLocation(latitude: 29, longitude: -81)
        let store = EventWeatherStore(fileURL: file, clock: { now }) { _, _ in calls += 1; return self.snapshot(now: now) }
        _ = try await store.load(placeID: "track", location: location, timeZone: zone)
        now = now.addingTimeInterval(3599)
        let reused = try await store.load(placeID: "track", location: location, timeZone: zone)
        XCTAssertFalse(reused.isOutdated(at: now)); XCTAssertEqual(calls, 1)
        let reopened = EventWeatherStore(fileURL: file, clock: { now }) { _, _ in calls += 1; return self.snapshot(now: now) }
        _ = try await reopened.load(placeID: "track", location: location, timeZone: zone)
        XCTAssertEqual(calls, 1)
        now = now.addingTimeInterval(1)
        _ = try await reopened.load(placeID: "track", location: location, timeZone: zone)
        XCTAssertEqual(calls, 2)
        now = now.addingTimeInterval(86400)
        XCTAssertNil(reopened.cached(placeID: "track"))
        let persisted = try JSONDecoder().decode(EventWeatherStore.State.self, from: Data(contentsOf: file))
        XCTAssertNil(persisted.entries["track"])
        _ = try await reopened.load(placeID: "track", location: location, timeZone: zone)
        XCTAssertEqual(calls, 3)
        _ = try await reopened.load(placeID: "another-track", location: location, timeZone: zone)
        XCTAssertEqual(calls, 4)
    }

    func testFailedRequestsAreLimitedAcrossRelaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "cache.json")
        var now = date("2026-10-13"); var calls = 0
        let location = CLLocation(latitude: 29, longitude: -81)
        let store = EventWeatherStore(fileURL: file, clock: { now }) { _, _ in calls += 1; throw URLError(.notConnectedToInternet) }
        do { _ = try await store.load(placeID: "track", location: location, timeZone: zone); XCTFail("Expected network failure") } catch {}
        let reopened = EventWeatherStore(fileURL: file, clock: { now }) { _, _ in calls += 1; throw URLError(.notConnectedToInternet) }
        do { _ = try await reopened.load(placeID: "track", location: location, timeZone: zone); XCTFail("Expected daily limit") }
        catch { XCTAssertEqual(error as? EventWeatherStore.Failure, .dailyLimit) }
        XCTAssertEqual(calls, 1); XCTAssertNil(reopened.cached(placeID: "track"))
        now = now.addingTimeInterval(3600)
        do { _ = try await reopened.load(placeID: "track", location: location, timeZone: zone) } catch {}
        XCTAssertEqual(calls, 2)
    }

    func testDeviceBudgetIncludesFailuresAndSurvivesRelaunch() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appending(path: "cache.json")
        var now = date("2026-10-13")
        let start = now
        var calls = 0
        let location = CLLocation(latitude: 29, longitude: -81)
        let store = EventWeatherStore(fileURL: file, clock: { now }) { _, _ in
            calls += 1
            throw URLError(.notConnectedToInternet)
        }
        for index in 0..<24 {
            do { _ = try await store.load(placeID: "track-\(index)", location: location, timeZone: zone) } catch {}
        }
        XCTAssertEqual(calls, 24)
        let reopened = EventWeatherStore(fileURL: file, clock: { now }) { _, _ in
            calls += 1; return self.snapshot(now: now)
        }
        now = start.addingTimeInterval(86399)
        XCTAssertEqual(reopened.nextAttempt(placeID: "new-track"), start.addingTimeInterval(86400))
        do {
            _ = try await reopened.load(placeID: "new-track", location: location, timeZone: zone)
            XCTFail("Expected device budget limit")
        } catch { XCTAssertEqual(error as? EventWeatherStore.Failure, .dailyLimit) }
        XCTAssertEqual(calls, 24)
        now = start.addingTimeInterval(86400)
        _ = try await reopened.load(placeID: "new-track", location: location, timeZone: zone)
        XCTAssertEqual(calls, 25)
    }

    func testLegacyCacheMigratesWithoutResettingBudget() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "cache.json")
        let now = date("2026-10-13")
        let entries = Dictionary(uniqueKeysWithValues: (0..<24).map {
            ("track-\($0)", EventWeatherStore.Entry(attemptedAt: now, snapshot: nil))
        })
        try JSONEncoder().encode(entries).write(to: file)
        let store = EventWeatherStore(fileURL: file, clock: { now }) { _, _ in
            XCTFail("Migrated budget should prevent network access")
            return self.snapshot(now: now)
        }
        XCTAssertEqual(store.nextAttempt(placeID: "new-track"), now.addingTimeInterval(86400))
    }

    func testUndecodableSnapshotsRecoverWithoutResettingBudget() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "cache.json")
        let now = date("2026-10-13")
        let stamp = now.timeIntervalSinceReferenceDate
        let json = #"{"attempts":[\#(stamp)],"entries":{"track":{"attemptedAt":\#(stamp),"snapshot":{"futureField":true}}}}"#
        try Data(json.utf8).write(to: file)
        var calls = 0
        let store = EventWeatherStore(fileURL: file, clock: { now }) { _, _ in calls += 1; return self.snapshot(now: now) }
        XCTAssertNil(store.cached(placeID: "track"))
        XCTAssertEqual(store.nextAttempt(placeID: "track"), now.addingTimeInterval(3600))
        XCTAssertNil(store.nextAttempt(placeID: "another-track"))
        _ = try await store.load(placeID: "another-track", location: CLLocation(latitude: 29, longitude: -81), timeZone: zone)
        XCTAssertEqual(calls, 1)
        let persisted = try JSONDecoder().decode(EventWeatherStore.State.self, from: Data(contentsOf: file))
        XCTAssertEqual(persisted.attempts.count, 2)
    }

    func testUnreadableCacheSpendsBudgetUntilADayAfterLastWrite() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appending(path: "cache.json")
        var now = date("2026-10-13")
        try Data("not json".utf8).write(to: file)
        try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: file.path)
        var calls = 0
        let location = CLLocation(latitude: 29, longitude: -81)
        let store = EventWeatherStore(fileURL: file, clock: { now }) { _, _ in calls += 1; return self.snapshot(now: now) }
        do { _ = try await store.load(placeID: "track", location: location, timeZone: zone); XCTFail("Expected daily limit") }
        catch { XCTAssertEqual(error as? EventWeatherStore.Failure, .dailyLimit) }
        XCTAssertNoThrow(try JSONDecoder().decode(EventWeatherStore.State.self, from: Data(contentsOf: file)))
        now = now.addingTimeInterval(86400)
        let reopened = EventWeatherStore(fileURL: file, clock: { now }) { _, _ in calls += 1; return self.snapshot(now: now) }
        _ = try await reopened.load(placeID: "track", location: location, timeZone: zone)
        XCTAssertEqual(calls, 1)
    }

    func testConcurrentLoadsMakeOneRequest() async throws {
        var calls = 0
        let now = date("2026-10-13")
        let store = EventWeatherStore(fileURL: nil, clock: { now }) { _, _ in
            calls += 1; try await Task.sleep(for: .milliseconds(30)); return self.snapshot(now: now)
        }
        let location = CLLocation(latitude: 29, longitude: -81)
        async let first = store.load(placeID: "track", location: location, timeZone: zone)
        async let second = store.load(placeID: "track", location: location, timeZone: zone)
        _ = try await (first, second)
        XCTAssertEqual(calls, 1)
    }
}

final class SessionTimeInputTests: XCTestCase {
    func testClockFormatsAndInvalidInput() {
        let zone = TimeZone(identifier: "America/Chicago")!
        let day = Day.date(from: "2026-10-24", timeZone: zone)!
        for (input, hours) in [("9:30 AM", 9.5), ("21:30", 21.5), ("12 am", 0), ("12 PM", 12), ("9pm", 21)] {
            XCTAssertEqual(SessionTimeInput.date(input, on: day, zone: zone), day.addingTimeInterval(hours * 3600), input)
        }
        for input in ["", "25:00", "9:60", "0pm", "13am", "9:30junk", "-1"] {
            XCTAssertNil(SessionTimeInput.date(input, on: day, zone: zone), input)
        }
        let spring = Day.date(from: "2026-03-08", timeZone: zone)!
        XCTAssertNil(SessionTimeInput.date("2:30 AM", on: spring, zone: zone))
    }
}
