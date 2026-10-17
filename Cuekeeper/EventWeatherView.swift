import Combine
import MapKit
import SwiftUI

/// Owns one event's forecast: eligibility, the shared cache and request limits stay in EventWeatherStore.
@MainActor final class EventWeatherLoader: ObservableObject {
    @Published private(set) var snapshot: EventWeatherSnapshot?
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published private(set) var now = Date()
    private var venueZone: TimeZone?
    private var loadID = UUID()
    private(set) var request: EventWeatherRequest?

    private func potentiallyEligible(_ request: EventWeatherRequest) -> Bool {
        // Resolve the venue timezone before enforcing the exact civil-date window.
        // This broad preflight allows both sides of the international date line.
        request.eligible(now: now, timeZone: TimeZone(secondsFromGMT: -12 * 3600)!) ||
        request.eligible(now: now, timeZone: TimeZone(secondsFromGMT: 14 * 3600)!)
    }
    /// Callers pass the job's request so eligibility is known before the first load starts.
    func eligible(_ request: EventWeatherRequest) -> Bool {
        potentiallyEligible(request) && (venueZone.map { request.eligible(now: now, timeZone: $0) } ?? true)
    }
    /// A forecast that may be shown right now.
    func current(_ request: EventWeatherRequest) -> EventWeatherSnapshot? {
        guard request == self.request, eligible(request), let snapshot, snapshot.canDisplay(at: now) else { return nil }
        return snapshot
    }

    func reset(for request: EventWeatherRequest) {
        self.request = request
        loadID = UUID(); loading = false; snapshot = nil; venueZone = nil
    }

    func tick(_ date: Date, scenePhase: ScenePhase) {
        now = date
        EventWeatherStore.shared.purgeExpired()
        if let snapshot, !snapshot.canDisplay(at: date) { self.snapshot = nil }
        if scenePhase == .active, let request, eligible(request), EventWeatherStore.shared.nextAttempt(placeID: request.placeID) == nil {
            Task { await load() }
        }
    }

    func load() async {
        now = Date()
        guard let requested = request, potentiallyEligible(requested) else { snapshot = nil; return }
        #if DEBUG
        if ProcessInfo.processInfo.isUITesting || NSClassFromString("XCTestCase") != nil {
            if ProcessInfo.processInfo.arguments.contains("--weather-fixtures") {
                snapshot = .fixture(now: now); venueZone = snapshot?.timeZone
            }
            return // Automated tests never consume real WeatherKit quota.
        }
        #endif
        if let cached = EventWeatherStore.shared.cached(placeID: requested.placeID) {
            venueZone = cached.timeZone
            snapshot = requested.eligible(now: now, timeZone: cached.timeZone) ? cached : nil
            if EventWeatherStore.shared.nextAttempt(placeID: requested.placeID) != nil { return }
        } else {
            snapshot = nil
        }
        guard !loading else { return }
        loading = true; error = nil
        let token = UUID(); loadID = token
        defer { if loadID == token { loading = false } }
        do {
            let track = try await TrackLookup.shared.resolve(requested.placeID)
            try Task.checkCancellation()
            guard requested == request else { return }
            guard let zone = track.timeZone else { throw EventWeatherStore.Failure.unavailable }
            venueZone = zone
            guard requested.eligible(now: Date(), timeZone: zone) else { return }
            let result = try await EventWeatherStore.shared.load(placeID: requested.placeID, location: track.location, timeZone: zone)
            try Task.checkCancellation()
            guard requested == request else { return }
            snapshot = result; now = Date()
        } catch {
            if !Task.isCancelled {
                self.error = (error as? EventWeatherStore.Failure)?.localizedDescription
                    ?? "The track forecast couldn’t be loaded. Check your connection; weather also needs to be available for this location."
            }
        }
    }

