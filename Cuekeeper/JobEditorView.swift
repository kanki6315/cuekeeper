import CoreData
import SwiftUI

/// Compatibility entry point for existing navigation and fixture routes.
struct JobEditorView: View {
    var job: Job? = nil
    var duplicating = false
    var body: some View {
        if let job, !duplicating { EventEditorView(anchor: job) }
        else { EventWizardView(template: duplicating ? job : nil) }
    }
}

struct JobDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var job: Job
    @FetchRequest(sortDescriptors: []) private var eventRecords: FetchedResults<WorkEvent>
    @Environment(\.managedObjectContext) private var context
    @State private var error: String?
    @State private var editing = false
    @State private var confirmingDeletion = false
    @State private var duplicating = false
    @State private var batch = false
    @State private var addingSession = false
    @State private var addingInvoice = false
    @State private var addingPayment = false
    var body: some View {
        let _ = eventRecords.count
        DaybookForm(title: job.eventTitle, subtitle: job.client?.name ?? "Client to add") {
            Section {
                BookingStatusSegments(selection: Binding(
                    get: { BookingStatus(rawValue: job.bookingStatus) ?? .tentative },
                    set: { updateBookingStatus($0) }
                ), identifier: "booking-status")
                Button { editing = true } label: { DaybookMetadata(symbol: "calendar", text: dateRange(job)) }.accessibilityIdentifier("edit-event-dates")
                DaybookMetadata(symbol: "globe", text: "Event timezone: " + zoneLabel(TimeZone.effective(job.eventTimeZoneID).identifier, date: Day.date(from: job.eventStartDay) ?? Date()))
                if !job.eventLocation.isEmpty { DaybookMetadata(symbol: "mappin", text: job.eventLocation) }
            }.containerValue(\.daybookUnframed, true)
            SessionsSection(job: job) { addingSession = true }
            if !job.activeSessions.isEmpty {
                Section { Button("Edit Multiple Sessions", systemImage: "checklist") { batch = true }.accessibilityIdentifier("batch-sessions") }.containerValue(\.daybookUnframed, true)
            }
            if !job.eventTrackPlaceID.isEmpty {
                Section("Track location") { SavedTrackView(placeID: job.eventTrackPlaceID) }
            }
            EventWeatherSection(job: job)
            Section("Work") {
                if let client = job.client {
                    DaybookLink { LibraryDetailView(record: client, kind: .client) } label: { DaybookMetadata(symbol: "person", text: client.name) }
                }
                DaybookMetadata(symbol: job.workArrangement == "remote" ? "video" : "mappin.and.ellipse", text: (job.roleNames + [WorkArrangement(rawValue: job.workArrangement)?.title ?? "Unspecified"]).joined(separator: " · "))
                if job.hasWorkTimeZone {
                    let zone = zoneLabel(TimeZone.effective(job.workTimeZoneID).identifier, date: Day.date(from: job.eventStartDay) ?? Date())
                    DaybookMetadata(symbol: "globe", text: job.location.isEmpty ? "Your timezone: " + zone : "Working from \(job.location) · " + zone)
                }
                if !["completed", "cancelled"].contains(job.bookingStatus) {
                    Button(job.bookingStatus == "tentative" ? "Mark as booked" : "Mark completed") { updateBookingStatus(job.bookingStatus == "tentative" ? .booked : .completed) }.accessibilityIdentifier("advance-booking-status")
                }
            }
            Section("Fee") {
                DaybookLink { FeeDetailView(job: job) } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text("Overall fee"); Spacer(); Text(job.feeSummary).fontWeight(.semibold).monospacedDigit() }
                        Text("View fee & breakdown").font(.subheadline)
                    }
                }.accessibilityIdentifier("job-fee")
            }
            EventExpensesSection(job: job)
            JobBillingSection(job: job, onInvoice: { addingInvoice = true }, onPayment: { addingPayment = true })
            if !job.eventNotes.isEmpty { Section("Event notes") { Text(job.eventNotes).textSelection(.enabled) } }
            if !job.notes.isEmpty { Section("Previous booking notes") { Text(job.notes).textSelection(.enabled) } }
            if job.project != nil || !job.allSeries.isEmpty {
                Section("Project & series") {
                    if let project = job.project {
                        DaybookLink { LibraryDetailView(record: project, kind: .project) } label: { LabeledContent("Project", value: project.name) }.accessibilityIdentifier("job-project-link")
                    }
                    ForEach(Array(job.allSeries).sorted { $0.name < $1.name }, id: \.objectID) { series in
                        DaybookLink { LibraryDetailView(record: series, kind: .series) } label: { LabeledContent("Series", value: series.name) }
                    }
                }
            }
            Section {
                Button("Duplicate Event", systemImage: "plus.square.on.square") { duplicating = true }
                    .accessibilityIdentifier("duplicate-job")
            } footer: { Text("Create a new event with this client and fee. Existing sessions and payment history stay here.") }
            Section {
                Button("Delete Event", systemImage: "trash", role: .destructive) { confirmingDeletion = true }
                    .accessibilityIdentifier("delete-job")
                    .alert("Delete this event?", isPresented: $confirmingDeletion) {
                        Button("Delete Event", role: .destructive) {
                            do {
                                try Job.remove(job.objectID, in: context)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }
                        Button("Cancel", role: .cancel) {}
                    } message: {
                        Text("This removes the event and its sessions from your schedule and synced calendar. Existing invoices and payments are kept. You can restore the event from Settings → Recently Deleted for 30 days.")
                    }
            }
        }
        .saveErrorAlert($error)
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Edit Event") { editing = true }.accessibilityIdentifier("edit-event") }
        .sheet(isPresented: $editing) { JobEditorView(job: job) }
        .sheet(isPresented: $duplicating) { JobEditorView(job: job, duplicating: true) }
        .sheet(isPresented: $batch) { SessionBatchEditorView(anchor: job) }
        .sheet(isPresented: $addingSession) { SessionEditorView(job: job) }
        .sheet(isPresented: $addingInvoice) { InvoiceEditorView(job: job) }
         .sheet(isPresented: $addingPayment) { PaymentEditorView(job: job) }
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
    @State private var contentHeight: CGFloat = 360
    @State private var navigationHeight: CGFloat = 56
    @Environment(\.dismiss) private var dismiss
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Client.name, ascending: true)]) private var clients: FetchedResults<Client>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \WorkProject.name, ascending: true)]) private var projects: FetchedResults<WorkProject>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \WorkSeries.name, ascending: true)]) private var series: FetchedResults<WorkSeries>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \WorkRole.name, ascending: true)]) private var roles: FetchedResults<WorkRole>
    var body: some View {
        NavigationStack {
            DaybookForm(compact: true, onContentHeightChange: { contentHeight = $0 }) {
                Section {
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
                }
            }.navigationTitle("Filter Events").navigationBarTitleDisplayMode(.inline)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.safeAreaInsets.top
                } action: { height in
                    navigationHeight = height
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Reset") { filter = JobFilter() }
                            .disabled(!filter.isActive)
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        Button("Done") { dismiss() }
                    }
                }
                .onChange(of: filter.start) { _, start in if filter.end < start { filter.end = start } }
        }
        .presentationDetents([.height(contentHeight + navigationHeight), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color("PageBackground"))
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
