import Combine
import CoreLocation
import Foundation
import WeatherKit

/// Only the user-selected Place ID is synced. Forecasts and request limits stay on this device.
struct EventWeatherRequest: Equatable {
    let placeID: String
    let bookingStatus: String
    let arrangement: String
    let startDay: String
    let endDay: String

    func eligible(now: Date, timeZone: TimeZone) -> Bool {
        guard bookingStatus == "booked", arrangement == "onSite", !placeID.isEmpty,
              let start = Day.date(from: startDay, timeZone: timeZone),
              let end = Day.date(from: endDay, timeZone: timeZone), start <= end else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        let horizon = calendar.date(byAdding: .day, value: 10, to: today)!
        return end >= today && start < horizon
    }
}

struct EventWeatherDay: Codable, Identifiable {
    var id: Date { date }
    let date: Date
    let condition: String
    let symbol: String
    let high: Double
    let low: Double
    let precipitation: Double
    let wind: Double
}

struct EventWeatherHour: Codable, Identifiable {
    var id: Date { date }
    let date: Date
    let condition: String
    let symbol: String
    let temperature: Double
    let precipitation: Double
    let wind: Double
}

struct EventWeatherSnapshot: Codable {
    let fetchedAt: Date
    let expiresAt: Date
    let timeZoneID: String
    let days: [EventWeatherDay]
    let hours: [EventWeatherHour]
    let legalURL: URL
    let lightMarkURL: URL
    let darkMarkURL: URL

    static let lifetime: TimeInterval = 24 * 60 * 60
    func canDisplay(at now: Date) -> Bool {
        now >= fetchedAt && now.timeIntervalSince(fetchedAt) < Self.lifetime
    }
    func isOutdated(at now: Date) -> Bool { now >= expiresAt }
    var timeZone: TimeZone { TimeZone(identifier: timeZoneID) ?? .gmt }

    func days(for request: EventWeatherRequest, now: Date) -> [EventWeatherDay] {
        let today = Day.string(from: now, timeZone: timeZone)
        return days.filter {
            let day = Day.string(from: $0.date, timeZone: timeZone)
            return day >= today && day >= request.startDay && day <= request.endDay
        }
    }

    func hours(from start: Date, to end: Date) -> [EventWeatherHour] {
        guard end > start else { return [] }
        return hours.filter { $0.date < end && $0.date.addingTimeInterval(3600) > start }
    }
}

/// Hourly attempts per place, with a shared rolling 24-hour device budget (including failures).
/// Persist the attempt before calling Apple so relaunching cannot bypass the limit.
@MainActor
final class EventWeatherStore {
    static let shared: EventWeatherStore = {
        let testing = ProcessInfo.processInfo.arguments.contains("--ui-testing") || NSClassFromString("XCTestCase") != nil
        return EventWeatherStore(fileURL: testing ? nil : URL.applicationSupportDirectory.appending(path: "Weather/local-cache.json"))
    }()
    struct Entry: Codable {
        let attemptedAt: Date
        var snapshot: EventWeatherSnapshot?
    }
    static let refreshInterval: TimeInterval = 60 * 60
    static let budgetWindow: TimeInterval = 24 * 60 * 60
    static let dailyFetchLimit = 24
    struct State: Codable {
        var entries: [String: Entry]
        var attempts: [Date]
    }
    private var attempts: [Date] = []
    private var entries: [String: Entry] = [:]
    private var inFlight: [String: Task<EventWeatherSnapshot, Error>] = [:]
    private let fileURL: URL?
    private let clock: () -> Date
    private let fetch: (CLLocation, TimeZone) async throws -> EventWeatherSnapshot
    private var storageFailed = false

    init(fileURL: URL?, clock: @escaping () -> Date = Date.init,
         fetch: @escaping (CLLocation, TimeZone) async throws -> EventWeatherSnapshot = EventWeatherStore.fetchWeather) {
        self.fileURL = fileURL; self.clock = clock; self.fetch = fetch
        if let fileURL, FileManager.default.fileExists(atPath: fileURL.path) {
            do {
                let data = try Data(contentsOf: fileURL)
                if let state = try? JSONDecoder().decode(State.self, from: data) {
                    entries = state.entries; attempts = state.attempts
                } else {
                    // Preserve attempts from the original per-place cache during migration.
                    entries = try JSONDecoder().decode([String: Entry].self, from: data)
                    attempts = entries.values.map(\.attemptedAt)
                }
            }
            catch { storageFailed = true } // Fail closed instead of silently resetting the request budget.
        }
        purgeExpired()
    }

    func cached(placeID: String) -> EventWeatherSnapshot? {
        purgeExpired()
        return entries[placeID]?.snapshot
    }

