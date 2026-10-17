import SwiftUI

/// An Events row: a date rail that spans the event, the title and client, then one line per day.
///
/// Multi-day rows always carry three day lines and single-day rows one, so rows of each kind
/// share a height. The rail's start sits beside the title, its line runs beside the days, and
/// the end day is level with the event's last day line.
struct EventsListRowView: View {
    let row: EventsListRow
    @ScaledMetric(relativeTo: .body) private var railWidth = 47
    @ScaledMetric(relativeTo: .subheadline) private var weekdayWidth = 34
    @ScaledMetric(relativeTo: .subheadline) private var lineHeight = 22

    private var tint: Color { row.finished ? Color("SecondaryText") : Color.accentColor }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .center, spacing: 14) {
                start.frame(width: railWidth)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(row.facts.title).font(.headline).foregroundStyle(row.finished ? Color("SecondaryText") : Color.primary).lineLimit(1)
                        Spacer(minLength: 4)
                        EventsStatusBadge(badge: row.badge)
                    }
                    Text(subtitle).font(.subheadline).foregroundStyle(Color("SecondaryText")).lineLimit(1)
                }
            }
            VStack(spacing: 0) {
                ForEach(Array(row.lines.enumerated()), id: \.offset) { index, line in
                    HStack(spacing: 14) {
                        railCell(index).frame(width: railWidth).frame(maxHeight: .infinity)
                        content(line)
                    }
                    .frame(minHeight: lineHeight)
                }
            }
        }
        .padding(.vertical, 14)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(spoken)
    }

    private var subtitle: String {
        let parts = [row.facts.client ?? "Client to add", row.facts.series.joined(separator: ", ")].filter { !$0.isEmpty }
        return parts.joined(separator: " · ")
    }

    private var start: some View {
        VStack(spacing: 2) {
            if let date = Day.date(from: row.facts.startDay) {
                Text(date.formatted(.dateTime.weekday(.abbreviated))).font(.caption)
                Text(date.formatted(.dateTime.day())).font(.title.weight(.semibold)).monospacedDigit()
            } else {
                Text("Dates to come").font(.caption).multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(tint)
    }

    @ViewBuilder private func railCell(_ index: Int) -> some View {
        if let end = row.endLine {
            if index < end {
                Rectangle().fill(tint.opacity(0.35)).frame(width: 1.5)
            } else if index == end, let date = Day.date(from: row.facts.endDay) {
                let crossesMonth = row.facts.endDay.prefix(7) != row.facts.startDay.prefix(7)
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text(date.formatted(.dateTime.day())).font(.headline).monospacedDigit()
                    if crossesMonth { Text(date.formatted(.dateTime.month(.abbreviated))).font(.caption2) }
                }
                .foregroundStyle(tint).lineLimit(1).minimumScaleFactor(0.8)
            } else {
                Color.clear
            }
        } else if let date = Day.date(from: row.facts.startDay) {
            // Single-day events keep the Upcoming rail: weekday, day, month.
            Text(date.formatted(.dateTime.month(.abbreviated))).font(.caption).foregroundStyle(tint)
        } else {
            Color.clear
        }
    }

    @ViewBuilder private func content(_ line: EventsListLine) -> some View {
        HStack(spacing: 6) {
            switch line {
            case let .day(day, sessions):
                weekday(day)
                if let first = sessions.first {
                    Text(sessions.map(\.title).joined(separator: " · ")).lineLimit(1)
                    Spacer(minLength: 6)
                    if let time = first.time ?? sessions.lazy.compactMap(\.time).first { Text(time).monospacedDigit() }
                } else {
                    Spacer(minLength: 0)
                }
            case let .scheduleToCome(day):
                if let day { weekday(day) }
                Text("Schedule to come").foregroundStyle(Color("SecondaryText")).lineLimit(1)
                Spacer(minLength: 0)
            case let .more(days, sessions):
                Color.clear.frame(width: weekdayWidth, height: 1)
                Text(Self.moreText(days: days, sessions: sessions)).foregroundStyle(Color("SecondaryText")).lineLimit(1)
                Spacer(minLength: 0)
            case .blank:
                Spacer(minLength: 0)
            }
        }
        .font(.subheadline)
    }

    private func weekday(_ day: String) -> some View {
        Text(Day.date(from: day)?.formatted(.dateTime.weekday(.abbreviated)) ?? "")
            .foregroundStyle(Color("SecondaryText"))
            .frame(width: weekdayWidth, alignment: .leading)
    }

    static func moreText(days: [String], sessions: Int) -> String {
        let names = days.compactMap { Day.date(from: $0)?.formatted(.dateTime.weekday(.abbreviated)) }
        let lead = days.count <= 3 ? "+ " + names.joined(separator: ", ") : "+\(days.count) more days"
        return sessions == 0 ? lead : lead + " · " + counted(sessions, "session", "sessions")
    }

    private var spoken: String {
        var parts = [row.facts.title, row.badge.text, Self.spokenDates(row.facts), subtitle]
        for line in row.lines {
            switch line {
            case let .day(day, sessions) where !sessions.isEmpty:
                let name = Day.date(from: day)?.formatted(.dateTime.weekday(.wide)) ?? day
                parts.append("\(name): " + sessions.map { [$0.title, $0.time].compactMap { $0 }.joined(separator: " ") }.joined(separator: ", "))
            case .scheduleToCome: parts.append("Schedule to come")
            case let .more(days, sessions): parts.append(Self.moreText(days: days, sessions: sessions))
            default: break
            }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: ". ")
    }

    private static func spokenDates(_ facts: EventsListFacts) -> String {
        guard let start = Day.date(from: facts.startDay) else { return "Dates to come" }
        let style = Date.FormatStyle.dateTime.weekday(.wide).day().month(.wide)
        guard facts.endDay != facts.startDay, let end = Day.date(from: facts.endDay) else { return start.formatted(style) }
        return "\(start.formatted(style)) to \(end.formatted(style))"
    }
}

/// Booking status before the work, payment state after it.
struct EventsStatusBadge: View {
    let badge: EventsBadge
    var body: some View {
        Text(badge.text)
            .font(.caption.weight(.semibold)).lineLimit(1).fixedSize()
            .foregroundStyle(foreground)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(background, in: Capsule())
    }
    private var foreground: Color {
        switch badge.tone {
        case .accent: Color.accentColor
        case .amber: Color("AmberText")
        case .muted: Color("SecondaryText")
        }
    }
    private var background: Color {
        switch badge.tone {
        case .accent: Color.accentColor.opacity(0.1)
        case .amber: Color.orange.opacity(0.13)
        case .muted: Color.primary.opacity(0.06)
        }
    }
}

/// Marks where past events end and current ones begin.
struct EventsTodayMarker: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Today").font(.caption.weight(.semibold))
            Rectangle().frame(height: 1)
        }
        .foregroundStyle(Color.accentColor)
        .padding(.top, 10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today")
    }
}

extension EventsListMonth {
    func title(currentYear: String) -> String {
        guard let date = Day.date(from: month + "-01") else { return "Dates to come" }
        return month.hasPrefix(currentYear) ? date.formatted(.dateTime.month(.wide)) : date.formatted(.dateTime.month(.wide).year())
    }
    /// "$2,150 to collect", one amount per currency.
    var collectText: String? {
        guard !toCollect.isEmpty else { return nil }
        return toCollect.map { Money.format($0.amount, currency: $0.currency) }.joined(separator: " · ") + " to collect"
    }
}
