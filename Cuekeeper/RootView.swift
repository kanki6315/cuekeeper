import CoreData
import SwiftUI
import WebKit

private enum AppSection: String, CaseIterable, Identifiable {
    case upcoming = "Upcoming", jobs = "Events", payments = "Payments", expenses = "Expenses", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .upcoming: "calendar"
        case .jobs: "text.book.closed"
        case .payments: "creditcard"
        case .expenses: "receipt"
        case .settings: "gearshape"
        }
    }
}

/// A Today request waits for editors to close through their normal save/discard flow.
@MainActor
final class TodayNavigation: ObservableObject {
    @Published private(set) var revision = 0
    private var editors: Set<UUID> = []
    private var pending = false

    func beginEditing(_ id: UUID) { editors.insert(id) }
    func endEditing(_ id: UUID) {
        editors.remove(id)
        if editors.isEmpty && pending { request() }
    }
    func request() {
        guard editors.isEmpty else { pending = true; return }
        pending = false
        revision += 1
    }
}

private struct TodayNavigationKey: EnvironmentKey {
    static let defaultValue: TodayNavigation? = nil
}
extension EnvironmentValues {
    var todayNavigation: TodayNavigation? {
        get { self[TodayNavigationKey.self] }
        set { self[TodayNavigationKey.self] = newValue }
    }
}
private struct PreserveDraftNavigation: ViewModifier {
    @Environment(\.todayNavigation) private var navigation
    @State private var id = UUID()
    func body(content: Content) -> some View {
        content.onAppear { navigation?.beginEditing(id) }
            .onDisappear { navigation?.endEditing(id) }
    }
}
private struct OpenExpensesInboxKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}
extension EnvironmentValues {
    /// Switches to the Expenses tab's inbox, from Payments or Settings.
    var openExpensesInbox: (() -> Void)? {
        get { self[OpenExpensesInboxKey.self] }
        set { self[OpenExpensesInboxKey.self] = newValue }
    }
}
extension View {
    func preservesDraftOnTodayLink() -> some View { modifier(PreserveDraftNavigation()) }
}

enum ScheduleDestination: Hashable {
    case event(NSManagedObjectID), booking(NSManagedObjectID), session(NSManagedObjectID)
    case fee(NSManagedObjectID), invoice(NSManagedObjectID)
}

