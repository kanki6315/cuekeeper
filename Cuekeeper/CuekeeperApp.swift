import SwiftUI
import AppIntents
import CoreData
import UIKit

@main
struct CuekeeperApp: App {
    @AppStorage("firstLaunchCompleted") private var firstLaunchCompleted = false
    @AppStorage("appearance") private var appearance = "system"
    @StateObject private var persistence: PersistenceController
    @StateObject private var expenseNotifications = ExpenseNotifications.shared
    @StateObject private var handoff: EventEditorHandoff
    @StateObject private var presentations = ExternalPresentations()
    @State private var pendingToday = false
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
        let testing = ProcessInfo.processInfo.isUITesting || NSClassFromString("XCTestCase") != nil
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
        if ProcessInfo.processInfo.isUITesting, arguments.contains("--reset-test-store") {
            for key in [UpcomingView.modeKey, UpcomingView.modeSetKey, "upcoming.scope", "upcoming.dismissedAttention", "firstLaunchCompleted", "defaultRole", "homeTimeZone", "homeLocation", "appearance", "defaultCurrency", "displayCurrencies", "walletAutomationGuideStep", "walletAutomationGuideStepV2"] {
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

    // Hosted unit tests open multiple stores and historical models. Mounting the
    // live UI would resolve its fetch requests against those test models and
    // leave onboarding sheets interfering with presentation-policy tests.
    private var isUnitTestHost: Bool {
        #if DEBUG
        return NSClassFromString("XCTestCase") != nil && !ProcessInfo.processInfo.isUITesting
        #else
        return false
        #endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if isUnitTestHost {
                    Color.clear
                } else if let error = persistence.loadError {
                    ContentUnavailableView {
                        Label("Couldn’t open your daybook", systemImage: "externaldrive.badge.exclamationmark")
                    } description: {
                        Text("Your saved data has not been replaced. Close and reopen Cuekeeper to try again.")
                    } actions: {
                        Button("Copy Details for Support", systemImage: "doc.on.doc") { UIPasteboard.general.string = error }
                    }
                } else if persistence.isLoaded {
                    Group {
                        #if DEBUG
                        if DesignFixtures.enabled { DesignFixtureScreen().preferredColorScheme(ProcessInfo.processInfo.arguments.contains("--design-dark") ? .dark : .light) } else { launchContent }
                        #else
                        launchContent
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
            .background {
                ExternalPresentationHost(presentations: presentations, ready: persistence.isLoaded && !isUnitTestHost) { request in
                    AnyView(externalContent(request)
                        .environment(\.managedObjectContext, persistence.container.viewContext)
                        .environmentObject(persistence).environmentObject(calendar))
                } onClose: { request in
                    switch request {
                    case .receipt: handoff.scanningReceipt = false
                    case .siri(let request): handoff.close(id: request.id)
                    default: break
                    }
                }
            }
            .onReceive(expenseNotifications.$route) { route in
                guard let route else { return }
                presentations.enqueue(.expense(route.id))
                Task { @MainActor in
                    if expenseNotifications.route?.id == route.id { expenseNotifications.route = nil }
                }
            }
            .onReceive(handoff.$scanningReceipt) { scanning in
                if scanning { presentations.enqueue(.receipt) }
            }
            .onReceive(handoff.$pending) { request in
                if let request { presentations.enqueue(.siri(request)) }
            }
            .task(id: pendingToday && persistence.isLoaded && (firstLaunchCompleted || bypassSetupForTests)) {
                guard pendingToday, persistence.isLoaded, firstLaunchCompleted || bypassSetupForTests else { return }
                // Let the completed setup install the tab navigation before delivering.
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
                NotificationCenter.default.post(name: Notification.Name("CuekeeperOpenToday"), object: nil)
                pendingToday = false
            }
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
                #if DEBUG
                if ProcessInfo.processInfo.isUITesting, url.host == "ui-test" {
                    triggerExternalRouteTest(url.lastPathComponent)
                    return
                }
                #endif
                if let link = CalendarLink(url: url) {
                    presentations.enqueue(.calendar(link))
                    return
                }
                guard url.scheme == "cuekeeper", url.host == "today" else { return }
                pendingToday = true
            }
            .tint(Color("AccentColor"))
            .preferredColorScheme(preferredAppearance)
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.isUITesting, ProcessInfo.processInfo.arguments.contains("--siri-wizard-test"), handoff.pending == nil {
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

    #if DEBUG
    private func triggerExternalRouteTest(_ kind: String) {
        let context = persistence.container.viewContext
        do {
            switch kind {
            case "receipt": try handoff.requestReceiptScan()
            case "siri":
                var draft = EventCreationDraft(); draft.events[0].details.name = "Routed Siri event"
                _ = try handoff.create(draft, in: context)
            case "expense":
                let records = try context.fetch(NSFetchRequest<Expense>(entityName: "Expense"))
                if let id = records.first(where: \.needsCompletion)?.id { expenseNotifications.open(userInfo: ["expenseID": id.uuidString]) }
            case "calendar":
                let records = try context.fetch(NSFetchRequest<Job>(entityName: "Job"))
                let id = records.first?.id ?? UUID()
                if let link = CalendarLink(url: URL(string: "cuekeeper://calendar/job/\(id)")!) { presentations.enqueue(.calendar(link)) }
            default: break
            }
        } catch { assertionFailure(error.localizedDescription) }
    }
    #endif

    @ViewBuilder private func externalContent(_ request: ExternalPresentation) -> some View {
        switch request {
        case .calendar(let link): CalendarLinkView(link: link)
        case .expense(let id): ExpenseNotificationView(id: id)
        case .receipt: ReceiptEventPicker()
        case .siri(let request): SiriCreatedEventView(request: request)
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
        return ProcessInfo.processInfo.isUITesting && !arguments.contains("--first-launch")
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
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.accessibilityIdentifier("calendar-route-done") }
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

extension ProcessInfo {
    /// Fixtures and the isolated test store are debug-only; release builds ignore `--ui-testing`.
    var isUITesting: Bool {
        #if DEBUG
        arguments.contains("--ui-testing")
        #else
        false
        #endif
    }
}

/// External actions are presented above the visible screen, including setup and
/// an existing editor. No sheet binding is left armed on a hidden root view.
enum ExternalPresentation: Identifiable {
    case calendar(CalendarLink), expense(UUID), receipt, siri(EventEditorHandoff.Request)
    var id: String {
        switch self {
        case .calendar(let link): "calendar/\(link.id)"
        case .expense(let id): "expense/\(id)"
        case .receipt: "receipt"
        case .siri(let request): "siri/\(request.id)"
        }
    }
}

@MainActor
final class ExternalPresentations: ObservableObject {
    @Published private(set) var waiting: [ExternalPresentation] = []
    private var active: Set<String> = []
    func enqueue(_ request: ExternalPresentation) {
        guard !active.contains(request.id), !waiting.contains(where: { $0.id == request.id }) else { return }
        waiting.append(request)
    }
    func didPresent(_ request: ExternalPresentation) {
        active.insert(request.id)
        waiting.removeAll { $0.id == request.id }
    }
    func didClose(_ request: ExternalPresentation) { active.remove(request.id) }
}

private struct ExternalPresentationHost: UIViewControllerRepresentable {
    @ObservedObject var presentations: ExternalPresentations
    let ready: Bool
    let content: (ExternalPresentation) -> AnyView
    let onClose: (ExternalPresentation) -> Void
    func makeUIViewController(context: Context) -> ExternalPresentationController { ExternalPresentationController() }
    func updateUIViewController(_ controller: ExternalPresentationController, context: Context) {
        controller.presentations = presentations
        controller.ready = ready
        controller.content = content
        controller.onClose = onClose
        controller.drain()
    }
}

private final class ExternalPresentationController: UIViewController {
    var presentations: ExternalPresentations?
    var ready = false
    var content: ((ExternalPresentation) -> AnyView)?
    var onClose: ((ExternalPresentation) -> Void)?
    private var delivery: Task<Void, Never>?
    override func loadView() { view = UIView(); view.isUserInteractionEnabled = false }
    override func viewDidAppear(_ animated: Bool) { super.viewDidAppear(animated); drain() }
    func drain() {
        guard delivery == nil, ready, presentations?.waiting.isEmpty == false else { return }
        delivery = Task { @MainActor [weak self] in
            defer { self?.delivery = nil }
            // Wait only for a mounted window or an in-flight presentation transition.
            // Ordinary sheets are valid presenters, rather than reasons to defer.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard let self, self.ready, let queue = self.presentations, let request = queue.waiting.first else { return }
                guard let window = self.view.window, window.windowScene?.activationState == .foregroundActive,
                      var presenter = window.rootViewController, let content = self.content else { continue }
                while let next = presenter.presentedViewController { presenter = next }
                guard !presenter.isBeingPresented, !presenter.isBeingDismissed,
                      presenter.transitionCoordinator == nil, !(presenter is UIAlertController) else { continue }
                let host = ExternalRouteHostingController(rootView: content(request))
                host.modalPresentationStyle = .pageSheet
                if case .expense = request { host.isModalInPresentation = true }
                host.sheetPresentationController?.detents = [.large()]
                let close = self.onClose
                host.onClose = { [weak queue] in queue?.didClose(request); close?(request) }
                presenter.present(host, animated: true)
                host.presentationController?.delegate = host
                queue.didPresent(request)
            }
        }
    }
    deinit { delivery?.cancel() }
}

private final class ExternalRouteHostingController: UIHostingController<AnyView>, UIAdaptivePresentationControllerDelegate {
    var onClose: (() -> Void)?
    private func closed() { let action = onClose; onClose = nil; action?() }
    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || presentingViewController == nil { closed() }
    }
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { closed() }
}
