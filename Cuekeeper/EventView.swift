import CoreData
import SwiftUI

struct EventEditorView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    let anchor: Job?
    let onSave: ((NSManagedObjectID) -> Void)?
    @State private var draft: EventDraft
    @State private var initial: EventDraft
    @State private var bookings: [EventBookingDraft]
    @State private var expandedBookings: Set<NSManagedObjectID>
    @State private var expandedFees: Set<NSManagedObjectID>
    let focusBooking: NSManagedObjectID?
    let focusFee: Bool
    @State private var booking = JobDraft()
    @State private var initialBooking: JobDraft
    @State private var multipleDays: Bool
    @State private var additions: [PendingEventBooking] = []
    @State private var choosingTrack = false
    @State private var discard = false
    @State private var error: String?
    init(anchor: Job? = nil, template: Job? = nil, focusBooking: NSManagedObjectID? = nil, focusFee: Bool = false, addingBooking: Bool = false, onSave: ((NSManagedObjectID) -> Void)? = nil) {
        self.anchor = anchor; self.onSave = onSave
        self.focusBooking = focusBooking; self.focusFee = focusFee
        _expandedFees = State(initialValue: Set(focusFee ? (focusBooking.map { [$0] } ?? []) : []))
        _bookings = State(initialValue: anchor?.eventBookings.map(EventBookingDraft.init(job:)) ?? [])
        _expandedBookings = State(initialValue: Set(addingBooking ? [] : focusBooking.map { [$0] } ?? (anchor?.eventBookings.count == 1 ? anchor.map { [$0.objectID] } ?? [] : [])))
        _additions = State(initialValue: addingBooking ? [PendingEventBooking()] : [])
        let first = template.map(JobDraft.duplicate) ?? JobDraft()
        _initialBooking = State(initialValue: first); _booking = State(initialValue: first)
        var value = anchor.map(EventDraft.init(anchor:)) ?? EventDraft()
        if let template {
            value = EventDraft(anchor: template); value.startDate = Date(); value.endDate = value.startDate; value.notes = ""
        }
        _draft = State(initialValue: value); _initial = State(initialValue: value)
        _multipleDays = State(initialValue: Day.string(from: value.startDate) != Day.string(from: value.endDate))
    }
    private var changed: Bool { draft != initial || booking != initialBooking || !additions.isEmpty || bookings.contains { $0.changed } }
    private func bookingSummary(_ booking: JobDraft) -> String {
        let fee = booking.fee.flatMap { value -> String? in
            guard !value.amount.isEmpty, let amount = try? Money.parse(value.amount) else { return nil }
            return Money.format(amount, currency: value.currency)
        } ?? (booking.fee == nil ? "Fee needs review" : "Fee not set")
        return "\(booking.bookingStatus.title) · \(fee)"
    }
    private func expansion(_ id: NSManagedObjectID, in selection: Binding<Set<NSManagedObjectID>>) -> Binding<Bool> {
        Binding(get: { selection.wrappedValue.contains(id) }, set: { expanded in
            if expanded { selection.wrappedValue.insert(id) } else { selection.wrappedValue.remove(id) }
        })
    }
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                DaybookForm {
                    Section("Event details") {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Title").font(.subheadline).foregroundStyle(Color("SecondaryText"))
                            DaybookTextField("Custom title (optional)", text: $draft.title).accessibilityIdentifier("event-title")
                        }
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Location").font(.subheadline).foregroundStyle(Color("SecondaryText"))
                            DaybookTextField("Add location", text: $draft.location).accessibilityIdentifier("job-location")
                        }
                        if !draft.trackPlaceID.isEmpty { SavedTrackView(placeID: draft.trackPlaceID) }
                        Button(draft.trackPlaceID.isEmpty ? "Choose track location" : "Change track location", systemImage: "mappin.and.ellipse") { choosingTrack = true }.accessibilityIdentifier("choose-track")
                        if !draft.trackPlaceID.isEmpty { Button("Remove track location", role: .destructive) { draft.trackPlaceID = "" }.accessibilityIdentifier("remove-track") }
                        DaybookLink { TimeZonePicker(selection: $draft.timeZoneID, date: draft.startDate) } label: {
                            LabeledContent("Timezone", value: draft.timeZoneID.isEmpty ? "Choose timezone" : zoneLabel(draft.timeZoneID, date: draft.startDate))
                        }
                    }.id("event-details")
                    Section {
                        DatePicker(multipleDays ? "Start" : "Date", selection: $draft.startDate, displayedComponents: .date)
                        Toggle("Multiple days", isOn: $multipleDays).accessibilityIdentifier("job-multiple-days")
                        if multipleDays { DatePicker("End", selection: $draft.endDate, in: draft.startDate..., displayedComponents: .date).accessibilityIdentifier("job-end-date") }
                    } header: { Text("Dates") } footer: { Text("Session dates and times are edited separately.") }
                    Section("Event notes") {
                        DaybookTextField("Add notes", text: $draft.notes, axis: .vertical).lineLimit(3...8)
                    }
                    if anchor == nil {
                        Section("First client booking") {
                            NamedLibraryField(kind: .client, name: $booking.clientName)
                            FeeFields(draft: Binding(get: { booking.fee ?? FeeDraft() }, set: { booking.fee = $0 }))
                        }
                    }
                    Section { EmptyView() } header: { Text("Client bookings") }
                    ForEach($bookings) { $entry in
                        Section {
                            DisclosureGroup(isExpanded: expansion(entry.id, in: $expandedBookings)) {
                                VStack(alignment: .leading, spacing: 18) {
                                    EventBookingFields(draft: $entry.draft, newRole: $entry.newRole,
                                                       feeExpanded: expansion(entry.id, in: $expandedFees),
                                                       feeID: "fee-\(entry.id.uriRepresentation())")
                                }.padding(.top, 12)
                            } label: {
                                EditorSectionLabel(title: entry.draft.clientName.isEmpty ? "Client booking" : entry.draft.clientName,
                                                   summary: bookingSummary(entry.draft), expanded: expandedBookings.contains(entry.id))
                                    .foregroundStyle(Color.primary)
                                    .accessibilityIdentifier("editor-booking-section")
                            }
                            .id(entry.id)
                        }.containerValue(\.daybookUnframed, true)
                    }
                    ForEach($additions) { $entry in
                        Section {
                            DisclosureGroup(isExpanded: $entry.expanded) {
                                EventBookingFields(draft: $entry.draft, newRole: $entry.newRole, feeExpanded: $entry.feeExpanded, feeID: entry.id.uuidString, newBooking: true)
                                Button("Remove new booking", role: .destructive) { additions.removeAll { $0.id == entry.id } }
                            } label: {
                                EditorSectionLabel(title: entry.draft.clientName.isEmpty ? "New client booking" : entry.draft.clientName,
                                                   summary: bookingSummary(entry.draft), expanded: entry.expanded).foregroundStyle(Color.primary)
                            }.id(entry.id)
                        }.containerValue(\.daybookUnframed, true)
                    }
                    if anchor != nil {
                        Section {
                            Button("Add client booking", systemImage: "plus") {
                                let entry = PendingEventBooking()
                                expandedBookings.removeAll()
                                for index in additions.indices { additions[index].expanded = false }
                                additions.append(entry)
                                Task { @MainActor in
                                    try? await Task.sleep(for: .milliseconds(100))
                                    proxy.scrollTo(entry.id, anchor: .top)
                                }
                            }.accessibilityIdentifier("editor-add-client")
                        }.containerValue(\.daybookUnframed, true)
                    }
                }
                .task {
                    // The sheet must finish its initial layout before resolving scroll targets.
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    if let added = additions.first { proxy.scrollTo(added.id, anchor: .top) }
                    else if let focusBooking {
                        if focusFee { proxy.scrollTo("fee-\(focusBooking.uriRepresentation())", anchor: .top) }
                        else { proxy.scrollTo(focusBooking, anchor: .top) }
                    }
                }
            }
            .navigationTitle(anchor == nil ? "Add Event" : "Edit Event").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if changed { discard = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            let id = try draft.save(in: context, anchorID: anchor?.objectID, baseline: anchor == nil ? nil : initial, firstBooking: anchor == nil ? booking : nil, bookings: bookings, newBookings: additions.map(\.resolved))
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

private struct EditorSectionLabel: View {
    let title: String
    let summary: String
    let expanded: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.headline)
            Text(summary).font(.subheadline).foregroundStyle(Color("SecondaryText")).fixedSize(horizontal: false, vertical: true)
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}

