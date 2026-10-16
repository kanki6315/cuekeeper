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
extension View {
    func preservesDraftOnTodayLink() -> some View { modifier(PreserveDraftNavigation()) }
}

enum ScheduleDestination: Hashable {
    case event(NSManagedObjectID), booking(NSManagedObjectID), session(NSManagedObjectID), pendingExpenses
}

struct RootView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var persistence: PersistenceController
    @StateObject private var todayNavigation = TodayNavigation()
    @State private var selectedTab: AppSection = .upcoming
    @State private var paths: [AppSection: NavigationPath] = [:]
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
                                case .pendingExpenses: PendingExpensesView()
                                case .event(let id):
                                    if let job = try? context.existingObject(with: id) as? Job { EventDetailView(anchor: job) }
                                case .booking(let id):
                                    if let job = try? context.existingObject(with: id) as? Job { JobDetailView(job: job) }
                                case .session(let id):
                                    if let session = try? context.existingObject(with: id) as? WorkSession { SessionDetailView(session: session) }
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
        #if DEBUG
        .onAppear {
            if DesignFixtures.enabled && DesignFixtures.route == "expenses-overview" { selectedTab = .expenses }
            if DesignFixtures.enabled && DesignFixtures.route == "payments-root" { selectedTab = .payments }
        }
        #endif
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("CuekeeperOpenToday"))) { _ in
            todayNavigation.request()
        }
        .onChange(of: todayNavigation.revision) { _, _ in
            UserDefaults.standard.set("Today", forKey: "upcoming.scope")
            paths[.upcoming] = NavigationPath()
            selectedTab = .upcoming
        }
    }
    private func path(for section: AppSection) -> Binding<NavigationPath> {
        Binding(get: { paths[section] ?? NavigationPath() }, set: { paths[section] = $0 })
    }
    @ViewBuilder private func content(_ section: AppSection) -> some View {
        switch section {
        case .upcoming: JobsView(upcomingOnly: true, path: path(for: .upcoming))
        case .jobs: JobsView(upcomingOnly: false, path: path(for: .jobs))
        case .payments: PaymentsView()
        case .expenses: ExpensesView()
        case .settings: SettingsView()
        }
    }
}

