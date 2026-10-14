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
    @State private var feeExpanded: Bool
    @State private var newRole = ""
    let focusBooking: NSManagedObjectID?
    let focusFee: Bool
    @State private var booking = JobDraft()
    @State private var initialBooking: JobDraft
    @State private var multipleDays: Bool
    @State private var choosingTrack = false
    @State private var discard = false
    @State private var error: String?
    init(anchor: Job? = nil, template: Job? = nil, focusBooking: NSManagedObjectID? = nil, focusFee: Bool = false, onSave: ((NSManagedObjectID) -> Void)? = nil) {
        self.anchor = anchor; self.onSave = onSave
        self.focusBooking = focusBooking; self.focusFee = focusFee
        _feeExpanded = State(initialValue: focusFee)
        _bookings = State(initialValue: anchor?.eventBookings.map(EventBookingDraft.init(job:)) ?? [])
        let first = template.map(JobDraft.duplicate) ?? JobDraft()
        _initialBooking = State(initialValue: first); _booking = State(initialValue: first)
        var value = anchor.map(EventDraft.init(anchor:)) ?? EventDraft()
        if let template {
            value = EventDraft(anchor: template); value.startDate = Date(); value.endDate = value.startDate; value.notes = ""
        }
        _draft = State(initialValue: value); _initial = State(initialValue: value)
        _multipleDays = State(initialValue: Day.string(from: value.startDate) != Day.string(from: value.endDate))
    }
    private var changed: Bool { draft != initial || booking != initialBooking || !newRole.isEmpty || bookings.contains { $0.changed } }
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
                    Section {
                        if anchor == nil {
                            EventBookingFields(draft: $booking, newRole: $newRole, feeExpanded: $feeExpanded, feeID: "event-fee", newBooking: true)
                        } else {
                            ForEach($bookings) { $entry in
                                EventBookingFields(draft: $entry.draft, newRole: $entry.newRole, feeExpanded: $feeExpanded, feeID: "event-fee")
                            }
                        }
                    }.containerValue(\.daybookUnframed, true).id("event-work")
                    Section("Event notes") {
                        DaybookTextField("Add notes", text: $draft.notes, axis: .vertical).lineLimit(3...8)
                    }
                }
                .task {
                    // The sheet must finish its initial layout before resolving scroll targets.
                    try? await Task.sleep(for: .milliseconds(350))
                    guard !Task.isCancelled else { return }
                    if focusFee { proxy.scrollTo("event-fee", anchor: .top) }
                    else if focusBooking != nil { proxy.scrollTo("event-work", anchor: .top) }
                }
            }
            .navigationTitle(anchor == nil ? "Add Event" : "Edit Event").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if changed { discard = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            var first = booking
                            let role = newRole.trimmingCharacters(in: .whitespacesAndNewlines)
                            if !role.isEmpty { first.roleNames.insert(role) }
                            let id = try draft.save(in: context, anchorID: anchor?.objectID, baseline: anchor == nil ? nil : initial, firstBooking: anchor == nil ? first : nil, bookings: bookings)
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
            if !draft.notes.isEmpty {
                Section("Previous booking notes") {
                    DaybookTextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(3...8)
                }
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

/// Existing navigation routes all open the same single-client event detail.
struct EventDetailView: View {
    @ObservedObject var anchor: Job
    var body: some View { JobDetailView(job: anchor) }
}

struct EventScheduleRow: View {
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
