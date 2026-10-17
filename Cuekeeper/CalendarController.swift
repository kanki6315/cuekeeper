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
    /// The calendar a switch was refused for because the previous calendar's entries
    /// couldn't be removed, so Settings can offer to switch and leave them in place.
    @Published private(set) var blockedSwitch: String?
    let store: EKEventStore
    private let worker: CalendarWorker
    private let defaults: UserDefaults
    private var deviceID: String
    /// Nil when a test injects the device ID.
    private let resolveDeviceID: (() -> String)?
    private let publisher: any CalendarPublishing
    private var queued = false
    private var generation = 0
    private var syncPermit = CalendarSyncPermit()
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
        let resolve = { CalendarDeviceIdentity.resolve(defaults: defaults, keychain: .system, vendor: UIDevice.current.identifierForVendor?.uuidString) }
        resolveDeviceID = deviceID == nil ? resolve : nil
        self.deviceID = deviceID ?? resolve()
    }
    /// Resolve again before claiming: a Keychain that was locked at launch may now accept
    /// the cached ID, making it durable before another device can see it as an owner.
    /// A connected device keeps the ID it already claimed with.
    private func establishIdentity() {
        if !connected, let resolveDeviceID { deviceID = resolveDeviceID() }
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
                Task { @MainActor in
                    // Calendars may have been added, removed, or changed permissions.
                    if name == .EKEventStoreChanged { self?.refreshCalendars() }
                    self?.scheduleSync()
                }
            })
        }
        // Calendar access can change in Settings while the app is in the background.
        observers.append(NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.refreshCalendars() }
        })
        refreshCalendars(); scheduleSync()
    }
    func refreshCalendars() {
        calendars = EKEventStore.authorizationStatus(for: .event) == .fullAccess
            ? store.calendars(for: .event).filter(\.allowsContentModifications) : []
    }
    /// Keeps a picker choice that is still writable, otherwise falls back to the
    /// connected calendar, or to no choice when neither is available.
    nonisolated static func validSelection(_ selection: String, connected: String, available: [String]) -> String {
        if available.contains(selection) { return selection }
        return available.contains(connected) ? connected : ""
    }
    func requestAccess() async {
        guard !disabledForTests else { return }
        do {
            guard try await store.requestFullAccessToEvents() else { status = "Allow full Calendar access in Settings to connect. Jobs remain saved in Cuekeeper."; return }
            store.reset(); refreshCalendars(); status = "Choose a writable calendar."
        } catch { status = error.localizedDescription }
    }
    /// `leavingOldEntries` switches without removing entries from the previous calendar,
    /// e.g. when it became read-only. Those entries are no longer updated.
    func connect(_ id: String, leavingOldEntries: Bool = false) async {
        guard !busy, !disabledForTests else { return }
        let generation = generation
        let leavingOldEntries = leavingOldEntries && connected && selectedID != id
        busy = true
        do {
            guard store.calendar(withIdentifier: id)?.allowsContentModifications == true else { throw RecordError.invalid("Choose a writable calendar.") }
            establishIdentity()
            try await publisher.claim(deviceID: deviceID, name: ownerLabel)
            guard generation == self.generation else { busy = false; return }
            try await adopt(id, generation: generation, leavingOldEntries: leavingOldEntries)
        } catch let error as CalendarSwitchBlocked {
            if generation == self.generation { status = error.localizedDescription }
        } catch CalendarOwnershipError.managedElsewhere(let owner) {
            guard generation == self.generation else { busy = false; return }
            otherOwner = owner
            status = "Calendar not connected: \(CalendarOwnershipError.managedElsewhere(owner).localizedDescription)"
        } catch { if generation == self.generation { status = "Calendar not connected: \(error.localizedDescription)" } }
        busy = false
        guard connected else { return }
        await sync()
        if leavingOldEntries && selectedID == id && generation == self.generation {
            status += " Entries in the previous calendar were left in place and are no longer updated."
        }
    }
    /// Claims the calendar even though another device holds it. That device stops updating
    /// entries; this one adopts the existing Cuekeeper entries instead of duplicating them.
    func takeOver(_ id: String) async {
        guard !busy, !disabledForTests else { return }
        let generation = generation
        busy = true
        do {
            guard store.calendar(withIdentifier: id)?.allowsContentModifications == true else { throw RecordError.invalid("Choose a writable calendar.") }
            establishIdentity()
            try await publisher.takeOver(deviceID: deviceID, name: ownerLabel)
            guard generation == self.generation else { busy = false; return }
            try await adopt(id, generation: generation)
        } catch let error as CalendarSwitchBlocked {
            if generation == self.generation { status = error.localizedDescription }
        } catch { if generation == self.generation { status = "Calendar not connected: \(error.localizedDescription)" } }
        busy = false
        if connected { await sync() }
    }
    private func adopt(_ id: String, generation: Int, leavingOldEntries: Bool = false) async throws {
        if connected && selectedID != id && !leavingOldEntries {
            do { _ = try await worker.removeManagedEvents(calendarID: selectedID, knownKeys: try await currentPlan().knownKeys, permit: syncPermit) }
            catch is CancellationError { throw CancellationError() }
            catch {
                guard generation == self.generation else { throw CancellationError() }
                blockedSwitch = id
                throw CalendarSwitchBlocked(reason: error.localizedDescription)
            }
        }
        guard generation == self.generation else { throw CancellationError() }
        syncPermit = CalendarSyncPermit()
        selectedID = id; defaults.set(id, forKey: "calendar.selected")
        otherOwner = nil; blockedSwitch = nil
        status = leavingOldEntries ? "Connected. Entries in the previous calendar were left in place. Updating entries…" : "Connected. Updating entries…"
    }
    func disconnect() async {
        guard !busy, !disabledForTests else { return }
        let generation = generation
        let permit = syncPermit
        busy = true; defer { busy = false }
        do {
            do { try await publisher.verify(deviceID: deviceID) }
            catch CalendarOwnershipError.notOwner {
                guard generation == self.generation else { return }
                // Another device took over and now owns the entries; leave them in place.
                clearConnection()
                status = "Disconnected. Calendar entries were left for the device that now manages them."
                return
            }
            guard generation == self.generation else { return }
            let found = try await worker.removeManagedEvents(calendarID: selectedID, knownKeys: try await currentPlan().knownKeys, permit: permit)
            guard generation == self.generation else { return }
            try await publisher.release(deviceID: deviceID)
            guard generation == self.generation else { return }
            clearConnection()
            status = found ? "Disconnected. Cuekeeper’s calendar entries were removed." : "Disconnected. The calendar is no longer available, so there were no entries to remove."
        } catch {
            if generation == self.generation {
                status = "Couldn’t disconnect: \(error.localizedDescription) Retry when Calendar and iCloud are available, or choose Disconnect without removing entries."
            }
        }
    }
    /// An offline escape hatch: do not require EventKit access or contact iCloud.
    /// The remote claim may remain, so another device can use the existing takeover flow.
    func disconnectKeepingEntries() {
        guard connected else { return }
        generation += 1
        syncPermit.cancel()
        debounce?.cancel(); queued = false
        clearConnection()
        otherOwner = nil
        status = "Disconnected on this device. Entries remain in Calendar. Another device may need to choose Use This Device Instead."
    }

    private func clearConnection() {
        selectedID = ""; defaults.removeObject(forKey: "calendar.selected")
        blockedSwitch = nil
        defaults.removeObject(forKey: "calendar.eventIDs")
        defaults.removeObject(forKey: "calendar.lastPublished")
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
        let generation = generation
        let calendarID = selectedID
        let permit = syncPermit
        busy = true
        defer { busy = false; if queued { queued = false; scheduleSync() } }
        do {
            guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw RecordError.invalid("Full Calendar access is needed. Enable it in Settings; your jobs are saved locally.") }
            guard let calendar = store.calendar(withIdentifier: selectedID), calendar.allowsContentModifications else { throw RecordError.invalid("The selected calendar is unavailable. Choose another calendar in Cuekeeper Settings.") }
            try await publisher.verify(deviceID: deviceID)
            guard generation == self.generation else { return }
            let plan = try await currentPlan()
            guard generation == self.generation else { return }
            try await worker.sync(plan: plan, calendarID: calendarID, permit: permit)
            guard generation == self.generation else { return }
            status = "Updated at \(Date().formatted(date: .omitted, time: .shortened)) on this device."
        } catch let error as CalendarOwnershipError {
            guard generation == self.generation else { return }
            store.reset()
            status = "\(error.localizedDescription) Disconnect here, or connect again to take over."
        } catch {
            guard generation == self.generation else { return }
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
    nonisolated static func update(_ event: EKEvent, from desired: CalendarEntry, lastPublished: CalendarEntry? = nil) -> Bool {
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
        // Only changed source fields are authoritative. Providers may normalize the
        // last successfully published text; writing it again would trigger another sync.
        let titleChanged = lastPublished?.title != desired.title && event.title != desired.title
        let notesChanged = lastPublished?.notes != desired.notes && (event.notes ?? "") != desired.notes
        let locationChanged = lastPublished?.location != desired.location && (event.location ?? "") != desired.location
        let urlChanged = lastPublished?.url != desired.url && event.url != desired.url
        let scheduleChanged = event.startDate != start || event.endDate != end || event.isAllDay != desired.allDay || event.timeZone != timeZone
        guard titleChanged || notesChanged || locationChanged || urlChanged || scheduleChanged else { return false }
        if titleChanged { event.title = desired.title }
        if scheduleChanged {
            event.timeZone = timeZone
            event.startDate = start
            event.endDate = end
            event.isAllDay = desired.allDay
        }
        if notesChanged { event.notes = desired.notes }
        if locationChanged { event.location = desired.location }
        if urlChanged { event.url = desired.url }
        return true
    }

    deinit { for observer in observers { NotificationCenter.default.removeObserver(observer) } }
}

