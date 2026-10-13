import Foundation

struct CalendarEntry: Equatable {
    let key: String
    var title: String
    var start: Date
    var end: Date
    var allDay: Bool
    var timeZoneID: String
    var notes: String
    var location: String
    var url: URL { URL(string: "cuekeeper://calendar/\(key)")! }
}

/// Every known record has a key, even when it is ineligible. Unknown remote events
/// are left alone while a new device is still downloading its Core Data records.
struct CalendarPlan {
    var desired: [String: CalendarEntry] = [:]
    var knownKeys: Set<String> = []
    var bounds: [Date] = []

    init(jobs: [Job]) {
        for job in jobs {
            guard let id = job.id else { continue }
            let key = "job/\(id.uuidString)"
            knownKeys.insert(key)
            var calendar = Calendar(identifier: .gregorian)
            let zone = TimeZone(identifier: job.timeZoneID) ?? .current
            calendar.timeZone = zone
            if let start = Day.date(from: job.startDay, timeZone: zone),
               let last = Day.date(from: job.endDay, timeZone: zone),
               let end = calendar.date(byAdding: .day, value: 1, to: last) {
                bounds += [start, end]
                if job.bookingStatus != "cancelled" {
                    desired[key] = CalendarEntry(key: key, title: job.name, start: start, end: end, allDay: true,
                                                 timeZoneID: zone.identifier, notes: "Cuekeeper · \(job.bookingStatus.capitalized)\n\(job.notes)", location: job.location)
                }
            }
            for session in job.sessions ?? [] {
                guard let id = session.id else { continue }
                let key = "session/\(id.uuidString)"
                knownKeys.insert(key)
                if let start = session.startTime { bounds.append(start) }
                if let end = session.endTime { bounds.append(end) }
                if session.calendarEligible, let start = session.startTime, let end = session.endTime {
                    desired[key] = CalendarEntry(key: key, title: "\(job.name) · \(session.title)", start: start, end: end, allDay: false,
                                                 timeZoneID: session.timeZoneID, notes: session.notes, location: job.location)
                }
            }
        }
    }
    static func key(from url: URL?) -> String? {
        guard let url, url.scheme == "cuekeeper", url.host == "calendar" else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count == 2, ["job", "session"].contains(parts[0]), UUID(uuidString: parts[1]) != nil else { return nil }
        return parts.joined(separator: "/")
    }
}