    func nextAttempt(placeID: String) -> Date? {
        let now = clock()
        var limits: [Date] = []
        if let attempt = entries[placeID]?.attemptedAt {
            limits.append(attempt.addingTimeInterval(Self.refreshInterval))
        }
        let recent = attempts.filter { now < $0.addingTimeInterval(Self.budgetWindow) }.sorted()
        if recent.count >= Self.dailyFetchLimit {
            limits.append(recent[recent.count - Self.dailyFetchLimit].addingTimeInterval(Self.budgetWindow))
        }
        return limits.filter { $0 > now }.max()
    }

    func load(placeID: String, location: CLLocation, timeZone: TimeZone) async throws -> EventWeatherSnapshot {
        let cached = cached(placeID: placeID)
        if let task = inFlight[placeID] { return try await task.value }
        guard !storageFailed else { throw Failure.storage }
        if nextAttempt(placeID: placeID) != nil {
            if let cached { return cached }
            throw Failure.dailyLimit
        }
        let previous = entries[placeID]
        let previousAttempts = attempts
        attempts.append(clock())
        entries[placeID] = Entry(attemptedAt: clock(), snapshot: cached)
        do { try persist() } catch {
            entries[placeID] = previous; attempts = previousAttempts; throw Failure.storage
        }
        let task = Task { try await fetch(location, timeZone) }
        inFlight[placeID] = task
        defer { inFlight[placeID] = nil }
        let snapshot = try await task.value
        guard snapshot.canDisplay(at: clock()) else { throw Failure.unavailable }
        entries[placeID]?.snapshot = snapshot
        do { try persist() } catch { entries[placeID]?.snapshot = nil; throw Failure.storage }
        return snapshot
    }

    func purgeExpired() {
        let now = clock()
        let oldAttemptCount = attempts.count
        attempts.removeAll { now >= $0.addingTimeInterval(Self.budgetWindow) }
        let oldCount = entries.count
        entries = entries.filter { now < $0.value.attemptedAt.addingTimeInterval(EventWeatherSnapshot.lifetime) || inFlight[$0.key] != nil }
        var changed = entries.count != oldCount || attempts.count != oldAttemptCount
        for key in Array(entries.keys) {
            if let snapshot = entries[key]?.snapshot, !snapshot.canDisplay(at: now) {
                entries[key]?.snapshot = nil; changed = true
            }
        }
        if changed { do { try persist() } catch { storageFailed = true } }
    }

    private func persist() throws {
        guard let fileURL else { return }
        var directory = fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        try JSONEncoder().encode(State(entries: entries, attempts: attempts)).write(to: fileURL, options: .atomic)
    }

    enum Failure: LocalizedError {
        case dailyLimit, unavailable, storage
        var errorDescription: String? {
            switch self {
            case .dailyLimit: return "Weather has reached its refresh limit on this device. Try again after the next update becomes available."
            case .unavailable: return "Weather is unavailable for this track."
            case .storage: return "Weather couldn’t save its local update limit. Try reopening Cuekeeper."
            }
        }
    }

    static func fetchWeather(location: CLLocation, timeZone: TimeZone) async throws -> EventWeatherSnapshot {
        let service = WeatherService.shared
        let attribution = try await service.attribution
        let (daily, hourly) = try await service.weather(for: location, including: .daily, .hourly)
        return EventWeatherSnapshot(
            fetchedAt: Date(), expiresAt: min(daily.metadata.expirationDate, hourly.metadata.expirationDate),
            timeZoneID: timeZone.identifier,
            days: daily.map { EventWeatherDay(date: $0.date, condition: $0.condition.description, symbol: $0.symbolName,
                high: $0.highTemperature.converted(to: .celsius).value, low: $0.lowTemperature.converted(to: .celsius).value,
                precipitation: $0.precipitationChance, wind: $0.wind.speed.converted(to: .kilometersPerHour).value) },
            hours: hourly.map { EventWeatherHour(date: $0.date, condition: $0.condition.description, symbol: $0.symbolName,
                temperature: $0.temperature.converted(to: .celsius).value, precipitation: $0.precipitationChance,
                wind: $0.wind.speed.converted(to: .kilometersPerHour).value) },
            legalURL: attribution.legalPageURL, lightMarkURL: attribution.combinedMarkLightURL, darkMarkURL: attribution.combinedMarkDarkURL)
    }
}

extension Job {
    var weatherRequest: EventWeatherRequest {
        EventWeatherRequest(placeID: eventTrackPlaceID, bookingStatus: eventBookings.allSatisfy { $0.bookingStatus == "cancelled" } ? "cancelled" : "booked", arrangement: eventBookings.contains { $0.workArrangement == "onSite" || $0.workArrangement == "hybrid" } ? "onSite" : workArrangement,
                            startDay: eventStartDay, endDay: eventEndDay)
    }
}