/// Identifies this physical device for the calendar claim.
///
/// The ID lives in a this-device-only Keychain item: it survives reinstalls, but is not
/// carried to another phone by a device backup or restore, so two phones can't share it.
/// A defaults marker detects a restored copy whose Keychain item didn't come along.
///
/// The cached copy also records the vendor ID it was cached on. When the Keychain is
/// locked or rejects a write, that cached copy is a stable fallback on this device, but a
/// restore onto another device (a different vendor ID) never reuses it.
struct CalendarDeviceIdentity {
    enum Lookup { case found(String), missing, unavailable }
    var read: () -> Lookup
    var write: (String) -> Bool
    static let legacyKey = "calendar.device", markerKey = "calendar.deviceInKeychain", vendorKey = "calendar.deviceVendor"

    static func resolve(defaults: UserDefaults, keychain: CalendarDeviceIdentity, vendor: String?) -> String {
        let legacy = defaults.string(forKey: legacyKey)
        let cachedVendor = defaults.string(forKey: vendorKey)
        let inKeychain = defaults.bool(forKey: markerKey)
        func cache(_ id: String, inKeychain: Bool) -> String {
            defaults.set(id, forKey: legacyKey); defaults.set(inKeychain, forKey: markerKey)
            if let vendor { defaults.set(vendor, forKey: vendorKey) } else { defaults.removeObject(forKey: vendorKey) }
            return id
        }
        switch keychain.read() {
        case .found(let id):
            return cache(id, inKeychain: true)
        case .unavailable:
            // Keychain is locked (e.g. before first unlock); use the cached copy unless it is
            // known to come from another device. Persist any new ID so the next launch agrees.
            if let legacy, cachedVendor == nil || vendor == nil || cachedVendor == vendor { return legacy }
            return cache(UUID().uuidString, inKeychain: false)
        case .missing:
            // Same device: a pre-Keychain ID, or a fallback whose Keychain write failed.
            // A copy that reached the Keychain elsewhere, or came from another vendor ID,
            // was restored onto this device and must not be shared.
            let sameDevice = vendor != nil && cachedVendor == vendor
            let reusable = legacy.flatMap { sameDevice || (cachedVendor == nil && !inKeychain) ? $0 : nil }
            let id = reusable ?? UUID().uuidString
            return cache(id, inKeychain: keychain.write(id))
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

/// A local disconnect invalidates work already awaiting EventKit or iCloud.
final class CalendarSyncPermit: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    func commit(_ operation: () throws -> Void) throws {
        lock.lock(); defer { lock.unlock() }
        guard !cancelled else { throw CancellationError() }
        try operation()
    }
}

struct CalendarPublishedState: Codable {
    var calendarID: String
    var entries: [String: CalendarEntry] = [:]
    func entry(calendarID: String, eventID: String?) -> CalendarEntry? {
        guard self.calendarID == calendarID, let eventID else { return nil }
        return entries[eventID]
    }
}

/// Owns its EventKit objects away from the main actor. No EventKit objects cross
/// this boundary; the UI store is used only for calendar selection and permission.
private actor CalendarWorker {
    private let store = EKEventStore()
    private let defaults: UserDefaults
    init(defaults: UserDefaults) { self.defaults = defaults }

    func sync(plan: CalendarPlan, calendarID: String, permit: CalendarSyncPermit) throws {
        do {
            store.reset()
            guard let calendar = store.calendar(withIdentifier: calendarID), calendar.allowsContentModifications else {
                throw RecordError.invalid("The selected calendar is unavailable. Choose another calendar in Cuekeeper Settings.")
            }
            let published = publishedState()
            // Read discovery before bounds change: a new owner hasn't published here yet.
            let discover = published?.calendarID != calendarID
            rememberBounds(plan.bounds)
            var changed = false
            let existing = managedEvents(calendar: calendar, discover: discover)
            let grouped = Dictionary(grouping: existing, by: { CalendarPlan.key(from: $0.url)! })
            var retained: [EKEvent] = []
            var ids: [String: String] = [:]
            for (key, events) in grouped {
                guard plan.knownKeys.contains(key) else { continue }
                if plan.desired[key] == nil { for event in events { try store.remove(event, span: .thisEvent, commit: false); changed = true } }
            }
            for (key, desired) in plan.desired {
                let matches = grouped[key] ?? []
                let event: EKEvent
                if let match = matches.first { event = match } else {
                    event = EKEvent(eventStore: store)
                    // Entries are schedule markers, not reminders: request no alerts.
                    // Existing entries keep any alerts the user added themselves.
                    event.alarms = []
                }
                for duplicate in matches.dropFirst() { try store.remove(duplicate, span: .thisEvent, commit: false); changed = true }
                if event.calendar == nil { event.calendar = calendar }
                // Save only actual changes; EventKit notifications must not create a sync loop.
                if CalendarController.update(event, from: desired, lastPublished: published?.entry(calendarID: calendarID, eventID: event.eventIdentifier)) {
                    try store.save(event, span: .thisEvent, commit: false)
                    changed = true
                }
                retained.append(event)
            }
            try permit.commit {
                if changed { try store.commit() }
                // IDs are assigned on commit; recapture them for date changes and moved entries.
                for event in retained { if let key = CalendarPlan.key(from: event.url), let id = event.eventIdentifier { ids[key] = id } }
                defaults.set(ids, forKey: "calendar.eventIDs")
                var state = CalendarPublishedState(calendarID: calendarID)
                for (key, id) in ids { state.entries[id] = plan.desired[key] }
                defaults.set(try JSONEncoder().encode(state), forKey: "calendar.lastPublished")
            }
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
    private func publishedState() -> CalendarPublishedState? {
        defaults.data(forKey: "calendar.lastPublished").flatMap { try? JSONDecoder().decode(CalendarPublishedState.self, from: $0) }
    }
    /// How far a device without its own publication history searches for entries
    /// published by a previous owner, whose dates and event IDs it never saw.
    static let discoveryYears = 10
    private func managedEvents(calendar: EKCalendar, discover: Bool) -> [EKEvent] {
        var result: [String: EKEvent] = [:]
        let ids = defaults.dictionary(forKey: "calendar.eventIDs") as? [String: String] ?? [:]
        for id in ids.values {
            if let event = store.event(withIdentifier: id), event.calendar.calendarIdentifier == calendar.calendarIdentifier,
               CalendarPlan.key(from: event.url) != nil { result[event.eventIdentifier] = event }
        }
        var start = (defaults.object(forKey: "calendar.earliest") as? Date ?? Date()).addingTimeInterval(-86400)
        var end = (defaults.object(forKey: "calendar.latest") as? Date ?? Date()).addingTimeInterval(86400)
        if discover {
            start = min(start, Calendar.current.date(byAdding: .year, value: -Self.discoveryYears, to: Date())!)
            end = max(end, Calendar.current.date(byAdding: .year, value: Self.discoveryYears, to: Date())!)
        }
        while start < end {
            let next = min(Calendar.current.date(byAdding: .year, value: 1, to: start)!, end)
            for event in store.events(matching: store.predicateForEvents(withStart: start, end: next, calendars: [calendar])) where CalendarPlan.key(from: event.url) != nil {
                result[event.eventIdentifier] = event
            }
            start = next
        }
        return Array(result.values).sorted { $0.eventIdentifier < $1.eventIdentifier }
    }
    /// Returns false when the calendar no longer exists, so there was nothing to remove.
    func removeManagedEvents(calendarID: String, knownKeys: Set<String>, permit: CalendarSyncPermit) throws -> Bool {
        store.reset()
        defer { store.reset() }
        let calendar = EKEventStore.authorizationStatus(for: .event) == .fullAccess ? store.calendar(withIdentifier: calendarID) : nil
        try CalendarCleanup.check(fullAccess: EKEventStore.authorizationStatus(for: .event) == .fullAccess,
                                  calendar: calendar.map { ($0.title, $0.allowsContentModifications) })
        // With full access, a missing calendar has no entries left to remove.
        // Let disconnect release the claim, or adopt select a replacement calendar.
        guard let calendar else { return false }
        for event in managedEvents(calendar: calendar, discover: publishedState()?.calendarID != calendarID) {
            guard let key = CalendarPlan.key(from: event.url), knownKeys.contains(key) else { continue }
            try store.remove(event, span: .thisEvent, commit: false)
        }
        try permit.commit { try store.commit() }
        return true
    }
}

/// Whether entries can be removed from a calendar this device published to.
enum CalendarCleanup {
    static func check(fullAccess: Bool, calendar: (title: String, writable: Bool)?) throws {
        guard fullAccess else { throw RecordError.invalid("Full Calendar access is needed to remove Cuekeeper’s entries.") }
        if let calendar, !calendar.writable {
            throw RecordError.invalid("“\(calendar.title)” is read-only, so Cuekeeper’s entries there can’t be removed.")
        }
    }
}

struct CalendarSwitchBlocked: LocalizedError {
    let reason: String
    var errorDescription: String? {
        "Still using the previous calendar. \(reason) To switch anyway, choose Switch and Leave Old Entries; existing entries stay in the previous calendar and are no longer updated."
    }
}
