import CoreData
import SwiftUI

private enum AppSection: String, CaseIterable, Identifiable {
    case upcoming = "Upcoming", jobs = "Events", payments = "Payments", settings = "Settings"
    var id: String { rawValue }
    var symbol: String {
        switch self {
        case .upcoming: "calendar"
        case .jobs: "text.book.closed"
        case .payments: "creditcard"
        case .settings: "gearshape"
        }
    }
}

struct RootView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @EnvironmentObject private var persistence: PersistenceController
    @State private var selection: AppSection? = .upcoming
    @State private var selectedJob: Job?
    @State private var selectedTab: AppSection = .upcoming
    @State private var todayNavigationID = UUID()
    @FetchRequest(sortDescriptors: [], predicate: NSPredicate(format: "deletedAt == nil")) private var allJobs: FetchedResults<Job>
    private var showsSyncFeedback: Bool {
        !allJobs.isEmpty || persistence.syncActivity.needsAttention || persistence.syncActivity.offline
    }

    var body: some View {
        Group {
        if sizeClass == .regular && !typeSize.isAccessibilitySize {
            if (selection == .upcoming || selection == .jobs) && !allJobs.isEmpty {
                NavigationSplitView {
                    sidebar
                } content: {
                    JobsView(upcomingOnly: selection == .upcoming, selectedJob: $selectedJob)
                        .id("\(selection?.rawValue ?? "Upcoming")-\(todayNavigationID)")
                        .navigationSplitViewColumnWidth(min: 320, ideal: 420, max: 520)
                } detail: {
                    NavigationStack {
                        if let selectedJob { EventDetailView(anchor: selectedJob).id(selectedJob.objectID) }
                        else { ContentUnavailableView("Select an event", systemImage: "text.book.closed", description: Text("Your schedule, fees and payments, together.")).daybookSurface() }
                    }
                }.navigationSplitViewStyle(.balanced)
            } else {
                NavigationSplitView { sidebar } detail: { NavigationStack { content(selection ?? .upcoming) } }
            }
        } else {
            TabView(selection: $selectedTab) {
                ForEach(AppSection.allCases) { section in
                    NavigationStack {
                        content(section)
                            .overlay(alignment: .bottom) {
                                if section != .settings && showsSyncFeedback {
                                    SyncFeedbackView { selectedTab = .settings }
                                        .padding(.horizontal, 20)
                                        .padding(.bottom, 12)
                                }
                            }
                    }
                    .id(section == .upcoming ? todayNavigationID : nil)
                    .tabItem { Label(section.rawValue, systemImage: section.symbol) }
                    .tag(section)
                }
            }
        }
            }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("CuekeeperOpenToday"))) { _ in
            todayNavigationID = UUID()
            selectedJob = nil
            selectedTab = .upcoming
            selection = .upcoming
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            BrandLockup().padding(.horizontal, 18).padding(.top, 22).padding(.bottom, 12)
            List(AppSection.allCases, selection: $selection) { section in
                Label { Text(section.rawValue) } icon: {
                    Image(systemName: section.symbol)
                        .foregroundStyle(selection == section ? Color.white : Color("AccentColor"))
                }
                    .padding(.vertical, 6).tag(section)
            }
            .listStyle(.sidebar)
            .tint(Color("SidebarSelection"))
            .scrollContentBackground(.hidden)
            if showsSyncFeedback {
                Button { selection = .settings } label: {
                    Label(persistence.syncActivity.message ?? "Saved on this device", systemImage: persistence.syncActivity.needsAttention ? "exclamationmark.icloud" : "icloud")
                        .font(.footnote)
                        .foregroundStyle(persistence.syncActivity.needsAttention ? Color("AmberText") : Color("SecondaryText"))
                        .padding(20)
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("sync-feedback")
                .accessibilityHint("Opens storage and iCloud details")
            }
        }
        .modifier(DaybookSidebarSurface())
        .padding(10)
        .background(Color("PageBackground"))
        .navigationSplitViewColumnWidth(min: 210, ideal: 230, max: 280)
    }
    @ViewBuilder private func content(_ section: AppSection) -> some View {
        switch section {
        case .upcoming: JobsView(upcomingOnly: true)
        case .jobs: JobsView(upcomingOnly: false)
        case .payments: PaymentsView()
        case .settings: SettingsView()
        }
    }
}

