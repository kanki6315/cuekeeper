import CoreData
import MapKit
import SwiftUI
import Combine

struct EventDateFields: View {
    @Binding var draft: JobDraft
    private var calendar: Calendar { Calendar.current }
    private var selection: Binding<Set<DateComponents>> {
        Binding(get: {
            Set([draft.startDate, draft.endDate].map {
                calendar.dateComponents([.era, .year, .month, .day], from: $0)
            })
        }, set: { selected in
            // Events require at least one date. A third date starts a fresh range.
            let previous = Set([draft.startDate, draft.endDate].map {
                calendar.dateComponents([.era, .year, .month, .day], from: $0)
            })
            let dates = (selected.count > 2 ? selected.subtracting(previous) : selected)
                .compactMap { calendar.date(from: $0) }.sorted()
            guard let start = dates.first, let end = dates.last else { return }
            draft.startDate = start; draft.endDate = end
        })
    }
    var body: some View {
        MultiDatePicker("Event dates", selection: selection)
            .accessibilityIdentifier("event-date-calendar")
        LabeledContent("Start", value: draft.startDate.formatted(date: .abbreviated, time: .omitted))
            .accessibilityIdentifier("event-start-summary")
        if !calendar.isDate(draft.startDate, inSameDayAs: draft.endDate) {
            LabeledContent("End", value: draft.endDate.formatted(date: .abbreviated, time: .omitted))
                .accessibilityIdentifier("event-end-summary")
        }
        Text("Select one day, or the first and last days of your event. All days between are included. Selecting a third date starts a new selection.")
            .font(.caption).foregroundStyle(.secondary)
    }
}

struct SeriesSelectionFields: View {
    @Binding var names: Set<String>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \WorkSeries.name, ascending: true)]) private var library: FetchedResults<WorkSeries>
    @State private var newName = ""
    var body: some View {
        ForEach(names.sorted(), id: \.self) { name in
            HStack {
                Text(name).fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button("Remove", systemImage: "minus.circle", role: .destructive) { names.remove(name) }
                    .labelStyle(.iconOnly).accessibilityLabel("Remove \(name)").frame(minWidth: 44, minHeight: 44)
            }
        }
        LibraryTypeaheadField(title: "Championship", prompt: "Search or add championship", text: $newName,
                              savedNames: library.map(\.name).filter { !names.contains($0) },
                              identifier: "championship-search", onSelect: { value in
                                  let canonical = library.first {
                                      $0.name.compare(value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
                                  }?.name ?? value
                                  names.insert(canonical); newName = ""
                              })
    }
}

/// Suggestions come only from saved records; typing never creates a library entry.
struct LibraryTypeaheadField: View {
    let title: String
    let prompt: String
    @Binding var text: String
    let savedNames: [String]
    let identifier: String
    var onSelect: ((String) -> Void)? = nil
    @FocusState private var focused: Bool

    private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var matches: [String] {
        Array(Set(savedNames)).sorted().filter { query.isEmpty || $0.localizedStandardContains(query) }
    }
    private var exactMatch: String? {
        savedNames.first { $0.compare(query, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            VStack(alignment: .leading, spacing: 6) {
                Text(title).font(.subheadline).foregroundStyle(Color("SecondaryText"))
                DaybookTextField(prompt, text: $text)
                    .focused($focused).submitLabel(.done)
                    .accessibilityLabel(title).accessibilityIdentifier(identifier)
                    .onSubmit { if !query.isEmpty { select(exactMatch ?? query) } else { focused = false } }
            }
            if focused || (onSelect != nil && !query.isEmpty) {
                ForEach(matches.prefix(5), id: \.self) { name in
                    Button { select(name) } label: {
                        Text(name).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }.accessibilityIdentifier("\(identifier)-suggestion")
                }
            }
            if onSelect != nil && !query.isEmpty && exactMatch == nil {
                Button { select(query) } label: {
                    Text("Add “\(query)”").fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.accessibilityIdentifier("\(identifier)-add")
            }
        }
    }

    private func select(_ name: String) {
        focused = false
        if let onSelect { onSelect(name) } else { text = name }
    }
}

@MainActor
final class LocationSuggestions: NSObject, ObservableObject, @preconcurrency MKLocalSearchCompleterDelegate {
    @Published var results: [MKLocalSearchCompletion] = []
    @Published var unavailable = false
    private let completer = MKLocalSearchCompleter()
    override init() {
        super.init(); completer.delegate = self; completer.resultTypes = [.address, .pointOfInterest]
    }
    func search(_ text: String) {
        unavailable = false
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { completer.cancel(); results = []; return }
        completer.queryFragment = text
    }
    func stop() { completer.cancel(); results = [] }
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) { results = Array(completer.results.prefix(5)) }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) { results = []; unavailable = true }
}

