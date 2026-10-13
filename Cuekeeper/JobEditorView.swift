import CoreData
import SwiftUI

struct JobEditorView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Client.name, ascending: true)]) private var clients: FetchedResults<Client>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \WorkRole.name, ascending: true)]) private var roles: FetchedResults<WorkRole>
    private let job: Job?
    private let duplicating: Bool
    @State private var initial: JobDraft
    @State private var draft: JobDraft
    @State private var newRole = ""
    @State private var error: String?
    @State private var discard = false
    @State private var datesChosen = false
    @FocusState private var nameFocused: Bool

    init(job: Job? = nil, duplicating: Bool = false) {
        self.job = job
        self.duplicating = duplicating
        let value = job.map { duplicating ? JobDraft.duplicate($0) : JobDraft(job: $0) } ?? JobDraft()
        _initial = State(initialValue: value)
        _draft = State(initialValue: value)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Job name", text: $draft.name).focused($nameFocused).accessibilityIdentifier("job-name")
                        .submitLabel(.done).onSubmit { nameFocused = false }
                    DatePicker("Start", selection: $draft.startDate, displayedComponents: .date)
                    DatePicker("End", selection: $draft.endDate, in: draft.startDate..., displayedComponents: .date)
                    if duplicating {
                        Toggle("Use these dates for the new job", isOn: $datesChosen)
                            .accessibilityIdentifier("confirm-duplicate-dates")
                    }
                } footer: {
                    Text(duplicating ? "Choose dates for the new engagement. It starts tentative, without the original notes." : "A name and dates are all you need. Add details whenever they arrive.")
                }
                Section("Booking") {
                    Picker("Status", selection: $draft.bookingStatus) {
                        ForEach(BookingStatus.allCases, id: \.self) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("edit-booking-status")
                }
                Section("Client") {
                    if !clients.isEmpty {
                        Picker("Reuse client", selection: $draft.clientName) {
                            Text("No client").tag("")
                            ForEach(Array(Set(clients.map(\.name))).sorted(), id: \.self) { Text($0).tag($0) }
                            if !draft.clientName.isEmpty && !clients.contains(where: { $0.name == draft.clientName }) {
                                Text(draft.clientName).tag(draft.clientName)
                            }
                        }
                    }
                    TextField("Client name (optional)", text: $draft.clientName).accessibilityIdentifier("job-client")
                }
                Section {
                    ForEach(Array(Set(roles.map(\.name)).union(draft.roleNames)).sorted(), id: \.self) { role in
                        Toggle(role, isOn: Binding(get: { draft.roleNames.contains(role) }, set: { selected in
                            if selected { draft.roleNames.insert(role) } else { draft.roleNames.remove(role) }
                        }))
                    }
                    HStack {
                        TextField("New role", text: $newRole).accessibilityIdentifier("new-role")
                            .onSubmit(addRole)
                        Button("Add", action: addRole)
                            .disabled(newRole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                            .accessibilityLabel("Add role")
                    }
                } header: { Text("Roles") } footer: { Text("Clients and roles are saved for reuse when you save the job.") }
                Section {
                    if draft.fee != nil {
                        DisclosureGroup("Optional fee") {
                            FeeFields(draft: Binding(get: { draft.fee ?? FeeDraft() }, set: { draft.fee = $0 }))
                        }
                    } else { Text("This fee needs review. Resolve it from the job’s Fee screen.").foregroundStyle(.secondary) }
                }
                Section("Where you’ll work") {
                    Picker("Arrangement", selection: $draft.workArrangement) {
                        ForEach(WorkArrangement.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    TextField("Location (optional)", text: $draft.location).accessibilityIdentifier("job-location")
                    NavigationLink {
                        TimeZonePicker(selection: $draft.timeZoneID)
                    } label: {
                        LabeledContent("Timezone", value: draft.timeZoneID.isEmpty ? "Unspecified" : draft.timeZoneID.replacingOccurrences(of: "_", with: " "))
                    }
                }
                Section("Notes") {
                    TextField("Preparation, travel, or other details", text: $draft.notes, axis: .vertical)
                        .lineLimit(4...12).accessibilityIdentifier("job-notes")
                }
            }
            .navigationTitle(duplicating ? "Duplicate Job" : job == nil ? "Add Job" : "Edit Job")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if draft != initial || !newRole.isEmpty { discard = true } else { dismiss() } }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        addRole()
                        do {
                            try draft.save(in: context, editing: duplicating ? nil : job?.objectID, baseline: job != nil && !duplicating ? initial : nil)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }
                    .disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (duplicating && !datesChosen))
                    .accessibilityIdentifier("save-job")
                }
            }
            .saveErrorAlert($error)
            .interactiveDismissDisabled(draft != initial || !newRole.isEmpty)
            .confirmationDialog("Discard changes?", isPresented: $discard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .onChange(of: draft.clientName) { _, name in
                if job == nil, draft.fee?.amount.isEmpty == true, let client = clients.first(where: { $0.name == name }) { draft.fee?.currency = client.defaultCurrency }
            }
            .onChange(of: draft.startDate) { _, start in if draft.endDate < start { draft.endDate = start } }
            .task { if job == nil { nameFocused = true } }
        }
    }

    private func addRole() {
        let name = newRole.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty {
            let canonical = roles.first { $0.name.compare(name, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }?.name ?? name
            draft.roleNames.insert(canonical)
        }
        newRole = ""
    }
}

