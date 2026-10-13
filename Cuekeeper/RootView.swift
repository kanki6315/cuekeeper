import CoreData
import SwiftUI

private enum AppSection: String, CaseIterable, Identifiable {
    case upcoming = "Upcoming", jobs = "Jobs", payments = "Payments", settings = "Settings"
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

    var body: some View {
        if sizeClass == .regular && !typeSize.isAccessibilitySize {
            if selection == .upcoming || selection == .jobs {
                NavigationSplitView {
                    sidebar
                } content: {
                    JobsView(upcomingOnly: selection == .upcoming, selectedJob: $selectedJob)
                        .id(selection ?? .upcoming)
                        .navigationSplitViewColumnWidth(min: 320, ideal: 420, max: 520)
                } detail: {
                    NavigationStack {
                        if let selectedJob { JobDetailView(job: selectedJob).id(selectedJob.objectID) }
                        else { ContentUnavailableView("Select a job", systemImage: "text.book.closed", description: Text("Your schedule, fees and payments, together.")).daybookSurface() }
                    }
                }.navigationSplitViewStyle(.balanced)
            } else {
                NavigationSplitView { sidebar } detail: { NavigationStack { content(selection ?? .upcoming) } }
            }
        } else {
            TabView {
                ForEach(AppSection.allCases) { section in
                    NavigationStack { content(section) }
                        .tabItem { Label(section.rawValue, systemImage: section.symbol) }
                }
            }
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
            Label(persistence.syncActivity.message ?? "Saved on this device", systemImage: persistence.syncActivity.needsAttention ? "icloud.slash" : "icloud")
                .font(.footnote).foregroundStyle(Color("SecondaryText")).padding(20)
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
    @Environment(\.dynamicTypeSize) private var typeSize
    @EnvironmentObject private var persistence: PersistenceController
    @Environment(\.managedObjectContext) private var context
    let upcomingOnly: Bool
    var selectedJob: Binding<Job?>? = nil
    @State private var jobScope = "Upcoming"
    @State private var thisWeek = false
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Job.startDay, ascending: true),
                                   NSSortDescriptor(keyPath: \Job.createdAt, ascending: true)])
    private var jobs: FetchedResults<Job>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \WorkSession.startTime, ascending: true)], predicate: NSPredicate(format: "deletedAt == nil AND scheduleStatus == %@", "confirmed")) private var sessions: FetchedResults<WorkSession>
    @State private var showingAdd = false
    @State private var query = ""
    @State private var filter = JobFilter()
    @State private var showingFilters = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var today = Day.string(from: Date())
    private var visibleJobs: [Job] {
        jobs.filter {
            (!upcomingOnly || (($0.endDay >= today || $0.activeSessions.contains { $0.scheduleStatus == "confirmed" && ($0.endTime ?? .distantPast) >= Date() }) && $0.bookingStatus != "cancelled" && $0.bookingStatus != "completed"))
                && filter.includes($0, query: query)
                && (upcomingOnly || (jobScope == "Completed" ? $0.bookingStatus == "completed" : jobScope == "Cancelled" ? $0.bookingStatus == "cancelled" : $0.bookingStatus != "completed" && $0.bookingStatus != "cancelled"))
                && (!upcomingOnly || !thisWeek || $0.startDay <= Day.string(from: Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.end.addingTimeInterval(-1) ?? Date()))
        }
    }

    private var visibleSessions: [WorkSession] {
        guard upcomingOnly else { return [] }
        return sessions.filter { session in
            guard let job = session.job, let end = session.endTime else { return false }
            return end >= Date() && job.bookingStatus != "cancelled" && job.bookingStatus != "completed" && filter.includes(job, query: query)
        }
    }

    @AppStorage("upcoming.dismissedAttention") private var dismissedAttention = ""
    private func jobDay(_ job: Job) -> String { max(today, job.startDay) }
    private func sessionDay(_ session: WorkSession) -> String { max(today, session.day) }
    private var agendaDays: [String] { Array(Set(visibleJobs.map(jobDay) + visibleSessions.map(sessionDay))).sorted() }
    private var attention: [Job] {
        let dismissed = Set(dismissedAttention.split(separator: "\n").map(String.init))
        let soon = Day.string(from: Date().addingTimeInterval(14 * 86400))
        return jobs.filter { job in
            guard job.bookingStatus != "cancelled", job.bookingStatus != "completed", filter.includes(job, query: query), !dismissed.contains(attentionKey(job)) else { return false }
            return job.endDay < today || (job.startDay <= soon && (job.activeSessions.isEmpty || job.activeSessions.contains { $0.scheduleStatus != "confirmed" }))
        }
    }
    private func attentionKey(_ job: Job) -> String { "\(job.id?.uuidString ?? "")/\(job.startDay)/\(job.bookingStatus)/\(job.endDay < today ? "past" : "schedule")" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                let headerLayout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12)) : AnyLayout(HStackLayout())
                headerLayout {
                    if selectedJob == nil { BrandLockup() }
                    else { Text(upcomingOnly ? "Upcoming" : "Jobs").font(.largeTitle.bold()) }
                    if !typeSize.isAccessibilitySize { Spacer() }
                    Button { showingAdd = true } label: { Label("Add Job", systemImage: "plus") }
                        .buttonStyle(DaybookPrimaryButton()).accessibilityIdentifier("add-job")
                }
                if selectedJob == nil { DaybookPageHeading(title: upcomingOnly ? "Upcoming" : "Jobs", subtitle: upcomingOnly ? "Your next gigs, all in one place." : "") }
                HStack(spacing: 12) {
                    HStack {
                        Image(systemName: "magnifyingglass").foregroundStyle(Color("SecondaryText"))
                        DaybookTextField("Search jobs", text: $query).accessibilityIdentifier("search-jobs")
                    }.padding(12).background(.primary.opacity(0.055), in: RoundedRectangle(cornerRadius: 10))
                    Button { showingFilters = true } label: {
                        Image(systemName: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle").font(.title2).frame(width: 44, height: 44)
                    }.buttonStyle(.glass).buttonBorderShape(.circle).accessibilityLabel("Filter Jobs").accessibilityIdentifier("filter-jobs")
                }
                if upcomingOnly {
                    Text(Date().formatted(.dateTime.month(.wide).year())).font(.title3.weight(.semibold))
                    Picker("Show upcoming", selection: $thisWeek) {
                        Text("This week").tag(true); Text("All upcoming").tag(false)
                    }.pickerStyle(.menu).accessibilityIdentifier("upcoming-scope")
                } else {
                    Picker("Job status", selection: $jobScope) {
                        ForEach(["Upcoming", "Completed", "Cancelled"], id: \.self) { Text($0).tag($0) }
                    }.pickerStyle(.segmented)
                }
                if visibleJobs.isEmpty {
                    ContentUnavailableView {
                        Label(query.isEmpty && !filter.isActive ? "Room for your next gig" : "No matching jobs", systemImage: "calendar")
                    } description: {
                        Text(jobs.isEmpty && persistence.awaitingInitialImport ? "Existing jobs may still arrive from iCloud. You can add a job now; it will be saved on this device." : "Start with a name and dates. Add the details as they arrive.")
                    } actions: {
                        if filter.isActive { Button("Clear Filters") { filter = JobFilter() } }
                    }
                }
                LazyVStack(spacing: 0) {
                    ForEach(visibleJobs, id: \.objectID) { job in
                        jobRow(job)
                        Divider()
                    }
                }
                if upcomingOnly && !attention.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            Label("Needs attention", systemImage: "exclamationmark.circle").font(.headline)
                            Spacer()
                            Button {
                                dismissedAttention = Set(dismissedAttention.split(separator: "\n").map(String.init) + attention.map(attentionKey)).sorted().joined(separator: "\n")
                            } label: { Image(systemName: "xmark").frame(width: 32, height: 32) }.accessibilityLabel("Dismiss current attention items")
                        }
                        ForEach(Array(attention.prefix(3)), id: \.objectID) { job in
                            NavigationLink { JobDetailView(job: job) } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(job.endDay < today ? "Ready to mark complete?" : "Schedule needed for \(job.name)").font(.subheadline.weight(.semibold))
                                    Text("\(job.name) · Review job ›").font(.subheadline)
                                }.frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.padding(16).foregroundStyle(Color("AmberText"))
                        .background(.orange.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                }
            }.padding(20).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }
        .daybookSurface()
        .safeAreaInset(edge: .top, spacing: 0) { SyncFeedbackView() }
        .toolbar(selectedJob == nil ? .hidden : .visible, for: .navigationBar)
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $showingAdd) { JobEditorView() }
        .sheet(isPresented: $showingFilters) { JobFiltersView(filter: $filter) }
        .onChange(of: scenePhase) { _, phase in if phase == .active { today = Day.string(from: Date()) } }
        .onChange(of: filter.status) { _, status in
            guard !upcomingOnly, !status.isEmpty else { return }
            jobScope = status == "completed" ? "Completed" : status == "cancelled" ? "Cancelled" : "Upcoming"
        }
        .onChange(of: jobScope) { _, scope in
            if (scope == "Completed" && filter.status != "completed") || (scope == "Cancelled" && filter.status != "cancelled") || (scope == "Upcoming" && ["completed", "cancelled"].contains(filter.status)) { filter.status = "" }
        }
        .onAppear { if selectedJob?.wrappedValue == nil { selectedJob?.wrappedValue = visibleJobs.first } }
    }
    @ViewBuilder private func jobRow(_ job: Job) -> some View {
        if let selectedJob {
            Button { selectedJob.wrappedValue = job } label: { rowContent(job) }
                .buttonStyle(.plain)
                .background(selectedJob.wrappedValue == job ? Color.accentColor.opacity(0.08) : .clear, in: RoundedRectangle(cornerRadius: 10))
        } else {
            NavigationLink { JobDetailView(job: job) } label: { rowContent(job) }.buttonStyle(.plain)
        }
    }
    private func rowContent(_ job: Job) -> some View {
        HStack(alignment: .top, spacing: 14) {
            DaybookDateRail(day: job.startDay)
            Rectangle().fill(.primary.opacity(0.12)).frame(width: 1)
            VStack(alignment: .leading, spacing: 9) {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top) { Text(job.name).font(.headline); Spacer(minLength: 4); BookingBadge(status: job.bookingStatus) }
                    VStack(alignment: .leading, spacing: 6) { Text(job.name).font(.headline); BookingBadge(status: job.bookingStatus) }
                }
                Text(([job.client?.name] + job.roleNames.map { Optional($0) }).compactMap { $0 }.joined(separator: " · ")).font(.subheadline).foregroundStyle(Color("SecondaryText"))
                if job.project != nil || job.series != nil {
                    Text([job.project?.name, job.series?.name].compactMap { $0 }.joined(separator: " · ")).font(.caption).foregroundStyle(Color("SecondaryText"))
                }
                if upcomingOnly {
                    if let session = job.activeSessions.first(where: { $0.scheduleStatus == "confirmed" && ($0.endTime ?? .distantPast) >= Date() }) {
                        DaybookMetadata(symbol: "clock", text: session.compactSchedule)
                        Text("\(session.scheduleStatus.capitalized) · \(session.coverage == "notCovering" ? "Not covering" : session.coverage.capitalized)").font(.caption).foregroundStyle(Color("SecondaryText"))
                        if let call = session.callTime { DaybookMetadata(symbol: "video", text: "Call \(session.shortTime(call))") }
                        if job.activeSessions.count > 1 { Text("\(job.activeSessions.count) sessions · View schedule").font(.caption).foregroundStyle(Color("SecondaryText")) }
                    } else {
                        DaybookMetadata(symbol: "calendar", text: job.startDay == job.endDay ? "All day" : "Dates held · \(dateRange(job))")
                        Text("Schedule to come").font(.caption).foregroundStyle(Color("SecondaryText"))
                    }
                } else {
                    Text(job.feeSummary).font(.subheadline).monospacedDigit()
                    Text(job.billingSummary(in: context)).font(.caption).foregroundStyle(Color("SecondaryText"))
                }
            }
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary).padding(.top, 8)
        }.fixedSize(horizontal: false, vertical: true).padding(.vertical, 20).padding(.horizontal, 4).contentShape(Rectangle())
    }

}

