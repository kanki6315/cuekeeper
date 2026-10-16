import Combine
import CoreData
import EventKit
import Security
import UIKit

@MainActor
final class CalendarController: ObservableObject {
    @Published private(set) var status = "Not connected"
    @Published private(set) var busy = false
    @Published private(set) var calendars: [EKCalendar] = []
    @Published private(set) var selectedID: String
    /// Set when another device holds the calendar claim, so Settings can offer a takeover.
    @Published private(set) var otherOwner: String?
    let store: EKEventStore
    private let worker: CalendarWorker
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
    init(defaults: UserDefaults = .standard, store: EKEventStore = EKEventStore(), publisher: any CalendarPublishing = CalendarPublisher(), deviceID: String? = nil) {
        self.defaults = defaults; self.store = store; self.publisher = publisher
        worker = CalendarWorker(defaults: defaults)
        selectedID = defaults.string(forKey: "calendar.selected") ?? ""
        self.deviceID = deviceID ?? CalendarDeviceIdentity.resolve(defaults: defaults, keychain: .system)
    }
    /// `UIDevice.name` is usually just "iPhone" on current iOS, so add when it connected.
    private var ownerLabel: String {
        "\(UIDevice.current.name), connected \(Date().formatted(date: .abbreviated, time: .omitted))"
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
            try await publisher.claim(deviceID: deviceID, name: ownerLabel)
            try await adopt(id)
        } catch CalendarOwnershipError.managedElsewhere(let owner) {
            otherOwner = owner
            status = "Calendar not connected: \(CalendarOwnershipError.managedElsewhere(owner).localizedDescription)"
        } catch { status = "Calendar not connected: \(error.localizedDescription)" }
        busy = false
        if connected { await sync() }
    }
    /// Claims the calendar even though another device holds it. That device stops updating
    /// entries; this one adopts the existing Cuekeeper entries instead of duplicating them.
    func takeOver(_ id: String) async {
        guard !busy, !disabledForTests else { return }
        busy = true
        do {
            guard store.calendar(withIdentifier: id)?.allowsContentModifications == true else { throw RecordError.invalid("Choose a writable calendar.") }
            try await publisher.takeOver(deviceID: deviceID, name: ownerLabel)
            try await adopt(id)
        } catch { status = "Calendar not connected: \(error.localizedDescription)" }
        busy = false
        if connected { await sync() }
    }
    private func adopt(_ id: String) async throws {
        if connected && selectedID != id { try await worker.removeManagedEvents(calendarID: selectedID, knownKeys: try await currentPlan().knownKeys) }
        selectedID = id; defaults.set(id, forKey: "calendar.selected")
        otherOwner = nil
        status = "Connected. Updating entries…"
    }
    func disconnect() async {
        guard !busy, !disabledForTests else { return }
        busy = true; defer { busy = false }
        do {
            do { try await publisher.verify(deviceID: deviceID) }
            catch CalendarOwnershipError.notOwner {
                // Another device took over and now owns the entries; leave them in place.
                clearConnection()
                status = "Disconnected. Calendar entries were left for the device that now manages them."
                return
            }
            try await worker.removeManagedEvents(calendarID: selectedID, knownKeys: try await currentPlan().knownKeys)
            try await publisher.release(deviceID: deviceID)
            clearConnection()
            status = "Disconnected. Cuekeeper’s calendar entries were removed."
        } catch { status = "Couldn’t disconnect: \(error.localizedDescription). Retry when Calendar and iCloud are available." }
    }
    private func clearConnection() {
        selectedID = ""; defaults.removeObject(forKey: "calendar.selected")
        defaults.removeObject(forKey: "calendar.eventIDs")
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
        guard connected, !disabledForTests, context != nil else { return }
        guard !busy else { queued = true; return }
        busy = true
        defer { busy = false; if queued { queued = false; scheduleSync() } }
        do {
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw RecordError.invalid("Full Calendar access is needed. Enable it in Settings; your jobs are saved locally.") }
            guard let calendar = store.calendar(withIdentifier: selectedID), calendar.allowsContentModifications else { throw RecordError.invalid("The selected calendar is unavailable. Choose another calendar in Cuekeeper Settings.") }
            try await publisher.verify(deviceID: deviceID)
            let plan = try await currentPlan()
            try await worker.sync(plan: plan, calendarID: selectedID)
            status = "Updated at \(Date().formatted(date: .omitted, time: .shortened)) on this device."
        } catch let error as CalendarOwnershipError {
            store.reset()
            status = "\(error.localizedDescription) Disconnect here, or connect again to take over."
        } catch {
            store.reset()
            status = "Calendar update pending: \(error.localizedDescription)"
        }
    }
    /// Only local record keys establish ownership. A shared calendar may also contain
    /// other users' Cuekeeper URLs, including IDs cached by older app versions.
    private func currentPlan() async throws -> CalendarPlan {
        guard let context else { throw RecordError.invalid("Cuekeeper records are not available yet. Try again after loading finishes.") }
        let reader = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        reader.persistentStoreCoordinator = context.persistentStoreCoordinator
        return try await reader.perform {
            let jobs = try reader.fetch(NSFetchRequest<Job>(entityName: "Job"))
            let history = try reader.fetch(NSFetchRequest<WorkEvent>(entityName: "WorkEvent"))
            return CalendarPlan(jobs: jobs, historicalEventIDs: history.compactMap(\.id))
        }
    }

    /// EventKit represents all-day dates in the device's default time zone.
    /// Preserve the job's civil dates, rather than its midnight instants, when publishing.
    nonisolated static func update(_ event: EKEvent, from desired: CalendarEntry) -> Bool {
        let timeZone = desired.allDay ? nil : TimeZone(identifier: desired.timeZoneID)
        func eventDate(_ date: Date) -> Date {
            guard desired.allDay else { return date }
            var source = Calendar(identifier: .gregorian)
            source.timeZone = TimeZone.effective(desired.timeZoneID)
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

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}

/// Identifies this physical device for the calendar claim.
///
/// The ID lives in a this-device-only Keychain item: it survives reinstalls, but is not
/// carried to another phone by a device backup or restore, so two phones can't share it.
/// A defaults marker detects a restored copy whose Keychain item didn't come along.
struct CalendarDeviceIdentity {
    enum Lookup { case found(String), missing, unavailable }
    var read: () -> Lookup
    var write: (String) -> Bool
    static let legacyKey = "calendar.device", markerKey = "calendar.deviceInKeychain"

    static func resolve(defaults: UserDefaults, keychain: CalendarDeviceIdentity) -> String {
        let legacy = defaults.string(forKey: legacyKey)
        switch keychain.read() {
        case .found(let id):
            defaults.set(id, forKey: legacyKey); defaults.set(true, forKey: markerKey)
            return id
        case .unavailable:
            // Keychain is locked (e.g. before first unlock); use the cached copy for now.
            return legacy ?? UUID().uuidString
        case .missing:
            // Migrate the pre-Keychain ID once; after that, a missing item with the marker
            // set means these defaults were restored onto a different device.
            let restoredCopy = defaults.bool(forKey: markerKey)
            let id = restoredCopy ? UUID().uuidString : legacy ?? UUID().uuidString
            guard keychain.write(id) else { return id }
            defaults.set(id, forKey: legacyKey); defaults.set(true, forKey: markerKey)
            return id
        }
    }

    static let system: CalendarDeviceIdentity = {
        let base: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                   kSecAttrService as String: "com.arjunakankipati.cuekeeper.calendar",
                                   kSecAttrAccount as String: "device-id"]
        return CalendarDeviceIdentity(read: {
            var query = base
            query[kSecReturnData as String] = true
            var result: CFTypeRef?
            switch SecItemCopyMatching(query as CFDictionary, &result) {
            case errSecSuccess:
                guard let data = result as? Data, let id = String(data: data, encoding: .utf8), !id.isEmpty else { return .missing }
                return .found(id)
            case errSecItemNotFound: return .missing
            default: return .unavailable
            }
        }, write: { id in
            var item = base
            item[kSecValueData as String] = Data(id.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            SecItemDelete(base as CFDictionary)
            return SecItemAdd(item as CFDictionary, nil) == errSecSuccess
        })
    }()
}

/// Owns its EventKit objects away from the main actor. No EventKit objects cross
/// this boundary; the UI store is used only for calendar selection and permission.
private actor CalendarWorker {
    private let store = EKEventStore()
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }

    func sync(plan: CalendarPlan, calendarID: String) throws {
        do {
            store.reset()
            guard let calendar = store.calendar(withIdentifier: calendarID), calendar.allowsContentModifications else {
                throw RecordError.invalid("The selected calendar is unavailable. Choose another calendar in Cuekeeper Settings.")
            }
            rememberBounds(plan.bounds)
            let existing = managedEvents(calendar: calendar)
            let grouped = Dictionary(grouping: existing, by: { CalendarPlan.key(from: $0.url)! })
            var retained: [EKEvent] = []
            var ids: [String: String] = [:]
            for (key, events) in grouped {
                guard plan.knownKeys.contains(key) else { continue }
                if plan.desired[key] == nil { for event in events { try store.remove(event, span: .thisEvent, commit: false) } }
            }
            for (key, desired) in plan.desired {
                let matches = grouped[key] ?? []
                let event = matches.first ?? EKEvent(eventStore: store)
                for duplicate in matches.dropFirst() { try store.remove(duplicate, span: .thisEvent, commit: false) }
                if event.calendar == nil { event.calendar = calendar }
                // Save only actual changes; EventKit notifications must not create a sync loop.
                if CalendarController.update(event, from: desired) {
                    try store.save(event, span: .thisEvent, commit: false)
                }
                retained.append(event)
            }
            try store.commit()
            // IDs are assigned on commit; recapture them for date changes and moved entries.
            for event in retained { if let key = CalendarPlan.key(from: event.url), let id = event.eventIdentifier { ids[key] = id } }
            defaults.set(ids, forKey: "calendar.eventIDs")
        } catch {
            store.reset()
            throw error
        }
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
    func removeManagedEvents(calendarID: String, knownKeys: Set<String>) throws {
        store.reset()
        defer { store.reset() }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw RecordError.invalid("Restore Calendar access before disconnecting.") }
        // With full access, a missing calendar has no entries left to remove.
        // Let disconnect release the claim, or adopt select a replacement calendar.
        guard let calendar = store.calendar(withIdentifier: calendarID) else { return }
        for event in managedEvents(calendar: calendar) {
            guard let key = CalendarPlan.key(from: event.url), knownKeys.contains(key) else { continue }
            try store.remove(event, span: .thisEvent, commit: false)
        }
        try store.commit()
    }
}
