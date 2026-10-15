import Combine
import MapKit
import SwiftUI

struct EventWeatherSection: View {
    @ObservedObject var job: Job
    @Environment(\.scenePhase) private var scenePhase
    @State private var snapshot: EventWeatherSnapshot?
    @State private var now = Date()
    @State private var loading = false
    @State private var loadID = UUID()
    @State private var error: String?
    @State private var venueZone: TimeZone?
    private let timer = Timer.publish(every: 60, on: .main, in: .common).autoconnect()
    private var request: EventWeatherRequest { job.weatherRequest }
    private var potentiallyEligible: Bool {
        // Resolve the venue timezone before enforcing the exact civil-date window.
        // This broad preflight allows both sides of the international date line.
        request.eligible(now: now, timeZone: TimeZone(secondsFromGMT: -12 * 3600)!) ||
        request.eligible(now: now, timeZone: TimeZone(secondsFromGMT: 14 * 3600)!)
    }
    private var eligible: Bool {
        potentiallyEligible && (venueZone.map { request.eligible(now: now, timeZone: $0) } ?? true)
    }

    var body: some View {
        Group {
            if eligible {
                Section {
                    if let snapshot, snapshot.canDisplay(at: now) {
                        ForecastContent(snapshot: snapshot, request: request, sessions: job.eventSessions, now: now)
                    } else if loading {
                        ProgressView("Getting the track forecast…")
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Label("Weather unavailable", systemImage: "cloud")
                            Text(error ?? "Open this job while connected to load the forecast.")
                                .font(.subheadline).foregroundStyle(Color("SecondaryText"))
                            if let next = EventWeatherStore.shared.nextAttempt(placeID: request.placeID) {
                                Text("Next update available \(next.formatted(date: .abbreviated, time: .shortened)).")
                                    .font(.caption).foregroundStyle(Color("SecondaryText"))
                            } else {
                                Button("Try again") { Task { await load() } }.frame(minHeight: 44)
                            }
                        }
                    }
                } header: { Text("Track weather") }
                footer: { Text("Updates at most hourly per venue, up to 24 times per day on this device. Forecasts can change before the event.") }
            }
        }
        .task(id: request) { loadID = UUID(); loading = false; snapshot = nil; venueZone = nil; await load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } }
        }
        .onReceive(timer) { date in
            now = date
            EventWeatherStore.shared.purgeExpired()
            if let snapshot, !snapshot.canDisplay(at: date) {
                self.snapshot = nil
            }
            if scenePhase == .active, eligible,
               EventWeatherStore.shared.nextAttempt(placeID: request.placeID) == nil {
                Task { await load() }
            }
        }
    }

    @MainActor private func load() async {
        now = Date()
        guard potentiallyEligible else { snapshot = nil; return }
        let requested = request
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") || NSClassFromString("XCTestCase") != nil {
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
            guard requested == job.weatherRequest else { return }
            guard let zone = track.timeZone else { throw EventWeatherStore.Failure.unavailable }
            venueZone = zone
            guard requested.eligible(now: Date(), timeZone: zone) else { return }
            let result = try await EventWeatherStore.shared.load(placeID: requested.placeID, location: track.location, timeZone: zone)
            try Task.checkCancellation()
            guard requested == job.weatherRequest else { return }
            snapshot = result; now = Date()
        } catch {
            if !Task.isCancelled {
                self.error = (error as? EventWeatherStore.Failure)?.localizedDescription
                    ?? "The track forecast couldn’t be loaded. Check your connection; weather also needs to be available for this location."
            }
        }
    }
}