private struct JobsView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var persistence: PersistenceController
    let upcomingOnly: Bool
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
    @AppStorage("upcoming.scope") private var upcomingScope = "Today"
    @AppStorage("upcoming.dismissedAttention") private var dismissedAttention = ""
    private func attentionKey(_ job: Job) -> String { "\(job.id?.uuidString ?? "")/\(job.eventStartDay)/\(job.bookingStatus)/\(job.eventEndDay < Day.string(from: Date()) ? "past" : "schedule")" }
    private var attention: [Job] {
        let dismissed = Set(dismissedAttention.split(separator: "\n").map(String.init))
        let today = Day.string(from: Date()), soon = Day.string(from: Date().addingTimeInterval(14 * 86400))
        return jobs.filter { job in
            !["completed", "cancelled"].contains(job.bookingStatus) && filter.includes(job, query: query) && !dismissed.contains(attentionKey(job))
            && (job.eventEndDay < today || (job.eventStartDay <= soon && (job.activeSessions.isEmpty || job.activeSessions.contains { $0.scheduleStatus != "confirmed" })))
        }
    }
    private var representatives: [Job] {
        let _ = events.count + sessions.count
        let today = Day.string(from: Date())
        let weekEnd = Day.string(from: Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.end.addingTimeInterval(-1) ?? Date())
        let matching = jobs.filter { job in
            let active = !["completed", "cancelled"].contains(job.bookingStatus)
            return filter.includes(job, query: query)
                && (!upcomingOnly || (active && (job.eventEndDay >= today || job.activeSessions.contains { ($0.endTime ?? .distantPast) >= Date() })))
                && (!upcomingOnly || upcomingScope != "Week" || job.eventStartDay <= weekEnd)
                && (upcomingOnly || scope == "All" || (scope == "Active" ? active : job.bookingStatus == scope.lowercased()))
        }
        var seen = Set<NSManagedObjectID>()
        return matching.filter { seen.insert($0.eventKey).inserted }.sorted {
            ($0.eventStartDay, $0.eventTitle) < ($1.eventStartDay, $1.eventTitle)
        }
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if selectedJob == nil {
                    // Matches DaybookForm's 29pt gap below the tab header (5pt row padding + 24pt section spacing).
                    DaybookTabHeader { if !jobs.isEmpty { addButton } }.padding(.bottom, 11)
                } else if upcomingOnly {
                    HStack { Spacer(); addButton }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack { Text(upcomingOnly ? "Upcoming" : "Events").font(.largeTitle.bold()); Spacer(); addButton }
                        VStack(alignment: .leading, spacing: 12) { Text(upcomingOnly ? "Upcoming" : "Events").font(.largeTitle.bold()); addButton }
                    }
                }
                if upcomingOnly { PendingExpensesPrompt() }
                if !jobs.isEmpty {
                    if !upcomingOnly || upcomingScope != "Today" { HStack {
                        DaybookTextField("Search events, clients or series", text: $query).accessibilityIdentifier("search-jobs")
                        Button { showingFilters = true } label: { Image(systemName: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle").frame(width: 44, height: 44) }.accessibilityLabel("Filter Events").accessibilityIdentifier("filter-jobs")
                    } }
                    if upcomingOnly {
                        if upcomingScope == "Today" {
                            TimelineView(.periodic(from: .now, by: 60)) { timeline in
                                Text(timeline.date, format: .dateTime.weekday(.wide).day().month(.wide))
                                    .foregroundStyle(Color("SecondaryText"))
                            }
                        }
                        DaybookSegments(title: "Show upcoming", selection: $upcomingScope,
                                        options: ["Today", "Week", "All"], identifier: "upcoming-scope",
                                        label: { $0 })
                    } else {
                        DaybookSegments(title: "Bookings", selection: $scope,
                                        options: ["All", "Active", "Completed", "Cancelled"],
                                        identifier: "event-status-scope", label: { $0 })
                    }
                }
                if jobs.isEmpty {
                    if selectedJob == nil { Text(upcomingOnly ? "Upcoming" : "Events").font(.largeTitle.bold()) }
                    VStack(spacing: 24) {
                        CuekeeperMark().fill(Color.accentColor.opacity(0.2), style: FillStyle(eoFill: true))
                            .frame(width: 90, height: 104).accessibilityHidden(true)
                        Text("Your next event\nstarts here").font(.title2.bold())
                        Text("Start with a date. Add the details when you know them.")
                            .foregroundStyle(Color("SecondaryText"))
                        if persistence.awaitingInitialImport {
                            Label("Existing work may still arrive from iCloud. You can add an event now.", systemImage: "icloud.and.arrow.down")
                                .font(.subheadline).foregroundStyle(Color("SecondaryText"))
                        }
                        Button("Add your first event") { showingAdd = true }
                            .buttonStyle(LaunchPrimaryButton()).accessibilityIdentifier("add-job")
                    }.multilineTextAlignment(.center).frame(maxWidth: 480).padding(.vertical, 48)
                        .frame(maxWidth: .infinity)
                } else if (!upcomingOnly || upcomingScope != "Today") && representatives.isEmpty {
                    ContentUnavailableView("No events to show", systemImage: "calendar", description: Text("Start with dates and a client. Add the schedule when it arrives."))
                    if filter.isActive { Button("Clear Filters") { filter = JobFilter() } }
                }
                if upcomingOnly && upcomingScope == "Today" && !jobs.isEmpty {
                    TodayScheduleView(selectedJob: selectedJob)
                } else {
                LazyVStack(spacing: 0) {
                    ForEach(representatives, id: \.eventKey) { job in
                        if let selectedJob {
                            Button { selectedJob.wrappedValue = job } label: { row(job) }.buttonStyle(.plain)
                        } else {
                            NavigationLink(value: ScheduleDestination.event(job.objectID)) { row(job) }.buttonStyle(.plain)
                        }
                        Divider()
                    }
                }
                }
                if upcomingOnly && upcomingScope != "Today" && !attention.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Label("Needs attention", systemImage: "exclamationmark.circle").font(.headline)
                            Spacer()
                            Button { dismissedAttention = Set(dismissedAttention.split(separator: "\n").map(String.init) + attention.map(attentionKey)).sorted().joined(separator: "\n") } label: { Image(systemName: "xmark").frame(width: 44, height: 44) }.accessibilityLabel("Dismiss current attention items")
                        }
                        ForEach(Array(attention.prefix(3)), id: \.objectID) { job in
                            NavigationLink(value: ScheduleDestination.booking(job.objectID)) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(job.eventEndDay < Day.string(from: Date()) ? "Ready to mark complete?" : "Schedule to confirm").font(.subheadline.weight(.semibold))
                                    Text(job.displayName).font(.subheadline)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.padding(16).foregroundStyle(Color("AmberText")).background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
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
            .onAppear { if selectedJob?.wrappedValue == nil { selectedJob?.wrappedValue = representatives.first } }
    }
    private var addButton: some View { Button("Add Event", systemImage: "plus") { showingAdd = true }.buttonStyle(DaybookPrimaryButton()).accessibilityIdentifier("add-job") }
    private func row(_ job: Job) -> some View {
        HStack(alignment: .top, spacing: 14) {
            DaybookDateRail(day: job.eventStartDay)
            VStack(alignment: .leading, spacing: 8) {
                Text(job.eventTitle).font(.headline)
                Text(job.eventDateDescription).font(.subheadline).foregroundStyle(Color("SecondaryText"))
                ForEach(job.eventBookings, id: \.objectID) { booking in
                    HStack { Text(booking.client?.name ?? "Client to add").font(.subheadline); Spacer(); BookingBadge(status: booking.bookingStatus) }
                }
                if let next = job.eventSessions.first(where: { $0.scheduleStatus == "confirmed" && ($0.endTime ?? .distantPast) >= Date() && $0.job?.bookingStatus != "cancelled" }) {
                    DaybookMetadata(symbol: "clock", text: next.compactSchedule)
                    if let call = next.callTime { DaybookMetadata(symbol: "video", text: "Call \(next.shortTime(call))") }
                }
                Text(job.eventSessions.isEmpty ? "Schedule to come" : counted(job.eventSessions.count, "session", "sessions")).font(.caption).foregroundStyle(Color("SecondaryText"))
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }.padding(.vertical, 20).contentShape(Rectangle())
    }
}

func dateRange(_ job: Job) -> String { job.eventDateDescription }

struct SettingsView: View {
    @ScaledMetric(relativeTo: .body) private var libraryIconWidth = 26
    @Environment(\.horizontalSizeClass) private var sizeClass
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
            Section {
                Button("Run setup again") { showingSetup = true }.frame(minHeight: 44)
                    .accessibilityIdentifier("run-setup-again")
            }
            Section("Integrations") {
                DaybookLink { CalendarSettingsView() } label: { Label("Calendar", systemImage: "calendar").frame(maxWidth: .infinity, alignment: .leading) }
                DaybookLink { ExpenseAutomationSettingsView() } label: { Label("Wallet Automation", systemImage: "creditcard").frame(maxWidth: .infinity, alignment: .leading) }.accessibilityIdentifier("wallet-automation-settings")
            }
            Section("Libraries") {
                DaybookLink { LibraryView(kind: .series) } label: { libraryLabel("Series", symbol: "rectangle.stack") }
                DaybookLink { LibraryView(kind: .client) } label: { libraryLabel("Clients", symbol: "person.2") }
                DaybookLink { LibraryView(kind: .role) } label: { libraryLabel("Roles", symbol: "person.text.rectangle") }
            }
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
            Section("Recovery & backups") {
                DaybookLink { BackupView() } label: {
                    HStack {
                        Label("Backups", systemImage: "icloud.and.arrow.up")
                        Spacer(minLength: 8)
                        if let latestBackup {
                            Text(latestBackup).foregroundStyle(Color("SecondaryText"))
                                .accessibilityLabel("Latest manual backup \(latestBackup)")
                        }
                    }
                }
                .accessibilityIdentifier("backups-link")
                DaybookLink { RecentlyDeletedView() } label: { Label("Recently Deleted", systemImage: "trash") }
            }
            Section("About") {
                Button("Help & Support", systemImage: "questionmark.circle") {
                    webPage = WebPageLink(title: "Help & Support", url: URL(string: "https://cuekeeper.arjunakankipati.com/support")!)
                }
                Button("Privacy Policy", systemImage: "hand.raised") {
                    webPage = WebPageLink(title: "Privacy Policy", url: URL(string: "https://cuekeeper.arjunakankipati.com/privacy")!)
                }
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

    private func libraryLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: libraryIconWidth).accessibilityHidden(true)
            Text(title)
        }
        .foregroundStyle(Color.accentColor)
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
                                .foregroundStyle(Color("AmberText"))
                        } else if activity.isBusy {
                            ProgressView().controlSize(.small).tint(Color.accentColor)
                        } else {
                            Image(systemName: activity.offline ? "icloud.slash" : "icloud").foregroundStyle(Color.accentColor)
                        }
                        Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color("SecondaryText"))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 16).padding(.vertical, 12)
                    .frame(maxWidth: 540, minHeight: 48)
                    .background(Color("SurfaceBackground"), in: RoundedRectangle(cornerRadius: 16))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(activity.needsAttention ? Color("AmberText").opacity(0.5) : Color.primary.opacity(0.16), lineWidth: 1)
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
    private var tint: Color { summary.warning ? Color("AmberText") : Color.accentColor }

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
                        .foregroundStyle(summary.warning ? Color("AmberText") : Color("SecondaryText"))
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
                Image(systemName: symbol).foregroundStyle(status == .ok ? Color.accentColor : (status == .warning ? Color("AmberText") : Color("SecondaryText")))
            }
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            Text(value).foregroundStyle(status == .warning ? Color("AmberText") : Color("SecondaryText"))
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
