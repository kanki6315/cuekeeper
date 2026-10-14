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
        if duplicating { value.scheduleStatus = "tentative"; value.links = []; value.notes = "" }
        // Resolve legacy inheritance once for the simple, direct series picker.
        value.seriesName = session?.effectiveSeries?.name ?? job.series?.name ?? ""
        value.overridesSeries = true
        _draft = State(initialValue: value); _initial = State(initialValue: value)
    }
    private var zone: TimeZone { TimeZone(identifier: draft.timeZoneID) ?? .current }
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
                        .disabled(draft.startTime != nil)
                    if !draft.day.isEmpty {
                        if typeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Session date")
                                sessionDatePicker.labelsHidden()
                            }
                        } else { sessionDatePicker }
                    }
                    DaybookLink { TimeZonePicker(selection: $draft.timeZoneID, date: draft.startTime ?? Day.date(from: draft.day) ?? Date()) } label: {
                        if typeSize.isAccessibilitySize {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Timezone")
                                Text(zoneLabel(draft.timeZoneID, date: draft.startTime ?? Day.date(from: draft.day) ?? Date())).foregroundStyle(Color("SecondaryText"))
                            }
                        } else {
                            LabeledContent("Timezone", value: zoneLabel(draft.timeZoneID, date: draft.startTime ?? Day.date(from: draft.day) ?? Date()))
                        }
                    }
                    optionalTime("Start", value: $draft.startTime)
                    optionalTime("End", value: $draft.endTime)
                    optionalTime("Call time", value: $draft.callTime)
                } header: { Text("Schedule") } footer: {
                    Text("Times can remain incomplete. For overnight work, set the end on the following date. Times are shown in the selected timezone.")
                }
                Section {
                    DaybookChoicePicker("Schedule", selection: $draft.scheduleStatus, identifier: "session-schedule") {
                        Text("Tentative").tag("tentative"); Text("Confirmed").tag("confirmed")
                    }
                    DaybookChoicePicker("Coverage", selection: $draft.coverage, identifier: "session-coverage") {
                        Text("Undecided").tag("undecided"); Text("Covering").tag("covering"); Text("Not covering").tag("notCovering")
                    }
                } header: { Text("Status & coverage") } footer: { Text("Confirming times does not change whether you’re covering this session or whether the client booking is confirmed.") }
                Section { Button(details ? "Fewer details" : "Roles, notes & links", systemImage: "slider.horizontal.3") { details.toggle() } }
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
                Section {
                    ForEach($draft.links) { $link in
                        VStack(alignment: .leading, spacing: 12) {
                            DaybookTextField("Link label (optional)", text: $link.label)
                            DaybookTextField("https://…", text: $link.url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityIdentifier("broadcast-url")
                            DaybookTextField("Link notes (optional)", text: $link.notes, axis: .vertical)
                            Button("Remove Link", role: .destructive) { draft.links.removeAll { $0.id == link.id } }
                        }.padding(.vertical, 4)
                    }
                    Button("Add Broadcast Link", systemImage: "link.badge.plus") { draft.links.append(LinkDraft()) }
                        .accessibilityIdentifier("add-broadcast-link")
                } header: { Text("Broadcast links") } footer: { Text("Save links when they’re available. They aren’t required to save a session.") }
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
                draft.scheduleStatus = "tentative"; draft.notes = ""; draft.links = []
                initial = draft; savedCount += 1
            } else { dismiss() }
        } catch { self.error = error.localizedDescription }
    }
    private var sessionDatePicker: some View {
        DatePicker("Session date", selection: Binding(get: { Day.date(from: draft.day, timeZone: zone) ?? Date() }, set: { draft.day = Day.string(from: $0, timeZone: zone) }), displayedComponents: .date)
            .disabled(draft.startTime != nil)
    }
    @ViewBuilder private func optionalTime(_ label: String, value: Binding<Date?>) -> some View {
        if value.wrappedValue != nil {
            if typeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 12) {
                    Text(label)
                    DatePicker(label, selection: Binding(get: { value.wrappedValue ?? Date() }, set: { value.wrappedValue = $0 })).labelsHidden()
                    Button { value.wrappedValue = nil } label: {
                        Label("Clear \(label.lowercased())", systemImage: "xmark.circle").frame(minHeight: 44)
                    }
                }
            } else {
                HStack {
                    DatePicker(label, selection: Binding(get: { value.wrappedValue ?? Date() }, set: { value.wrappedValue = $0 }))
                    Button { value.wrappedValue = nil } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color("SecondaryText")).frame(width: 44, height: 44) }.accessibilityLabel("Clear \(label.lowercased())")
                }
            }
        } else {
            Button {
                if draft.timeZoneID.isEmpty { draft.timeZoneID = TimeZone.current.identifier }
                let start = draft.startTime ?? Day.date(from: draft.day, timeZone: zone) ?? Date()
                value.wrappedValue = label == "End" ? start.addingTimeInterval(3600) : start
            } label: { HStack { Text(label).foregroundStyle(Color.primary); Spacer(); Text("Add time"); Image(systemName: "plus").font(.caption) } }
        }
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
                DaybookLink { SessionDetailView(session: session) } label: { SessionRow(session: session) }
            }
        } header: { HStack { Text("Sessions"); Spacer(); Button("Add", systemImage: "plus", action: onAdd).buttonStyle(DaybookSecondaryButton()).accessibilityLabel("Add Session").accessibilityIdentifier("add-session") } } footer: {
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
            Section("Series") { Text(session.effectiveSeries?.name ?? "Not added") }
            Section("Schedule") {
                Text(session.scheduleDescription)
                LabeledContent("Schedule", value: session.scheduleStatus.capitalized)
                LabeledContent("Coverage", value: session.coverage == "notCovering" ? "Not covering" : session.coverage.capitalized)
                if let call = session.callTime {
                    Text("Call: \(session.shortTime(call))")
                        .environment(\.timeZone, TimeZone(identifier: session.timeZoneID) ?? .current)
                }
                LabeledContent("Roles", value: session.roleNames.isEmpty ? "None selected" : session.roleNames.joined(separator: ", "))
            }
            if !session.notes.isEmpty { Section("Notes") { Text(session.notes).textSelection(.enabled) } }
            Section("Broadcast links") {
                if session.sortedLinks.isEmpty { Text("No links added yet").foregroundStyle(Color("SecondaryText")) }
                ForEach(session.sortedLinks, id: \.objectID) { link in
                    VStack(alignment: .leading, spacing: 6) {
                        if let url = URL(string: link.url), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                            Link(link.label.isEmpty ? link.url : link.label, destination: url)
                        } else { Text(link.url).textSelection(.enabled) }
                        if !link.notes.isEmpty { Text(link.notes).font(.subheadline).foregroundStyle(Color("SecondaryText")) }
                    }
                }
            }
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
        .confirmationDialog("Remove this session and its links from the booking?", isPresented: $removing, titleVisibility: .visible) {
            Button("Remove Session", role: .destructive) {
                do {
                    let writer = isolatedWriter(context)
                    let record = try writer.existingObject(with: session.objectID) as! WorkSession
                    record.deletedAt = Date(); try writer.save(); context.refreshAllObjects(); dismiss()
                } catch { self.error = error.localizedDescription }
            }
        }
    }
}

