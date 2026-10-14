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

/// A single-tap choice backed by an IANA zone, never a fixed UTC offset.
struct TimeZoneChoice: Identifiable {
    let label: String
    let identifiers: [String]
    var id: String { identifiers[0] }

    static func grouped(date: Date, identifiers: [String] = TimeZone.knownTimeZoneIdentifiers) -> [Self] {
        let groups = Dictionary(grouping: identifiers) { identifier in
            zoneLabel(identifier, date: date) + "|" + (futureRules(identifier, date: date) ?? identifier)
        }.values.map { $0.sorted() }
        let labels = Dictionary(grouping: groups, by: { zoneLabel($0[0], date: date) })
        return groups.map { zones in
            let label = zoneLabel(zones[0], date: date)
            // Equal names/offsets can still have different transition dates.
            let region = zones[0].split(separator: "/").last.map(String.init) ?? zones[0]
            let suffix = labels[label, default: []].count > 1
                ? " (\(region.replacingOccurrences(of: "_", with: " ")))" : ""
            return Self(label: label + suffix, identifiers: zones)
        }.sorted {
            let lhsOffset = TimeZone(identifier: $0.id)?.secondsFromGMT(for: date) ?? 0
            let rhsOffset = TimeZone(identifier: $1.id)?.secondsFromGMT(for: date) ?? 0
            if lhsOffset != rhsOffset { return lhsOffset < rhsOffset }
            return $0.label.localizedStandardCompare($1.label) == .orderedAscending
        }
    }

    func identifier(selection: String, search: String, current: String = TimeZone.current.identifier) -> String {
        let matches = matching(search)
        if matches.contains(selection) { return selection }
        if matches.contains(current) { return current }
        return matches.first ?? identifiers[0]
    }

    // Compare all stored future transitions and the recurring TZif footer, rather
    // than sampling a few dates. Historical differences before the event do not
    // create duplicate choices. Unknown formats conservatively remain separate.
    // Format: https://www.rfc-editor.org/rfc/rfc9636.html
    private static func futureRules(_ identifier: String, date: Date) -> String? {
        guard let zone = NSTimeZone(name: identifier) else { return nil }
        let bytes = Array(zone.data)
        func uint(_ offset: Int, _ size: Int) -> UInt64 {
            bytes[offset..<(offset + size)].reduce(0) { ($0 << 8) | UInt64($1) }
        }
        func header(_ offset: Int) -> [Int]? {
            guard offset >= 0, offset + 44 <= bytes.count,
                  Array(bytes[offset..<(offset + 4)]) == [84, 90, 105, 102] else { return nil }
            return (0..<6).map { Int(uint(offset + 20 + $0 * 4, 4)) }
        }
        func blockSize(_ counts: [Int], width: Int) -> Int {
            counts[3] * (width + 1) + counts[4] * 6 + counts[5]
                + counts[2] * (width + 4) + counts[0] + counts[1]
        }
        guard let first = header(0), [50, 51, 52].contains(bytes[4]) else { return nil }
        let second = 44 + blockSize(first, width: 4)
        guard let counts = header(second), counts[4] > 0, counts[2] == 0 else { return nil }
        let start = second + 44
        let end = start + blockSize(counts, width: 8)
        guard end < bytes.count else { return nil }
        let types = start + counts[3] * 9
        var rules = ["\(zone.secondsFromGMT(for: date)):\(zone.isDaylightSavingTime(for: date))"]
        var previous = rules[0]
        for index in 0..<counts[3] {
            let instant = Int64(bitPattern: uint(start + index * 8, 8))
            guard Double(instant) > date.timeIntervalSince1970 else { continue }
            let type = Int(bytes[start + counts[3] * 8 + index])
            guard type < counts[4] else { return nil }
            let offset = Int32(bitPattern: UInt32(uint(types + type * 6, 4)))
            let rule = "\(offset):\(bytes[types + type * 6 + 4] != 0)"
            if rule != previous { rules.append("\(instant):\(rule)"); previous = rule }
        }
        rules.append(String(decoding: bytes[end...], as: UTF8.self))
        return rules.joined(separator: "|")
    }

