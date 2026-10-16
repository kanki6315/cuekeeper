import CoreData
import SwiftUI

struct SessionEditorView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \WorkRole.name, ascending: true)]) private var roles: FetchedResults<WorkRole>
    let job: Job
    let session: WorkSession?
    private let savedBaseline: SessionDraft?
    @State private var draft: SessionDraft
    @State private var initial: SessionDraft
    @State private var error: String?
    @State private var discard = false
    @State private var details = false
    @State private var savedCount = 0

    init(job: Job, session: WorkSession? = nil, duplicating: Bool = false) {
        self.job = job; self.session = duplicating ? nil : session
        self.savedBaseline = duplicating ? nil : session.map(SessionDraft.init(session:))
        var value = session.map(SessionDraft.init(session:)) ?? SessionDraft(job: job)
        if duplicating { value.scheduleStatus = "tentative"; value.notes = "" }
        // Resolve legacy inheritance once for the simple, direct series picker.
        value.seriesName = session?.effectiveSeries?.name ?? job.series?.name ?? ""
        value.overridesSeries = true
        _draft = State(initialValue: value); _initial = State(initialValue: value)
    }
    private var zone: TimeZone { TimeZone(identifier: job.eventTimeZoneID) ?? .current }
    var body: some View {
        NavigationStack {
            DaybookForm {
                if savedCount > 0 { Section { Text("\(savedCount) saved. Ready for the next session.").foregroundStyle(Color("SecondaryText")) } }
                Section("Client & series") {
                    Text(job.client?.name ?? "Client to add")
                    NamedLibraryField(kind: .series, name: $draft.seriesName)
                }
                Section {
                    DaybookTextField("Session type or name (optional)", text: $draft.name).accessibilityIdentifier("session-name")
                    Toggle("Date known", isOn: Binding(get: { !draft.day.isEmpty }, set: { draft.day = $0 ? job.eventStartDay : "" }))
                        .disabled(draft.startTime != nil || draft.endTime != nil)
                    if !draft.day.isEmpty {
                        if typeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Session date")
                                sessionDatePicker.labelsHidden()
                            }
                        } else { sessionDatePicker }
                    }
                    TimeZoneValueLabel(title: "Event timezone", value: zoneLabel(job.eventTimeZoneID, date: draft.startTime ?? Day.date(from: draft.day) ?? Date()))
                    if job.eventTimeZoneID.isEmpty { Text("Set the timezone in Edit Event before adding times.").font(.caption).foregroundStyle(.secondary) }
                    SessionScheduleField(draft: $draft, zone: zone).disabled(job.eventTimeZoneID.isEmpty)
                    optionalTime("Call time", value: $draft.callTime)
                } header: { Text("Schedule") } footer: {
                    Text("Times can remain incomplete. An end time earlier than the start falls on the next day. All sessions use the event timezone.")
                }
                Section {
                    DaybookChoicePicker("Schedule", selection: $draft.scheduleStatus, identifier: "session-schedule") {
                        Text("Tentative").tag("tentative"); Text("Confirmed").tag("confirmed")
                    }
                    DaybookChoicePicker("Coverage", selection: $draft.coverage, identifier: "session-coverage") {
                        Text("Undecided").tag("undecided"); Text("Covering").tag("covering"); Text("Not covering").tag("notCovering")
                    }
                } header: { Text("Status & coverage") } footer: { Text("Confirming times does not change whether you’re covering this session or whether the client booking is confirmed.") }
                Section { Button(details ? "Fewer details" : "Roles & notes", systemImage: "slider.horizontal.3") { details.toggle() } }
                if details {
                Section("Roles") {
                    Toggle("Override booking roles", isOn: $draft.overridesRoles)
                    if draft.overridesRoles {
                        ForEach(Array(Set(roles.map(\.name))).sorted(), id: \.self) { role in
                            Toggle(role, isOn: Binding(get: { draft.roleNames.contains(role) }, set: { if $0 { draft.roleNames.insert(role) } else { draft.roleNames.remove(role) } }))
                        }
                        if roles.isEmpty { Text("Add reusable roles in Settings or in the booking editor.").foregroundStyle(Color("SecondaryText")) }
                    } else { Text(job.roleNames.isEmpty ? "No booking roles selected" : job.roleNames.joined(separator: ", ")).foregroundStyle(Color("SecondaryText")) }
                }
                Section("Notes") { DaybookTextField("Session notes", text: $draft.notes, axis: .vertical).lineLimit(3...8) }
                }
                if session == nil {
                    Section { Button("Save & Add Another", systemImage: "plus") { save(another: true) }.accessibilityIdentifier("save-another-session") }
                }
            }
            .environment(\.timeZone, zone)
            .navigationTitle(session == nil ? "Add Session" : "Edit Session").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if draft != initial { discard = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        save(another: false)
                    }.accessibilityIdentifier("save-session")
                }
            }
            .saveErrorAlert($error).interactiveDismissDisabled(draft != initial)
            .confirmationDialog("Discard changes?", isPresented: $discard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }; Button("Keep Editing", role: .cancel) {}
            }
        }
        .presentationSizing(.page)
        .presentationDetents([.large])
        .presentationBackground(Color("PageBackground"))
    }
    private func save(another: Bool) {
        do {
            let savedID = try draft.save(in: context, jobID: job.objectID, editing: session?.objectID, baseline: savedBaseline)
            if another {
                if let saved = try context.existingObject(with: savedID) as? WorkSession { draft.day = saved.day }
                draft.name = ""; draft.startTime = nil; draft.endTime = nil; draft.callTime = nil
                draft.scheduleStatus = "tentative"; draft.notes = ""
                initial = draft; savedCount += 1
            } else { dismiss() }
        } catch { self.error = error.localizedDescription }
    }
    private var sessionDatePicker: some View {
        SessionDateField(draft: $draft, zone: zone)
    }
    @ViewBuilder private func optionalTime(_ label: String, value: Binding<Date?>) -> some View {
        OptionalSessionTimeField(title: label, value: value,
            defaultDate: draft.startTime ?? Day.date(from: draft.day, timeZone: zone) ?? Date(), zone: zone)
            .disabled(job.eventTimeZoneID.isEmpty)
    }

}

