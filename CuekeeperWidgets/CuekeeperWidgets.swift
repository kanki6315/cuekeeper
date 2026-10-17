import SwiftUI
import WidgetKit

struct ScheduleEntry: TimelineEntry {
    let date: Date
    let schedule: DaySchedule?
}

struct ScheduleProvider: TimelineProvider {
    func placeholder(in context: Context) -> ScheduleEntry { ScheduleEntry(date: .now, schedule: example) }
    func getSnapshot(in context: Context, completion: @escaping (ScheduleEntry) -> Void) {
        completion(ScheduleEntry(date: .now, schedule: context.isPreview ? example : ScheduleStore.read()))
    }
    func getTimeline(in context: Context, completion: @escaping (Timeline<ScheduleEntry>) -> Void) {
        let now = Date()
        let schedule = ScheduleStore.read()
        // Schedule transitions locally; WidgetKit decides when fresh app data can reload.
        let horizon = Calendar.current.date(byAdding: .day, value: 1, to: now)!
        let midnight = Calendar.current.startOfDay(for: horizon)
        var dates = Set([now, midnight])
        for row in schedule?.sessions ?? [] {
            for date in [row.call, row.start, row.end].compactMap({ $0 }) where date > now && date <= horizon {
                dates.insert(date.addingTimeInterval(1))
            }
        }
        completion(Timeline(entries: dates.sorted().map { ScheduleEntry(date: $0, schedule: schedule) }, policy: .after(min(horizon, now.addingTimeInterval(3600)))))
    }
    private var example: DaySchedule {
        let id = UUID(), now = Date(), start = Calendar.current.date(byAdding: .hour, value: 1, to: Date())!
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: start)!
        return DaySchedule(events: [ScheduleEvent(id: id, title: "Silverstone weekend", client: "Northside Sports", startDay: DaySchedule.dayKey(now, zone: .current), endDay: DaySchedule.dayKey(tomorrow, zone: .current), status: "booked")], sessions: [ScheduleSession(id: UUID(), eventID: id, title: "Race", day: "", start: tomorrow, end: tomorrow.addingTimeInterval(7200), call: tomorrow.addingTimeInterval(-3600), zone: TimeZone.current.identifier, confirmed: true, coverage: "covering"), ScheduleSession(id: UUID(), eventID: id, title: "Qualifying", day: "", start: start, end: start.addingTimeInterval(3600), call: start.addingTimeInterval(-1800), zone: TimeZone.current.identifier, confirmed: true, coverage: "covering"), ScheduleSession(id: UUID(), eventID: id, title: "Race briefing", day: "", start: start.addingTimeInterval(7200), end: start.addingTimeInterval(9000), call: nil, zone: TimeZone.current.identifier, confirmed: true, coverage: "covering")])
    }
}