    /// The day's forecast for a run-of-show day key, matched in the venue's own timezone.
    func day(_ key: String, request: EventWeatherRequest) -> EventWeatherDay? {
        guard let snapshot = current(request) else { return nil }
        return snapshot.days(for: request, now: now).first { Day.string(from: $0.date, timeZone: snapshot.timeZone) == key }
    }
}

/// Keeps a loader current while its view is visible: on appear, on return to the foreground and every minute.
struct EventWeatherDriver: ViewModifier {
    @ObservedObject var loader: EventWeatherLoader
    let request: EventWeatherRequest?
    @Environment(\.scenePhase) private var scenePhase
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    func body(content: Content) -> some View {
        content
            .task(id: request) {
                guard let request else { return }
                loader.reset(for: request); await loader.load()
            }
            .onChange(of: scenePhase) { _, phase in if phase == .active { Task { await loader.load() } } }
            .onReceive(timer) { loader.tick($0, scenePhase: scenePhase) }
    }
}

extension View {
    func eventWeather(_ loader: EventWeatherLoader, request: EventWeatherRequest?) -> some View { modifier(EventWeatherDriver(loader: loader, request: request)) }
}

enum WeatherFormat {
    static func temperature(_ value: Double) -> String {
        Measurement(value: value, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .abbreviated, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))
    }
    /// "24° Partly cloudy" for a run-of-show day header.
    static func headline(_ day: EventWeatherDay) -> String { "\(temperature(day.high)) \(day.condition)" }
}