struct LocationSearchField: View {
    @Binding var text: String
    @StateObject private var suggestions = LocationSuggestions()
    @FocusState private var focused: Bool
    var body: some View {
        DaybookTextField("Location", text: $text).focused($focused)
            .onChange(of: text) { _, value in if focused { suggestions.search(value) } }
            .onChange(of: focused) { _, value in if value { suggestions.search(text) } else { suggestions.stop() } }
        if focused {
            ForEach(Array(suggestions.results.enumerated()), id: \.offset) { _, result in
                Button {
                    focused = false; suggestions.stop()
                    text = [result.title, result.subtitle].filter { !$0.isEmpty }.joined(separator: ", ")
                } label: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(result.title).foregroundStyle(.primary)
                        if !result.subtitle.isEmpty { Text(result.subtitle).font(.caption).foregroundStyle(.secondary) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.accessibilityIdentifier("location-suggestion")
            }
            if suggestions.unavailable { Text("Suggestions unavailable. You can still enter a location.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct WizardSessionFields: View {
    @Binding var draft: SessionDraft
    let eventTimeZoneID: String
    var zone: TimeZone { TimeZone(identifier: eventTimeZoneID) ?? .current }
    var body: some View {
        DaybookTextField("Session title", text: $draft.name)
        SessionDateField(draft: $draft, zone: zone, title: "Date").accessibilityIdentifier("wizard-session-date").accessibilityLabel("Session date")
        if eventTimeZoneID.isEmpty { Text("Choose the event timezone above to add times.").font(.caption).foregroundStyle(.secondary) }
        SessionScheduleField(draft: $draft, zone: zone).disabled(eventTimeZoneID.isEmpty)
        optionalTime("Call time", value: $draft.callTime)
        DaybookChoicePicker("Schedule", selection: $draft.scheduleStatus, identifier: "wizard-session-schedule") { Text("Tentative").tag("tentative"); Text("Confirmed").tag("confirmed") }
        DaybookChoicePicker("Coverage", selection: $draft.coverage, identifier: "wizard-session-coverage") { Text("Undecided").tag("undecided"); Text("Covering").tag("covering"); Text("Not covering").tag("notCovering") }
        Group {}.onChange(of: draft.startTime) { _, value in if let value { draft.day = Day.string(from: value, timeZone: zone) } }
            .onChange(of: eventTimeZoneID) { _, _ in if let value = draft.startTime { draft.day = Day.string(from: value, timeZone: zone) } }
    }
    @ViewBuilder private func optionalTime(_ title: String, value: Binding<Date?>) -> some View {
        OptionalSessionTimeField(title: title, value: value,
            defaultDate: (draft.startTime ?? Day.date(from: draft.day, timeZone: zone) ?? Date())
                .addingTimeInterval(title == "End" ? 3600 : 0), zone: zone)
            .disabled(eventTimeZoneID.isEmpty)
    }
}

func zoneLabel(_ identifier: String, date: Date = Date()) -> String {
    guard let zone = TimeZone(identifier: identifier) else { return "Unspecified" }
    let name = zone.localizedName(for: .generic, locale: .current) ?? identifier
    let seconds = zone.secondsFromGMT(for: date)
    let offset = String(format: "UTC%@%02d:%02d", seconds < 0 ? "−" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
    return "\(name) · \(offset)"
}

struct EventTimeZoneField: View {
    @Binding var selection: String
    var date: Date
    var body: some View {
        DaybookLink { TimeZonePicker(selection: $selection, date: date) } label: {
            TimeZoneValueLabel(title: "Event timezone", value: zoneLabel(selection, date: date))
        }.accessibilityIdentifier("event-timezone")
    }
}

struct WorkTimeZoneField: View {
    @Binding var draft: JobDraft
    var date: Date
    var body: some View {
        if draft.workArrangement == .remote || draft.workArrangement == .hybrid {
            DaybookLink { TimeZonePicker(selection: $draft.timeZoneID, date: date) } label: {
                TimeZoneValueLabel(title: "Your timezone", value: zoneLabel(draft.timeZoneID, date: date))
            }.accessibilityIdentifier("work-timezone")
            Text("Session schedules use the event timezone. Your timezone shows the corresponding local times.").font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct TimeZoneValueLabel: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    let value: String
    var body: some View {
        if typeSize.isAccessibilitySize {
            stackedLabel
        } else {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 16) {
                    Text(title).fixedSize()
                    Spacer(minLength: 0)
                    Text(value)
                        .foregroundStyle(Color("SecondaryText"))
                        .fixedSize()
                }
                stackedLabel
            }
        }
    }

    private var stackedLabel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
            Text(value).foregroundStyle(Color("SecondaryText"))
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A missing time remains missing until the user explicitly adds it.
struct OptionalSessionTimeField: View {
    let title: String
    @Binding var value: Date?
    let defaultDate: Date
    let zone: TimeZone
    var components: DatePickerComponents = [.date, .hourAndMinute]

    var body: some View {
        HStack {
            if value != nil {
                DatePicker(title, selection: Binding(get: { value ?? defaultDate }, set: { value = $0 }),
                           displayedComponents: components)
                    .datePickerStyle(.compact)
                    .accessibilityIdentifier("session-time-\(title)")
                Button { value = nil } label: {
                    Image(systemName: "xmark.circle.fill")
                        .frame(minWidth: 44, minHeight: 44)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Clear \(title.lowercased())")
            } else {
                Text(title)
                Spacer()
                Button("Not set") { value = defaultDate }
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
                    .accessibilityLabel("\(title), Not set")
                    .accessibilityHint("Add a time")
                    .accessibilityIdentifier("session-time-\(title)-unset")
            }
        }
        .environment(\.timeZone, zone)
    }
}

struct SessionScheduleField: View {
    @Binding var draft: SessionDraft
    let zone: TimeZone
    private var day: Date { Day.date(from: draft.day, timeZone: zone) ?? Date() }

    var body: some View {
        OptionalSessionTimeField(title: "Start", value: Binding(get: { draft.startTime }, set: {
            draft.setStartTime($0, zone: zone)
        }), defaultDate: day, zone: zone, components: .hourAndMinute)
        OptionalSessionTimeField(title: "End", value: Binding(get: { draft.endTime }, set: {
            draft.endTime = $0
            if draft.day.isEmpty, let date = $0 { draft.day = Day.string(from: date, timeZone: zone) }
            draft.timeZoneID = zone.identifier
            draft.inferEndDate(zone: zone)
        }), defaultDate: draft.startTime ?? day, zone: zone, components: .hourAndMinute)
        if let start = draft.startTime, let end = draft.endTime {
            if Day.string(from: end, timeZone: zone) != Day.string(from: start, timeZone: zone) {
                Text("Ends the next day").font(.caption).foregroundStyle(.secondary)
            } else if end <= start {
                Text("Choose different start and end times.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct SessionDateField: View {
    @Binding var draft: SessionDraft
    let zone: TimeZone
    var title = "Session date"

    var body: some View {
        DatePicker(title, selection: Binding(get: {
            draft.startTime ?? Day.date(from: draft.day, timeZone: zone) ?? Date()
        }, set: { draft.moveSchedule(to: $0, zone: zone) }), displayedComponents: .date)
            .datePickerStyle(.compact)
            .environment(\.timeZone, zone)
    }
}
