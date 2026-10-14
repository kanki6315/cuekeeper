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
                        if let selectedJob { EventDetailView(anchor: selectedJob).id(selectedJob.objectID) }
                        else { ContentUnavailableView("Select an event", systemImage: "text.book.closed", description: Text("Your schedule, fees and payments, together.")).daybookSurface() }
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
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var persistence: PersistenceController
    let upcomingOnly: Bool
    var selectedJob: Binding<Job?>? = nil
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Job.startDay, ascending: true)]) private var jobs: FetchedResults<Job>
    @FetchRequest(sortDescriptors: []) private var events: FetchedResults<WorkEvent>
    @FetchRequest(sortDescriptors: []) private var sessions: FetchedResults<WorkSession>
    @State private var showingAdd = false
    @State private var showingFilters = false
    @State private var query = ""
    @State private var filter = JobFilter()
    @State private var scope = "All"
    @State private var thisWeek = false
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
                && (!upcomingOnly || !thisWeek || job.eventStartDay <= weekEnd)
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
                if selectedJob == nil { BrandLockup() }
                ViewThatFits(in: .horizontal) {
                    HStack { Text(upcomingOnly ? "Upcoming" : "Events").font(.largeTitle.bold()); Spacer(); addButton }
                    VStack(alignment: .leading, spacing: 12) { Text(upcomingOnly ? "Upcoming" : "Events").font(.largeTitle.bold()); addButton }
                }
                HStack {
                    DaybookTextField("Search events, clients or series", text: $query).accessibilityIdentifier("search-jobs")
                    Button { showingFilters = true } label: { Image(systemName: filter.isActive ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle").frame(width: 44, height: 44) }.accessibilityLabel("Filter Events").accessibilityIdentifier("filter-jobs")
                }
                if upcomingOnly {
                    Picker("Show upcoming", selection: $thisWeek) { Text("All upcoming").tag(false); Text("This week").tag(true) }.pickerStyle(.menu)
                } else {
                    Picker("Bookings", selection: $scope) { ForEach(["All", "Active", "Completed", "Cancelled"], id: \.self) { Text($0).tag($0) } }.pickerStyle(.menu)
                }
                if representatives.isEmpty {
                    ContentUnavailableView("No events to show", systemImage: "calendar", description: Text(jobs.isEmpty && persistence.awaitingInitialImport ? "Existing work may still arrive from iCloud. You can add an event now." : "Start with dates and a client. Add the schedule when it arrives."))
                    if filter.isActive { Button("Clear Filters") { filter = JobFilter() } }
                }
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
                if upcomingOnly && !attention.isEmpty {
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
            }.padding(20).frame(maxWidth: 850).frame(maxWidth: .infinity)
        }.daybookSurface()
            .safeAreaInset(edge: .top, spacing: 0) { SyncFeedbackView() }
            .navigationTitle("").navigationBarTitleDisplayMode(.inline)
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
                Text(job.eventSessions.isEmpty ? "Schedule to come" : "\(job.eventSessions.count) sessions").font(.caption).foregroundStyle(Color("SecondaryText"))
            }
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }.padding(.vertical, 20).contentShape(Rectangle())
    }
}

func dateRange(_ job: Job) -> String { job.eventDateDescription }

struct SettingsView: View {
    @AppStorage("defaultCurrency") private var defaultCurrency = "USD"
    @EnvironmentObject private var persistence: PersistenceController
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        DaybookForm(title: "Settings") {
            Section("Preferences") { DaybookPicker("Currency", selection: $defaultCurrency) { Text("USD").tag("USD"); Text("EUR").tag("EUR") } }
            Section("Integrations") { DaybookLink { CalendarSettingsView() } label: { Label("Calendar", systemImage: "calendar").frame(maxWidth: .infinity, alignment: .leading) } }
            Section("Libraries") {
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
                Text("Events are saved on this device first. iCloud transfers changes when available. A completed operation does not confirm that every device has received the latest changes. Sync is not a backup.")
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