/// Forecast status and the Apple Weather attribution, shown wherever forecast data appears.
struct WeatherStatusFooter: View {
    @ObservedObject var loader: EventWeatherLoader
    let request: EventWeatherRequest
    var body: some View {
        if loader.eligible(request) {
            VStack(alignment: .leading, spacing: 6) {
                if let snapshot = loader.current(request) {
                    Text("Track forecast updated \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened)) · \(snapshot.timeZoneID.replacingOccurrences(of: "_", with: " ")) time")
                        .font(.footnote).foregroundStyle(Color.theme.secondaryText)
                    if snapshot.isOutdated(at: loader.now) {
                        Label("Outdated forecast · awaiting daily update", systemImage: "clock")
                            .font(.caption).foregroundStyle(Color.theme.amberText)
                            .accessibilityElement(children: .combine)
                            .accessibilityIdentifier("weather-outdated")
                    }
                    WeatherAttribution(snapshot: snapshot)
                } else if loader.loading {
                    ProgressView("Getting the track forecast…").font(.footnote)
                } else {
                    Label("Weather unavailable", systemImage: "cloud").font(.footnote)
                    Text(loader.error ?? "Open this event while connected to load the forecast.")
                        .font(.footnote).foregroundStyle(Color.theme.secondaryText)
                    if let next = EventWeatherStore.shared.nextAttempt(placeID: request.placeID) {
                        Text("Next update available \(next.formatted(date: .abbreviated, time: .shortened)).")
                            .font(.caption).foregroundStyle(Color.theme.secondaryText)
                    } else {
                        Button("Try again") { Task { await loader.load() } }.frame(minHeight: 44)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct WeatherAttribution: View {
    let snapshot: EventWeatherSnapshot
    @Environment(\.colorScheme) private var colorScheme
    var body: some View {
        Link(destination: snapshot.legalURL) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) { mark; Text("Data sources").font(.caption).fixedSize() }
                VStack(alignment: .leading, spacing: 8) { mark; Text("Data sources").font(.caption) }
            }.frame(minHeight: 44)
        }.accessibilityLabel("Apple Weather data sources")
    }
    private var mark: some View {
        AsyncImage(url: colorScheme == .dark ? snapshot.darkMarkURL : snapshot.lightMarkURL) { image in
            image.resizable().scaledToFit().frame(width: 96, height: 24)
        } placeholder: {
            Text("Apple Weather").font(.subheadline).fixedSize(horizontal: true, vertical: false)
        }.fixedSize()
    }
}

/// The track forecast for one session: its day, then each hour from call (or start) to the end.
/// The parent attaches `eventWeather(_:request:)` so loading runs even before this section has content.
struct SessionWeatherSection: View {
    @ObservedObject var session: WorkSession
    @ObservedObject var loader: EventWeatherLoader
    var body: some View {
        if let request = session.job?.weatherRequest, loader.eligible(request), session.coverage != "notCovering",
           let start = session.callTime ?? session.startTime {
            let end = session.endTime ?? start.addingTimeInterval(3600)
            Section {
                if let snapshot = loader.current(request) {
                    let hours = snapshot.hours(from: start, to: end)
                    if let day = loader.day(session.eventDay, request: request) {
                        Label("\(day.condition) · High \(WeatherFormat.temperature(day.high)) · Low \(WeatherFormat.temperature(day.low))", systemImage: day.symbol)
                            .accessibilityElement(children: .combine)
                    }
                    if hours.isEmpty {
                        Text("Hourly forecast isn’t available for this session yet.").foregroundStyle(Color.theme.secondaryText)
                    }
                    ForEach(hours) { hour in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(hourText(hour.date, zone: snapshot.timeZone)).font(.subheadline).fontWeight(.semibold)
                            Label("\(hour.condition) · \(WeatherFormat.temperature(hour.temperature))", systemImage: hour.symbol)
                            WeatherMetrics(precipitation: hour.precipitation, wind: hour.wind)
                        }.padding(.vertical, 6).accessibilityElement(children: .combine).accessibilityIdentifier("weather-hour")
                    }
                }
                WeatherStatusFooter(loader: loader, request: request)
            } header: { Text("Track weather") } footer: {
                Text("Hourly from \(session.callTime == nil ? "session start" : "call time"). Forecasts can change before the event.")
            }
        }
    }
    private func hourText(_ date: Date, zone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = zone
        return date.formatted(style)
    }
}

struct WeatherMetrics: View {
    let precipitation: Double
    let wind: Double
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { rain; windLabel }
            VStack(alignment: .leading, spacing: 6) { rain; windLabel }
        }.font(.subheadline).foregroundStyle(Color.theme.secondaryText)
    }
    private var rain: some View {
        Label("Precipitation \(precipitation.formatted(.percent.precision(.fractionLength(0))))", systemImage: "drop")
    }
    private var windLabel: some View {
        Label("Wind \(Measurement(value: wind, unit: UnitSpeed.kilometersPerHour).formatted(.measurement(width: .abbreviated, usage: .wind, numberFormatStyle: .number.precision(.fractionLength(0)))))", systemImage: "wind")
    }
}

#if DEBUG
extension EventWeatherSnapshot {
    static func fixture(now: Date) -> EventWeatherSnapshot {
        let zone = TimeZone(identifier: "America/New_York")!
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let today = calendar.startOfDay(for: now)
        return EventWeatherSnapshot(fetchedAt: now.addingTimeInterval(-7200), expiresAt: now.addingTimeInterval(-3600),
            timeZoneID: zone.identifier,
            days: (0..<10).map { EventWeatherDay(date: calendar.date(byAdding: .day, value: $0, to: today)!,
                condition: "Partly cloudy", symbol: "cloud.sun.fill", high: 24, low: 16, precipitation: 0.35, wind: 18) },
            hours: (0..<240).map { EventWeatherHour(date: today.addingTimeInterval(Double($0) * 3600),
                condition: "Partly cloudy", symbol: "cloud.sun.fill", temperature: 22, precipitation: 0.35, wind: 18) },
            legalURL: URL(string: "https://weatherkit.apple.com/legal-attribution.html")!,
            lightMarkURL: URL(string: "https://weatherkit.apple.com/assets/branding/en/Apple_Weather_mark_Light.svg")!,
            darkMarkURL: URL(string: "https://weatherkit.apple.com/assets/branding/en/Apple_Weather_mark_Dark.svg")!)
    }
}
#endif
