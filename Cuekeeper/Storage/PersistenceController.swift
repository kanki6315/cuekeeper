import CloudKit
import Combine
import Network
import CoreData
import UIKit

@MainActor
final class PersistenceController: ObservableObject {
    static let containerIdentifier = "iCloud.com.arjunakankipati.cuekeeper"
    let container: NSPersistentCloudKitContainer
    let cloudEnabled: Bool
    let hadExistingStore: Bool
    @Published private(set) var isLoaded = false
    @Published private(set) var loadError: String?
    @Published private(set) var accountStatus = "Checking…"
    @Published private(set) var syncActivity = SyncActivity()
    var transferStatus: String { cloudEnabled ? (syncActivity.message ?? "No iCloud transfer in progress") : "Local storage only" }
    var awaitingInitialImport: Bool { syncActivity.awaitingInitialImport }
    private let networkMonitor = NWPathMonitor()
    @Published private(set) var schemaInitializationStatus: String? {
        didSet {
            #if CLOUDKIT_SCHEMA_SETUP
            if let schemaInitializationStatus {
                print("Cuekeeper CloudKit setup: \(schemaInitializationStatus)")
            }
            #endif
        }
    }
    @Published private(set) var lastTransfer: Date?
    /// Records that share an identity but differ, kept for review (see `IdentityReconciliation`).
    @Published private(set) var identityIssue: String?
    private var reconcileTask: Task<Void, Never>?
    private var reconcileObservers: [NSObjectProtocol] = []
    private var eventObserver: NSObjectProtocol?
    private var accountObserver: NSObjectProtocol?
    private let defaults: UserDefaults

    private let storeReadiness = StoreReadiness()

    func waitUntilLoaded() async throws {
        try await storeReadiness.wait()
    }

