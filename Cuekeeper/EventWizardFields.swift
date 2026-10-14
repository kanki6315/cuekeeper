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
    @State private var adding = false
    @State private var newName = ""
    @FocusState private var enteringName: Bool
    var body: some View {
        ForEach(names.sorted(), id: \.self) { name in
            HStack {
                Text(name); Spacer()
                Button("Remove", systemImage: "minus.circle", role: .destructive) { names.remove(name) }
                    .labelStyle(.iconOnly).accessibilityLabel("Remove \(name)").frame(minWidth: 44, minHeight: 44)
            }
        }
        Button { enteringName = false; adding.toggle() } label: {
            HStack { Text("Add championship"); Spacer(); Image(systemName: adding ? "chevron.up" : "chevron.down") }
        }
        if adding {
            let available = Array(Set(library.map(\.name))).filter { !names.contains($0) }.sorted()
            if !available.isEmpty {
                Menu("Reuse championship") { ForEach(available, id: \.self) { name in Button(name) { enteringName = false; names.insert(name); adding = false } } }
            }
            HStack {
                DaybookTextField("New championship", text: $newName).focused($enteringName).onSubmit(add)
                Button("Add", action: add).disabled(newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
    private func add() {
        let value = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        let canonical = library.first { $0.name.compare(value, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }?.name ?? value
        enteringName = false; names.insert(canonical); newName = ""; adding = false
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
    var zone: TimeZone { TimeZone(identifier: draft.timeZoneID) ?? .current }
    var body: some View {
        DaybookTextField("Session title", text: $draft.name)
        DatePicker("Date", selection: Binding(get: { Day.date(from: draft.day, timeZone: zone) ?? Date() }, set: { draft.day = Day.string(from: $0, timeZone: zone) }), displayedComponents: .date).environment(\.timeZone, zone).disabled(draft.startTime != nil).accessibilityIdentifier("wizard-session-date").accessibilityLabel("Session date")
        DaybookLink { TimeZonePicker(selection: $draft.timeZoneID, date: draft.startTime ?? Day.date(from: draft.day, timeZone: zone) ?? Date()) } label: { LabeledContent("Timezone", value: zoneLabel(draft.timeZoneID, date: draft.startTime ?? Day.date(from: draft.day, timeZone: zone) ?? Date())) }
        if draft.timeZoneID.isEmpty { Text("Choose a timezone to add times.").font(.caption).foregroundStyle(.secondary) }
        SessionScheduleField(draft: $draft)
        optionalTime("Call time", value: $draft.callTime)
        DaybookChoicePicker("Schedule", selection: $draft.scheduleStatus, identifier: "wizard-session-schedule") { Text("Tentative").tag("tentative"); Text("Confirmed").tag("confirmed") }
        DaybookChoicePicker("Coverage", selection: $draft.coverage, identifier: "wizard-session-coverage") { Text("Undecided").tag("undecided"); Text("Covering").tag("covering"); Text("Not covering").tag("notCovering") }
        Group {}.onChange(of: draft.startTime) { _, value in if let value { draft.day = Day.string(from: value, timeZone: zone) } }
            .onChange(of: draft.timeZoneID) { _, _ in if let value = draft.startTime { draft.day = Day.string(from: value, timeZone: zone) } }
    }
    @ViewBuilder private func optionalTime(_ title: String, value: Binding<Date?>) -> some View {
        OptionalSessionTimeField(title: title, value: value,
            defaultDate: (draft.startTime ?? Day.date(from: draft.day, timeZone: zone) ?? Date())
                .addingTimeInterval(title == "End" ? 3600 : 0), zone: zone)
            .disabled(draft.timeZoneID.isEmpty)
    }
}

func zoneLabel(_ identifier: String, date: Date = Date()) -> String {
    guard let zone = TimeZone(identifier: identifier) else { return "Unspecified" }
    let name = zone.localizedName(for: .generic, locale: .current) ?? identifier
    let seconds = zone.secondsFromGMT(for: date)
    let offset = String(format: "UTC%@%02d:%02d", seconds < 0 ? "−" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
    return "\(name) · \(offset)"
}

/// Opening the editor never assigns a time; only Set or Clear changes the draft.
struct OptionalSessionTimeField: View {
    let title: String
    @Binding var value: Date?
    let defaultDate: Date
    let zone: TimeZone
    @State private var editing = false

    var body: some View {
        Button { editing = true } label: {
            ViewThatFits(in: .horizontal) {
                HStack {
                    Text(title).foregroundStyle(.primary)
                    Spacer()
                    summary
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text(title).foregroundStyle(.primary)
                    summary
                }
            }.frame(minHeight: 44)
        }
        .accessibilityIdentifier("session-time-\(title)")
        .sheet(isPresented: $editing) {
            SessionTimeEditor(title: title, value: $value, initialDate: value ?? defaultDate, zone: zone)
        }
    }

    private func formatted(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = zone
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    private var summary: some View {
        HStack {
            if let value {
                Text(formatted(value))
            } else { Text("Not set") }
            Image(systemName: "chevron.right").font(.caption)
        }
    }
}

private struct SessionTimeEditor: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    @Binding var value: Date?
    let zone: TimeZone
    @State private var date: Date
    @State private var typing = false
    @State private var text = ""

    init(title: String, value: Binding<Date?>, initialDate: Date, zone: TimeZone) {
        self.title = title; _value = value; self.zone = zone
        _date = State(initialValue: initialDate)
    }

    private var result: Date? { typing ? SessionTimeInput.date(text, on: date, zone: zone) : date }

    var body: some View {
        NavigationStack {
            DaybookForm {
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Picker("Time entry", selection: $typing) {
                        Text("Picker").tag(false)
                        Text("Type time").tag(true)
                    }.pickerStyle(.segmented)
                    if typing {
                        TextField("Time, e.g. 9:30 AM or 21:30", text: $text)
                            .textInputAutocapitalization(.never).autocorrectionDisabled()
                            .accessibilityLabel("\(title) time")
                            .accessibilityIdentifier("typed-session-time")
                        if result == nil && !text.isEmpty {
                            Text("Enter a time like 9:30 AM or 21:30. The time must exist on this date.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    } else {
                        DatePicker("Time", selection: $date, displayedComponents: .hourAndMinute)
                            .datePickerStyle(.wheel).labelsHidden()
                    }
                } footer: { Text(zoneLabel(zone.identifier, date: date)) }
                if value != nil {
                    Section {
                        Button("Clear \(title.lowercased())", role: .destructive) { value = nil; dismiss() }
                    }
                }
            }
            .environment(\.timeZone, zone)
            .navigationTitle(title).navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") { if let result { value = result; dismiss() } }.disabled(result == nil)
                }
            }
            .onChange(of: typing) { old, enabled in
                if enabled {
                    let formatter = DateFormatter()
                    formatter.locale = Locale(identifier: "en_US_POSIX")
                    formatter.timeZone = zone; formatter.dateFormat = "HH:mm"
                    text = formatter.string(from: date)
                } else if old, let parsed = SessionTimeInput.date(text, on: date, zone: zone) { date = parsed }
            }
        }
    }
}

struct SessionScheduleField: View {
    @Binding var draft: SessionDraft
    @State private var editing = false
    private var zone: TimeZone { TimeZone(identifier: draft.timeZoneID) ?? .current }
    private var summary: String {
        guard draft.startTime != nil || draft.endTime != nil else { return "Not set" }
        let formatter = DateFormatter()
        formatter.timeZone = zone; formatter.dateStyle = .medium; formatter.timeStyle = .short
        return [draft.startTime.map { formatter.string(from: $0) } ?? "Start not set",
                draft.endTime.map { formatter.string(from: $0) } ?? "End not set"].joined(separator: " – ")
    }
    var body: some View {
        Button { editing = true } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack { Text("Start & end"); Spacer(); Image(systemName: "chevron.right").font(.caption) }
                Text(summary).font(.subheadline).foregroundStyle(.secondary)
            }.frame(minHeight: 44)
        }
        .accessibilityIdentifier("session-schedule-times")
        .sheet(isPresented: $editing) { SessionScheduleEditor(draft: $draft, zone: zone) }
    }
}

private struct SessionScheduleEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: SessionDraft
    let zone: TimeZone
    @State private var day: Date
    @State private var endDay: Date
    @State private var differentEndDay: Bool
    @State private var startText: String
    @State private var endText: String

    init(draft: Binding<SessionDraft>, zone: TimeZone) {
        _draft = draft; self.zone = zone
        let value = draft.wrappedValue
        let base = value.startTime ?? Day.date(from: value.day, timeZone: zone) ?? value.endTime ?? Date()
        _day = State(initialValue: base)
        _endDay = State(initialValue: value.endTime ?? base)
        _differentEndDay = State(initialValue: value.endTime.map {
            Day.string(from: $0, timeZone: zone) != Day.string(from: base, timeZone: zone)
        } ?? false)
        _startText = State(initialValue: Self.clock(value.startTime, zone: zone))
        _endText = State(initialValue: Self.clock(value.endTime, zone: zone))
    }
    static func clock(_ date: Date?, zone: TimeZone) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = zone; formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
    private var start: Date? { SessionTimeInput.date(startText, on: day, zone: zone) }
    private var end: Date? { SessionTimeInput.date(endText, on: differentEndDay ? endDay : day, zone: zone) }
    private var issue: String? {
        if (!startText.isEmpty && start == nil) || (!endText.isEmpty && end == nil) {
            return "Enter a time like 9:30 AM or 21:30. The time must exist on this date."
        }
        if let start, let end, end <= start { return "End must be after start. For overnight work, choose a different end date." }
        return nil
    }
    var body: some View {
        NavigationStack {
            DaybookForm {
                Section {
                    DatePicker("Date", selection: $day, displayedComponents: .date)
                    ScheduleClockField(title: "Start", text: $startText, day: day, zone: zone)
                    ScheduleClockField(title: "End", text: $endText, day: differentEndDay ? endDay : day, zone: zone)
                    Toggle("Different end date", isOn: $differentEndDay)
                    if differentEndDay { DatePicker("End date", selection: $endDay, displayedComponents: .date) }
                } footer: { Text(zoneLabel(zone.identifier, date: day)) }
                if let issue { Section { Text(issue).foregroundStyle(.secondary) } }
                Section { Button("Clear start & end", role: .destructive) { startText = ""; endText = "" } }
            }
            .environment(\.timeZone, zone)
            .navigationTitle("Start & end").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        draft.startTime = start; draft.endTime = end
                        draft.day = Day.string(from: day, timeZone: zone)
                        if (start != nil || end != nil) && draft.timeZoneID.isEmpty { draft.timeZoneID = zone.identifier }
                        dismiss()
                    }.disabled(issue != nil)
                }
            }
        }
    }
}