func dateRange(_ job: Job) -> String {
    guard let start = Day.date(from: job.startDay), let end = Day.date(from: job.endDay) else {
        return "Dates not available"
    }
    if job.startDay == job.endDay { return start.formatted(date: .abbreviated, time: .omitted) }
    return "\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))"
}

struct SettingsView: View {
    @AppStorage("defaultCurrency") private var defaultCurrency = "USD"
    @EnvironmentObject private var persistence: PersistenceController
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        DaybookForm(title: "Settings") {
            Section("Preferences") { DaybookPicker("Currency", selection: $defaultCurrency) { Text("USD").tag("USD"); Text("EUR").tag("EUR") } }
            Section("Integrations") { DaybookLink { CalendarSettingsView() } label: { Label("Calendar", systemImage: "calendar").frame(maxWidth: .infinity, alignment: .leading) } }
            Section("Libraries") {
                NavigationLink { LibraryView(kind: .project) } label: { HStack { Label("Projects", systemImage: "folder"); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) } }
                NavigationLink { LibraryView(kind: .series) } label: { HStack { Label("Series", systemImage: "rectangle.stack"); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) } }
                NavigationLink { LibraryView(kind: .client) } label: { HStack { Label("Clients", systemImage: "person.2"); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) } }
                NavigationLink { LibraryView(kind: .role) } label: { HStack { Label("Roles", systemImage: "person.text.rectangle"); Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary) } }
            }
            Section {
                LabeledContent("On this device", value: "Saved locally")
                LabeledContent("iCloud account", value: persistence.accountStatus)
                if let setupStatus = persistence.schemaInitializationStatus {
                    Text(setupStatus)
                }
                Text(persistence.transferStatus).foregroundStyle(Color("SecondaryText"))
                if let detail = persistence.syncActivity.errorDetails { Text(detail).font(.subheadline) }
                if let date = persistence.lastTransfer {
                    LabeledContent("Last operation", value: date.formatted(date: .abbreviated, time: .shortened))
                }
                Button("Check iCloud Account") { Task { await persistence.refreshAccountStatus() } }
            } header: {
                Text("Storage & iCloud")
            } footer: {
                Text("Jobs are saved on this device first. iCloud transfers changes when available. A completed operation does not confirm that every device has received the latest changes. Sync is not a backup.")
            }
            Section("About") {
                LabeledContent("Version", value: "\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—") (\(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"))")
                Text("Personal beta").foregroundStyle(Color("SecondaryText"))
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .task { await persistence.refreshAccountStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await persistence.refreshAccountStatus() } }
        }
    }
}

struct SyncFeedbackView: View {
    @EnvironmentObject private var persistence: PersistenceController
    var body: some View {
        if let message = persistence.syncActivity.message {
            NavigationLink { SettingsView() } label: {
                HStack(spacing: 10) {
                    if persistence.syncActivity.isBusy { ProgressView().controlSize(.small) }
                    else { Image(systemName: persistence.syncActivity.needsAttention ? "icloud.slash" : "icloud") }
                    Text(message).font(.subheadline).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right").font(.caption)
                }
                .foregroundStyle(.primary)
                .padding(.horizontal).padding(.vertical, 12)
                .frame(minHeight: 44)
                .background(Color("PageBackground"))
            }
            .accessibilityIdentifier("sync-feedback")
            .accessibilityHint("Opens storage and iCloud details")
        }
    }
}
