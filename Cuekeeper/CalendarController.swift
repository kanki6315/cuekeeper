import Combine
import CoreData
import EventKit
import UIKit

@MainActor
final class CalendarController: ObservableObject {
    @Published private(set) var status = "Not connected"
    @Published private(set) var busy = false
    @Published private(set) var calendars: [EKCalendar] = []
    @Published private(set) var selectedID: String
    let store: EKEventStore
    private let defaults: UserDefaults
    private let deviceID: String
    private let publisher: any CalendarPublishing
    private var queued = false
    private var context: NSManagedObjectContext?
    private var observers: [NSObjectProtocol] = []
    private var disabledForTests = false
    private var debounce: Task<Void, Never>?
    var connected: Bool { !selectedID.isEmpty }
    var permission: String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess: "Full access"
        case .denied, .restricted: "Calendar access denied"
        case .writeOnly: "Full access required to update entries"
        default: "Not requested"
        }
    }
    init(defaults: UserDefaults = .standard, store: EKEventStore = EKEventStore(), publisher: any CalendarPublishing = CalendarPublisher()) {
        self.defaults = defaults; self.store = store; self.publisher = publisher
        selectedID = defaults.string(forKey: "calendar.selected") ?? ""
        deviceID = defaults.string(forKey: "calendar.device") ?? UUID().uuidString
        defaults.set(deviceID, forKey: "calendar.device")
    }
    func start(context: NSManagedObjectContext, enabled: Bool) {
        guard self.context == nil else { return }
        self.context = context; disabledForTests = !enabled
        guard enabled else { status = "Calendar disabled in test sessions"; return }
        for name in [NSManagedObjectContext.didSaveObjectsNotification, .NSPersistentStoreRemoteChange, .EKEventStoreChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.scheduleSync() }
            })
        }
        refreshCalendars(); scheduleSync()
    }
    func refreshCalendars() {
        calendars = EKEventStore.authorizationStatus(for: .event) == .fullAccess
            ? store.calendars(for: .event).filter(\.allowsContentModifications) : []
    }
    func requestAccess() async {
        guard !disabledForTests else { return }
        do {
            guard try await store.requestFullAccessToEvents() else { status = "Allow full Calendar access in Settings to connect. Jobs remain saved in Cuekeeper."; return }
            store.reset(); refreshCalendars(); status = "Choose a writable calendar."
        } catch { status = error.localizedDescription }
    }
    func connect(_ id: String) async {
        guard !busy, !disabledForTests else { return }
        busy = true
        do {
            guard store.calendar(withIdentifier: id)?.allowsContentModifications == true else { throw RecordError.invalid("Choose a writable calendar.") }
            try await publisher.claim(deviceID: deviceID, name: UIDevice.current.name)
            if connected && selectedID != id { try removeManagedEvents() }
            selectedID = id; defaults.set(id, forKey: "calendar.selected")
            status = "Connected. Updating entries…"
        } catch { status = "Calendar not connected: \(error.localizedDescription)" }
        busy = false
        if connected { await sync() }
    }
    func disconnect() async {
        guard !busy, !disabledForTests else { return }
        busy = true; defer { busy = false }
        do {
            try await publisher.verify(deviceID: deviceID)
            try removeManagedEvents()
            try await publisher.release(deviceID: deviceID)
            selectedID = ""; defaults.removeObject(forKey: "calendar.selected")
            defaults.removeObject(forKey: "calendar.eventIDs")
            status = "Disconnected. Cuekeeper’s calendar entries were removed."
        } catch { status = "Couldn’t disconnect: \(error.localizedDescription). Retry when Calendar and iCloud are available." }
    }
    func scheduleSync() {
        guard !disabledForTests, connected else { return }
        debounce?.cancel()
        debounce = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await self?.sync()
        }
    }
    func sync() async {
        guard connected, !disabledForTests, let context else { return }
        guard !busy else { queued = true; return }
        busy = true
        defer { busy = false; if queued { queued = false; scheduleSync() } }
        do {
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw RecordError.invalid("Full Calendar access is needed. Enable it in Settings; your jobs are saved locally.") }
            guard let calendar = store.calendar(withIdentifier: selectedID), calendar.allowsContentModifications else { throw RecordError.invalid("The selected calendar is unavailable. Choose another calendar in Cuekeeper Settings.") }
            try await publisher.verify(deviceID: deviceID)
            let jobs = try context.fetch(NSFetchRequest<Job>(entityName: "Job"))
            let historicalEvents = try context.fetch(NSFetchRequest<WorkEvent>(entityName: "WorkEvent"))
            let plan = CalendarPlan(jobs: jobs, historicalEventIDs: historicalEvents.compactMap(\.id))
            rememberBounds(plan.bounds)
            let existing = managedEvents(calendar: calendar)
            var ids: [String: String] = [:]
            for (key, events) in Dictionary(grouping: existing, by: { CalendarPlan.key(from: $0.url)! }) {
                guard plan.knownKeys.contains(key) else {
                    if let id = events.first?.eventIdentifier { ids[key] = id }; continue
                }
                if plan.desired[key] == nil { for event in events { try store.remove(event, span: .thisEvent, commit: false) } }
            }
            for (key, desired) in plan.desired {
                let matches = existing.filter { CalendarPlan.key(from: $0.url) == key }
                let event = matches.first ?? EKEvent(eventStore: store)
                for duplicate in matches.dropFirst() { try store.remove(duplicate, span: .thisEvent, commit: false) }
                if event.calendar == nil { event.calendar = calendar }
                // Save only actual changes; EventKit notifications must not create a sync loop.
                if Self.update(event, from: desired) {
                    try store.save(event, span: .thisEvent, commit: false)
                }
                if let id = event.eventIdentifier { ids[key] = id }
            }
            try store.commit()
            // IDs are assigned on commit; recapture them for date changes and moved entries.
            for event in managedEvents(calendar: calendar) { if let key = CalendarPlan.key(from: event.url), let id = event.eventIdentifier { ids[key] = id } }
            defaults.set(ids, forKey: "calendar.eventIDs")
            status = "Updated at \(Date().formatted(date: .omitted, time: .shortened)) on this device."
        } catch {
            store.reset()
            status = "Calendar update pending: \(error.localizedDescription)"
        }
    }
    /// EventKit represents all-day dates in the device's default time zone.
    /// Preserve the job's civil dates, rather than its midnight instants, when publishing.
    static func update(_ event: EKEvent, from desired: CalendarEntry) -> Bool {
        let timeZone = desired.allDay ? nil : TimeZone(identifier: desired.timeZoneID)
        func eventDate(_ date: Date) -> Date {
            guard desired.allDay else { return date }
            var source = Calendar(identifier: .gregorian)
            source.timeZone = TimeZone(identifier: desired.timeZoneID) ?? .current
            var local = Calendar(identifier: .gregorian)
            local.timeZone = .current
            return local.date(from: source.dateComponents([.year, .month, .day], from: date))!
        }
        let start = eventDate(desired.start)
        // The plan uses an exclusive next-day boundary; EventKit normalizes all-day
        // end dates to the final second of the last included day.
        let end = eventDate(desired.end).addingTimeInterval(desired.allDay ? -1 : 0)
        guard event.title != desired.title || event.startDate != start || event.endDate != end
            || event.isAllDay != desired.allDay || (event.notes ?? "") != desired.notes || (event.location ?? "") != desired.location
            || event.url != desired.url || event.timeZone != timeZone else { return false }
        event.title = desired.title
        event.timeZone = timeZone
        event.startDate = start
        event.endDate = end
        // Set this last: changing the time zone can turn an all-day event into a timed event.
        event.isAllDay = desired.allDay
        event.notes = desired.notes; event.location = desired.location; event.url = desired.url
        return true
    }

    private func rememberBounds(_ dates: [Date]) {
        let low = defaults.object(forKey: "calendar.earliest") as? Date ?? Date()
        let high = defaults.object(forKey: "calendar.latest") as? Date ?? Date()
        defaults.set(min(low, dates.min() ?? low), forKey: "calendar.earliest")
        defaults.set(max(high, dates.max() ?? high), forKey: "calendar.latest")
    }
    private func managedEvents(calendar: EKCalendar) -> [EKEvent] {
        var result: [String: EKEvent] = [:]
        let ids = defaults.dictionary(forKey: "calendar.eventIDs") as? [String: String] ?? [:]
        for id in ids.values {
            if let event = store.event(withIdentifier: id), event.calendar.calendarIdentifier == calendar.calendarIdentifier,
               CalendarPlan.key(from: event.url) != nil { result[event.eventIdentifier] = event }
        }
        var start = (defaults.object(forKey: "calendar.earliest") as? Date ?? Date()).addingTimeInterval(-86400)
        let end = (defaults.object(forKey: "calendar.latest") as? Date ?? Date()).addingTimeInterval(86400)
        while start < end {
            let next = min(Calendar.current.date(byAdding: .year, value: 1, to: start)!, end)
            for event in store.events(matching: store.predicateForEvents(withStart: start, end: next, calendars: [calendar])) where CalendarPlan.key(from: event.url) != nil {
                result[event.eventIdentifier] = event
            }
            start = next
        }
        return Array(result.values).sorted { $0.eventIdentifier < $1.eventIdentifier }
    }
    private func removeManagedEvents() throws {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess,
              let calendar = store.calendar(withIdentifier: selectedID) else { throw RecordError.invalid("Restore Calendar access before disconnecting.") }
        for event in managedEvents(calendar: calendar) { try store.remove(event, span: .thisEvent, commit: false) }
        try store.commit()
    }
    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}