struct RootView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var persistence: PersistenceController
    @StateObject private var todayNavigation = TodayNavigation()
    @State private var selectedTab: AppSection = .upcoming
    @SceneStorage("expenses.mode") private var expensesMode = ExpensesMode.inbox
    @State private var paths: [AppSection: NavigationPath] = [:]
    #if DEBUG
    @State private var openedWorkflowFixture = false
    #endif
    @FetchRequest(sortDescriptors: [], predicate: NSPredicate(format: "deletedAt == nil")) private var allJobs: FetchedResults<Job>
    private var showsSyncFeedback: Bool {
        !allJobs.isEmpty || persistence.syncActivity.needsAttention || persistence.syncActivity.offline
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            ForEach(AppSection.allCases) { section in
                Tab(section.rawValue, systemImage: section.symbol, value: section) {
                    NavigationStack(path: path(for: section)) {
                        content(section)
                            .navigationDestination(for: ScheduleDestination.self) { destination in
                                switch destination {
                                case .event(let id):
                                    if let job = try? context.existingObject(with: id) as? Job { EventDetailView(anchor: job) }
                                case .booking(let id):
                                    if let job = try? context.existingObject(with: id) as? Job { JobDetailView(job: job) }
                                case .session(let id):
                                    if let session = try? context.existingObject(with: id) as? WorkSession { SessionDetailView(session: session) }
                                case .fee(let id):
                                    if let job = try? context.existingObject(with: id) as? Job { FeeDetailView(job: job) }
                                case .invoice(let id):
                                    if let invoice = try? context.existingObject(with: id) as? Invoice { InvoiceDetailView(invoice: invoice) }
                                }
                            }
                            .safeAreaInset(edge: .bottom, spacing: 0) {
                                if section != .settings && showsSyncFeedback {
                                    SyncFeedbackView { selectedTab = .settings }
                                        .padding(.horizontal, 20).padding(.bottom, 12)
                                }
                            }
                    }
                }
            }
        }
        .tabViewStyle(.sidebarAdaptable)
        .environment(\.todayNavigation, todayNavigation)
        .environment(\.openExpensesInbox) {
            expensesMode = .inbox
            paths[.expenses] = NavigationPath()
            selectedTab = .expenses
        }
        #if DEBUG
        .onAppear {
            if DesignFixtures.enabled && DesignFixtures.route == "expenses-overview" { expensesMode = .ledger; selectedTab = .expenses }
            if DesignFixtures.enabled && DesignFixtures.route == "expenses-inbox" { expensesMode = .inbox; selectedTab = .expenses }
            if DesignFixtures.enabled && DesignFixtures.route == "payments-root" { selectedTab = .payments }
            // Workflow prerequisites use the real Events navigation stack, including
            // its tab switching and back navigation, without replaying list setup.
            if DesignFixtures.enabled, !openedWorkflowFixture,
               ProcessInfo.processInfo.arguments.contains(where: { $0.hasPrefix("--workflow-event-title=") }),
               let job = allJobs.first {
                openedWorkflowFixture = true
                if ProcessInfo.processInfo.arguments.contains("--workflow-open-event") {
                    var path = NavigationPath()
                    path.append(ScheduleDestination.event(job.objectID))
                    paths[.jobs] = path
                }
                selectedTab = .jobs
            }
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("CuekeeperOpenToday"))) { _ in
            todayNavigation.request()
        }
        .onChange(of: todayNavigation.revision) { _, _ in
            UpcomingView.requestNow()
            paths[.upcoming] = NavigationPath()
            selectedTab = .upcoming
        }
    }
    private func path(for section: AppSection) -> Binding<NavigationPath> {
        Binding(get: { paths[section] ?? NavigationPath() }, set: { paths[section] = $0 })
    }
    @ViewBuilder private func content(_ section: AppSection) -> some View {
        switch section {
        case .upcoming: UpcomingView(path: path(for: .upcoming), onShowAllEvents: { selectedTab = .jobs })
        case .jobs: JobsView(path: path(for: .jobs))
        case .payments: PaymentsView()
        case .expenses: ExpensesView(mode: $expensesMode)
        case .settings: SettingsView()
        }
    }
}

