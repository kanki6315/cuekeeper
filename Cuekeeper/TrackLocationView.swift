import MapKit
import SwiftUI

@MainActor
final class TrackLookup {
    static let shared = TrackLookup()
    private var cache: [String: (item: MKMapItem, fetched: Date)] = [:]
    private var inFlight: [String: Task<MKMapItem, Error>] = [:]

    func resolve(_ placeID: String) async throws -> MKMapItem {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            if ProcessInfo.processInfo.arguments.contains("--weather-fixtures"), placeID == "fixture-track" {
                let item = MKMapItem(location: CLLocation(latitude: 29.1852, longitude: -81.0705), address: nil)
                item.name = "Daytona International Speedway"; item.timeZone = TimeZone(identifier: "America/New_York")
                return item
            }
            throw EventWeatherStore.Failure.unavailable
        }
        #endif
        cache = cache.filter { Date().timeIntervalSince($0.value.fetched) < 3600 }
        if let item = cache[placeID]?.item { return item }
        if let task = inFlight[placeID] { return try await task.value }
        guard let identifier = MKMapItem.Identifier(rawValue: placeID) else { throw EventWeatherStore.Failure.unavailable }
        let task = Task { try await MKMapItemRequest(mapItemIdentifier: identifier).mapItem }
        inFlight[placeID] = task
        defer { inFlight[placeID] = nil }
        let item = try await task.value
        cache[placeID] = (item, Date())
        return item
    }
}

struct TrackMap: View {
    let item: MKMapItem
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Map(initialPosition: .region(MKCoordinateRegion(center: item.location.coordinate,
                span: MKCoordinateSpan(latitudeDelta: 0.035, longitudeDelta: 0.035))), interactionModes: []) {
                Marker(item: item)
            }
            .frame(height: 160)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .accessibilityLabel("Map of \(item.name ?? "selected track")")
            Text(item.name ?? "Selected track").font(.headline)
            if let address = item.address?.fullAddress { Text(address).font(.subheadline).foregroundStyle(Color("SecondaryText")) }
            Button("Open in Apple Maps", systemImage: "arrow.up.right") { item.openInMaps() }
                .frame(minHeight: 44)
        }
    }
}

struct SavedTrackView: View {
    let placeID: String
    @State private var item: MKMapItem?
    @State private var failed = false
    var body: some View {
        Group {
            if let item { TrackMap(item: item).id(placeID) }
            else if failed { Text("Track saved. Connect to the internet to load its map.").foregroundStyle(Color("SecondaryText")) }
            else { ProgressView("Loading track…") }
        }
        .task(id: placeID) {
            item = nil; failed = false
            do {
                let result = try await TrackLookup.shared.resolve(placeID)
                try Task.checkCancellation(); item = result
            } catch { if !Task.isCancelled { failed = true } }
        }
    }
}

/// Debounced typeahead keeps results current without submitting on every keystroke.
struct TrackLocationPicker: View {
    @Binding var placeID: String
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var selected: MKMapItem?
    @State private var searching = false
    @State private var searched = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            DaybookForm(title: "Track location") {
                Section {
                    DaybookTextField("Track name and city", text: $query)
                        .accessibilityIdentifier("track-search-field")
                        .submitLabel(.search).onSubmit { search() }
                        .onChange(of: query) { _, _ in search(debounce: true) }
                } footer: { Text("Suggestions appear as you type. Add a city to narrow the results, then select a track. Your device location isn’t needed.") }
                if searching { Section { ProgressView("Searching Apple Maps…") } }
                if let error {
                    Section {
                        Text(error).foregroundStyle(Color("SecondaryText"))
                        Button("Try again") { search() }.frame(minHeight: 44)
                    }
                }
                if !results.isEmpty && selected == nil {
                    Section("Search results") {
                        ForEach(Array(results.enumerated()), id: \.offset) { index, item in
                            Button {
                                selected = item; results = [item]
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(item.name ?? "Unnamed venue").foregroundStyle(.primary)
                                        if let address = item.address?.fullAddress {
                                            Text(address).font(.subheadline).foregroundStyle(Color("SecondaryText"))
                                        }
                                    }
                                    Spacer()
                                    if selected === item { Image(systemName: "checkmark.circle.fill") }
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityIdentifier("track-result-\(index)")
                        }
                    }
                } else if searched && !searching && error == nil && selected == nil {
                    Section { Text("No matching tracks. Try the full venue name and city.").foregroundStyle(Color("SecondaryText")) }
                }
                if let selected {
                    Section("Confirm track") {
                        TrackMap(item: selected).id(selected.identifier?.rawValue ?? query)

                    }
                }
            }
            .navigationTitle("Track location").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Use track") {
                        guard let selected, let id = identifier(for: selected) else { return }
                        placeID = id; dismiss()
                    }.disabled(selected == nil).accessibilityIdentifier("use-track")
                }
            }
            .onDisappear { searchTask?.cancel() }
        }
        .presentationSizing(.page)
        .presentationDetents([.large])
        .presentationBackground(Color("PageBackground"))
    }

    private func identifier(for item: MKMapItem) -> String? {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") && ProcessInfo.processInfo.arguments.contains("--weather-fixtures") { return "fixture-track" }
        #endif
        return item.identifier?.rawValue
    }

    private func search(debounce: Bool = false) {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        searching = false; searched = false; error = nil; selected = nil; results = []
        guard !text.isEmpty else { return }
        searching = true; searched = true
        searchTask = Task { @MainActor in
            do {
                if debounce { try await Task.sleep(for: .milliseconds(350)) }
                try Task.checkCancellation()
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
                    if ProcessInfo.processInfo.arguments.contains("--weather-fixtures") {
                        let item = try await TrackLookup.shared.resolve("fixture-track")
                        try Task.checkCancellation()
                        results = [item]; searching = false
                        return
                    }
                    throw EventWeatherStore.Failure.unavailable
                }
                #endif
                let request = MKLocalSearch.Request(); request.naturalLanguageQuery = text
                let response = try await MKLocalSearch(request: request).start()
                try Task.checkCancellation()
                results = response.mapItems.filter { $0.identifier != nil }
                searching = false
            } catch {
                guard !Task.isCancelled else { return }
                if let mapError = error as? MKError, mapError.code == .placemarkNotFound {
                    // MapKit can report an empty search as an error instead of an empty response.
                    results = []
                    self.error = nil
                } else {
                    self.error = "Search couldn’t connect to Apple Maps. Check your connection and try again."
                }
                searching = false
            }
        }
    }
}