private struct JobsView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var persistence: PersistenceController
    let upcomingOnly: Bool
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
    @State private var opened: Job?
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
                    DaybookTabHeader { if !jobs.isEmpty { addButton } }
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
                        Text(upcomingScope == "Today" ? "Today" : "Upcoming").font(.largeTitle.bold())
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
                            NavigationLink { EventDetailView(anchor: job) } label: { row(job) }.buttonStyle(.plain)
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
                            NavigationLink { JobDetailView(job: job) } label: {
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
                    if let selectedJob { selectedJob.wrappedValue = job } else { opened = job }
                }
            } }
            .sheet(isPresented: $showingFilters) { JobFiltersView(filter: $filter) }
            .navigationDestination(item: $opened) { EventDetailView(anchor: $0) }
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
            Section {
                LabeledContent("iCloud account", value: persistence.accountStatus)
                if let message = persistence.syncActivity.message {
                    Text(message)
                        .foregroundStyle(persistence.syncActivity.needsAttention ? Color("AmberText") : Color("SecondaryText"))
                }
                if let detail = persistence.syncActivity.errorDetails { Text(detail).font(.subheadline) }
                if let setupStatus = persistence.schemaInitializationStatus {
                    Text(setupStatus)
                }
                DisclosureGroup("iCloud details") {
                    VStack(alignment: .leading, spacing: 12) {
                        if persistence.syncActivity.message == nil {
                            Text(persistence.transferStatus).foregroundStyle(Color("SecondaryText"))
                        }
                        if let date = persistence.lastTransfer {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Last transfer")
                                Text(date.formatted(date: .abbreviated, time: .shortened))
                                    .foregroundStyle(Color("SecondaryText"))
                            }
                        }
                        Button("Check iCloud Account") { Task { await persistence.refreshAccountStatus() } }
                        Text("A completed transfer doesn’t mean every device has received the latest changes.")
                            .font(.footnote).foregroundStyle(Color("SecondaryText"))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, 12)
                }
            } header: {
                Text("Storage & iCloud")
            } footer: {
                Text("Events are saved on this device and sync with iCloud when available. Backups are managed separately below.")
            }
            Section("Recovery & backups") {
                DaybookLink { BackupView() } label: { Label("Backups", systemImage: "icloud.and.arrow.up") }
                DaybookLink { RecentlyDeletedView() } label: { Label("Recently Deleted", systemImage: "trash") }
            }
            Section("About") {
                Link(destination: URL(string: "https://cuekeeper.arjunakankipati.com/support")!) {
                    Label("Help & Support", systemImage: "questionmark.circle")
                }
                Link(destination: URL(string: "https://cuekeeper.arjunakankipati.com/privacy")!) {
                    Label("Privacy Policy", systemImage: "hand.raised")
                }
                LabeledContent("Version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))")
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(sizeClass == .compact ? .hidden : .visible, for: .navigationBar)
        .task { await persistence.refreshAccountStatus() }
        .sheet(isPresented: $showingSetup) {
            FirstLaunchView { showingSetup = false }
                .presentationSizing(.form)
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await persistence.refreshAccountStatus() } }
        }
    }

    private func libraryLabel(_ title: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).frame(width: libraryIconWidth).accessibilityHidden(true)
            Text(title)
        }
        .foregroundStyle(Color.accentColor)
    }
}

struct SyncFeedbackView: View {
    @EnvironmentObject private var persistence: PersistenceController
    @State private var displayedActivity: SyncActivity?
    let showDetails: () -> Void

    var body: some View {
        Group {
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
