import CoreData
import SwiftUI

struct EventEditorView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    let anchor: Job?
    let onSave: ((NSManagedObjectID) -> Void)?
    @State private var draft: EventDraft
    @State private var initial: EventDraft
    @State private var booking = JobDraft()
    private let initialBooking: JobDraft
    @State private var multipleDays: Bool
    @State private var details = false
    @State private var choosingTrack = false
    @State private var discard = false
    @State private var error: String?
    init(anchor: Job? = nil, template: Job? = nil, onSave: ((NSManagedObjectID) -> Void)? = nil) {
        self.anchor = anchor; self.onSave = onSave
        let first = template.map(JobDraft.duplicate) ?? JobDraft()
        initialBooking = first; _booking = State(initialValue: first)
        var value = anchor.map(EventDraft.init(anchor:)) ?? EventDraft()
        if let template {
            value = EventDraft(anchor: template); value.startDate = Date(); value.endDate = value.startDate; value.notes = ""
        }
        _draft = State(initialValue: value); _initial = State(initialValue: value)
        _multipleDays = State(initialValue: Day.string(from: value.startDate) != Day.string(from: value.endDate))
    }
    private var changed: Bool { draft != initial || booking != initialBooking }
    var body: some View {
        NavigationStack {
            DaybookForm {
                Section("Dates") {
                    DatePicker(multipleDays ? "Start" : "Date", selection: $draft.startDate, displayedComponents: .date)
                    Toggle("Multiple days", isOn: $multipleDays).accessibilityIdentifier("job-multiple-days")
                    if multipleDays { DatePicker("End", selection: $draft.endDate, in: draft.startDate..., displayedComponents: .date).accessibilityIdentifier("job-end-date") }
                }
                if anchor == nil {
                    Section("First client booking") {
                        NamedLibraryField(kind: .client, name: $booking.clientName)
                        FeeFields(draft: Binding(get: { booking.fee ?? FeeDraft() }, set: { booking.fee = $0 }))
                    }
                }
                Section("Location") {
                    DaybookTextField("Location (optional)", text: $draft.location).accessibilityIdentifier("job-location")
                    if !draft.trackPlaceID.isEmpty { SavedTrackView(placeID: draft.trackPlaceID) }
                    Button(draft.trackPlaceID.isEmpty ? "Choose track location" : "Change track location", systemImage: "mappin.and.ellipse") { choosingTrack = true }.accessibilityIdentifier("choose-track")
                    if !draft.trackPlaceID.isEmpty { Button("Remove track location", role: .destructive) { draft.trackPlaceID = "" }.accessibilityIdentifier("remove-track") }
                    DaybookLink { TimeZonePicker(selection: $draft.timeZoneID, date: draft.startDate) } label: {
                        LabeledContent("Timezone", value: draft.timeZoneID.isEmpty ? "Choose timezone" : zoneLabel(draft.timeZoneID, date: draft.startDate))
                    }
                }
                Section {
                    DisclosureGroup("Title & notes", isExpanded: $details) {
                        DaybookTextField("Custom title (optional)", text: $draft.title).accessibilityIdentifier("event-title")
                        DaybookTextField("Shared event notes", text: $draft.notes, axis: .vertical).lineLimit(3...8)
                    }
                } footer: { Text("The event uses its location and dates as its title unless you add one. Sessions keep their own dates and times when you change event dates.") }
            }
            .navigationTitle(anchor == nil ? "Add Event" : "Edit Event").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if changed { discard = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            let id = try draft.save(in: context, anchorID: anchor?.objectID, baseline: anchor == nil ? nil : initial, firstBooking: anchor == nil ? booking : nil)
                            onSave?(id); dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(anchor == nil && booking.clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("save-event")
                }
            }
            .onChange(of: draft.startDate) { _, start in if !multipleDays || draft.endDate < start { draft.endDate = start } }
            .onChange(of: multipleDays) { _, multiple in if !multiple { draft.endDate = draft.startDate } }
            .onChange(of: booking.clientName) { _, name in
                let request = NSFetchRequest<Client>(entityName: "Client"); request.predicate = NSPredicate(format: "name ==[cd] %@", name)
                if booking.fee?.amount.isEmpty == true, let client = try? context.fetch(request).first { booking.fee?.currency = client.defaultCurrency }
            }
            .sheet(isPresented: $choosingTrack) { TrackLocationPicker(placeID: $draft.trackPlaceID) }
            .saveErrorAlert($error).interactiveDismissDisabled(changed)
            .confirmationDialog("Discard changes?", isPresented: $discard, titleVisibility: .visible) { Button("Discard Changes", role: .destructive) { dismiss() }; Button("Keep Editing", role: .cancel) {} }
        }.presentationSizing(.page).presentationDetents([.large]).presentationBackground(Color("PageBackground"))
    }
}