private struct JobsView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var persistence: PersistenceController
    @Binding var path: NavigationPath
    var selectedJob: Binding<Job?>? = nil
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Job.startDay, ascending: true)], predicate: NSPredicate(format: "deletedAt == nil")) private var jobs: FetchedResults<Job>
    @FetchRequest(sortDescriptors: []) private var events: FetchedResults<WorkEvent>
    @FetchRequest(sortDescriptors: []) private var sessions: FetchedResults<WorkSession>
    @State private var showingAdd = false
    @State private var showingFilters = false
    @State private var query = ""
    @State private var filter = JobFilter()
    @State private var scope = "All"
    @State private var showEarlier = false
    @FetchRequest(sortDescriptors: []) private var invoiceRevisions: FetchedResults<InvoiceRevision>
    @FetchRequest(sortDescriptors: []) private var feeRevisions: FetchedResults<FeeRevision>
    @FetchRequest(sortDescriptors: []) private var payments: FetchedResults<PaymentRecord>
    @FetchRequest(sortDescriptors: []) private var expenses: FetchedResults<Expense>
    private var today: String { Day.string(from: Date()) }
    /// Older events stay out of All and Completed unless searched for, filtered by date or asked for.
    private var list: EventsList {
        let _ = invoiceRevisions.count + feeRevisions.count + payments.count + expenses.count
        let index = InvoiceIndex(in: context)
        let today = today
        let windowed = (scope == "All" || scope == "Completed")
            && query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !filter.usesDates
        // Hidden events only need counting, so skip reading their billing.
        let cutoff = windowed && !showEarlier ? EventsCalendar.day(today, adding: -EventsList.windowDays) : nil
        let facts = representatives.map { job in
            EventsListFacts(job: job, today: today, context: context, index: index,
                            readsPayment: cutoff.map { job.eventEndDay.isEmpty || job.eventEndDay >= $0 } ?? true)
        }
        return EventsList(events: facts, today: today, windowed: windowed, showEarlier: showEarlier)
    }
    private var representatives: [Job] {
        let _ = events.count + sessions.count
        let matching = jobs.filter { job in
            let active = !["completed", "cancelled"].contains(job.bookingStatus)
            return filter.includes(job, query: query)
                && (scope == "All" || (scope == "Active" ? active : job.bookingStatus == scope.lowercased()))
        }
        var seen = Set<NSManagedObjectID>()
        return matching.filter { seen.insert($0.eventKey).inserted }.sorted {
            ($0.eventStartDay, $0.eventTitle) < ($1.eventStartDay, $1.eventTitle)
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                let list = list
                if selectedJob == nil {
                    // Matches DaybookForm's 29pt gap below the tab header (5pt row padding + 24pt section spacing).
                    DaybookTabHeader { if !jobs.isEmpty { addButton } }.padding(.bottom, 11)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack { Text("Events").font(.largeTitle.bold()); Spacer(); addButton }
                        VStack(alignment: .leading, spacing: 12) { Text("Events").font(.largeTitle.bold()); addButton }
                    }
                }
                if !jobs.isEmpty {
                    HStack {
                        DaybookTextField("Search events, clients or series", text: $query).accessibilityIdentifier("search-jobs")
                        Button { showingFilters = true } label: { Image(systemName: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle").frame(width: 44, height: 44) }.accessibilityLabel("Filter Events").accessibilityIdentifier("filter-jobs")
                    }
                    DaybookSegments(title: "Bookings", selection: $scope,
                                    options: ["All", "Active", "Completed", "Cancelled"],
                                    identifier: "event-status-scope", label: { $0 })
                }
                if jobs.isEmpty {
                    if selectedJob == nil { Text("Events").font(.largeTitle.bold()) }
                    VStack(spacing: 24) {
                        CuekeeperMark().fill(Color.theme.accent.opacity(0.2), style: FillStyle(eoFill: true))
                            .frame(width: 90, height: 104).accessibilityHidden(true)
                        Text("Your next event\nstarts here").font(.title2.bold())
                        Text("Start with a date. Add the details when you know them.")
                            .foregroundStyle(Color.theme.secondaryText)
                        if persistence.awaitingInitialImport {
                            Label("Existing work may still arrive from iCloud. You can add an event now.", systemImage: "icloud.and.arrow.down")
                                .font(.subheadline).foregroundStyle(Color.theme.secondaryText)
                        }
                        Button("Add your first event") { showingAdd = true }
                            .buttonStyle(LaunchPrimaryButton()).accessibilityIdentifier("add-job")
                    }.multilineTextAlignment(.center).frame(maxWidth: 480).padding(.vertical, 48)
                        .frame(maxWidth: .infinity)
                } else if representatives.isEmpty {
                    ContentUnavailableView("No events to show", systemImage: "calendar", description: Text("Start with dates and a client. Add the schedule when it arrives."))
                    if filter.isActive { Button("Clear Filters") { filter = JobFilter() } }
                }
                if !representatives.isEmpty {
                    if list.rows.isEmpty {
                        Text("No events in the last two weeks.").font(.subheadline).foregroundStyle(Color.theme.secondaryText)
                    }
                    if list.hiddenEarlier > 0 { earlierButton(list) }
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(list.months) { month in
                            EventSectionTitle(title: month.title(currentYear: String(today.prefix(4)))) {
                                if let collect = month.collectText {
                                    Text(collect).font(.footnote).foregroundStyle(Color.theme.secondaryText).monospacedDigit()
                                }
                            }
                            .padding(.top, month.id == list.months.first?.id ? 4 : 22)
                            ForEach(month.rows) { row in
                                if row.id == list.todayBefore { EventsTodayMarker() }
                                if let id = row.facts.objectID, let job = try? context.existingObject(with: id) as? Job {
                                    if let selectedJob {
                                        Button { selectedJob.wrappedValue = job } label: { EventsListRowView(row: row) }.buttonStyle(.plain)
                                    } else {
                                        NavigationLink(value: ScheduleDestination.event(id)) { EventsListRowView(row: row) }.buttonStyle(.plain)
                                    }
                                }
                                Divider()
                            }
                        }
                    }
                }
            }.padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 20).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }.daybookSurface()
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
            .toolbar(sizeClass == .compact ? .hidden : .visible, for: .navigationBar)
            .sheet(isPresented: $showingAdd) { EventWizardView { id in
                if let job = try? context.existingObject(with: id) as? Job {
                    if let selectedJob { selectedJob.wrappedValue = job } else { path.append(ScheduleDestination.event(job.objectID)) }
                }
            } }
            .sheet(isPresented: $showingFilters) { JobFiltersView(filter: $filter) }
            .onAppear {
                guard let selectedJob, selectedJob.wrappedValue == nil else { return }
                let rows = list.rows
                let row = rows.first { $0.id == list.todayBefore } ?? rows.first { !$0.finished } ?? rows.first
                selectedJob.wrappedValue = row?.facts.objectID.flatMap { try? context.existingObject(with: $0) as? Job }
            }
    }
    private var addButton: some View { Button("Add Event", systemImage: "plus") { showingAdd = true }.buttonStyle(DaybookPrimaryButton()).accessibilityIdentifier("add-job") }
    private func earlierButton(_ list: EventsList) -> some View {
        Button(showEarlier ? "Hide events before \(Day.display(list.cutoff))"
                           : "Show " + counted(list.hiddenEarlier, "earlier event", "earlier events")) {
            withAnimation(.easeOut(duration: 0.2)) { showEarlier.toggle() }
        }
        .font(.subheadline.weight(.semibold)).frame(minHeight: 44)
        .accessibilityIdentifier("events-show-earlier")
    }
}

