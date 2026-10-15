import CloudKit
import Combine
import Network
import CoreData

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
    var awaitingInitialImport: Bool { syncActivity.enabled && !syncActivity.receivedImport }
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
    private var eventObserver: NSObjectProtocol?

    func waitUntilLoaded() async throws {
        for _ in 0..<200 {
            if let loadError { throw RecordError.invalid("Couldn’t open your daybook: \(loadError)") }
            if isLoaded { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw RecordError.invalid("Your daybook is still opening. Please try again.")
    }

    init(storeURL: URL? = nil, cloudEnabled: Bool = true) {
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
        syncActivity.enabled = cloudEnabled
        if cloudEnabled {
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
                    self.syncActivity.record(id: event.identifier, kind: kind, ended: event.endDate != nil,
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
        if !cloudEnabled && arguments.contains("--ui-testing") {
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
                if error == nil, let self, !cloudEnabled, arguments.contains("--ui-testing"),
                   arguments.contains("--setup-returning") || arguments.contains("--setup-backup-fixture") {
                    do {
                        let id = try JobDraft(name: "Recovered broadcast").save(in: self.container.viewContext)
                        if arguments.contains("--setup-backup-fixture") {
                            let snapshot = try BackupArchive.capture(in: self.container.viewContext)
                            try await FixtureBackups.shared.save(data: snapshot.encoded(), date: snapshot.createdAt, events: 1)
                            try Job.remove(id, in: self.container.viewContext)
                        }
                    } catch { self.loadError = error.localizedDescription }
                }
                if error == nil, let self, DesignFixtures.enabled {
                    do { try DesignFixtures.seed(self.container.viewContext) }
                    catch { self.loadError = "Review fixture setup failed: \(error.localizedDescription)" }
                }
                #endif
                self?.isLoaded = self?.loadError == nil
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

    deinit {
        networkMonitor.cancel()
        if let eventObserver { NotificationCenter.default.removeObserver(eventObserver) }
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
struct SyncActivity {
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
}
