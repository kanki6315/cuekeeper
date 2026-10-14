import CoreData
import MapKit
import SwiftUI
import Combine

struct EventDateFields: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var draft: JobDraft
    @State private var multipleDays = false
    var body: some View {
        Toggle("Multiple days", isOn: $multipleDays).accessibilityIdentifier("job-multiple-days")
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading) {
                Text(multipleDays ? "Start" : "Date")
                DatePicker(multipleDays ? "Start" : "Date", selection: $draft.startDate, displayedComponents: .date).datePickerStyle(.wheel).labelsHidden()
            }
            if multipleDays {
                VStack(alignment: .leading) {
                    Text("End")
                    DatePicker("End", selection: $draft.endDate, in: draft.startDate..., displayedComponents: .date).datePickerStyle(.wheel).labelsHidden().accessibilityIdentifier("job-end-date")
                }
            }
        } else {
            DatePicker(multipleDays ? "Start" : "Date", selection: $draft.startDate, displayedComponents: .date)
            if multipleDays { DatePicker("End", selection: $draft.endDate, in: draft.startDate..., displayedComponents: .date).accessibilityIdentifier("job-end-date") }
        }
        Group {}.onAppear { multipleDays = Day.string(from: draft.startDate) != Day.string(from: draft.endDate) }
            .onChange(of: draft.startDate) { _, date in if !multipleDays || draft.endDate < date { draft.endDate = date } }
            .onChange(of: multipleDays) { _, enabled in if !enabled { draft.endDate = draft.startDate } }
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
        DatePicker("Date", selection: Binding(get: { draft.startTime ?? Day.date(from: draft.day, timeZone: zone) ?? Date() }, set: { draft.day = Day.string(from: $0, timeZone: zone) }), displayedComponents: .date).environment(\.timeZone, zone).disabled(draft.startTime != nil).accessibilityIdentifier("wizard-session-date").accessibilityLabel("Session date")
        if eventTimeZoneID.isEmpty { Text("Choose the event timezone above to add times.").font(.caption).foregroundStyle(.secondary) }
        optionalTime("Start", value: $draft.startTime)
        optionalTime("End", value: $draft.endTime)
        optionalTime("Call time", value: $draft.callTime)
        DaybookChoicePicker("Schedule", selection: $draft.scheduleStatus, identifier: "wizard-session-schedule") { Text("Tentative").tag("tentative"); Text("Confirmed").tag("confirmed") }
        DaybookChoicePicker("Coverage", selection: $draft.coverage, identifier: "wizard-session-coverage") { Text("Undecided").tag("undecided"); Text("Covering").tag("covering"); Text("Not covering").tag("notCovering") }
        Group {}.onChange(of: draft.startTime) { _, value in if let value { draft.day = Day.string(from: value, timeZone: zone) } }
            .onChange(of: eventTimeZoneID) { _, _ in if let value = draft.startTime { draft.day = Day.string(from: value, timeZone: zone) } }
    }
    @ViewBuilder private func optionalTime(_ title: String, value: Binding<Date?>) -> some View {
        Toggle(title, isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? Day.date(from: draft.day, timeZone: zone) ?? Date() : nil }))
            .disabled(eventTimeZoneID.isEmpty)
        if value.wrappedValue != nil {
            DatePicker(title, selection: Binding(get: { value.wrappedValue ?? Date() }, set: { value.wrappedValue = $0 }))
                .environment(\.timeZone, zone)
        }
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
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                Text(value).foregroundStyle(Color("SecondaryText"))
            }
        } else { LabeledContent(title, value: value) }
    }
}