    init(storeURL: URL? = nil, cloudEnabled: Bool = true, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.cloudEnabled = cloudEnabled
        container = NSPersistentCloudKitContainer(name: "Cuekeeper")
        let description = container.persistentStoreDescriptions[0]
        if let storeURL { description.url = storeURL }
        hadExistingStore = description.url.map { FileManager.default.fileExists(atPath: $0.path) } ?? false
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.cloudKitContainerOptions = cloudEnabled
            ? NSPersistentCloudKitContainerOptions(containerIdentifier: Self.containerIdentifier)
            : nil
        container.viewContext.automaticallyMergesChangesFromParent = true
        // Nonfinancial fields merge independently. Financial records use immutable
        // revisions and explicit conflict resolution above this merge policy.
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.name = "Cuekeeper view context"
        CloudRecordNames.register(container)
        if cloudEnabled {
            // Also reconcile when records change remotely or the app returns, not only
            // after an import event, so a pass a concurrent edit aborted runs again soon.
            reconcileObservers = [
                NotificationCenter.default.addObserver(forName: .NSPersistentStoreRemoteChange, object: container.persistentStoreCoordinator, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.scheduleReconcile(after: 2) }
                },
                NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                    Task { @MainActor [weak self] in self?.scheduleReconcile(after: 0) }
                },
            ]
        }
        syncActivity.enabled = cloudEnabled
        if cloudEnabled {
            accountObserver = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.syncActivity.resetImportCompletion()
                    self.persistImportCompletion()
                    await self.refreshAccountStatus()
                }
            }
            networkMonitor.pathUpdateHandler = { [weak self] path in
                let offline = path.status == .unsatisfied
                Task { @MainActor [weak self] in self?.syncActivity.offline = offline }
            }
            networkMonitor.start(queue: DispatchQueue(label: "Cuekeeper connectivity"))
            eventObserver = NotificationCenter.default.addObserver(
                forName: NSPersistentCloudKitContainer.eventChangedNotification,
                object: container, queue: .main
            ) { [weak self] notification in
                guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    let kind: SyncActivity.Kind
                    switch event.type {
                    case .setup: kind = .setup
                    case .import: kind = .receiving
                    case .export: kind = .sending
                    @unknown default: kind = .setup
                    }
                    self.recordSyncEvent(id: event.identifier, kind: kind, ended: event.endDate != nil,
                                             succeeded: event.succeeded, error: event.error?.localizedDescription)
                    if event.succeeded, let date = event.endDate, kind != .setup { self.lastTransfer = date }
                }
            }
        } else {
            accountStatus = "Off for this test session"
        }
        #if DEBUG
        // Deterministic presentation tests never enable CloudKit or touch real records.
        let arguments = ProcessInfo.processInfo.arguments
        if !cloudEnabled && ProcessInfo.processInfo.isUITesting {
            if arguments.contains("--ui-test-sync-receiving") {
                syncActivity.enabled = true; syncActivity.checkingAccount = false
                syncActivity.record(id: UUID(), kind: .receiving, ended: false, succeeded: false, error: nil)
            } else if arguments.contains("--ui-test-sync-error") {
                syncActivity.enabled = true; syncActivity.checkingAccount = false
                syncActivity.record(id: UUID(), kind: .receiving, ended: true, succeeded: false, error: "Couldn’t receive changes. iCloud will try again.")
            } else if arguments.contains("--ui-test-sync-offline") {
                syncActivity.enabled = true; syncActivity.offline = true
            }
        }
        #endif
        container.loadPersistentStores { [weak self] _, error in
            Task { @MainActor [weak self] in
                self?.loadError = error?.localizedDescription
                #if DEBUG
                if error == nil, let self, !cloudEnabled, ProcessInfo.processInfo.isUITesting,
                   arguments.contains("--setup-returning") || arguments.contains("--setup-backup-fixture") {
                    do {
                        let id = try JobDraft(name: "Recovered broadcast").save(in: self.container.viewContext)
                        if arguments.contains("--setup-backup-fixture") {
                            let snapshot = try BackupArchive.capture(in: self.container.viewContext)
                            let file = try snapshot.writePackage()
                            try await FixtureBackups.shared.save(file: file.url, date: snapshot.createdAt, events: 1)
                            try Job.remove(id, in: self.container.viewContext)
                        }
                    } catch { self.loadError = error.localizedDescription }
                }
                if error == nil, let self, DesignFixtures.enabled {
                    do { try DesignFixtures.seed(self.container.viewContext) }
                    catch { self.loadError = "Review fixture setup failed: \(error.localizedDescription)" }
                }
                #endif
                if let self {
                    if error == nil {
                        let coordinator = self.container.persistentStoreCoordinator
                        let completed = coordinator.persistentStores.contains {
                            self.importCompletionKey(for: $0).map { self.defaults.bool(forKey: $0) } == true
                        }
                        if completed { self.syncActivity.restoreImportCompletion() }
                        // An import notification can arrive before the store-loaded callback.
                        self.persistImportCompletion()
                    }
                    self.isLoaded = self.loadError == nil
                    if self.isLoaded { self.scheduleReconcile(after: 0) }
                    if let loadError = self.loadError {
                        self.storeReadiness.complete(.failure(RecordError.invalid("Couldn’t open your daybook: \(loadError)")))
                    } else {
                        self.storeReadiness.complete(.success(()))
                    }
                }
                #if CLOUDKIT_SCHEMA_SETUP
                if error == nil, let self {
                    await self.initializeDevelopmentSchema()
                }
                #endif
            }
        }
    }

    #if CLOUDKIT_SCHEMA_SETUP
    private func initializeDevelopmentSchema() async {
        var succeeded = false
        defer {
            // Only the setup configuration contains this CLI handshake or exits on completion.
            if ProcessInfo.processInfo.arguments.contains("--cloudkit-schema-cli") {
                let marker = succeeded ? "CUEKEEPER_SCHEMA_INIT_OK" : "CUEKEEPER_SCHEMA_INIT_FAILED"
                FileHandle.standardOutput.write(Data("\n\(marker)\n".utf8))
                exit(succeeded ? 0 : 1)
            }
        }
        guard cloudEnabled,
              Bundle.main.object(forInfoDictionaryKey: "CuekeeperCloudKitEnvironment") as? String == "Development" else {
            schemaInitializationStatus = "Schema setup refused: a Development CloudKit configuration is required."
            return
        }
        schemaInitializationStatus = "Preparing development schema…"
        do {
            let account = try await CKContainer(identifier: Self.containerIdentifier).accountStatus()
            guard account == .available else {
                schemaInitializationStatus = "Sign in to iCloud on this device, then run the initialization scheme again."
                return
            }
            // This API blocks while doing CloudKit work. Keep the UI/main actor free.
            try await Task.detached { [container] in
                try container.initializeCloudKitSchema(options: [])
            }.value
            try await CloudBackupStore.initializeDevelopmentSchema()
            succeeded = true
            schemaInitializationStatus = "Development schema initialized. Return to the Cuekeeper scheme, then run ./cloudkit.sh export on your Mac."
        } catch {
            let failure = error as NSError
            schemaInitializationStatus = "Schema initialization failed (\(failure.domain) \(failure.code)): \(failure.localizedFailureReason ?? failure.localizedDescription)"
            if let underlying = failure.userInfo[NSUnderlyingErrorKey] as? NSError {
                print("Cuekeeper CloudKit underlying error: \(underlying)")
            }
        }
    }
    #endif

    func recordSyncEvent(id: UUID, kind: SyncActivity.Kind, ended: Bool, succeeded: Bool, error: String?) {
        syncActivity.record(id: id, kind: kind, ended: ended, succeeded: succeeded, error: error)
        if kind == .receiving && ended && succeeded {
            persistImportCompletion()
            scheduleReconcile(after: 0)
        }
    }

    /// Coalesce triggers into one pass; a pass aborted by a concurrent edit retries
    /// with backoff instead of waiting for the next iCloud download.
    func scheduleReconcile(after delay: TimeInterval, attempt: Int = 0) {
        reconcileTask?.cancel()
        reconcileTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(for: .seconds(delay)) }
            guard !Task.isCancelled, let self else { return }
            if await !self.reconcileIdentities(), attempt < 4 {
                self.scheduleReconcile(after: 2 * pow(2, Double(attempt)), attempt: attempt + 1)
            }
        }
    }

    /// Recompute the review prompt after a person resolves a conflict.
    func refreshIdentityIssue() {
        let entities = ((try? IdentityReconciliation.conflicts(in: container.viewContext)) ?? []).map(\.entity)
        identityIssue = IdentityReconciliation.Report(conflicts: Array(Set(entities)).sorted()).message
    }

    /// Merge copies of the same record that arrived after a restore. Runs after
    /// launch, completed imports, remote changes and returning to the foreground;
    /// differing copies are reported. Returns false when the pass must be retried.
    @discardableResult
    func reconcileIdentities() async -> Bool {
        // Duplicate identities come from CloudKit delivery; local-only stores never reconcile in the background.
        guard isLoaded, cloudEnabled else { return true }
        do {
            let report = try await BackupWorker.perform(coordinator: container.persistentStoreCoordinator, control: BackupControl()) { writer in
                try IdentityReconciliation.reconcile(in: writer)
            }
            // While iCloud is still receiving, related records may be mid-delivery:
            // clear a resolved warning at once, but raise a new one only once it settles.
            if report.message == nil || !syncActivity.isReceiving { identityIssue = report.message }
            return true
        } catch {
            // A concurrent edit aborts this pass (error merge policy).
            return false
        }
    }

    // The Core Data store UUID survives launches, but changes when the store is replaced.
    // Keep this device-local checkpoint out of CloudKit and backup archives.
    private func importCompletionKey(for store: NSPersistentStore) -> String? {
        let metadata = container.persistentStoreCoordinator.metadata(for: store)
        return (metadata[NSStoreUUIDKey] as? String).map { "cloudImportCompleted.\($0)" }
    }

    private func persistImportCompletion() {
        for store in container.persistentStoreCoordinator.persistentStores {
            if let key = importCompletionKey(for: store) { defaults.set(syncActivity.receivedImport, forKey: key) }
        }
    }

    deinit {
        networkMonitor.cancel()
        if let accountObserver { NotificationCenter.default.removeObserver(accountObserver) }
        if let eventObserver { NotificationCenter.default.removeObserver(eventObserver) }
        for observer in reconcileObservers { NotificationCenter.default.removeObserver(observer) }
    }

    func refreshAccountStatus() async {
        guard cloudEnabled else { return }
        do {
            let status = try await CKContainer(identifier: Self.containerIdentifier).accountStatus()
            syncActivity.checkingAccount = false
            syncActivity.accountIssue = status == .available ? nil : "iCloud needs attention"
            switch status {
            case .available: accountStatus = "Available"
            case .noAccount: accountStatus = "Sign in to iCloud in device Settings"
            case .restricted: accountStatus = "Restricted on this device"
            case .temporarilyUnavailable: accountStatus = "Temporarily unavailable"
            case .couldNotDetermine: accountStatus = "Could not check iCloud"
            @unknown default: accountStatus = "Unknown account status"
            }
        } catch {
            syncActivity.checkingAccount = false
            syncActivity.accountIssue = "Couldn’t connect to iCloud"
            accountStatus = "Could not check iCloud: \(error.localizedDescription)"
        }
    }
}

