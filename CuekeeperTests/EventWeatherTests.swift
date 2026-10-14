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
        now = now.addingTimeInterval(7200)
        let reused = try await store.load(placeID: "track", location: location, timeZone: zone)
        XCTAssertTrue(reused.isOutdated(at: now)); XCTAssertEqual(calls, 1)
        let reopened = EventWeatherStore(fileURL: file, clock: { now }) { _, _ in calls += 1; return self.snapshot(now: now) }
        _ = try await reopened.load(placeID: "track", location: location, timeZone: zone)
        XCTAssertEqual(calls, 1)
        now = now.addingTimeInterval(22 * 3600)
        XCTAssertNil(reopened.cached(placeID: "track"))
        let persisted = try JSONDecoder().decode([String: EventWeatherStore.Entry].self, from: Data(contentsOf: file))
        XCTAssertNil(persisted["track"])
        _ = try await reopened.load(placeID: "track", location: location, timeZone: zone)
        XCTAssertEqual(calls, 2)
        _ = try await reopened.load(placeID: "another-track", location: location, timeZone: zone)
        XCTAssertEqual(calls, 3)
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
        now = now.addingTimeInterval(86400)
        do { _ = try await reopened.load(placeID: "track", location: location, timeZone: zone) } catch {}
        XCTAssertEqual(calls, 2)
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
