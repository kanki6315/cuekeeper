import SwiftUI
import AppIntents
import CoreData

@main
struct CuekeeperApp: App {
    @AppStorage("firstLaunchCompleted") private var firstLaunchCompleted = false
    @AppStorage("appearance") private var appearance = "system"
    @StateObject private var persistence: PersistenceController
    @StateObject private var expenseNotifications = ExpenseNotifications.shared
    @StateObject private var handoff: EventEditorHandoff
    @State private var calendarLink: CalendarLink?
    @StateObject private var calendar = CalendarController()
    @StateObject private var schedulePublisher = SchedulePublisher()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Termination skips the normal deinit/defer cleanup of plaintext backup files.
        do {
            let failures = try BackupTemporaryFiles.removeInterruptedBackups()
            if !failures.isEmpty { NSLog("Could not remove %ld interrupted backup artifacts; will retry next launch.", failures.count) }
        } catch {
            NSLog("Could not enumerate temporary backup artifacts; will retry next launch.")
        }
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
        ExpenseNotifications.shared.installDelegate()
        let controller = PersistenceController(storeURL: storeURL, cloudEnabled: !testing)
        if !testing && UserDefaults.standard.object(forKey: "firstLaunchCompleted") == nil {
            // Capture upgrade evidence before the asynchronous store load creates a new file.
            UserDefaults.standard.set(controller.hadExistingStore, forKey: "firstLaunchCompleted")
        }
        #if DEBUG
        if arguments.contains("--ui-testing"), arguments.contains("--reset-test-store") {
            UserDefaults.standard.set(arguments.contains("--today-fixtures") ? "Today" : "All", forKey: "upcoming.scope")
            for key in ["firstLaunchCompleted", "defaultRole", "homeTimeZone", "appearance", "defaultCurrency", "walletAutomationGuideStep", "walletAutomationGuideStepV2"] {
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
                    .sheet(item: $calendarLink) { link in
                        CalendarLinkView(link: link)
                            .environment(\.managedObjectContext, persistence.container.viewContext)
                    }
                    .sheet(item: $expenseNotifications.route) { route in
                        ExpenseNotificationView(id: route.id).environment(\.managedObjectContext, persistence.container.viewContext)
                    }
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
                if loaded {
                    calendar.start(context: persistence.container.viewContext, enabled: persistence.cloudEnabled)
                    schedulePublisher.start(context: persistence.container.viewContext, enabled: persistence.cloudEnabled)
                }
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active {
                    EventWeatherStore.shared.purgeExpired()
                    schedulePublisher.refresh()
                    calendar.refreshCalendars(); calendar.scheduleSync()
                    Task {
                        await persistence.refreshAccountStatus()
                        if persistence.isLoaded { await expenseNotifications.reconcile(in: persistence.container.viewContext) }
                    }
                }
            }
            .onOpenURL { url in
                if let link = CalendarLink(url: url) {
                    calendarLink = link
                    return
                }
                guard url.scheme == "cuekeeper", url.host == "today" else { return }
                calendarLink = nil
                UserDefaults.standard.set("Today", forKey: "upcoming.scope")
                NotificationCenter.default.post(name: Notification.Name("CuekeeperOpenToday"), object: nil)
            }
            .tint(Color("AccentColor"))
            .preferredColorScheme(preferredAppearance)
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
                if persistence.isLoaded {
                    calendar.start(context: persistence.container.viewContext, enabled: persistence.cloudEnabled)
                    schedulePublisher.start(context: persistence.container.viewContext, enabled: persistence.cloudEnabled)
                }
            }
        }
    }

    private var preferredAppearance: ColorScheme? {
        #if DEBUG
        if DesignFixtures.enabled { return ProcessInfo.processInfo.arguments.contains("--design-dark") ? .dark : .light }
        #endif
        return appearance == "dark" ? .dark : appearance == "light" ? .light : nil
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

private struct CalendarLinkView: View {
    let link: CalendarLink
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var destination: CalendarLink.Destination?
    @State private var loading = true
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView("Opening calendar entry…")
                } else if let destination {
                    switch destination {
                    case .job(let job): EventDetailView(anchor: job)
                    case .session(let session): SessionDetailView(session: session)
                    }
                } else {
                    ContentUnavailableView("Calendar entry unavailable", systemImage: "calendar.badge.exclamationmark",
                        description: Text(error ?? "This event or session may have been deleted or may not have synced to this device yet."))
                }
            }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .task(id: link.id) {
            loading = true
            error = nil
            do { destination = try link.resolve(in: context) }
            catch { destination = nil; self.error = error.localizedDescription }
            loading = false
        }
    }
}