private func feeSummary(_ draft: FeeDraft?) -> String {
    guard let draft else { return "Fee needs review" }
    let amount: String
    if draft.amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { amount = "Fee unknown" }
    else if let value = try? Money.parse(draft.amount) { amount = Money.format(value, currency: draft.currency) }
    else { amount = "Amount needs review" }
    return "\(amount) · \(draft.agreement.capitalized) · \(draft.lines.count) breakdown \(draft.lines.count == 1 ? "item" : "items")"
}

private struct PendingEventBooking: Identifiable {
    let id = UUID()
    var draft = JobDraft()
    var newRole = ""
    var expanded = true
    var feeExpanded = false
    var resolved: JobDraft {
        var result = draft
        let role = newRole.trimmingCharacters(in: .whitespacesAndNewlines)
        if !role.isEmpty { result.roleNames.insert(role) }
        return result
    }
}

private struct EventBookingFields: View {
    @Binding var draft: JobDraft
    @Binding var newRole: String
    @Binding var feeExpanded: Bool
    let feeID: String
    var newBooking = false
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \WorkRole.name, ascending: true)]) private var roles: FetchedResults<WorkRole>
    var body: some View {
        DaybookSections {
            Section("Client") {
                NamedLibraryField(kind: .client, name: $draft.clientName)
                NamedLibraryField(kind: .project, name: $draft.projectName)
                SeriesSelectionFields(names: $draft.seriesNames)
            }
            Section("Work") {
                DaybookPicker("Status", selection: $draft.bookingStatus, identifier: "edit-booking-status") {
                    ForEach(BookingStatus.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                DaybookPicker("Arrangement", selection: $draft.workArrangement) {
                    ForEach(WorkArrangement.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                DisclosureGroup {
                    ForEach(Array(Set(roles.map(\.name)).union(draft.roleNames)).sorted(), id: \.self) { role in
                        Toggle(role, isOn: Binding(get: { draft.roleNames.contains(role) }, set: { if $0 { draft.roleNames.insert(role) } else { draft.roleNames.remove(role) } }))
                    }
                    HStack {
                        DaybookTextField("New role", text: $newRole)
                        Button("Add") {
                            let role = newRole.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !role.isEmpty { draft.roleNames.insert(role) }
                            newRole = ""
                        }.disabled(newRole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } label: { LabeledContent("Roles", value: draft.roleNames.isEmpty ? "None" : draft.roleNames.sorted().joined(separator: ", ")).foregroundStyle(Color.primary) }
            }
            Section("Fee") {
                DisclosureGroup(isExpanded: $feeExpanded) {
                    if draft.fee != nil {
                        DaybookSections {
                            FeeEditingFields(draft: Binding(get: { draft.fee ?? FeeDraft() }, set: { draft.fee = $0 }))
                        }.padding(.top, 12)
                    } else {
                        Text("This fee needs review. Resolve conflicting revisions from the booking’s Fee screen.").foregroundStyle(Color("SecondaryText"))
                    }
                } label: {
                    EditorSectionLabel(title: "Overall fee & breakdown", summary: feeSummary(draft.fee), expanded: feeExpanded)
                        .foregroundStyle(Color.primary).accessibilityIdentifier("editor-fee-section")
                }.id(feeID)
            }.containerValue(\.daybookUnframed, feeExpanded)
            Section("Booking notes") {
                DaybookTextField("Add booking notes", text: $draft.notes, axis: .vertical).lineLimit(3...8)
            }
            if !draft.name.isEmpty {
                Section {
                    DisclosureGroup("Original booking title") { DaybookTextField("Original title", text: $draft.name) }.foregroundStyle(Color.primary)
                }
            }
        }
        .onChange(of: draft.clientName) { _, name in
            guard newBooking, draft.fee?.amount.isEmpty == true else { return }
            let request = NSFetchRequest<Client>(entityName: "Client")
            request.predicate = NSPredicate(format: "name ==[cd] %@", name)
            if let client = try? context.fetch(request).first { draft.fee?.currency = client.defaultCurrency }
        }
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
                Section("Project") { NamedLibraryField(kind: .project, name: $draft.projectName) }
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
            Section {
                ForEach(anchor.eventSessions, id: \.objectID) { session in
                    DaybookLink { SessionDetailView(session: session) } label: {
                        VStack(alignment: .leading, spacing: 6) { EventScheduleRow(session: session) }
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
            Section {
                ForEach(anchor.eventBookings, id: \.objectID) { job in
                    Button { editBooking = BookingPresentation(job: job) } label: {
                        rowLayout {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(job.client?.name ?? "Add client").font(.headline).foregroundStyle(Color.primary)
                                Text(job.feeSummary).font(.subheadline).foregroundStyle(Color("SecondaryText"))
                            }
                            if !stacked { Spacer() }
                            BookingBadge(status: job.bookingStatus)
                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Color("SecondaryText"))
                        }.frame(minHeight: 44).contentShape(Rectangle())
                    }.accessibilityIdentifier("event-booking-\(job.client?.name ?? "missing")")
                }
            } header: { Text("Client bookings") }
            Section {
                Button("Add client booking", systemImage: "plus") { addingClient = true }.accessibilityIdentifier("event-add-client")
            }.containerValue(\.daybookUnframed, true)
            Section("Payments") {
                ForEach(anchor.eventBookings, id: \.objectID) { job in
                    DaybookLink { JobDetailView(job: job) } label: { Text("\(job.client?.name ?? "Client") · booking & payments") }
                }
            }
            if !anchor.eventSeriesNames.isEmpty { Section("Series") { Text(anchor.eventSeriesNames.joined(separator: ", ")) } }
            if !anchor.eventTrackPlaceID.isEmpty { Section("Track location") { SavedTrackView(placeID: anchor.eventTrackPlaceID) } }
            EventWeatherSection(job: anchor)
            if !anchor.eventNotes.isEmpty { Section("Event notes") { Text(anchor.eventNotes).textSelection(.enabled) } }
            Section { Button("Include Existing Booking", systemImage: "link") { attaching = true } } footer: { Text("Combine existing work into this event while keeping each client’s fees and payment history.") }
        }
        .navigationTitle("Event").navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Edit Event") { editing = true }.accessibilityIdentifier("edit-event") }
        .sheet(isPresented: $editing) { EventEditorView(anchor: anchor) }
        .sheet(isPresented: $addingClient) { EventEditorView(anchor: anchor, addingBooking: true) }
        .sheet(item: $editBooking) { EventEditorView(anchor: anchor, focusBooking: $0.job.objectID) }
        .sheet(item: $editFee) { EventEditorView(anchor: anchor, focusBooking: $0.job.objectID, focusFee: true) }
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

private struct EventScheduleRow: View {
    @ObservedObject var session: WorkSession
    private func scheduleDates(_ start: Date) -> String {
        let zone = TimeZone(identifier: session.timeZoneID) ?? .current
        var dates = session.shortDate(start)
        if let end = session.endTime, Day.string(from: start, timeZone: zone) != Day.string(from: end, timeZone: zone) {
            dates += " – " + session.shortDate(end)
        }
        return dates + " · " + (zone.abbreviation(for: start) ?? session.timeZoneID)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(session.title).font(.headline)
                Text(session.job?.client?.name ?? "Client to add").font(.subheadline).foregroundStyle(Color("SecondaryText"))
                if !session.effectiveSeriesNames.isEmpty { Text(session.effectiveSeriesNames.joined(separator: ", ")).font(.subheadline) }
            }
            VStack(alignment: .leading, spacing: 4) {
                if let start = session.startTime {
                    Text(session.shortTime(start) + (session.endTime.map { " – " + session.shortTime($0) } ?? ""))
                        .font(.title3.weight(.semibold)).multilineTextAlignment(.leading)
                    Text(scheduleDates(start)).font(.subheadline).foregroundStyle(Color("SecondaryText"))
                } else {
                    Text("Time to come").font(.title3.weight(.semibold))
                    if !session.day.isEmpty { Text(session.day).font(.subheadline).foregroundStyle(Color("SecondaryText")) }
                }
            }.fixedSize(horizontal: false, vertical: true)
            if let call = session.callTime {
                Divider()
                ViewThatFits(in: .horizontal) {
                    HStack { Text("Call time"); Spacer(); Text(session.shortTime(call)).bold() }
                    VStack(alignment: .leading) { Text("Call time"); Text(session.shortTime(call)).bold() }
                }
            }
            HStack {
                BookingBadge(status: session.scheduleStatus)
                Text(session.coverage == "notCovering" ? "Not covering" : session.coverage.capitalized).font(.subheadline).foregroundStyle(Color("SecondaryText"))
            }
        }.padding(.vertical, 4)
    }
}
