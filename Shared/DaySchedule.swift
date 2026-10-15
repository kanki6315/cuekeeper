import Foundation

struct ScheduleEvent: Codable, Identifiable, Equatable {
    let id: UUID
    let title: String
    let client: String
    let startDay: String
    let endDay: String
    let status: String
}

struct ScheduleSession: Codable, Identifiable, Equatable {
    let id: UUID
    let eventID: UUID
    let title: String
    let day: String
    let start: Date?
    let end: Date?
    let call: Date?
    let zone: String
    let confirmed: Bool
    let coverage: String
}

struct DaySchedule: Codable, Equatable {
    var events: [ScheduleEvent] = []
    var sessions: [ScheduleSession] = []

    static func dayKey(_ date: Date, zone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
    func event(for session: ScheduleSession) -> ScheduleEvent? { events.first { $0.id == session.eventID } }
    func today(at now: Date, calendar: Calendar = .current) -> [ScheduleSession] {
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        return sessions.filter { session in
            guard let event = event(for: session), event.status != "cancelled" else { return false }
            if let time = session.start {
                return time < end && (session.end.map { $0 > start } ?? (time >= start))
                    || session.call.map { $0 >= start && $0 < end } == true
            }
            let key = Self.dayKey(now, zone: TimeZone(identifier: session.zone) ?? calendar.timeZone)
            return session.day == key || (session.day.isEmpty && event.startDay <= key && event.endDay >= key)
        }.sorted {
            if $0.start != $1.start { return ($0.start ?? .distantFuture) < ($1.start ?? .distantFuture) }
            return ($0.title, $0.id.uuidString) < ($1.title, $1.id.uuidString)
        }
    }
    func nextCommitment(at now: Date, calendar: Calendar = .current) -> ScheduleSession? {
        today(at: now, calendar: calendar).filter {
            $0.confirmed && $0.coverage == "covering" && event(for: $0)?.status == "booked"
                && ($0.call ?? $0.start ?? .distantPast) >= now
        }.min { ($0.call ?? $0.start ?? .distantFuture) < ($1.call ?? $1.start ?? .distantFuture) }
    }
    func remaining(at now: Date, calendar: Calendar = .current) -> [ScheduleSession] {
        today(at: now, calendar: calendar).filter {
            $0.coverage != "notCovering" && event(for: $0)?.status != "completed"
                && ($0.end ?? .distantFuture) > now
        }
    }
    func unscheduledEvents(at now: Date, calendar: Calendar = .current) -> [ScheduleEvent] {
        let key = Self.dayKey(now, zone: calendar.timeZone)
        let scheduled = Set(today(at: now, calendar: calendar).map(\.eventID))
        return events.filter { $0.status != "cancelled" && $0.status != "completed" && $0.startDay <= key && $0.endDay >= key && !scheduled.contains($0.id) }
            .sorted { ($0.title, $0.id.uuidString) < ($1.title, $1.id.uuidString) }
    }
}

/// Contains schedule labels only, never fees, notes, links, or CloudKit credentials.
enum ScheduleStore {
    static let group = "group.com.arjunakankipati.cuekeeper"
    static let widgetKind = "CuekeeperDaySchedule"
    static var url: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)?.appendingPathComponent("schedule.json")
    }
    static func read() -> DaySchedule? {
        guard let url, let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(DaySchedule.self, from: data)
    }
    static func write(_ schedule: DaySchedule) throws {
        guard let url else { throw CocoaError(.fileNoSuchFile) }
        try JSONEncoder().encode(schedule).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