/// Tracks overlapping operations independently: completing an export must not hide an import.
struct SyncActivity: Equatable {
    enum Kind: Hashable { case setup, receiving, sending }
    var enabled = true
    var offline = false
    var checkingAccount = true
    var accountIssue: String?
    private(set) var receivedImport = false
    private(set) var active: [UUID: Kind] = [:]
    private(set) var failures: [Kind: String] = [:]

    mutating func record(id: UUID, kind: Kind, ended: Bool, succeeded: Bool, error: String?) {
        if !ended {
            active[id] = kind
        } else {
            active.removeValue(forKey: id)
            if succeeded {
                failures[kind] = nil
                if kind == .receiving { receivedImport = true }
            } else { failures[kind] = error ?? "The transfer did not complete. iCloud will try again." }
        }
    }
    mutating func restoreImportCompletion() { receivedImport = true }
    mutating func resetImportCompletion() { receivedImport = false }
    var awaitingInitialImport: Bool { enabled && !receivedImport }
    var restoreUnavailableReason: String? {
        // Local Files recovery must remain available when there is no usable account.
        guard enabled, !offline, accountIssue == nil else { return nil }
        if awaitingInitialImport {
            return "Wait for iCloud to finish its first download before restoring a backup. Connect to the internet and resolve any iCloud errors, then try again."
        }
        if active.values.contains(.receiving) || failures[.receiving] != nil {
            return "Wait for iCloud to finish receiving changes before restoring a backup, then try again."
        }
        return nil
    }
    /// Restoring before iCloud's first download is allowed (offline, account
    /// problems, or no account yet). Copies that arrive later are reconciled.
    var restoreCaution: String? {
        guard enabled, restoreUnavailableReason == nil, awaitingInitialImport else { return nil }
        return "iCloud hasn’t finished downloading to this device. When it does, restored records are matched with their iCloud copies; iCloud’s newer edits are kept, and any financial records that differ are kept for review."
    }
    var isReceiving: Bool { active.values.contains(.receiving) }
    var needsAttention: Bool { accountIssue != nil || !failures.isEmpty }
    var isBusy: Bool { enabled && !offline && !needsAttention && (checkingAccount || !active.isEmpty) }
    var message: String? {
        guard enabled else { return nil }
        if let accountIssue { return accountIssue }
        if !failures.isEmpty { return "iCloud needs attention" }
        if offline { return "Offline — changes saved on this device" }
        if active.values.contains(.receiving) && active.values.contains(.sending) { return "Sending and receiving changes…" }
        if active.values.contains(.receiving) { return "Receiving changes…" }
        if active.values.contains(.sending) { return "Sending changes…" }
        if active.values.contains(.setup) || checkingAccount { return "Connecting to iCloud…" }
        if !receivedImport { return "Waiting for iCloud updates" }
        return nil
    }
    var errorDetails: String? {
        let messages = Set(failures.values).sorted()
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    /// Settings headline. Mirrors `message` priority; "Last exchange" describes this device only.
    func summary(accountStatus: String, lastTransfer: Date?) -> SyncSummary {
        let exchange = lastTransfer.map { date in
            "Last exchange \(date.formatted(date: Calendar.current.isDateInToday(date) ? .omitted : .abbreviated, time: .shortened))"
        }
        guard enabled else { return SyncSummary(headline: "Saved on this device", detail: "iCloud sync is off", symbol: "iphone") }
        if accountIssue != nil { return SyncSummary(headline: "Not syncing", detail: accountStatus, symbol: "exclamationmark", warning: true) }
        if let errorDetails { return SyncSummary(headline: "Sync paused", detail: errorDetails, symbol: "exclamationmark", warning: true) }
        if offline { return SyncSummary(headline: "Offline", detail: "Syncs when you reconnect", symbol: "icloud.slash") }
        let kinds = Set(active.values)
        if kinds.isSuperset(of: [.receiving, .sending]) { return SyncSummary(headline: "Syncing changes", detail: exchange, symbol: "arrow.up.arrow.down", busy: true) }
        if kinds.contains(.receiving) { return SyncSummary(headline: "Receiving changes", detail: exchange, symbol: "arrow.down", busy: true) }
        if kinds.contains(.sending) { return SyncSummary(headline: "Sending changes", detail: exchange, symbol: "arrow.up", busy: true) }
        if kinds.contains(.setup) || checkingAccount { return SyncSummary(headline: "Connecting to iCloud", detail: nil, symbol: "icloud", busy: true) }
        if !receivedImport { return SyncSummary(headline: "Waiting for iCloud", detail: "Events may still arrive", symbol: "icloud.and.arrow.down") }
        return SyncSummary(headline: "Synced", detail: exchange, symbol: "checkmark")
    }

    var accountSummary: String? {
        guard enabled else { return nil }
        if checkingAccount { return "Checking…" }
        return accountIssue == nil ? "Available" : "Unavailable"
    }
}

struct SyncSummary: Equatable {
    let headline: String
    let detail: String?
    let symbol: String
    var warning = false
    var busy = false
}

/// Local store readiness, independent of CloudKit import and of any caller's lifetime.
@MainActor
final class StoreReadiness {
    private var result: Result<Void, Error>?
    private var waiters: [UUID: CheckedContinuation<Void, Error>] = [:]

    func wait() async throws {
        try Task.checkCancellation()
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                // Registration and completion are serialized on the main actor.
                if Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                } else if let result {
                    continuation.resume(with: result)
                } else {
                    waiters[id] = continuation
                }
            }
        } onCancel: {
            Task { @MainActor in
                self.waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
        try Task.checkCancellation()
    }

    func complete(_ result: Result<Void, Error>) {
        guard self.result == nil else { return }
        self.result = result
        let pending = waiters
        waiters.removeAll()
        for continuation in pending.values { continuation.resume(with: result) }
    }
}