struct BookingEditorView: View {
    let anchor: Job
    let booking: Job?
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var draft: JobDraft
    @State private var initial: JobDraft
    @State private var details = false
    @State private var error: String?
    @State private var discard = false
    @State private var newRole = ""
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \WorkRole.name, ascending: true)]) private var roles: FetchedResults<WorkRole>
    init(anchor: Job, booking: Job? = nil) {
        self.anchor = anchor; self.booking = booking
        var value = booking.map(JobDraft.init(job:)) ?? JobDraft()
        if booking == nil {
            value.startDate = Day.date(from: anchor.eventStartDay) ?? Date()
            value.endDate = Day.date(from: anchor.eventEndDay) ?? value.startDate
        }
        _draft = State(initialValue: value); _initial = State(initialValue: value)
    }
    var body: some View {
        NavigationStack {
            DaybookForm {
                Section("Client") { NamedLibraryField(kind: .client, name: $draft.clientName) }
                Section("Series") { SeriesSelectionFields(names: $draft.seriesNames) }
                Section("Booking") {
                    DaybookPicker("Status", selection: $draft.bookingStatus, identifier: "edit-booking-status") { ForEach(BookingStatus.allCases, id: \.self) { Text($0.title).tag($0) } }
                    DaybookPicker("Arrangement", selection: $draft.workArrangement) { ForEach(WorkArrangement.allCases, id: \.self) { Text($0.title).tag($0) } }
                }
                if booking == nil { Section("Fee") { FeeFields(draft: Binding(get: { draft.fee ?? FeeDraft() }, set: { draft.fee = $0 })) } }
                Section {
                    DisclosureGroup("Roles & notes", isExpanded: $details) {
                        ForEach(Array(Set(roles.map(\.name)).union(draft.roleNames)).sorted(), id: \.self) { role in
                            Toggle(role, isOn: Binding(get: { draft.roleNames.contains(role) }, set: { if $0 { draft.roleNames.insert(role) } else { draft.roleNames.remove(role) } }))
                        }
                        HStack {
                            DaybookTextField("New role", text: $newRole)
                            Button("Add") { addRole() }.disabled(newRole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                        }
                        DaybookTextField("Booking notes", text: $draft.notes, axis: .vertical).lineLimit(3...8)
                    }
                }
                if !draft.name.isEmpty || !draft.projectName.isEmpty {
                    Section { DisclosureGroup("Existing record details") {
                        DaybookTextField("Original title", text: $draft.name)
                        if !draft.projectName.isEmpty { NamedLibraryField(kind: .project, name: $draft.projectName) }
                    } } footer: { Text("Kept from your existing record. New bookings use the client’s name.") }
                }
            }
            .navigationTitle(booking == nil ? "Add Client Booking" : "Edit Booking").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if draft != initial || !newRole.isEmpty { discard = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        addRole()
                        do { try draft.saveBooking(in: context, anchorID: anchor.objectID, editing: booking?.objectID, baseline: booking == nil ? nil : initial); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(draft.clientName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("save-booking")
                }
            }
            .onChange(of: draft.clientName) { _, name in
                let request = NSFetchRequest<Client>(entityName: "Client"); request.predicate = NSPredicate(format: "name ==[cd] %@", name)
                if booking == nil, draft.fee?.amount.isEmpty == true, let client = try? context.fetch(request).first { draft.fee?.currency = client.defaultCurrency }
            }
            .saveErrorAlert($error).interactiveDismissDisabled(draft != initial || !newRole.isEmpty)
            .confirmationDialog("Discard changes?", isPresented: $discard, titleVisibility: .visible) { Button("Discard Changes", role: .destructive) { dismiss() }; Button("Keep Editing", role: .cancel) {} }
        }.presentationSizing(.page).presentationDetents([.large]).presentationBackground(Color("PageBackground"))
    }
    private func addRole() { let value = newRole.trimmingCharacters(in: .whitespacesAndNewlines); if !value.isEmpty { draft.roleNames.insert(value) }; newRole = "" }
}

private struct BookingPresentation: Identifiable { let id = UUID(); let job: Job }
private struct FeePresentation: Identifiable { let id = UUID(); let job: Job; let draft: FeeDraft }

struct EventDetailView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var stacked: Bool { typeSize.isAccessibilitySize && sizeClass != .regular }
    private var rowLayout: AnyLayout { stacked ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout()) }
    @ObservedObject var anchor: Job
    // Fetch both levels to invalidate the whole event after local or remote changes.
    @FetchRequest(sortDescriptors: []) private var events: FetchedResults<WorkEvent>
    @FetchRequest(sortDescriptors: []) private var jobs: FetchedResults<Job>
    @FetchRequest(sortDescriptors: []) private var sessions: FetchedResults<WorkSession>
    @Environment(\.managedObjectContext) private var context
    @State private var editing = false
    @State private var addingClient = false
    @State private var attaching = false
    @State private var batch = false
    @State private var sessionBooking: BookingPresentation?
    @State private var editBooking: BookingPresentation?
    @State private var editFee: FeePresentation?
    @State private var error: String?
    var body: some View {
        let _ = events.count + jobs.count + sessions.count
        DaybookForm(title: anchor.eventTitle) {
            Section {
                Button { editing = true } label: { DaybookMetadata(symbol: "calendar", text: anchor.eventDateDescription) }.accessibilityIdentifier("edit-event-dates")
                Button { editing = true } label: { DaybookMetadata(symbol: "mappin.and.ellipse", text: anchor.eventLocation.isEmpty ? "Add location" : anchor.eventLocation) }
            }.containerValue(\.daybookUnframed, true)
            if !anchor.eventSeriesNames.isEmpty { Section("Series") { Text(anchor.eventSeriesNames.joined(separator: ", ")) } }
            if !anchor.eventTrackPlaceID.isEmpty { Section("Track location") { SavedTrackView(placeID: anchor.eventTrackPlaceID) } }
            EventWeatherSection(job: anchor)
            Section {
                ForEach(anchor.eventBookings, id: \.objectID) { job in
                    VStack(alignment: .leading, spacing: 12) {
                        Button { editBooking = BookingPresentation(job: job) } label: {
                            rowLayout { Text(job.client?.name ?? "Add client").font(.headline); if !stacked { Spacer() }; BookingBadge(status: job.bookingStatus) }.frame(minHeight: 44)
                        }.accessibilityIdentifier("event-booking-\(job.client?.name ?? "missing")")
                        Button {
                            do { editFee = FeePresentation(job: job, draft: try FeeDraft(job: job)) }
                            catch { self.error = error.localizedDescription }
                        } label: { rowLayout { Text("Fee & items"); if !stacked { Spacer() }; Text(job.feeSummary).monospacedDigit() }.frame(minHeight: 44) }
                        NavigationLink { JobDetailView(job: job) } label: { Text("Booking details & payments").font(.subheadline).multilineTextAlignment(.leading).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading) }
                    }.padding(.vertical, 6)
                }
                Button("Add Client", systemImage: "person.badge.plus") { addingClient = true }.accessibilityIdentifier("event-add-client")
            } header: { Text("Client bookings") }
            Section {
                ForEach(anchor.eventSessions, id: \.objectID) { session in
                    DaybookLink { SessionDetailView(session: session) } label: {
                        VStack(alignment: .leading, spacing: 6) { SessionRow(session: session); Text(session.job?.client?.name ?? "Client to add").font(.caption).foregroundStyle(Color("SecondaryText")) }
                    }
                }
                if anchor.eventSessions.isEmpty { Text("Schedule to come").foregroundStyle(Color("SecondaryText")) }
                if anchor.eventBookings.count == 1 {
                    Button("Add Session", systemImage: "plus") { sessionBooking = BookingPresentation(job: anchor) }.accessibilityIdentifier("add-session")
                } else {
                    Menu("Add Session", systemImage: "plus") {
                        ForEach(anchor.eventBookings, id: \.objectID) { job in Button(job.client?.name ?? "Client to add") { sessionBooking = BookingPresentation(job: job) } }
                    }.accessibilityIdentifier("add-session")
                }
                if !anchor.eventSessions.isEmpty { Button("Edit Multiple Sessions", systemImage: "checklist") { batch = true }.accessibilityIdentifier("batch-sessions") }
            } header: { Text("Schedule") }
            if !anchor.eventNotes.isEmpty { Section("Event notes") { Text(anchor.eventNotes).textSelection(.enabled) } }
            Section { Button("Include Existing Booking", systemImage: "link") { attaching = true } } footer: { Text("Combine existing work into this event while keeping each client’s fees and payment history.") }
        }
        .navigationTitle("Event").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Edit Event") { editing = true }.accessibilityIdentifier("edit-event") }
        .sheet(isPresented: $editing) { EventEditorView(anchor: anchor) }
        .sheet(isPresented: $addingClient) { BookingEditorView(anchor: anchor) }
        .sheet(item: $editBooking) { BookingEditorView(anchor: anchor, booking: $0.job) }
        .sheet(item: $editFee) { FeeEditorView(job: $0.job, draft: $0.draft) }
        .sheet(item: $sessionBooking) { SessionEditorView(job: $0.job) }
        .sheet(isPresented: $batch) { SessionBatchEditorView(anchor: anchor) }
        .sheet(isPresented: $attaching) { AttachBookingView(anchor: anchor) }
        .saveErrorAlert($error)
    }
}

private struct AttachBookingView: View {
    @ObservedObject var anchor: Job
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Job.startDay, ascending: false)], predicate: NSPredicate(format: "event == nil")) private var jobs: FetchedResults<Job>
    @State private var selected: Job?
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(jobs.filter { $0 != anchor }, id: \.objectID) { job in
                        Button { selected = job } label: { VStack(alignment: .leading) { Text(job.displayName); Text(job.eventDateDescription).font(.caption) } }
                    }
                } footer: { Text("The selected booking will use this event’s dates and location. Its original details, sessions, fees and payments are retained.") }
                if jobs.filter({ $0 != anchor }).isEmpty { Text("No separate bookings available.") }
            }.navigationTitle("Include Existing Booking")
                .toolbar { Button("Done") { dismiss() } }
                .confirmationDialog("Include this booking in \(anchor.eventTitle)?", isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), titleVisibility: .visible) {
                    if let selected { Button("Include Booking") { do { try EventDraft.attach(selected.objectID, to: anchor.objectID, in: context); dismiss() } catch { self.error = error.localizedDescription } } }
                    Button("Cancel", role: .cancel) { selected = nil }
                }.saveErrorAlert($error)
        }
    }
}