struct ForecastContent: View {
    let snapshot: EventWeatherSnapshot
    let request: EventWeatherRequest
    let sessions: [WorkSession]
    let now: Date
    @Environment(\.colorScheme) private var colorScheme
    private var days: [EventWeatherDay] { snapshot.days(for: request, now: now) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Updated \(snapshot.fetchedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.subheadline).foregroundStyle(Color("SecondaryText"))
                if snapshot.isOutdated(at: now) {
                    Label("Outdated forecast · awaiting daily update", systemImage: "clock")
                        .font(.caption).foregroundStyle(Color("AmberText"))
                        .accessibilityIdentifier("weather-outdated")
                }
            }
            if days.isEmpty {
                Text("The event dates aren’t in the available forecast yet.").foregroundStyle(Color("SecondaryText"))
            }
            ForEach(days) { day in
                VStack(alignment: .leading, spacing: 8) {
                    Text(formattedDate(day.date, hourly: false))
                        .font(.headline)
                    Label(day.condition, systemImage: day.symbol)
                    Text("High \(temperature(day.high)) · Low \(temperature(day.low))")
                        .monospacedDigit()
                    WeatherMetrics(precipitation: day.precipitation, wind: day.wind)
                }.accessibilityElement(children: .combine)
                if day.id != days.last?.id { Divider() }
            }
            ForEach(sessions.filter { $0.scheduleStatus != "cancelled" && $0.coverage != "notCovering" }, id: \.objectID) { session in
                if let start = session.callTime ?? session.startTime {
                    let end = session.endTime ?? start.addingTimeInterval(3600)
                    let hours = snapshot.hours(from: start, to: end)
                    if !hours.isEmpty && end > now {
                        DisclosureGroup {
                            ForEach(hours) { hour in
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(formattedDate(hour.date, hourly: true))
                                        .font(.subheadline).fontWeight(.semibold)
                                    Label("\(hour.condition) · \(temperature(hour.temperature))", systemImage: hour.symbol)
                                    WeatherMetrics(precipitation: hour.precipitation, wind: hour.wind)
                                }.padding(.vertical, 6).accessibilityElement(children: .combine).accessibilityIdentifier("weather-hour")
                            }
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(session.title)
                                Text("Hourly from \(session.callTime == nil ? "session start" : "call time")")
                                    .font(.caption).foregroundStyle(Color("SecondaryText"))
                            }
                        }
                    }
                }
            }
            Text("Forecast dates and hours use \(snapshot.timeZoneID.replacingOccurrences(of: "_", with: " ")).")
                .font(.caption).foregroundStyle(Color("SecondaryText"))
            Link(destination: snapshot.legalURL) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { weatherMark; Text("Data sources").font(.caption).fixedSize() }
                    VStack(alignment: .leading, spacing: 8) { weatherMark; Text("Data sources").font(.caption) }
                }.frame(minHeight: 44)
            }.accessibilityLabel("Apple Weather data sources")
        }
    }

    private var weatherMark: some View {
        AsyncImage(url: colorScheme == .dark ? snapshot.darkMarkURL : snapshot.lightMarkURL) { image in
            image.resizable().scaledToFit().frame(width: 96, height: 24)
        } placeholder: {
            Label("Weather", systemImage: "apple.logo").font(.subheadline).fixedSize(horizontal: true, vertical: false)
        }.fixedSize()
    }

    private func formattedDate(_ date: Date, hourly: Bool) -> String {
        var style: Date.FormatStyle = hourly ? .dateTime.month(.abbreviated).day().hour().minute() : .dateTime.weekday(.wide).month(.abbreviated).day()
        style.timeZone = snapshot.timeZone
        return date.formatted(style)
    }

    private func temperature(_ value: Double) -> String {
        Measurement(value: value, unit: UnitTemperature.celsius)
            .formatted(.measurement(width: .abbreviated, usage: .weather, numberFormatStyle: .number.precision(.fractionLength(0))))
    }
}

private struct WeatherMetrics: View {
    let precipitation: Double
    let wind: Double
    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 16) { rain; windLabel }
            VStack(alignment: .leading, spacing: 6) { rain; windLabel }
        }.font(.subheadline).foregroundStyle(Color("SecondaryText"))
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
