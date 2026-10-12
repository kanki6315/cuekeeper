import CloudKit
import Combine
import CoreData

@MainActor
final class PersistenceController: ObservableObject {
    static let containerIdentifier = "iCloud.com.arjunakankipati.cuekeeper"
    let container: NSPersistentCloudKitContainer
    let cloudEnabled: Bool
    @Published private(set) var isLoaded = false
    @Published private(set) var loadError: String?
    @Published private(set) var accountStatus = "Checking…"
    @Published private(set) var transferStatus = "Waiting for iCloud activity"
    @Published private(set) var schemaInitializationStatus: String?
    @Published private(set) var lastTransfer: Date?
    private var eventObserver: NSObjectProtocol?

    init(storeURL: URL? = nil, cloudEnabled: Bool = true) {
        self.cloudEnabled = cloudEnabled
        container = NSPersistentCloudKitContainer(name: "Cuekeeper")
        let description = container.persistentStoreDescriptions[0]
        if let storeURL { description.url = storeURL }
        description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        description.setOption(true as NSNumber, forKey: NSPersistentStoreRemoteChangeNotificationPostOptionKey)
        description.shouldMigrateStoreAutomatically = true
        description.shouldInferMappingModelAutomatically = true
        description.cloudKitContainerOptions = cloudEnabled
            ? NSPersistentCloudKitContainerOptions(containerIdentifier: Self.containerIdentifier)
            : nil
        container.viewContext.automaticallyMergesChangesFromParent = true
        // Only nonfinancial job capture exists in this schema. Financial records will
        // require explicit revision/conflict handling, not this general merge policy.
        container.viewContext.mergePolicy = NSMergeByPropertyObjectTrumpMergePolicy
        container.viewContext.name = "Cuekeeper view context"
        if cloudEnabled {
            eventObserver = NotificationCenter.default.addObserver(
                forName: NSPersistentCloudKitContainer.eventChangedNotification,
                object: container, queue: .main
            ) { [weak self] notification in
                guard let event = notification.userInfo?[NSPersistentCloudKitContainer.eventNotificationUserInfoKey]
                    as? NSPersistentCloudKitContainer.Event else { return }
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if let error = event.error {
                        self.transferStatus = "iCloud needs attention: \(error.localizedDescription)"
                    } else if event.endDate == nil {
                        self.transferStatus = "iCloud transfer in progress"
                    } else if event.succeeded {
                        self.transferStatus = "Last iCloud operation completed"
                        self.lastTransfer = event.endDate
                    }
                }
            }
        } else {
            accountStatus = "Off for this test session"
            transferStatus = "Local storage only"
        }
        container.loadPersistentStores { [weak self] _, error in
            Task { @MainActor [weak self] in
                self?.loadError = error?.localizedDescription
                self?.isLoaded = error == nil
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
            try container.initializeCloudKitSchema(options: [])
            schemaInitializationStatus = "Development schema initialized. Return to the Cuekeeper scheme, then run ./cloudkit.sh export on your Mac."
        } catch {
            schemaInitializationStatus = "Schema initialization failed: \(error.localizedDescription)"
        }
        // A stable setup result, separate from transient import/export notifications.
        print("Cuekeeper CloudKit setup: \(schemaInitializationStatus ?? "No result")")
    }
    #endif

    deinit {
        if let eventObserver { NotificationCenter.default.removeObserver(eventObserver) }
    }

    func refreshAccountStatus() async {
        guard cloudEnabled else { return }
        do {
            let status = try await CKContainer(identifier: Self.containerIdentifier).accountStatus()
            switch status {
            case .available: accountStatus = "Available"
            case .noAccount: accountStatus = "Sign in to iCloud in device Settings"
            case .restricted: accountStatus = "Restricted on this device"
            case .temporarilyUnavailable: accountStatus = "Temporarily unavailable"
            case .couldNotDetermine: accountStatus = "Could not check iCloud"
            @unknown default: accountStatus = "Unknown account status"
            }
        } catch {
            accountStatus = "Could not check iCloud: \(error.localizedDescription)"
        }
    }
}
