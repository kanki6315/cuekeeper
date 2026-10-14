import CoreData
import MapKit
import SwiftUI
import Combine

struct EventDateFields: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var draft: JobDraft
    @State private var multipleDays = false
    var body: some View {
        Toggle("Multiple days", isOn: $multipleDays)
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading) {
                Text(multipleDays ? "Start" : "Date")
                DatePicker(multipleDays ? "Start" : "Date", selection: $draft.startDate, displayedComponents: .date).datePickerStyle(.wheel).labelsHidden()
            }
            if multipleDays {
                VStack(alignment: .leading) {
                    Text("End")
                    DatePicker("End", selection: $draft.endDate, in: draft.startDate..., displayedComponents: .date).datePickerStyle(.wheel).labelsHidden()
                }
            }
        } else {
            DatePicker(multipleDays ? "Start" : "Date", selection: $draft.startDate, displayedComponents: .date)
            if multipleDays { DatePicker("End", selection: $draft.endDate, in: draft.startDate..., displayedComponents: .date) }
        }
        Group {}.onAppear { multipleDays = Day.string(from: draft.startDate) != Day.string(from: draft.endDate) }
            .onChange(of: draft.startDate) { _, date in if !multipleDays || draft.endDate < date { draft.endDate = date } }
            .onChange(of: multipleDays) { _, enabled in if !enabled { draft.endDate = draft.startDate } }
    }
}

struct SeriesSelectionFields: View {
    @Binding var names: Set<String>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \WorkSeries.name, ascending: true)]) private var library: FetchedResults<WorkSeries>
    @State private var adding = false
    @State private var newName = ""
    var body: some View {
        ForEach(names.sorted(), id: \.self) { name in
            HStack {
                Text(name); Spacer()
                Button("Remove", systemImage: "minus.circle", role: .destructive) { names.remove(name) }
                    .labelStyle(.iconOnly).accessibilityLabel("Remove \(name)").frame(minWidth: 44, minHeight: 44)
            }
        }
        DisclosureGroup("Add championship", isExpanded: $adding) {
            let available = Array(Set(library.map(\.name))).filter { !names.contains($0) }.sorted()
            if !available.isEmpty {
                Menu("Reuse championship") { ForEach(available, id: \.self) { name in Button(name) { names.insert(name); adding = false } } }
            }
            HStack {
                DaybookTextField("New championship", text: $newName).onSubmit(add)
                Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
    private func add() {
        let value = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let canonical = library.first { $0.name.compare(value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }?.name ?? value
        names.insert(canonical); newName = ""; adding = false
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
                }
            }
            if suggestions.unavailable { Text("Suggestions unavailable. You can still enter a location.").font(.caption).foregroundStyle(.secondary) }
        }
    }
}

struct WizardSessionFields: View {
    @Binding var draft: SessionDraft
    var zone: TimeZone { TimeZone(identifier: draft.timeZoneID) ?? .current }
    var body: some View {
        DaybookTextField("Session title", text: $draft.name)
        DatePicker("Date", selection: Binding(get: { Day.date(from: draft.day, timeZone: zone) ?? Date() }, set: { draft.day = Day.string(from: $0, timeZone: zone) }), displayedComponents: .date).disabled(draft.startTime != nil)
        DaybookLink { TimeZonePicker(selection: $draft.timeZoneID, date: draft.startTime ?? Day.date(from: draft.day) ?? Date()) } label: { LabeledContent("Timezone", value: zoneLabel(draft.timeZoneID, date: draft.startTime ?? Day.date(from: draft.day) ?? Date())) }
        if draft.timeZoneID.isEmpty { Text("Choose a timezone to add times.").font(.caption).foregroundStyle(.secondary) }
        optionalTime("Start", value: $draft.startTime)
        optionalTime("End", value: $draft.endTime)
        optionalTime("Call time", value: $draft.callTime)
        DaybookPicker("Schedule", selection: $draft.scheduleStatus) { Text("Tentative").tag("tentative"); Text("Confirmed").tag("confirmed") }
        DaybookPicker("Coverage", selection: $draft.coverage) { Text("Undecided").tag("undecided"); Text("Covering").tag("covering"); Text("Not covering").tag("notCovering") }
        Group {}.onChange(of: draft.startTime) { _, value in if let value { draft.day = Day.string(from: value, timeZone: zone) } }
            .onChange(of: draft.timeZoneID) { _, _ in if let value = draft.startTime { draft.day = Day.string(from: value, timeZone: zone) } }
    }
    @ViewBuilder private func optionalTime(_ title: String, value: Binding<Date?>) -> some View {
        Toggle(title, isOn: Binding(get: { value.wrappedValue != nil }, set: { value.wrappedValue = $0 ? Day.date(from: draft.day, timeZone: zone) ?? Date() : nil }))
            .disabled(draft.timeZoneID.isEmpty)
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
