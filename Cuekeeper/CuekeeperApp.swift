import SwiftUI

@main
struct CuekeeperApp: App {
    @StateObject private var persistence: PersistenceController
    @StateObject private var calendar = CalendarController()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Test isolation never changes the user's production store or iCloud records.
        let arguments = ProcessInfo.processInfo.arguments
        let testing = arguments.contains("--ui-testing") || NSClassFromString("XCTestCase") != nil
        var storeURL: URL?
        if testing {
            let directory = URL.applicationSupportDirectory.appending(path: "UITests", directoryHint: .isDirectory)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            storeURL = directory.appending(path: "Cuekeeper.sqlite")
            if arguments.contains("--reset-test-store") {
                for suffix in ["", "-shm", "-wal"] {
                    try? FileManager.default.removeItem(atPath: storeURL!.path + suffix)
                }
            }
        }
        #if CLOUDKIT_SCHEMA_SETUP
        // Setup has its own local store; it never opens the normal daybook database.
        let setupDirectory = URL.applicationSupportDirectory.appending(path: "CloudKitSchemaSetup", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: setupDirectory, withIntermediateDirectories: true)
        storeURL = setupDirectory.appending(path: "Schema.sqlite")
        #endif
        _persistence = StateObject(wrappedValue: PersistenceController(storeURL: storeURL, cloudEnabled: !testing))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let error = persistence.loadError {
                    ContentUnavailableView {
                        Label("Couldn’t open your daybook", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text("Your saved data has not been replaced. Close and reopen Cuekeeper to try again.\n\n\(error)")
                    }
                } else if persistence.isLoaded {
                    Group {
                        #if DEBUG
                        if DesignFixtures.enabled { DesignFixtureScreen().preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--design-dark") ? .dark : .light) } else { RootView() }
                        #else
                        RootView()
                        #endif
                    }.environment(\.managedObjectContext, persistence.container.viewContext)
                } else {
                    ProgressView("Opening your daybook…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color("PageBackground"))
            .environmentObject(persistence)
            .environmentObject(calendar)
            .onChange(of: persistence.isLoaded) { _, loaded in
                if loaded { calendar.start(context: persistence.container.viewContext, enabled: persistence.cloudEnabled) }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    calendar.refreshCalendars(); calendar.scheduleSync()
                    Task { await persistence.refreshAccountStatus() }
                }
            }
            .tint(Color("AccentColor"))
            .task {
                await persistence.refreshAccountStatus()
                if persistence.isLoaded { calendar.start(context: persistence.container.viewContext, enabled: persistence.cloudEnabled) }
            }
        }
    }
}
