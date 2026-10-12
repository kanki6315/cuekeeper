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
                    Label(section.rawValue, systemImage: section.symbol).tag(section)
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
    @Environment(\.scenePhase) private var scenePhase
    @State private var today = Day.string(from: Date())
    private var visibleJobs: [Job] {
        jobs.filter {
            (!upcomingOnly || ($0.endDay >= today && $0.bookingStatus != "cancelled" && $0.bookingStatus != "completed"))
                && (query.isEmpty || $0.name.localizedCaseInsensitiveContains(query))
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
                    Label(query.isEmpty ? "Room for your next gig" : "No matching jobs", systemImage: "calendar")
                } description: {
                    Text(query.isEmpty ? "Start with a name and dates. Add the details as they arrive." : "Try a different job name.")
                } actions: {
                    if query.isEmpty {
                        Button("Add Job", action: { showingAdd = true }).buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .navigationTitle(upcomingOnly ? "Upcoming" : "Jobs")
        .searchable(text: $query, prompt: "Search jobs")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Add Job", systemImage: "plus") { showingAdd = true }
                    .accessibilityIdentifier("add-job")
            }
        }
        .sheet(isPresented: $showingAdd) { AddJobView() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { today = Day.string(from: Date()) }
        }
    }
}

private func dateRange(_ job: Job) -> String {
    guard let start = Day.date(from: job.startDay), let end = Day.date(from: job.endDay) else {
        return "Dates not available"
    }
    if job.startDay == job.endDay { return start.formatted(date: .abbreviated, time: .omitted) }
    return "\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))"
}

private struct JobDetailView: View {
    @ObservedObject var job: Job
    var body: some View {
        Form {
            Section("Booking") {
                LabeledContent("Dates", value: dateRange(job))
                LabeledContent("Status", value: job.bookingStatus.capitalized)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Booking status")
                    .accessibilityValue(job.bookingStatus.capitalized)
                    .accessibilityIdentifier("booking-status")
            }
            Section {
                Text("These dates hold space for your job. Sessions, fees and calendar entries will be available in a later build.")
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(job.name)
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct AddJobView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var draft = JobDraft()
    @State private var error: String?
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Job name", text: $draft.name)
                        .focused($nameFocused).accessibilityIdentifier("job-name")
                    DatePicker("Start", selection: $draft.startDate, displayedComponents: .date)
                    DatePicker("End", selection: $draft.endDate, in: draft.startDate..., displayedComponents: .date)
                } footer: {
                    Text("That’s all you need for now. Your job starts as tentative.")
                }
                if let error { Section { Text(error).foregroundStyle(.red) } }
            }
            .navigationTitle("Add Job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try draft.save(in: context); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .accessibilityIdentifier("save-job")
                }
            }
            .onChange(of: draft.startDate) { _, start in
                if draft.endDate < start { draft.endDate = start }
            }
            .task { nameFocused = true }
        }
    }
}

private struct SettingsView: View {
    @EnvironmentObject private var persistence: PersistenceController
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        Form {
            Section {
                LabeledContent("On this device", value: "Saved locally")
                LabeledContent("iCloud account", value: persistence.accountStatus)
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
                Text("Personal beta · Job capture foundation").foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Settings")
        .task { await persistence.refreshAccountStatus() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await persistence.refreshAccountStatus() } }
        }
    }
}