private struct ScheduleClockField: View {
    let title: String
    @Binding var text: String
    let day: Date
    let zone: TimeZone
    @State private var picking = false
    private var selection: Binding<Date> {
        Binding(get: { SessionTimeInput.date(text, on: day, zone: zone) ?? day },
                set: { text = SessionScheduleEditor.clock($0, zone: zone) })
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            HStack {
                TextField("Not set", text: $text)
                    .textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityLabel("\(title) time").accessibilityIdentifier("schedule-time-\(title)")
                Button { picking.toggle() } label: { Image(systemName: "clock").frame(minWidth: 44, minHeight: 44) }
                    .accessibilityLabel("Pick \(title.lowercased()) time")
                if !text.isEmpty {
                    Button { text = ""; picking = false } label: { Image(systemName: "xmark.circle").frame(minWidth: 44, minHeight: 44) }
                        .accessibilityLabel("Clear \(title.lowercased())")
                }
            }
            if picking {
                DatePicker(title, selection: selection, displayedComponents: .hourAndMinute)
                    .datePickerStyle(.wheel).labelsHidden()
                if text.isEmpty {
                    Button("Use displayed time") { text = SessionScheduleEditor.clock(selection.wrappedValue, zone: zone) }
                }
            }
            Text("Type a time, e.g. 9:30 AM or 21:30").font(.caption).foregroundStyle(.secondary)
        }
    }
}
