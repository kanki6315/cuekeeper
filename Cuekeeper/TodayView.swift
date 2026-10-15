import CoreData
import SwiftUI

struct TodayScheduleView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dynamicTypeSize) private var typeSize
    @FetchRequest(sortDescriptors: []) private var jobs: FetchedResults<Job>
    @FetchRequest(sortDescriptors: []) private var sessions: FetchedResults<WorkSession>
    @FetchRequest(sortDescriptors: []) private var events: FetchedResults<WorkEvent>
    @FetchRequest(sortDescriptors: []) private var clients: FetchedResults<Client>
    var selectedJob: Binding<Job?>?

    var body: some View {
        let _ = jobs.count + sessions.count + events.count + clients.count
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            // Fetch on each view update as related client/event edits also affect labels.
            if let schedule = try? DaySchedule.capture(in: context) {
                content(schedule, now: timeline.date)
            } else {
                ContentUnavailableView("Schedule unavailable", systemImage: "calendar.badge.exclamationmark", description: Text("Reopen Today to try again. Your events are still saved."))
            }
        }
    }
    private func content(_ schedule: DaySchedule, now: Date) -> some View {
        let rows = schedule.today(at: now)
        let pending = schedule.unscheduledEvents(at: now)
        let eventCount = Set(rows.map(\.eventID)).union(pending.map(\.id)).count
        return VStack(alignment: .leading, spacing: 18) {
            ViewThatFits(in: .horizontal) {
                HStack { Text("\(counted(eventCount, "event", "events")) · \(counted(rows.count, "session", "sessions"))"); Spacer(); zoneLabel(now) }
                VStack(alignment: .leading) { Text("\(counted(eventCount, "event", "events")) · \(counted(rows.count, "session", "sessions"))"); zoneLabel(now) }
            }.font(.subheadline).foregroundStyle(Color("SecondaryText"))
            if let next = schedule.nextCommitment(at: now), let time = next.call ?? next.start {
                Text("\(next.call == nil ? "Next session" : "Next call") \(time.formatted(date: .omitted, time: .shortened)) · \(next.title)")
                    .font(.subheadline.weight(.medium)).foregroundStyle(Color.accentColor)
                    .padding(12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
            }
            if rows.isEmpty && pending.isEmpty {
                ContentUnavailableView("No work scheduled today", systemImage: "sun.max", description: Text("Choose Week or All to see your upcoming events."))
            } else {
                if !rows.isEmpty {
                    Text("Day schedule").font(.title2.bold())
                    VStack(spacing: 0) {
                        ForEach(rows) { row in
                            Divider()
                            sessionRow(row, event: schedule.event(for: row))
                                .padding(.vertical, 12)
                        }
                    }
                    if schedule.remaining(at: now).isEmpty {
                        Text("No more sessions today").font(.subheadline).foregroundStyle(Color("SecondaryText"))
                    }
                }
                if !pending.isEmpty {
                    Text("Schedule to come").font(.title2.bold())
                    ForEach(pending) { event in
                        if let job = jobs.first(where: { $0.id == event.id }) {
                            eventLink(job) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(event.title).font(.headline)
                                    Text("\(event.client) · \(event.status.capitalized)").font(.subheadline).foregroundStyle(Color("SecondaryText"))
                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                            }
                        }
                    }
                }
            }
        }.accessibilityIdentifier("today-schedule")
    }
    private func zoneLabel(_ now: Date) -> some View {
        Text("Your time · \(TimeZone.current.abbreviation(for: now) ?? TimeZone.current.identifier)")
    }
    @ViewBuilder private func sessionRow(_ row: ScheduleSession, event: ScheduleEvent?) -> some View {
        if let session = sessions.first(where: { $0.id == row.id }), let job = session.job {
            let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(alignment: .top, spacing: 16))
            NavigationLink { SessionDetailView(session: session) } label: {
                layout {
                    VStack(alignment: .leading, spacing: 4) {
                        if let start = row.start {
                            Text(start, style: .time).font(.subheadline.weight(.semibold))
                            if let end = row.end {
                                Text(end, style: .time).font(.caption)
                                if !Calendar.current.isDate(start, inSameDayAs: end) { Text(end, format: .dateTime.month(.abbreviated).day()).font(.caption) }
                            }
                        } else { Text("Time TBD").font(.subheadline) }
                    }.monospacedDigit().frame(width: typeSize.isAccessibilitySize ? nil : 84, alignment: .leading)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack { Text(row.title).font(.headline); Spacer(); Image(systemName: "chevron.right").font(.caption) }
                        Label(event?.title ?? job.eventTitle, systemImage: "bookmark")
                            .font(.subheadline).foregroundStyle(Color.accentColor)
                        Text(event?.client ?? "Client to add").font(.caption).foregroundStyle(Color("SecondaryText"))
                        Text(statusLine(row)).font(.caption).foregroundStyle(Color("SecondaryText"))
                        if row.zone != TimeZone.current.identifier, let start = row.start, let zone = TimeZone(identifier: row.zone) {
                            Text("Event time: \(start.formatted(Date.FormatStyle(date: .omitted, time: .shortened, timeZone: zone))) \(zone.abbreviation(for: start) ?? row.zone)")
                                .font(.caption).foregroundStyle(Color("SecondaryText"))
                        }
                    }
                }.foregroundStyle(.primary).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.buttonStyle(.plain)

        }
    }
    private func statusLine(_ row: ScheduleSession) -> String {
        var parts: [String] = []
        if let call = row.call { parts.append("Call " + call.formatted(date: Calendar.current.isDateInToday(call) ? .omitted : .abbreviated, time: .shortened)) }
        parts.append(row.confirmed ? "Confirmed" : "Tentative")
        if row.coverage != "covering" { parts.append(row.coverage == "notCovering" ? "Not covering" : "Coverage undecided") }
        return parts.joined(separator: " · ")
    }
    @ViewBuilder private func eventLink<Label: View>(_ job: Job, @ViewBuilder label: () -> Label) -> some View {
        if let selectedJob { Button { selectedJob.wrappedValue = job } label: { label() }.buttonStyle(.plain) }
        else { NavigationLink { EventDetailView(anchor: job) } label: { label() }.buttonStyle(.plain) }
    }
}