func dateRange(_ job: Job) -> String { job.eventDateDescription }

struct SettingsView: View {
    @ScaledMetric(relativeTo: .body) private var tileSize = 30
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorSchemeContrast) private var contrast
    @EnvironmentObject private var calendar: CalendarController
    @State private var showingSetup = false
    @State private var webPage: WebPageLink?
    @State private var latestBackup: String?
    private let backups: any CloudBacking = CloudBackupStore()
    @EnvironmentObject private var persistence: PersistenceController
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        DaybookForm(topPadding: 12) {
            Section {
                DaybookTabHeader { EmptyView() }
            }
            .containerValue(\.daybookUnframed, true)
            .containerValue(\.daybookFlushTop, true)
            Section { PreferenceFields() }.containerValue(\.daybookUnframed, true)
            Section("Your data") {
                let activity = persistence.syncActivity
                SyncSummaryRow(summary: activity.summary(accountStatus: persistence.accountStatus, lastTransfer: persistence.lastTransfer))
                SyncLedgerRow(title: UIDevice.current.userInterfaceIdiom == .pad ? "This iPad" : "This iPhone", value: "Saved", status: .ok)
                if let account = activity.accountSummary {
                    SyncLedgerRow(title: "iCloud account", value: account,
                                  status: activity.accountIssue != nil ? .warning : (activity.checkingAccount ? .pending : .ok))
                }
                if activity.accountIssue != nil {
                    Button("Check Again") { Task { await persistence.refreshAccountStatus() } }
                        .frame(minHeight: 44)
                        .accessibilityIdentifier("check-icloud-account")
                }
                if let setupStatus = persistence.schemaInitializationStatus {
                    Text(setupStatus)
                }
            }
            Section("Integrations") {
                DaybookLink { CalendarSettingsView() } label: {
                    HStack {
                        tiledLabel("Calendar", symbol: "calendar")
                        Spacer(minLength: 8)
                        Text(calendar.connected ? "On" : "Off").foregroundStyle(Color.theme.secondaryText)
                    }
                }
                .accessibilityIdentifier("calendar-settings")
                DaybookLink { ExpenseAutomationSettingsView() } label: { tiledLabel("Wallet Automation", symbol: "creditcard") }
                    .accessibilityIdentifier("wallet-automation-settings")
            }
            Section("Libraries") {
                if typeSize.isAccessibilitySize {
                    DaybookLink { LibraryView(kind: .series) } label: { tiledLabel("Series", symbol: "rectangle.stack") }
                    DaybookLink { LibraryView(kind: .client) } label: { tiledLabel("Clients", symbol: "person.2") }
                    DaybookLink { LibraryView(kind: .role) } label: { tiledLabel("Roles", symbol: "person.text.rectangle") }
                } else {
                    HStack(spacing: 0) {
                        libraryButton("Series", symbol: "rectangle.stack", kind: .series)
                        libraryDivider
                        libraryButton("Clients", symbol: "person.2", kind: .client)
                        libraryDivider
                        libraryButton("Roles", symbol: "person.text.rectangle", kind: .role)
                    }
                    .padding(.vertical, -4)
                }
            }
            Section("Recovery & backups") {
                DaybookLink { BackupView() } label: {
                    HStack {
                        tiledLabel("Backups", symbol: "icloud.and.arrow.up")
                        Spacer(minLength: 8)
                        if let latestBackup {
                            Text(latestBackup).foregroundStyle(Color.theme.secondaryText)
                                .accessibilityLabel("Latest manual backup \(latestBackup)")
                        }
                    }
                }
                .accessibilityIdentifier("backups-link")
                DaybookLink { RecentlyDeletedView() } label: { tiledLabel("Recently Deleted", symbol: "trash") }
            }
            Section("About") {
                Button("Help & Support", systemImage: "questionmark.circle") {
                    webPage = WebPageLink(title: "Help & Support", url: URL(string: "https://cuekeeper.arjunakankipati.com/support")!)
                }
                Button("Privacy Policy", systemImage: "hand.raised") {
                    webPage = WebPageLink(title: "Privacy Policy", url: URL(string: "https://cuekeeper.arjunakankipati.com/privacy")!)
                }
                Button("Run setup again", systemImage: "arrow.counterclockwise") { showingSetup = true }
                    .accessibilityIdentifier("run-setup-again")
                LabeledContent("Version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))")
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(sizeClass == .compact ? .hidden : .visible, for: .navigationBar)
        .task { await persistence.refreshAccountStatus() }
        .onAppear { Task { await loadLatestBackup() } }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            latestBackup = nil
            Task { await loadLatestBackup() }
        }
        .sheet(isPresented: $showingSetup) {
            FirstLaunchView { showingSetup = false }
                .presentationSizing(.form)
        }
        .sheet(item: $webPage) { InAppWebPage(link: $0) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await persistence.refreshAccountStatus() } }
        }
    }

    /// Latest manual backup, read without creating the backup zone. Failures leave the row unlabelled.
    private func loadLatestBackup() async {
        guard persistence.cloudEnabled else { return }
        do {
            latestBackup = try await backups.latestDate().map { Self.backupDate($0) } ?? "None yet"
        } catch {
            latestBackup = nil
        }
    }

    static func backupDate(_ date: Date, now: Date = Date()) -> String {
        Calendar.current.isDate(date, equalTo: now, toGranularity: .year)
            ? date.formatted(.dateTime.month(.abbreviated).day())
            : date.formatted(.dateTime.month(.abbreviated).day().year())
    }

    /// A row label led by its symbol in a small tinted tile.
    private func tiledLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.theme.accent)
                .frame(width: tileSize, height: tileSize)
                .background(Color.theme.accent.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
                .accessibilityHidden(true)
            Text(title)
        }
    }

    private func libraryButton(_ title: String, symbol: String, kind: LibraryKind) -> some View {
        NavigationLink { LibraryView(kind: kind) } label: {
            VStack(spacing: 6) {
                Image(systemName: symbol).font(.title3).accessibilityHidden(true)
                Text(title).font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(Color.theme.accent)
            .frame(maxWidth: .infinity, minHeight: 60)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("library-\(title.lowercased())")
    }

    private var libraryDivider: some View {
        Rectangle().fill(Color.primary.opacity(contrast == .increased ? 0.45 : 0.16))
            .frame(width: 0.5).padding(.vertical, 6)
    }
}

private struct WebPageLink: Identifiable {
    let title: String
    let url: URL
    var id: URL { url }
}

private struct InAppWebPage: View {
    let link: WebPageLink
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @State private var page = WebPage()

    var body: some View {
        NavigationStack {
            WebView(page)
                .overlay { if page.isLoading && page.estimatedProgress < 0.1 { ProgressView() } }
                .ignoresSafeArea(edges: .bottom)
                .navigationTitle(link.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Done", systemImage: "xmark") { dismiss() }
                    }
                    ToolbarItem(placement: .primaryAction) {
                        Button("Open in Browser", systemImage: "safari") { openURL(page.url ?? link.url) }
                    }
                }
        }
        .onAppear { if page.url == nil { page.load(URLRequest(url: link.url)) } }
    }
}

