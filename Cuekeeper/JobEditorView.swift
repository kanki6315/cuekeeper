import CoreData
import SwiftUI

struct JobEditorView: View {
    var job: Job? = nil
    var duplicating = false
    var body: some View {
        if let job { ExistingJobEditorView(job: job, duplicating: duplicating) }
        else { EventWizardView() }
    }
}

struct ExistingJobEditorView: View {
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
    @State private var multipleDays: Bool
    @State private var moreDetails: Bool
    @FocusState private var nameFocused: Bool

    init(job: Job? = nil, duplicating: Bool = false) {
        self.job = job
        self.duplicating = duplicating
        let value = job.map { duplicating ? JobDraft.duplicate($0) : JobDraft(job: $0) } ?? JobDraft()
        _moreDetails = State(initialValue: job != nil)
        _multipleDays = State(initialValue: Day.string(from: value.startDate) != Day.string(from: value.endDate))
        _initial = State(initialValue: value)
        _draft = State(initialValue: value)
    }

    var body: some View {
        NavigationStack {
            DaybookForm {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Title").font(.caption).foregroundStyle(Color("SecondaryText"))
                        DaybookTextField("Title", text: $draft.name).focused($nameFocused).accessibilityIdentifier("job-name")
                            .submitLabel(.done).onSubmit { nameFocused = false }
                    }
                    Toggle("Multiple days", isOn: $multipleDays).accessibilityIdentifier("job-multiple-days")
                    DatePicker(multipleDays ? "Start" : "Date", selection: $draft.startDate, displayedComponents: .date)
                    if multipleDays {
                        DatePicker("End", selection: $draft.endDate, in: draft.startDate..., displayedComponents: .date)
                            .accessibilityIdentifier("job-end-date")
                    }
                    if duplicating {
                        Toggle("Use these dates for the new job", isOn: $datesChosen)
                            .accessibilityIdentifier("confirm-duplicate-dates")
                    }
                } footer: {
                    Text(duplicating ? "Choose dates for the new engagement. It starts tentative, without the original notes." : "A name and dates are all you need. Add details whenever they arrive.")
                }
                Section {
                    Button { moreDetails.toggle(); nameFocused = false } label: {
                        HStack { Label(moreDetails ? "Fewer details" : "Add more details", systemImage: "slider.horizontal.3"); Spacer(); Image(systemName: moreDetails ? "chevron.up" : "chevron.down").font(.caption) }
                    }.accessibilityIdentifier("job-more-details")
                }
                if moreDetails {
                Section {
                    NamedLibraryField(kind: .project, name: $draft.projectName)
                    SeriesSelectionFields(names: $draft.seriesNames)
                } header: { Text("Project & series") } footer: {
                    Text("Sessions can choose a championship separately.")
                }
                Section("Booking") {
                    DaybookPicker("Status", selection: $draft.bookingStatus, identifier: "edit-booking-status") {
                        ForEach(BookingStatus.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
                Section("Client") {
                    if !clients.isEmpty {
                        DaybookPicker("Reuse client", selection: $draft.clientName) {
                            Text("No client").tag("")
                            ForEach(Array(Set(clients.map(\.name))).sorted(), id: \.self) { Text($0).tag($0) }
                            if !draft.clientName.isEmpty && !clients.contains(where: { $0.name == draft.clientName }) {
                                Text(draft.clientName).tag(draft.clientName)
                            }
                        }
                    }
                    DaybookTextField("Client name (optional)", text: $draft.clientName).accessibilityIdentifier("job-client")
                }
                Section {
                    ForEach(Array(Set(roles.map(\.name)).union(draft.roleNames)).sorted(), id: \.self) { role in
                        Toggle(role, isOn: Binding(get: { draft.roleNames.contains(role) }, set: { selected in
                            if selected { draft.roleNames.insert(role) } else { draft.roleNames.remove(role) }
                        }))
                    }
                    HStack {
                        DaybookTextField("New role", text: $newRole).accessibilityIdentifier("new-role")
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
                    } else { Text("This fee needs review. Resolve it from the job’s Fee screen.").foregroundStyle(Color("SecondaryText")) }
                }
                Section("Where you’ll work") {
                    DaybookPicker("Arrangement", selection: $draft.workArrangement) {
                        ForEach(WorkArrangement.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    DaybookTextField("Location (optional)", text: $draft.location).accessibilityIdentifier("job-location")
                    DaybookLink {
                        TimeZonePicker(selection: $draft.timeZoneID, date: draft.startDate)
                    } label: {
                        LabeledContent("Timezone", value: zoneLabel(draft.timeZoneID, date: draft.startDate))
                    }
                }
                Section("Notes") {
                    DaybookTextField("Preparation, travel, or other details", text: $draft.notes, axis: .vertical)
                        .lineLimit(4...12).accessibilityIdentifier("job-notes")
                }
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
            .onChange(of: draft.startDate) { _, start in if !multipleDays || draft.endDate < start { draft.endDate = start } }
            .onChange(of: multipleDays) { _, enabled in if !enabled { draft.endDate = draft.startDate } }
            .task { if job == nil && !ProcessInfo.processInfo.arguments.contains("--design-fixtures") { nameFocused = true } }
        }
        .presentationSizing(.page)
        .presentationDetents([.large])
        .presentationBackground(Color("PageBackground"))
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
    var date = Date()
    @State private var search = ""
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        DaybookList {
            Button("Unspecified") { selection = ""; dismiss() }
            ForEach(TimeZone.knownTimeZoneIdentifiers.filter { search.isEmpty || zoneLabel($0, date: date).localizedCaseInsensitiveContains(search) || $0.localizedCaseInsensitiveContains(search) }, id: \.self) { zone in
                Button { selection = zone; dismiss() } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(zoneLabel(zone, date: date)).foregroundStyle(.primary)
                            Text(zone).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        if selection == zone { Image(systemName: "checkmark").accessibilityLabel("Selected") }
                    }
                }
            }
        }.searchable(text: $search, prompt: "Search timezones").navigationTitle("Timezone").navigationBarTitleDisplayMode(.inline)
    }
}

private struct LinkPresentation: Identifiable { let id = UUID(); let session: WorkSession? }

struct JobDetailView: View {
    @EnvironmentObject private var calendar: CalendarController
    @ObservedObject var job: Job
    @Environment(\.managedObjectContext) private var context
    @State private var error: String?
    @State private var editing = false
    @State private var duplicating = false
    @State private var addingSession = false
    @State private var addingInvoice = false
    @State private var addingPayment = false
    @State private var choosingLinkSession = false
    @State private var linkEditor: LinkPresentation?
    var body: some View {
        DaybookForm(title: job.name) {
            Section {
                BookingBadge(status: job.bookingStatus)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Booking status")
                    .accessibilityValue(job.bookingStatus.capitalized)
                    .accessibilityIdentifier("booking-status")
                DaybookMetadata(symbol: "calendar", text: dateRange(job))
                if let client = job.client {
                    DaybookLink { LibraryDetailView(record: client, kind: .client) } label: { DaybookMetadata(symbol: "person", text: client.name) }
                }
                DaybookMetadata(symbol: job.workArrangement == "remote" ? "video" : "mappin.and.ellipse", text: (job.roleNames + [WorkArrangement(rawValue: job.workArrangement)?.title ?? "Unspecified"]).joined(separator: " · "))
                if !job.location.isEmpty { DaybookMetadata(symbol: "mappin", text: job.location) }
                if !job.timeZoneID.isEmpty { DaybookMetadata(symbol: "globe", text: job.timeZoneID.replacingOccurrences(of: "_", with: " ")) }
            }.containerValue(\.daybookUnframed, true)
            SessionsSection(job: job) { addingSession = true }
            Section("Broadcast links") {
                ForEach(job.activeSessions.filter { !$0.sortedLinks.isEmpty }, id: \.objectID) { session in
                    DisclosureGroup(session.title) {
                        ForEach(session.sortedLinks, id: \.objectID) { link in
                            if let url = LinkDraft(url: link.url).validURL {
                                Link(link.label.isEmpty ? link.url : link.label, destination: url)
                                if !link.notes.isEmpty { Text(link.notes).font(.subheadline).foregroundStyle(Color("SecondaryText")) }
                            }
                        }
                    }
                }
                Button("Add Broadcast Link", systemImage: "link.badge.plus") {
                    if job.activeSessions.isEmpty { linkEditor = LinkPresentation(session: nil) } else { choosingLinkSession = true }
                }.buttonStyle(DaybookSecondaryButton()).accessibilityIdentifier("job-add-link")
            }
            Section("Fee") {
                DaybookLink { FeeDetailView(job: job) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("Overall fee"); Spacer(); Text(job.feeSummary).fontWeight(.semibold).monospacedDigit() }
                        Text("View fee & breakdown").font(.subheadline)
                    }
                }.accessibilityIdentifier("job-fee")
            }
            JobBillingSection(job: job, onInvoice: { addingInvoice = true }, onPayment: { addingPayment = true })
            if !job.notes.isEmpty { Section("Notes") { Text(job.notes).textSelection(.enabled) } }
            if job.project != nil || !job.allSeries.isEmpty {
                Section("Project & series") {
                    if let project = job.project {
                        DaybookLink { LibraryDetailView(record: project, kind: .project) } label: { LabeledContent("Project", value: project.name) }.accessibilityIdentifier("job-project-link")
                    }
                    ForEach(job.allSeries.sorted { $0.name < $1.name }, id: \.objectID) { series in
                        DaybookLink { LibraryDetailView(record: series, kind: .series) } label: { LabeledContent("Series", value: series.name) }
                    }
                }
            }
            Section("Calendar") {
                Text(job.bookingStatus == "cancelled" ? "Cancelled jobs have no calendar entries." : "The all-day placeholder stays alongside confirmed sessions you’re covering.")
                Text(calendar.status).font(.subheadline).foregroundStyle(Color("SecondaryText"))
            }
            Section {
                Button("Duplicate Job", systemImage: "plus.square.on.square") { duplicating = true }
                    .accessibilityIdentifier("duplicate-job")
            } footer: { Text("Reuse the project, series, client, roles and location with new dates. The original job stays in your history.") }
        }
        .safeAreaBar(edge: .bottom) {
            HStack {
                if job.bookingStatus != "completed" && job.bookingStatus != "cancelled" {
                    Button {
                        updateBookingStatus(job.bookingStatus == "tentative" ? .booked : .completed)
                    } label: {
                        Label(job.bookingStatus == "tentative" ? "Mark as booked" : "Mark completed", systemImage: "checkmark")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(DaybookPrimaryButton())
                        .accessibilityIdentifier("advance-booking-status")
                }
                Menu("More", systemImage: "ellipsis") {
                    Section("Booking status") {
                        ForEach(BookingStatus.allCases.filter { $0.rawValue != job.bookingStatus }, id: \.self) { status in
                            Button("Mark as \(status.title.lowercased())") { updateBookingStatus(status) }
                        }
                    }
                    Button("Duplicate Job", systemImage: "plus.square.on.square") { duplicating = true }
                    Button("Edit Job", systemImage: "pencil") { editing = true }
                }.labelStyle(.iconOnly).buttonStyle(.glass).buttonBorderShape(.circle)
                    .controlSize(.large).accessibilityLabel("More job actions")
            }.padding(.horizontal, 20).padding(.vertical, 10)
        }
        .saveErrorAlert($error)
        .navigationTitle("Job details")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Edit") { editing = true }.accessibilityIdentifier("edit-job") }
        .sheet(isPresented: $editing) { JobEditorView(job: job) }
        .sheet(isPresented: $duplicating) { JobEditorView(job: job, duplicating: true) }
        .sheet(isPresented: $addingSession) { SessionEditorView(job: job) }
        .sheet(isPresented: $addingInvoice) { InvoiceEditorView(job: job) }
         .sheet(isPresented: $addingPayment) { PaymentEditorView(job: job) }
        .sheet(item: $linkEditor) { BroadcastLinkEditorView(job: job, session: $0.session) }
        .confirmationDialog("Choose a session for this link", isPresented: $choosingLinkSession, titleVisibility: .visible) {
            ForEach(job.activeSessions, id: \.objectID) { session in
                Button(session.title) { linkEditor = LinkPresentation(session: session) }
            }
            Button("New Session") { linkEditor = LinkPresentation(session: nil) }
        }
    }

    private func updateBookingStatus(_ status: BookingStatus) {
        let baseline = JobDraft(job: job)
        var draft = baseline
        draft.bookingStatus = status
        do { try draft.save(in: context, editing: job.objectID, baseline: baseline) }
        catch { self.error = error.localizedDescription }
    }
}

struct JobFiltersView: View {
    @Binding var filter: JobFilter
    @Environment(\.dismiss) private var dismiss
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Client.name, ascending: true)]) private var clients: FetchedResults<Client>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \WorkProject.name, ascending: true)]) private var projects: FetchedResults<WorkProject>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \WorkSeries.name, ascending: true)]) private var series: FetchedResults<WorkSeries>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \WorkRole.name, ascending: true)]) private var roles: FetchedResults<WorkRole>
    var body: some View {
        NavigationStack {
            DaybookForm {
                Section {
                    DaybookPicker("Booking status", selection: $filter.status) {
                        Text("Any status").tag("")
                        ForEach(BookingStatus.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }
                    DaybookPicker("Client", selection: $filter.client) {
                        Text("Any client").tag("")
                        ForEach(Array(Set(clients.map(\.name))).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    DaybookPicker("Project", selection: $filter.project) {
                        Text("Any project").tag("")
                        ForEach(Array(Set(projects.map(\.name))).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    DaybookPicker("Series", selection: $filter.series) {
                        Text("Any series").tag("")
                        ForEach(Array(Set(series.map(\.name))).sorted(), id: \.self) { Text($0).tag($0) }
                    }
                    DaybookPicker("Role", selection: $filter.role) {
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
