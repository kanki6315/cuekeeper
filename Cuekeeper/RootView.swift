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
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var selection: AppSection? = .upcoming

    var body: some View {
        if sizeClass == .regular {
            NavigationSplitView {
                List(AppSection.allCases, selection: $selection) { section in
                    Label(section.rawValue, systemImage: section.symbol)
                        .foregroundStyle(.primary)
                        .tag(section)
                }
                .navigationTitle("Cuekeeper")
            } detail: {
                NavigationStack { content(selection ?? .upcoming) }
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

    @ViewBuilder private func content(_ section: AppSection) -> some View {
        switch section {
        case .upcoming: JobsView(upcomingOnly: true)
        case .jobs: JobsView(upcomingOnly: false)
        case .payments:
            ContentUnavailableView("Payments are coming next", systemImage: "creditcard",
                description: Text("This first build saves your jobs. Fees, invoices and payment tracking will follow."))
                .navigationTitle("Payments")
        case .settings: SettingsView()
        }
    }
}

private struct JobsView: View {
    let upcomingOnly: Bool
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Job.startDay, ascending: true),
                                   NSSortDescriptor(keyPath: \Job.createdAt, ascending: true)])
    private var jobs: FetchedResults<Job>
    @State private var showingAdd = false
    @State private var query = ""
    @State private var filter = JobFilter()
    @State private var showingFilters = false
    @Environment(\.scenePhase) private var scenePhase
    @State private var today = Day.string(from: Date())
    private var visibleJobs: [Job] {
        jobs.filter {
            (!upcomingOnly || ($0.endDay >= today && $0.bookingStatus != "cancelled" && $0.bookingStatus != "completed"))
                && filter.includes($0, query: query)
        }
    }

    var body: some View {
        List {
            ForEach(visibleJobs, id: \.objectID) { job in
                NavigationLink {
                    JobDetailView(job: job)
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(job.name).font(.headline)
                        if let client = job.client { Text(client.name).font(.subheadline) }
                        Text(dateRange(job)).font(.subheadline).foregroundStyle(.secondary)
                        Text(job.bookingStatus.capitalized).font(.caption).foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(Color("PageBackground"))
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color("PageBackground"))
        .overlay {
            if visibleJobs.isEmpty {
                ContentUnavailableView {
                    Label((query.isEmpty && !filter.isActive) ? "Room for your next gig" : "No matching jobs", systemImage: "calendar")
                } description: {
                    Text((query.isEmpty && !filter.isActive) ? "Start with a name and dates. Add the details as they arrive." : "Try another name or client, or clear your filters.")
                } actions: {
                    if filter.isActive { Button("Clear Filters") { filter = JobFilter() } }
                    if query.isEmpty && !filter.isActive {
                        Button("Add Job", action: { showingAdd = true }).buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .navigationTitle(upcomingOnly ? "Upcoming" : "Jobs")
        .searchable(text: $query, prompt: "Search jobs or clients")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                Button(filter.isActive ? "Filters Applied" : "Filter Jobs", systemImage: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle") { showingFilters = true }
                    .accessibilityIdentifier("filter-jobs")
            }
            ToolbarItem(placement: .primaryAction) {
                Button("Add Job", systemImage: "plus") { showingAdd = true }
                    .accessibilityIdentifier("add-job")
            }
        }
        .sheet(isPresented: $showingAdd) { JobEditorView() }
        .sheet(isPresented: $showingFilters) { JobFiltersView(filter: $filter) }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { today = Day.string(from: Date()) }
        }
    }
}

func dateRange(_ job: Job) -> String {
    guard let start = Day.date(from: job.startDay), let end = Day.date(from: job.endDay) else {
        return "Dates not available"
    }
    if job.startDay == job.endDay { return start.formatted(date: .abbreviated, time: .omitted) }
    return "\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))"
}

private struct SettingsView: View {
    @EnvironmentObject private var persistence: PersistenceController
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Form {
            Section("People & roles") {
                NavigationLink("Clients") { LibraryView(kind: .client) }
                NavigationLink("Roles") { LibraryView(kind: .role) }
            }
            Section {
                LabeledContent("On this device", value: "Saved locally")
                LabeledContent("iCloud account", value: persistence.accountStatus)
                if let setupStatus = persistence.schemaInitializationStatus {
                    Text(setupStatus)
                }
                Text(persistence.transferStatus).foregroundStyle(.secondary)
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
                Text("Personal beta · Job management").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .task { await persistence.refreshAccountStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await persistence.refreshAccountStatus() } }
        }
    }
}