struct SyncFeedbackView: View {
    @EnvironmentObject private var persistence: PersistenceController
    @State private var displayedActivity: SyncActivity?
    let showDetails: () -> Void

    var body: some View {
        // Keep a task host even before the first activity makes the banner visible.
        // An empty Group has no child on which SwiftUI can run the task below.
        ZStack {
            if let activity = displayedActivity, let message = activity.message {
                Button(action: showDetails) {
                    HStack(spacing: 12) {
                        if activity.needsAttention {
                            Image(systemName: "exclamationmark.icloud")
                                .foregroundStyle(Color.theme.caution)
                        } else if activity.isBusy {
                            ProgressView().controlSize(.small).tint(Color.theme.accent)
                        } else {
                            Image(systemName: activity.offline ? "icloud.slash" : "icloud").foregroundStyle(Color.theme.accent)
                        }
                        Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color.theme.secondaryText)
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: 540, minHeight: 48)
                    .background(Color.theme.surface, in: RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(activity.needsAttention ? Color.theme.caution.opacity(0.5) : Color.primary.opacity(0.16), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 4)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sync-feedback")
                .accessibilityLabel(activity.needsAttention ? "Warning: \(message)" : message)
                .accessibilityHint("Opens storage and iCloud details in Settings")
            }
        }
        .task(id: persistence.syncActivity) {
            let activity = persistence.syncActivity
            if activity.enabled && activity.message == nil {
                // CloudKit can finish one transfer before announcing the next.
                // Keep the same banner and indicator until activity settles.
                do { try await Task.sleep(for: .seconds(1.5)) }
                catch { return }
            }
            guard !Task.isCancelled else { return }
            displayedActivity = activity.message == nil ? nil : activity
        }
    }
}

/// Settings headline for live sync. Backups are reported separately on the Backups row.
struct SyncSummaryRow: View {
    let summary: SyncSummary
    @ScaledMetric(relativeTo: .title3) private var badge = 44
    @Environment(\.dynamicTypeSize) private var typeSize
    private var tint: Color { summary.warning ? Color.theme.caution : Color.theme.positive }

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10)) : AnyLayout(HStackLayout(spacing: 14))
        layout {
            Image(systemName: summary.symbol)
                .font(.title3.weight(.medium))
                .foregroundStyle(tint)
                .symbolEffect(.pulse, options: .repeating, isActive: summary.busy)
                .frame(width: badge, height: badge)
                .background(tint.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.headline).font(.title3.weight(.semibold))
                if let detail = summary.detail {
                    Text(detail).font(.subheadline)
                        .foregroundStyle(summary.warning ? Color.theme.caution : Color.theme.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .animation(.easeOut(duration: 0.2), value: summary)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(summary.warning ? "Warning: \(summary.headline)" : summary.headline)
        .accessibilityValue(summary.detail ?? "")
        .accessibilityIdentifier("sync-summary")
    }
}

struct SyncLedgerRow: View {
    enum Status { case ok, pending, warning }
    let title: String
    let value: String
    let status: Status
    @Environment(\.dynamicTypeSize) private var typeSize

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            Label {
                Text(title)
            } icon: {
                Image(systemName: symbol).foregroundStyle(status == .ok ? Color.theme.positive : (status == .warning ? Color.theme.caution : Color.theme.secondaryText))
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            Text(value).foregroundStyle(status == .warning ? Color.theme.caution : Color.theme.secondaryText)
        }
        .frame(minHeight: 28)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(status == .warning ? "Warning: \(value)" : value)
    }

    private var symbol: String {
        switch status {
        case .ok: "checkmark.circle.fill"
        case .pending: "circle.dotted"
        case .warning: "exclamationmark.circle.fill"
        }
    }
}