    func matching(_ search: String) -> [String] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        if query.isEmpty || label.localizedCaseInsensitiveContains(query) { return identifiers }
        return identifiers.filter {
            $0.replacingOccurrences(of: "_", with: " ").localizedCaseInsensitiveContains(query)
                || $0.localizedCaseInsensitiveContains(query)
        }
    }
}

struct TimeZonePicker: View {
    @Binding var selection: String
    var date = Date()
    @State private var search = ""
    @State private var choices: [TimeZoneChoice] = []
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        DaybookList {
            Button("Unspecified") { selection = ""; dismiss() }
            ForEach(choices) { choice in
                let matches = choice.matching(search)
                if !matches.isEmpty {
                    Button { select(choice.identifier(selection: selection, search: search)) } label: {
                        choiceLabel(choice.label, selected: choice.identifiers.contains(selection))
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Search timezones or cities")
        .navigationTitle("Timezone")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: date) { choices = TimeZoneChoice.grouped(date: date) }
    }

    private func select(_ zone: String) {
        selection = zone
        dismiss()
    }

    private func choiceLabel(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            if selected { Image(systemName: "checkmark").accessibilityLabel("Selected") }
        }
    }
}

private struct LinkPresentation: Identifiable { let id = UUID(); let session: WorkSession? }

struct JobDetailView: View {
    @EnvironmentObject private var calendar: CalendarController
    @ObservedObject var job: Job
    @FetchRequest(sortDescriptors: []) private var eventRecords: FetchedResults<WorkEvent>
    @Environment(\.managedObjectContext) private var context
    @State private var error: String?
    @State private var editing = false
    @State private var duplicating = false
    @State private var batch = false
    @State private var addingSession = false
    @State private var addingInvoice = false
    @State private var addingPayment = false
    @State private var choosingLinkSession = false
    @State private var linkEditor: LinkPresentation?
    var body: some View {
        let _ = eventRecords.count
        DaybookForm(title: job.eventTitle, subtitle: job.client?.name ?? "Client to add") {
            Section {
                Menu {
                    ForEach(BookingStatus.allCases, id: \.self) { status in Button(status.title) { updateBookingStatus(status) } }
                } label: { HStack { BookingBadge(status: job.bookingStatus); Text("Change status"); Spacer(); Image(systemName: "chevron.down") } }
                .accessibilityIdentifier("booking-status")
                Button { editing = true } label: { DaybookMetadata(symbol: "calendar", text: dateRange(job)) }.accessibilityIdentifier("edit-event-dates")
                if !job.eventTimeZoneID.isEmpty { DaybookMetadata(symbol: "globe", text: "Event timezone: " + zoneLabel(job.eventTimeZoneID, date: Day.date(from: job.eventStartDay) ?? Date())) }
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
                if job.hasWorkTimeZone { DaybookMetadata(symbol: "globe", text: "Your timezone: " + zoneLabel(job.workTimeZoneID, date: Day.date(from: job.eventStartDay) ?? Date())) }
                if !["completed", "cancelled"].contains(job.bookingStatus) {
                    Button(job.bookingStatus == "tentative" ? "Mark as booked" : "Mark completed") { updateBookingStatus(job.bookingStatus == "tentative" ? .booked : .completed) }.accessibilityIdentifier("advance-booking-status")
                }
            }
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
            Section("Calendar") {
                Text(job.bookingStatus == "cancelled" ? "Cancelled events have no calendar entries." : "The all-day placeholder stays alongside confirmed sessions you’re covering.")
                Text(calendar.status).font(.subheadline).foregroundStyle(Color("SecondaryText"))
            }
            Section {
                Button("Duplicate Event", systemImage: "plus.square.on.square") { duplicating = true }
                    .accessibilityIdentifier("duplicate-job")
            } footer: { Text("Create a new event with this client and fee. Existing sessions and payment history stay here.") }
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