struct BroadcastLinkEditorView: View {
    let job: Job
    let session: WorkSession?
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var link = LinkDraft()
    @State private var name = ""
    @State private var error: String?
    @State private var discard = false
    @FocusState private var focused: Bool
    private var changed: Bool { !link.url.isEmpty || !link.label.isEmpty || !link.notes.isEmpty || !name.isEmpty }
    var body: some View {
        NavigationStack {
            DaybookForm {
                Section {
                    if let session { LabeledContent("Session", value: session.title) }
                    else { DaybookTextField("Session name (optional)", text: $name) }
                    DaybookTextField("Label (optional)", text: $link.label)
                    DaybookTextField("https://…", text: $link.url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled().focused($focused).accessibilityIdentifier("quick-broadcast-url")
                    DaybookTextField("Notes (optional)", text: $link.notes, axis: .vertical)
                } footer: {
                    if session == nil { Text("This creates an unscheduled session to keep the link with its broadcast. Add times later if useful.") }
                }
            }.navigationTitle("Add Broadcast Link").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if changed { discard = true } else { dismiss() } } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Save") {
                            do {
                                let original = session.map(SessionDraft.init(session:))
                                var draft = original ?? SessionDraft(job: job)
                                if session == nil { draft.name = name }
                                draft.links.append(link)
                                try draft.save(in: context, jobID: job.objectID, editing: session?.objectID, baseline: original)
                                dismiss()
                            } catch { self.error = error.localizedDescription }
                        }.accessibilityIdentifier("save-broadcast-link")
                    }
                }
                .task { if !ProcessInfo.processInfo.arguments.contains("--design-fixtures") { focused = true } }
                .saveErrorAlert($error).interactiveDismissDisabled(changed)
                .confirmationDialog("Discard link?", isPresented: $discard, titleVisibility: .visible) {
                    Button("Discard Changes", role: .destructive) { dismiss() }; Button("Keep Editing", role: .cancel) {}
                }
        }
        .presentationSizing(.page)
        .presentationDetents([.large])
        .presentationBackground(Color("PageBackground"))
    }
}