struct TimeZonePicker: View {
    @Binding var selection: String
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        List {
            Button("Unspecified") { selection = ""; dismiss() }
            ForEach(TimeZone.knownTimeZoneIdentifiers.filter { search.isEmpty || $0.replacingOccurrences(of: "_", with: " ").localizedCaseInsensitiveContains(search) }, id: \.self) { zone in
                Button { selection = zone; dismiss() } label: {
                    HStack {
                        Text(zone.replacingOccurrences(of: "_", with: " ")).foregroundStyle(.primary)
                        Spacer()
                        if selection == zone { Image(systemName: "checkmark") }
                    }
                }
            }
        }.searchable(text: $search, prompt: "Search city or region").navigationTitle("Timezone")
    }
}

struct JobDetailView: View {
    @EnvironmentObject private var calendar: CalendarController
    @ObservedObject var job: Job
    @State private var editing = false
    @State private var duplicating = false
    @State private var addingSession = false
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
            Section("People & place") {
                if let client = job.client {
                    NavigationLink { LibraryDetailView(record: client, kind: .client) } label: {
                        LabeledContent("Client", value: client.name)
                    }
                } else { LabeledContent("Client", value: "Not added") }
                LabeledContent("Roles", value: job.roleNames.isEmpty ? "Not added" : job.roleNames.joined(separator: ", "))
                LabeledContent("Arrangement", value: WorkArrangement(rawValue: job.workArrangement)?.title ?? "Unspecified")
                if !job.location.isEmpty { LabeledContent("Location", value: job.location) }
                if !job.timeZoneID.isEmpty { LabeledContent("Timezone", value: job.timeZoneID.replacingOccurrences(of: "_", with: " ")) }
            }
            if !job.notes.isEmpty { Section("Notes") { Text(job.notes).textSelection(.enabled) } }
            Section("Fee") { NavigationLink { FeeDetailView(job: job) } label: { LabeledContent("Overall fee", value: job.feeSummary) }.accessibilityIdentifier("job-fee") }
            SessionsSection(job: job) { addingSession = true }
            Section("Calendar") {
                Text(job.bookingStatus == "cancelled" ? "Cancelled jobs have no calendar entries." : "The all-day placeholder stays alongside confirmed sessions you’re covering.")
                Text(calendar.status).font(.subheadline).foregroundStyle(.secondary)
            }
            Section {
                Button("Duplicate Job", systemImage: "plus.square.on.square") { duplicating = true }
                    .accessibilityIdentifier("duplicate-job")
            } footer: { Text("Reuse the client, roles and location with new dates. The original job stays in your history.") }
        }
        .navigationTitle(job.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Edit") { editing = true }.accessibilityIdentifier("edit-job") }
        .sheet(isPresented: $editing) { JobEditorView(job: job) }
        .sheet(isPresented: $duplicating) { JobEditorView(job: job, duplicating: true) }
        .sheet(isPresented: $addingSession) { SessionEditorView(job: job) }
    }
}

struct JobFiltersView: View {
    @Binding var filter: JobFilter
    @Environment(\.dismiss) private var dismiss
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Client.name, ascending: true)]) private var clients: FetchedResults<Client>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \WorkRole.name, ascending: true)]) private var roles: FetchedResults<WorkRole>
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Booking status", selection: $filter.status) {
                        Text("Any status").tag("")
                        ForEach(BookingStatus.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                    Picker("Client", selection: $filter.client) {
                        Text("Any client").tag("")
                        ForEach(Array(Set(clients.map(\.name))).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    Picker("Role", selection: $filter.role) {
                        Text("Any role").tag("")
                        ForEach(Array(Set(roles.map(\.name))).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                }
                Section {
                    Toggle("Limit date range", isOn: $filter.usesDates)
                    if filter.usesDates {
                        DatePicker("From", selection: $filter.start, displayedComponents: .date)
                        DatePicker("Through", selection: $filter.end, in: filter.start..., displayedComponents: .date)
                    }
                } footer: { Text("Includes jobs that overlap these dates. Upcoming always excludes completed and cancelled jobs.") }
                Button("Clear Filters") { filter = JobFilter() }.disabled(!filter.isActive)
            }.navigationTitle("Filter Jobs").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Done") { dismiss() } }
                .onChange(of: filter.start) { _, start in if filter.end < start { filter.end = start } }
        }
    }
}

/// Shared by both editors so a failed save is visible even when a long form is scrolled.
extension View {
    func saveErrorAlert(_ error: Binding<String?>) -> some View {
        alert("Couldn’t save changes", isPresented: Binding(
            get: { error.wrappedValue != nil },
            set: { if !$0 { error.wrappedValue = nil } }
        )) {
            Button("OK", role: .cancel) { error.wrappedValue = nil }
        } message: {
            Text(error.wrappedValue ?? "Please try again.")
        }
    }
}