struct SessionsSection: View {
    @ObservedObject var job: Job
    @FetchRequest private var sessions: FetchedResults<WorkSession>
    let onAdd: () -> Void
    init(job: Job, onAdd: @escaping () -> Void) {
        self.job = job; self.onAdd = onAdd
        _sessions = FetchRequest(sortDescriptors: [NSSortDescriptor(key: "day", ascending: true), NSSortDescriptor(key: "startTime", ascending: true)], predicate: NSPredicate(format: "job == %@ AND deletedAt == nil", job))
    }
    var body: some View {
        Section {
            if sessions.isEmpty { Text("Schedule to come").foregroundStyle(Color("SecondaryText")) }
            ForEach(sessions, id: \.objectID) { session in
                DaybookLink { SessionDetailView(session: session) } label: { EventScheduleRow(session: session) }
            }
        } header: { HStack { Text("Schedule"); Spacer(); Button("Add", systemImage: "plus", action: onAdd).buttonStyle(DaybookSecondaryButton()).accessibilityLabel("Add Session").accessibilityIdentifier("add-session") } } footer: {
            if sessions.isEmpty { Text("No sessions yet. Event dates remain useful until the schedule arrives.") }
            else if sessions.contains(where: { $0.scheduleStatus != "confirmed" }) { Text("Some session times are still tentative.") }
        }
    }
}

struct SessionRow: View {
    @ObservedObject var session: WorkSession
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(session.title).font(.headline)
            if !session.effectiveSeriesNames.isEmpty { Text(session.effectiveSeriesNames.joined(separator: ", ")).font(.subheadline) }
            DaybookMetadata(symbol: "clock", text: session.compactSchedule)
            if let local = session.localScheduleDescription { Text(local).font(.subheadline).foregroundStyle(Color("SecondaryText")) }
            HStack { BookingBadge(status: session.scheduleStatus); Text(session.coverage == "notCovering" ? "Not covering" : session.coverage.capitalized).font(.caption).foregroundStyle(Color("SecondaryText")) }
            if let call = session.callTime { DaybookMetadata(symbol: "video", text: "Call \(session.shortTime(call))") }
        }.padding(.vertical, 4)
    }
}

struct SessionDetailView: View {
    @EnvironmentObject private var calendar: CalendarController
    @ObservedObject var session: WorkSession
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @State private var removing = false
    @State private var duplicating = false
    @State private var error: String?
    var body: some View {
        DaybookForm(title: session.title, subtitle: session.job?.displayName ?? "") {
            if let job = session.job {
                Section("Event") {
                    DaybookLink { EventDetailView(anchor: job) } label: { Label(job.eventTitle, systemImage: "bookmark") }
                }
            }
            Section("Series") { Text(session.effectiveSeries?.name ?? "Not added") }
            Section("Schedule") {
                Text(session.scheduleDescription)
                if let local = session.localScheduleDescription { Text(local).font(.subheadline).foregroundStyle(Color("SecondaryText")) }
                LabeledContent("Schedule", value: session.scheduleStatus.capitalized)
                LabeledContent("Coverage", value: session.coverage == "notCovering" ? "Not covering" : session.coverage.capitalized)
                if let call = session.callTime {
                    Text("Call: \(session.shortTime(call))")
                        .environment(\.timeZone, TimeZone(identifier: session.eventTimeZoneID) ?? .current)
                }
                LabeledContent("Roles", value: session.roleNames.isEmpty ? "None selected" : session.roleNames.joined(separator: ", "))
            }
            if !session.notes.isEmpty { Section("Notes") { Text(session.notes).textSelection(.enabled) } }
            Section("Calendar") {
                Text(session.calendarEligible ? "Eligible for a timed entry in your connected calendar." : "A timed entry requires confirmed start and end times and coverage set to Covering.")
                Text(calendar.status).font(.subheadline).foregroundStyle(Color("SecondaryText"))
            }
            Section { Button("Duplicate Session", systemImage: "plus.square.on.square") { duplicating = true }.accessibilityIdentifier("duplicate-session") }
            Section { Button("Remove Session", role: .destructive) { removing = true } }
        }
        .navigationTitle(session.title).navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Edit") { editing = true }.accessibilityIdentifier("edit-session") }
        .sheet(isPresented: $editing) { if let job = session.job { SessionEditorView(job: job, session: session) } }
        .sheet(isPresented: $duplicating) { if let job = session.job { SessionEditorView(job: job, session: session, duplicating: true) } }
        .saveErrorAlert($error)
        .confirmationDialog("Remove this session? You can restore it from Recently Deleted for 30 days.", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove Session", role: .destructive) {
                do {
                    let writer = isolatedWriter(context)
                    let record = try writer.existingObject(with: session.objectID) as! WorkSession
                    record.deletedAt = Date(); record.recoveryDiscardedAt = nil; try writer.save(); context.refreshAllObjects(); dismiss()
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}
