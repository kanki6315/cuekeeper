import SwiftUI
import AppIntents
import CoreData

@main
struct CuekeeperApp: App {
    @AppStorage("firstLaunchCompleted") private var firstLaunchCompleted = false
    @AppStorage("appearance") private var appearance = "system"
    @StateObject private var persistence: PersistenceController
    @StateObject private var handoff: EventEditorHandoff
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
        let controller = PersistenceController(storeURL: storeURL, cloudEnabled: !testing)
        if !testing && UserDefaults.standard.object(forKey: "firstLaunchCompleted") == nil {
            // Capture upgrade evidence before the asynchronous store load creates a new file.
            UserDefaults.standard.set(controller.hadExistingStore, forKey: "firstLaunchCompleted")
        }
        #if DEBUG
        if arguments.contains("--ui-testing"), arguments.contains("--reset-test-store") {
            for key in ["firstLaunchCompleted", "defaultRole", "homeTimeZone", "appearance", "defaultCurrency"] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        #endif
        _persistence = StateObject(wrappedValue: controller)
        AppDependencyManager.shared.add(dependency: controller)
        let handoff = EventEditorHandoff()
        _handoff = StateObject(wrappedValue: handoff)
        AppDependencyManager.shared.add(dependency: handoff)

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
                        if DesignFixtures.enabled { DesignFixtureScreen().preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--design-dark") ? .dark : .light) } else { launchContent }
                        #else
                        launchContent
                        #endif
                    }.environment(\.managedObjectContext, persistence.container.viewContext)
                    .sheet(isPresented: $handoff.scanningReceipt) {
                        ReceiptEventPicker().environment(\.managedObjectContext, persistence.container.viewContext)
                    }
                    .fullScreenCover(item: Binding(get: { handoff.pending }, set: { value in
                        if value == nil, let id = handoff.pending?.id { handoff.close(id: id) }
                    })) { request in
                        SiriCreatedEventView(request: request)
                            .environment(\.managedObjectContext, persistence.container.viewContext)
                            .onDisappear { handoff.close(id: request.id) }
                    }
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
                    EventWeatherStore.shared.purgeExpired()
                    calendar.refreshCalendars(); calendar.scheduleSync()
                    Task { await persistence.refreshAccountStatus() }
                }
            }
            .tint(Color("AccentColor"))
            .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.arguments.contains("--ui-testing"), ProcessInfo.processInfo.arguments.contains("--siri-wizard-test"), handoff.pending == nil {
                    do {
                        try await persistence.waitUntilLoaded()
                        let context = persistence.container.viewContext
                        if try context.count(for: NSFetchRequest<Job>(entityName: "Job")) == 0 {
                            let draft = try SiriEventDraft.make(title: "IMSA esports", start: Day.date(from: "2026-11-07")!, end: nil, allDay: true)
                            _ = try handoff.create(draft, in: context, notices: ProcessInfo.processInfo.arguments.contains("--siri-import-notice") ? ["Recurrence wasn’t imported. Only one event was created."] : [])
                        }
                    } catch { assertionFailure(error.localizedDescription) }
                }
                #endif
                await persistence.refreshAccountStatus()
                if persistence.isLoaded { calendar.start(context: persistence.container.viewContext, enabled: persistence.cloudEnabled) }
            }
        }
    }

    @ViewBuilder private var launchContent: some View {
        if firstLaunchCompleted || bypassSetupForTests {
            RootView()
        } else {
            FirstLaunchPresentation { firstLaunchCompleted = true }
        }
    }
    private var bypassSetupForTests: Bool {
        #if DEBUG
        let arguments = ProcessInfo.processInfo.arguments
        return arguments.contains("--ui-testing") && !arguments.contains("--first-launch")
        #else
        return false
        #endif
    }
}