struct ScheduleWidgetView: View {
    @Environment(\.widgetFamily) private var systemFamily
    var familyOverride: WidgetFamily? = nil
    private var family: WidgetFamily { familyOverride ?? systemFamily }
    @Environment(\.colorScheme) private var appearance
    let entry: ScheduleEntry
    private var tint: Color { appearance == .dark ? Color(red: 0.65, green: 0.86, blue: 0.71) : Color(red: 0.027, green: 0.243, blue: 0.153) }
    private var rows: [ScheduleSession] { entry.schedule?.upcoming(at: entry.date) ?? [] }
    private var accessorySession: ScheduleSession? { next ?? rows.first }
    private var next: ScheduleSession? { entry.schedule?.nextCommitment(at: entry.date) }
    private var zone: String { TimeZone.current.abbreviation(for: entry.date) ?? TimeZone.current.identifier }
    private var callLabel: String {
        guard let next, let date = next.call ?? next.start else { return "Today · \(zone)" }
        return "\(next.call == nil ? "Next" : "Call") \(when(date)) · \(zone)"
    }
    var body: some View {
        Group {
            switch family {
            case .accessoryInline:
                Text(accessorySession.map { "\(callLabel) · \($0.title)" } ?? emptyTitle)
            case .accessoryCircular:
                VStack(spacing: 2) {
                    Image(systemName: "calendar")
                    if let date = next?.call ?? accessorySession?.start { Text(time(date)).font(.caption.bold()).minimumScaleFactor(0.8); Text(isToday(date) ? zone : date.formatted(.dateTime.weekday(.abbreviated))).font(.caption2) }
                    else { Text("Today").font(.caption2); Text("—").font(.caption) }
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 3) {
                    Label(accessorySession == nil ? emptyTitle : callLabel, systemImage: "bookmark").font(.caption.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.85)
                    if let row = accessorySession { Text("\(row.title) · \(eventTitle(row))").font(.caption).lineLimit(2) }
                    else { Text(emptyDetail).font(.caption).lineLimit(2) }
                }
            default:
                if rows.isEmpty { emptyView } else if family == .systemSmall { small } else { medium }
            }
        }
        .privacySensitive()
        .widgetURL(URL(string: "cuekeeper://today"))
        .containerBackground(for: .widget) {
            (appearance == .dark ? Color(red: 0.09, green: 0.118, blue: 0.098) : Color(red: 0.98, green: 0.973, blue: 0.949))
        }
    }
    private var small: some View {
        let shown = Array(rows.prefix(2))
        let shared = Set(shown.map(\.eventID)).count == 1
        return VStack(alignment: .leading, spacing: 6) {
            Label { Text(callLabel) } icon: { CuekeeperMark().fill(tint, style: FillStyle(eoFill: true)).frame(width: 13, height: 15) }.font(.caption2).lineLimit(1).foregroundStyle(tint)
            if shared, let first = shown.first { Text(eventTitle(first)).font(.caption.weight(.semibold)).foregroundStyle(tint).lineLimit(2) }
            ForEach(shown) { row in
                Divider()
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(row.start.map(when) ?? "TBD").font(.caption2.weight(.medium)).monospacedDigit().fixedSize()
                        Text(row.title).font(.caption.weight(.semibold)).lineLimit(2)
                    }
                    if !shared { Text(eventTitle(row)).font(.caption2).foregroundStyle(tint).lineLimit(1) }
                    if !row.confirmed || row.coverage != "covering" { Text(!row.confirmed ? "Tentative" : "Coverage undecided").font(.caption2).foregroundStyle(.secondary).lineLimit(1) }
                }

            }
            if rows.count > shown.count { Text("+\(rows.count - shown.count) more").font(.caption2).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
    }
    private var medium: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack { Text("Upcoming").font(.headline).foregroundStyle(tint); Spacer(); Text("\(rows.count) sessions · \(zone)").font(.caption2).foregroundStyle(.secondary) }
            ForEach(Array(rows.prefix(4))) { row in
                Divider()
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(row.start.map(when) ?? "TBD").font(.caption).monospacedDigit().frame(width: rows.prefix(4).contains { $0.start.map(isToday) == false } ? 84 : 58, alignment: .leading)
                    Text(row.title + (!row.confirmed ? " · Tentative" : row.coverage != "covering" ? " · Undecided" : "")).font(.caption.weight(.semibold)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                    Text(eventTitle(row)).font(.caption2).foregroundStyle(tint).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityLabel("\(row.start.map { $0.formatted(date: isToday($0) ? .omitted : .abbreviated, time: .shortened) } ?? "Time to come"), \(row.title), \(eventTitle(row)), \(row.confirmed ? "Confirmed" : "Tentative"), \(row.coverage == "covering" ? "Covering" : "Coverage undecided")")
            }
            if rows.count > 4 { Text("+\(rows.count - 4) more").font(.caption2).foregroundStyle(.secondary) }
            Spacer(minLength: 0)
        }
    }
    private var emptyTitle: String {
        guard let schedule = entry.schedule else { return "Open Cuekeeper" }
        if !schedule.unscheduledEvents(at: entry.date).isEmpty { return "Schedule to come" }
        return schedule.today(at: entry.date).isEmpty ? "No upcoming work" : "No more sessions"
    }
    private var emptyDetail: String {
        entry.schedule?.unscheduledEvents(at: entry.date).first?.title ?? (entry.schedule == nil ? "Open the app to load your schedule." : "View your upcoming events in Cuekeeper.")
    }
    private var emptyView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label { Text("Upcoming") } icon: { CuekeeperMark().fill(tint, style: FillStyle(eoFill: true)).frame(width: 16, height: 19) }.font(.headline).foregroundStyle(tint)
            Text(emptyTitle).font(.headline)
            Text(emptyDetail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
        }.frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    private func eventTitle(_ row: ScheduleSession) -> String { entry.schedule?.event(for: row)?.title ?? "Event" }
    private func time(_ date: Date) -> String { date.formatted(date: .omitted, time: .shortened) }
    private func isToday(_ date: Date) -> Bool { Calendar.current.isDate(date, inSameDayAs: entry.date) }
    /// Time alone for today; weekday within the coming week, otherwise month and day.
    private func when(_ date: Date) -> String {
        if isToday(date) { return time(date) }
        let soon = date < Calendar.current.date(byAdding: .day, value: 6, to: Calendar.current.startOfDay(for: entry.date))!
        let day = soon ? date.formatted(.dateTime.weekday(.abbreviated)) : date.formatted(.dateTime.month(.abbreviated).day())
        return "\(day) \(time(date))"
    }
}

#if WIDGET_EXTENSION
@main
struct CuekeeperWidgets: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: ScheduleStore.widgetKind, provider: ScheduleProvider()) { ScheduleWidgetView(entry: $0) }
            .configurationDisplayName("Upcoming schedule")
            .description("Today’s remaining sessions and what’s next, with your next call time.")
            .supportedFamilies([.systemSmall, .systemMedium, .accessoryInline, .accessoryCircular, .accessoryRectangular])
    }
}

#endif
