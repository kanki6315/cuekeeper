import CoreData
import SwiftUI

/// Compatibility entry point for existing navigation and fixture routes.
struct JobEditorView: View {
    var job: Job? = nil
    var duplicating = false
    var body: some View {
        if let job, !duplicating { EventEditorView(anchor: job, focusBooking: job.objectID) }
        else { EventWizardView(template: duplicating ? job : nil) }
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
        DaybookForm(title: job.client?.name ?? "Client to add", subtitle: job.eventTitle) {
            Section {
                Menu {
                    ForEach(BookingStatus.allCases, id: \.self) { status in Button(status.title) { updateBookingStatus(status) } }
                } label: { HStack { BookingBadge(status: job.bookingStatus); Text("Change status"); Spacer(); Image(systemName: "chevron.down") } }
                .accessibilityIdentifier("booking-status")
                if !["completed", "cancelled"].contains(job.bookingStatus) {
                    Button(job.bookingStatus == "tentative" ? "Mark as booked" : "Mark completed") { updateBookingStatus(job.bookingStatus == "tentative" ? .booked : .completed) }.accessibilityIdentifier("advance-booking-status")
                }
                DaybookLink { EventDetailView(anchor: job) } label: { DaybookMetadata(symbol: "calendar", text: dateRange(job)) }
                if let client = job.client {
                    DaybookLink { LibraryDetailView(record: client, kind: .client) } label: { DaybookMetadata(symbol: "person", text: client.name) }
                }
                DaybookMetadata(symbol: job.workArrangement == "remote" ? "video" : "mappin.and.ellipse", text: (job.roleNames + [WorkArrangement(rawValue: job.workArrangement)?.title ?? "Unspecified"]).joined(separator: " · "))
                if !job.eventLocation.isEmpty { DaybookMetadata(symbol: "mappin", text: job.eventLocation) }
                if !job.eventTimeZoneID.isEmpty { DaybookMetadata(symbol: "globe", text: job.eventTimeZoneID.replacingOccurrences(of: "_", with: " ")) }
            }.containerValue(\.daybookUnframed, true)
            if !job.eventTrackPlaceID.isEmpty {
                Section("Track location") { SavedTrackView(placeID: job.eventTrackPlaceID) }
            }
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
                    ForEach(Array(job.allSeries).sorted { $0.name < $1.name }, id: \.objectID) { series in
                        DaybookLink { LibraryDetailView(record: series, kind: .series) } label: { LabeledContent("Series", value: series.name) }
                    }
                }
            }
            Section("Calendar") {
                Text(job.bookingStatus == "cancelled" ? "Cancelled bookings have no timed entries. The event placeholder remains for other active clients." : "The all-day placeholder stays alongside confirmed sessions you’re covering.")
                Text(calendar.status).font(.subheadline).foregroundStyle(Color("SecondaryText"))
            }
            Section {
                Button("Duplicate Booking", systemImage: "plus.square.on.square") { duplicating = true }
                    .accessibilityIdentifier("duplicate-job")
            } footer: { Text("Create a new event with this client and fee. Existing sessions and payment history stay here.") }
        }
        .saveErrorAlert($error)
        .navigationTitle("Client booking")
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
                } footer: { Text("Includes events with matching client bookings in these dates. Upcoming excludes completed and cancelled bookings.") }
                Button("Clear Filters") { filter = JobFilter() }.disabled(!filter.isActive)
            }.navigationTitle("Filter Events").navigationBarTitleDisplayMode(.inline)
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
