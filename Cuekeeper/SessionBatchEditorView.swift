import CoreData
import SwiftUI

/// Explicitly chosen fields only; unrelated times, links and notes never get rewritten.
struct SessionBatchChange {
    var day: String?
    var series: String?
    var coverage: String?
    var bookingID: NSManagedObjectID?

    func save(ids: Set<NSManagedObjectID>, anchorID: NSManagedObjectID, in context: NSManagedObjectContext) throws {
        guard !ids.isEmpty else { throw RecordError.invalid("Select at least one session.") }
        let writer = isolatedWriter(context)
        let anchor = try writer.existingObject(with: anchorID) as! Job
        let bookings = Set(anchor.eventBookings.map(\.objectID))
        let target = try bookingID.map { try writer.existingObject(with: $0) as! Job }
        if let target, !bookings.contains(target.objectID) { throw RecordError.invalid("Choose a client booking in this event.") }
        if let coverage, !["undecided", "covering", "notCovering"].contains(coverage) { throw RecordError.invalid("Choose valid coverage.") }
        for id in ids {
            let session = try writer.existingObject(with: id) as! WorkSession
            guard session.deletedAt == nil, let job = session.job, bookings.contains(job.objectID) else { throw RecordError.invalid("A selected session changed. Close this editor and select the sessions again.") }
            if let day {
                // Shift all timed fields together in the session's own timezone (DST included).
                let zone = TimeZone(identifier: session.timeZoneID) ?? .current
                var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
                guard let destination = Day.date(from: day, timeZone: zone) else { throw RecordError.invalid("Choose a valid date.") }
                let source = session.startTime.map { calendar.startOfDay(for: $0) } ?? Day.date(from: session.day, timeZone: zone)
                if let source {
                    let delta = calendar.dateComponents([.day], from: source, to: destination).day ?? 0
                    for key in ["startTime", "endTime", "callTime"] {
                        if let value = session.value(forKey: key) as? Date {
                            guard let shifted = calendar.date(byAdding: .day, value: delta, to: value) else { throw RecordError.invalid("Couldn’t move this session’s times.") }
                            session.setValue(shifted, forKey: key)
                        }
                    }
                } else if session.startTime != nil || session.endTime != nil || session.callTime != nil {
                    throw RecordError.invalid("Add a date to timed sessions before moving them together.")
                }
                session.day = day
            }
            if let series { session.overridesSeries = true; session.series = try reusableRecord(entity: "WorkSeries", name: series, in: writer) as? WorkSeries }
            if let coverage { session.coverage = coverage }
            if let target {
                // Preserve inherited meaning when moving between client bookings.
                if !session.overridesSeries { session.series = session.effectiveSeries; session.overridesSeries = true }
                if !session.overridesRoles { session.roles = job.roles; session.overridesRoles = true }
                session.job = target
            }
            try SessionDraft(session: session).validate()
        }
        try writer.save(); context.refreshAllObjects()
    }
}

struct SessionBatchEditorView: View {
    @ObservedObject var anchor: Job
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var selected = Set<NSManagedObjectID>()
    @State private var changeDate = false
    @State private var date = Date()
    @State private var changeSeries = false
    @State private var series = ""
    @State private var changeCoverage = false
    @State private var coverage = "covering"
    @State private var error: String?
    @State private var discard = false
    private var changed: Bool { changeDate || changeSeries || changeCoverage }
    var body: some View {
        NavigationStack {
            DaybookForm {
                Section {
                    Button(selected.count == anchor.eventSessions.count ? "Deselect All" : "Select All") {
                        selected = selected.count == anchor.eventSessions.count ? [] : Set(anchor.eventSessions.map(\.objectID))
                    }
                    ForEach(anchor.eventSessions, id: \.objectID) { session in
                        Toggle(isOn: Binding(get: { selected.contains(session.objectID) }, set: { if $0 { selected.insert(session.objectID) } else { selected.remove(session.objectID) } })) {
                            VStack(alignment: .leading) { Text(session.title); Text("\(session.job?.client?.name ?? "Client to add") · \(session.compactSchedule)").font(.caption) }
                        }
                    }
                } header: { Text("Select sessions") }
                Section {
                    Toggle("Change date", isOn: $changeDate)
                    if changeDate { DatePicker("Date", selection: $date, displayedComponents: .date) }
                    Toggle("Change series", isOn: $changeSeries)
                    if changeSeries { NamedLibraryField(kind: .series, name: $series) }
                    Toggle("Change coverage", isOn: $changeCoverage)
                    if changeCoverage { DaybookChoicePicker("Coverage", selection: $coverage, identifier: "batch-session-coverage") { Text("Undecided").tag("undecided"); Text("Covering").tag("covering"); Text("Not covering").tag("notCovering") } }

                } header: { Text("Apply to selected sessions") } footer: { Text("Only enabled changes apply. Moving dates keeps each session’s local times.") }
            }.navigationTitle("Edit Sessions").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if changed { discard = true } else { dismiss() } } }
                    ToolbarItem(placement: .confirmationAction) { Button("Apply") {
                        do {
                            try SessionBatchChange(day: changeDate ? Day.string(from: date) : nil, series: changeSeries ? series : nil, coverage: changeCoverage ? coverage : nil).save(ids: selected, anchorID: anchor.objectID, in: context)
                            dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.disabled(selected.isEmpty || !changed).accessibilityIdentifier("apply-session-changes") }
                }
                .saveErrorAlert($error).interactiveDismissDisabled(changed)
                .confirmationDialog("Discard changes?", isPresented: $discard, titleVisibility: .visible) { Button("Discard Changes", role: .destructive) { dismiss() }; Button("Keep Editing", role: .cancel) {} }
        }.presentationSizing(.page).presentationDetents([.large]).presentationBackground(Color("PageBackground"))
    }
}
