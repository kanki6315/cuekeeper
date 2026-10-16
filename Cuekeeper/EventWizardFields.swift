import CoreData
import MapKit
import SwiftUI
import Combine

struct EventDateFields: View {
    @Binding var draft: JobDraft
    @State private var calendarExpanded = true

    init(draft: Binding<JobDraft>) {
        _draft = draft
        #if DEBUG
        if DesignFixtures.enabled,
           ProcessInfo.processInfo.arguments.contains("--design-collapsed-event-dates") {
            _calendarExpanded = State(initialValue: false)
        }
        #endif
    }

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
    private var multipleDays: Bool {
        !calendar.isDate(draft.startDate, inSameDayAs: draft.endDate)
    }

    private var dateSummary: String {
        let start = draft.startDate.formatted(date: .abbreviated, time: .omitted)
        guard multipleDays else { return start }
        return "\(start) – \(draft.endDate.formatted(date: .abbreviated, time: .omitted))"
    }

    var body: some View {
        if calendarExpanded {
            MultiDatePicker("Event dates", selection: selection)
                .accessibilityIdentifier("event-date-calendar")
            LabeledContent("Start", value: draft.startDate.formatted(date: .abbreviated, time: .omitted))
                .accessibilityIdentifier("event-start-summary")
            if multipleDays {
                LabeledContent("End", value: draft.endDate.formatted(date: .abbreviated, time: .omitted))
                    .accessibilityIdentifier("event-end-summary")
            }
            Text("Select one day, or the first and last days of your event. All days between are included. Selecting a third date starts a new selection.")
                .font(.caption).foregroundStyle(.secondary)
            Button { calendarExpanded = false } label: {
                Label("Done choosing dates", systemImage: "checkmark")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    .contentShape(Rectangle())
            }
            // The form already supplies 12 points of vertical padding per edge.
            .padding(.vertical, -12)
            .accessibilityIdentifier("event-date-toggle")
            .accessibilityValue("Calendar expanded")
        } else {
            Button { calendarExpanded = true } label: {
                HStack(spacing: 12) {
                    Image(systemName: "calendar").accessibilityHidden(true)
                    TimeZoneValueLabel(title: multipleDays ? "Dates" : "Date", value: dateSummary)
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color("SecondaryText"))
                        .accessibilityHidden(true)
                }
                .foregroundStyle(.primary)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .padding(.vertical, -12)
            .accessibilityIdentifier("event-date-toggle")
            .accessibilityLabel("Event dates, \(dateSummary)")
            .accessibilityHint("Opens the calendar to change dates")
            .accessibilityValue("Calendar collapsed")
        }
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

struct PlaceSuggestion {
    let title: String
    let subtitle: String
    var completion: MKLocalSearchCompletion? = nil
    var fixtureZoneID: String? = nil
    var text: String { [title, subtitle].filter { !$0.isEmpty }.joined(separator: ", ") }

    #if DEBUG
    static let fixtures = [
        PlaceSuggestion(title: "Vancouver Convention Centre", subtitle: "Vancouver, BC, Canada", fixtureZoneID: "America/Vancouver"),
        PlaceSuggestion(title: "Silverstone Circuit", subtitle: "Towcester, England", fixtureZoneID: "Europe/London"),
        PlaceSuggestion(title: "Daytona International Speedway", subtitle: "Daytona Beach, FL, United States", fixtureZoneID: "America/New_York"),
    ]
    #endif
}

@MainActor
enum PlaceZone {
    static func resolve(_ suggestion: PlaceSuggestion) async throws -> TimeZone? {
        #if DEBUG
        if let id = suggestion.fixtureZoneID {
            let delay = ProcessInfo.processInfo.arguments.contains("--slow-location-fixtures") ? 3000 : 300
            try await Task.sleep(for: .milliseconds(delay))
            return TimeZone(identifier: id)
        }
        #endif
        guard let completion = suggestion.completion else { return nil }
        return try await MKLocalSearch(request: MKLocalSearch.Request(completion: completion)).start().mapItems.first?.timeZone
    }

    static func resolve(query: String) async throws -> TimeZone? {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        #if DEBUG
        if ProcessInfo.processInfo.isUITesting {
            return PlaceSuggestion.fixtures.first { $0.text.localizedCaseInsensitiveContains(text) }?.fixtureZoneID.flatMap(TimeZone.init(identifier:))
        }
        #endif
        let request = MKLocalSearch.Request(); request.naturalLanguageQuery = text
        return try await MKLocalSearch(request: request).start().mapItems.first?.timeZone
    }

    static func resolve(trackPlaceID: String) async throws -> TimeZone? {
        try await TrackLookup.shared.resolve(trackPlaceID).timeZone
    }

    /// Nil on failure or after the timeout; the caller keeps the previous zone.
    static func withTimeout(_ lookup: @escaping @MainActor () async throws -> TimeZone?) async -> TimeZone? {
        await withTaskGroup(of: TimeZone?.self) { group in
            group.addTask { @MainActor in try? await lookup() }
            group.addTask { try? await Task.sleep(for: .seconds(10)); return nil }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }
}

/// Tracks every place-to-zone lookup on one screen, keyed by what it sets.
@MainActor
final class PlaceZones: ObservableObject {
    @Published private var selections: [String: PlaceSelection] = [:]
    var pending: Bool { selections.values.contains(where: \.pending) }
    func pending(_ key: String) -> Bool { selections[key]?.pending ?? false }
    func failed(_ key: String) -> Bool { selections[key]?.failed ?? false }

    func choose(_ key: String, apply: @escaping (String) -> Void, lookup: @escaping @MainActor () async throws -> TimeZone?) {
        let token = selections[key, default: PlaceSelection()].begin()
        Task {
            let zone = await PlaceZone.withTimeout(lookup)
            if let zone = selections[key, default: PlaceSelection()].finish(token, zone: zone) { apply(zone.identifier) }
        }
    }

    func edited(_ key: String) {
        guard selections[key] != nil else { return }
        selections[key]?.cancel()
    }
}

@MainActor
final class LocationSuggestions: NSObject, ObservableObject, @preconcurrency MKLocalSearchCompleterDelegate {
    @Published var results: [PlaceSuggestion] = []
    @Published var unavailable = false
    private let completer = MKLocalSearchCompleter()
    override init() {
        super.init(); completer.delegate = self; completer.resultTypes = [.address, .pointOfInterest]
    }
    func search(_ text: String) {
        unavailable = false
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty { completer.cancel(); results = []; return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--location-fixtures") {
            results = PlaceSuggestion.fixtures.filter { $0.text.localizedCaseInsensitiveContains(query) }
            return
        }
        #endif
        completer.queryFragment = text
    }
    func stop() { completer.cancel(); results = [] }
    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        results = completer.results.prefix(5).map { PlaceSuggestion(title: $0.title, subtitle: $0.subtitle, completion: $0) }
    }
    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) { results = []; unavailable = true }
}

/// Picking a suggestion reports it so the caller can set a zone; typing reports an edit.
struct LocationSearchField: View {
    var title = "Location"
    @Binding var text: String
    var identifier = "location-field"
    var onChoose: ((PlaceSuggestion) -> Void)? = nil
    var onEdit: (() -> Void)? = nil
    @StateObject private var suggestions = LocationSuggestions()
    @FocusState private var focused: Bool
    @State private var chosen: String?
    var body: some View {
        DaybookTextField(title, text: $text).focused($focused).accessibilityIdentifier(identifier)
            .onChange(of: text) { _, value in
                if focused { suggestions.search(value) }
                if value != chosen { chosen = nil; onEdit?() }
            }
            .onChange(of: focused) { _, value in if value { suggestions.search(text) } else { suggestions.stop() } }
        if focused {
            ForEach(Array(suggestions.results.enumerated()), id: \.offset) { _, result in
                Button {
                    focused = false; suggestions.stop()
                    chosen = result.text; text = result.text
                    onChoose?(result)
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
    var zone: TimeZone { .effective(eventTimeZoneID) }
    var body: some View {
        DaybookTextField("Session title", text: $draft.name)
        SessionDateField(draft: $draft, zone: zone, title: "Date").accessibilityIdentifier("wizard-session-date").accessibilityLabel("Session date")
        SessionScheduleField(draft: $draft, zone: zone)
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
    }
}

func zoneLabel(_ identifier: String, date: Date = Date()) -> String {
    guard let zone = TimeZone(identifier: identifier) else { return "Unspecified" }
    let name = zone.localizedName(for: .generic, locale: .current) ?? identifier
    let seconds = zone.secondsFromGMT(for: date)
    let offset = String(format: "UTC%@%02d:%02d", seconds < 0 ? "−" : "+", abs(seconds) / 3600, abs(seconds) % 3600 / 60)
    return "\(name) · \(offset)"
}

/// Zones are never picked directly; this shows the one a place set, or the home fallback.
struct DerivedTimeZoneRow: View {
    let title: String
    let timeZoneID: String
    let date: Date
    let caption: String
    let identifier: String
    @ObservedObject var zones: PlaceZones
    let key: String
    var body: some View {
        TimeZoneValueLabel(title: title, value: zoneLabel(TimeZone.effective(timeZoneID).identifier, date: date))
            .accessibilityElement(children: .combine).accessibilityIdentifier(identifier)
        Group {
            if zones.pending(key) {
                HStack(spacing: 8) { ProgressView(); Text("Finding timezone…") }.accessibilityIdentifier("\(identifier)-pending")
            } else if zones.failed(key) {
                Text("Couldn’t get a timezone for this place.")
            } else {
                Text(TimeZone(identifier: timeZoneID) == nil ? "Your home timezone." : caption)
            }
        }.font(.caption).foregroundStyle(.secondary)
    }
}

/// The event location and track both set the event timezone; the last one chosen wins.
struct EventPlaceFields: View {
    @Binding var location: String
    @Binding var trackPlaceID: String
    @Binding var timeZoneID: String
    let date: Date
    @ObservedObject var zones: PlaceZones
    let key: String
    var locationIdentifier = "job-location"
    @State private var choosingTrack = false
    var body: some View {
        LocationSearchField(text: $location, identifier: locationIdentifier, onChoose: { suggestion in
            choose { try await PlaceZone.resolve(suggestion) }
        }, onEdit: { zones.edited(key) })
        if !trackPlaceID.isEmpty { SavedTrackView(placeID: trackPlaceID) }
        Button(trackPlaceID.isEmpty ? "Choose track location" : "Change track location", systemImage: "mappin.and.ellipse") { choosingTrack = true }
            .accessibilityIdentifier("choose-track")
            .sheet(isPresented: $choosingTrack) { TrackLocationPicker(placeID: $trackPlaceID) }
            .onChange(of: trackPlaceID) { _, id in
                if !id.isEmpty { choose { try await PlaceZone.resolve(trackPlaceID: id) } }
            }
        if !trackPlaceID.isEmpty { Button("Remove track location", role: .destructive) { trackPlaceID = "" }.accessibilityIdentifier("remove-track") }
        DerivedTimeZoneRow(title: "Event timezone", timeZoneID: timeZoneID, date: date,
                           caption: "Set by the event’s location or track. All sessions use it.",
                           identifier: "event-timezone", zones: zones, key: key)
    }
    private func choose(_ lookup: @escaping @MainActor () async throws -> TimeZone?) {
        let zone = $timeZoneID
        zones.choose(key, apply: { zone.wrappedValue = $0 }, lookup: lookup)
    }
}

/// Remote and hybrid work happens where the user is, which sets their timezone.
struct WorkLocationFields: View {
    @Binding var draft: JobDraft
    let date: Date
    @ObservedObject var zones: PlaceZones
    let key: String
    private static func remote(_ value: WorkArrangement) -> Bool { value == .remote || value == .hybrid }
    var body: some View {
        Group {
            if Self.remote(draft.workArrangement) {
                LocationSearchField(title: "Your location", text: $draft.location, identifier: "work-location", onChoose: { suggestion in
                    let zone = $draft.timeZoneID
                    zones.choose(key, apply: { zone.wrappedValue = $0 }) { try await PlaceZone.resolve(suggestion) }
                }, onEdit: { zones.edited(key) })
                DerivedTimeZoneRow(title: "Your timezone", timeZoneID: draft.timeZoneID, date: date,
                                   caption: "Set by your location. Session times also show in this timezone.",
                                   identifier: "work-timezone", zones: zones, key: key)
            }
        }
        .onChange(of: draft.workArrangement) { old, new in
            // On-site bookings store the venue here; it isn't where the user works from.
            if Self.remote(new) && !Self.remote(old) {
                zones.edited(key); draft.location = ""; draft.timeZoneID = TimeZone.home.identifier
            }
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


// Resolve on every access: controls can retain bindings after their row is removed.
// The snapshot keeps teardown reads safe; late writes to deleted items are ignored.
extension Binding {
    func elementBinding<Element: Identifiable>(for snapshot: Element) -> Binding<Element> where Value == [Element] {
        Binding<Element>(
            get: { wrappedValue.first { $0.id == snapshot.id } ?? snapshot },
            set: { updated in
                guard let index = wrappedValue.firstIndex(where: { $0.id == snapshot.id }) else { return }
                wrappedValue[index] = updated
            }
        )
    }
}
