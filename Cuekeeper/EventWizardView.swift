import CoreData
import SwiftUI

private enum EventWizardStep: String, CaseIterable, Hashable {
    case setup = "New event", events = "Events", context = "Client, project & series", sessions = "Session times", work = "Role & location", payment = "Fee & payment", review = "Review"
    static let optional: [Self] = [.context, .sessions, .work, .payment]
}

struct EventWizardView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Client.name, ascending: true)]) private var clients: FetchedResults<Client>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \WorkRole.name, ascending: true)]) private var roles: FetchedResults<WorkRole>
    let onSave: ((NSManagedObjectID) -> Void)?
    @State private var choosingTrack = false
    @State private var draft: EventCreationDraft
    @State private var inactiveDraft: EventCreationDraft
    @State private var initialDraft: EventCreationDraft
    @State private var initialInactiveDraft: EventCreationDraft
    @State private var initialSelected: Set<EventWizardStep>
    @State private var season = false
    @State private var selected: Set<EventWizardStep> = []
    @State private var path: [EventWizardStep] = []
    @State private var error: String?
    @State private var discard = false
    @State private var newRole = ""
    @State private var pastedTitles = ""
    @State private var editingEvent: UUID?
    @State private var sessionEvent = 0
    @State private var activeSession: Int?
    @State private var copyExpanded = false
    @State private var copyTimes = false
    @State private var copyTargets: Set<UUID> = []
    @State private var copyNotice = ""
    @State private var breakdown = false
    private var route: [EventWizardStep] { [.setup] + (season ? [.events] : []) + EventWizardStep.optional.filter { selected.contains($0) } + [.review] }
    private var workDate: Date { draft.events.map(\.details.startDate).min() ?? Date() }
    private var fee: Binding<FeeDraft> { Binding(get: { draft.shared.fee ?? FeeDraft() }, set: { draft.shared.fee = $0 }) }

    init(template: Job? = nil, onSave: ((NSManagedObjectID) -> Void)? = nil) {
        self.onSave = onSave
        var initial = EventCreationDraft()
        var initialSteps: Set<EventWizardStep> = []
        if let template {
            var value = EventCreationDraft()
            value.shared = JobDraft.duplicate(template)
            value.shared.location = template.eventLocation
            value.shared.trackPlaceID = template.eventTrackPlaceID
            value.events[0].timeZoneID = template.eventTimeZoneID
            value.events[0].details.name = template.eventTitle
            initial = value
            initialSteps = [.context, .work, .payment]
        }
        #if DEBUG
        let args = ProcessInfo.processInfo.arguments
        if DesignFixtures.enabled, args.contains("--design-multiday-event") {
            var sample = EventCreationDraft()
            sample.events[0].details.startDate = Day.date(from: "2026-10-16")!
            sample.events[0].details.endDate = Day.date(from: "2026-10-18")!
            initial = sample
        }
        if args.contains("--ui-testing"), args.contains("--wizard-populated-review") || args.contains("--wizard-foreign-session") || args.contains("--wizard-timezone-preview") {
            var sample = EventCreationDraft()
            sample.shared.clientName = "Northside Sports"
            sample.shared.projectName = "Winter broadcasts"
            sample.shared.roleNames = ["Commentator"]
            sample.shared.workArrangement = .onSite
            sample.shared.location = "Silverstone Circuit"
            sample.events[0].timeZoneID = "Asia/Tokyo"
            sample.shared.fee?.amount = "1200"
            sample.events[0].details.startDate = Day.date(from: "2026-01-15")!
            sample.events[0].details.endDate = sample.events[0].details.startDate
            sample.events[0].sessions = [SessionDraft(day: "2026-01-15", timeZoneID: "Asia/Tokyo")]
            initial = sample
            initialSteps = Set(EventWizardStep.optional)
            _path = State(initialValue: args.contains("--wizard-foreign-session") ? [.sessions] : [.review])
            _activeSession = State(initialValue: args.contains("--wizard-foreign-session") ? 0 : nil)
            if args.contains("--wizard-timezone-preview") {
                sample.events[0].timeZoneID = "Europe/Paris"
                sample.events[0].sessions = []
                initial = sample
                _path = State(initialValue: [.sessions])
            }
        }
        #endif
        let inactive = EventCreationDraft()
        _draft = State(initialValue: initial)
        _inactiveDraft = State(initialValue: inactive)
        _initialDraft = State(initialValue: initial)
        _initialInactiveDraft = State(initialValue: inactive)
        _selected = State(initialValue: initialSteps)
        _initialSelected = State(initialValue: initialSteps)
    }

    private var hasChanges: Bool {
        // Each mode keeps its own draft, including edits hidden by switching modes.
        (season ? inactiveDraft : draft) != initialDraft
            || (season ? draft : inactiveDraft) != initialInactiveDraft
            || season || selected != initialSelected
            || !newRole.isEmpty || !pastedTitles.isEmpty
    }

    var body: some View {
        NavigationStack(path: $path) {
            page(.setup)
                .navigationDestination(for: EventWizardStep.self) { page($0) }
        }
        .presentationSizing(.page).presentationDetents([.large])
        .presentationBackground(Color("PageBackground"))
        .interactiveDismissDisabled()
        .onChange(of: season) { _, _ in
            let previous = draft; draft = inactiveDraft; inactiveDraft = previous
            sessionEvent = 0; activeSession = nil; copyTargets = []; copyExpanded = false; copyNotice = ""
        }
        .onChange(of: draft.shared.clientName) { _, name in
            if fee.wrappedValue.amount.isEmpty, fee.wrappedValue.lines.isEmpty, draft.payment.amount.isEmpty,
               let client = clients.first(where: { $0.name == name }) { draft.shared.fee?.currency = client.defaultCurrency }
        }
        .sheet(isPresented: $choosingTrack) { TrackLocationPicker(placeID: $draft.shared.trackPlaceID) }
        .saveErrorAlert($error)
        .sheet(item: Binding(get: { editingEvent.map(EventEditID.init) }, set: { editingEvent = $0?.id })) { item in
            if let index = draft.events.firstIndex(where: { $0.id == item.id }) {
                NavigationStack {
                    DaybookForm {
                        Section("Event") { DaybookTextField("Title (optional)", text: $draft.events[index].details.name); EventDateFields(draft: $draft.events[index].details); EventTimeZoneField(selection: $draft.events[index].timeZoneID, date: draft.events[index].details.startDate) }
                        if season { Section("Series") {
                            Toggle("Use shared series", isOn: Binding(get: { draft.events[index].usesSharedSeries }, set: { shared in
                                if !shared && !draft.events[index].seriesOverrideInitialized {
                                    draft.events[index].details.seriesNames = draft.shared.seriesNames
                                    draft.events[index].seriesOverrideInitialized = true
                                }
                                draft.events[index].usesSharedSeries = shared
                            }))
                            if draft.events[index].usesSharedSeries { Text(draft.shared.seriesNames.sorted().joined(separator: ", ")) }
                            else { SeriesSelectionFields(names: $draft.events[index].details.seriesNames) }
                        }
                        }
                        Section("Location") { LocationSearchField(text: $draft.events[index].details.location) }
                        if draft.events.count > 1 { Section { Button("Remove Event", role: .destructive) { draft.events.remove(at: index); sessionEvent = 0; activeSession = nil; editingEvent = nil } } }
                    }
                    .navigationTitle("Edit event").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { editingEvent = nil } } }
                }.presentationSizing(.page)
            }
        }
    }

    private func page(_ current: EventWizardStep) -> some View {
        DaybookForm(title: current == .setup ? "" : current.rawValue) {
            switch current {
            case .setup: setup
            case .events: eventsPage
            case .context: contextPage
            case .sessions: sessionsPage
            case .work: workPage
            case .payment: paymentPage
            case .review: reviewPage
            }
        }
        .navigationTitle(season ? "New events" : "New event").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Cancel") {
                    if hasChanges { discard = true } else { dismiss() }
                }
                    .confirmationDialog("Discard this event draft?", isPresented: $discard, titleVisibility: .visible) {
                        Button("Discard Draft", role: .destructive) { dismiss() }
                        Button("Keep Editing", role: .cancel) {}
                    }
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text("Step \((route.firstIndex(of: current) ?? 0) + 1) of \(route.count)")
                    .font(.subheadline).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Button(current == .review ? (season && draft.events.count > 1 ? "Create \(draft.events.count) events" : "Create event") : (current == .setup && season ? "Add events" : "Continue")) {
                    if current == .review { save() } else { advance(from: current) }
                }.buttonStyle(DaybookPrimaryButton()).controlSize(.large).accessibilityIdentifier("wizard-continue")
            }.padding().background(.bar)
        }
    }

    @ViewBuilder private var setup: some View {
        Section {
            if typeSize.isAccessibilitySize {
                DaybookPicker("Create", selection: $season) { Text("One event").tag(false); Text("Season / multiple events").tag(true) }
            } else {
                Picker("Create", selection: $season) { Text("One event").tag(false); Text("Season / multiple events").tag(true) }.pickerStyle(.segmented)
            }
            if !season {
                DaybookTextField("Title (optional)", text: $draft.events[0].details.name).accessibilityIdentifier("job-name")
                EventDateFields(draft: $draft.events[0].details)
                EventTimeZoneField(selection: $draft.events[0].timeZoneID, date: draft.events[0].details.startDate)
            }
        }
        Section("Add details") {
            ForEach(EventWizardStep.optional, id: \.self) { item in
                Toggle(item.rawValue, isOn: Binding(get: { selected.contains(item) }, set: { if $0 { selected.insert(item) } else { selected.remove(item) } }))
            }
        }
    }
    @ViewBuilder private var eventsPage: some View {
        Section {
            Button("Add event", systemImage: "plus") { let event = EventOutline(); draft.events.append(event); editingEvent = event.id }
            eventRows
        } header: { Text("Season calendar") }
        Section {
            DisclosureGroup("Paste event titles") {
                DaybookTextField("One event per line", text: $pastedTitles, axis: .vertical).lineLimit(3...8)
                Button("Add events") {
                    for line in pastedTitles.split(separator: "\n") {
                        let name = line.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !name.isEmpty { var event = EventOutline(); event.details.name = name; draft.events.append(event) }
                    }
                    pastedTitles = ""
                }.disabled(pastedTitles.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
    }
    @ViewBuilder private var contextPage: some View {
        Section("Client & project") {
            LibraryTypeaheadField(title: "Client", prompt: "Search or enter client", text: $draft.shared.clientName,
                                  savedNames: clients.map(\.name), identifier: "job-client")
            NamedLibraryField(kind: .project, name: $draft.shared.projectName)
        }
        Section(season ? "Shared series" : "Series") { SeriesSelectionFields(names: $draft.shared.seriesNames) }
        Section {
            DaybookChoicePicker("Booking", selection: $draft.shared.bookingStatus, identifier: "wizard-booking") {
                Text("Tentative").tag(BookingStatus.tentative)
                Text("Booked").tag(BookingStatus.booked)
            }
            if !season { LabeledContent("Event title", value: draft.resolvedEvents()[0].displayTitle) }
        }
    }
    @ViewBuilder private var sessionsPage: some View {
        if season {
            Section {
                DaybookPicker("Event", selection: $sessionEvent) {
                    ForEach(draft.events.indices, id: \.self) { Text(draft.resolvedEvents()[$0].displayTitle).tag($0) }
                }.onChange(of: sessionEvent) { _, _ in activeSession = nil; copyTargets = []; copyExpanded = false; copyNotice = "" }
            }
        }
        Section {
            EventTimeZoneField(selection: $draft.events[sessionEvent].timeZoneID, date: draft.events[sessionEvent].details.startDate)
        } footer: { Text("All sessions use this event timezone. Changing it preserves existing scheduled instants.") }
        ForEach(draft.events[sessionEvent].sessions.indices, id: \.self) { index in
            Section {
                Button {
                    activeSession = activeSession == index ? nil : index
                } label: {
                    HStack { Text(draft.events[sessionEvent].sessions[index].name.isEmpty ? "Session \(index + 1)" : draft.events[sessionEvent].sessions[index].name); Spacer(); Image(systemName: activeSession == index ? "chevron.up" : "chevron.down") }
                }
                if activeSession == index {
                    WizardSessionFields(draft: $draft.events[sessionEvent].sessions[index], eventTimeZoneID: draft.events[sessionEvent].timeZoneID)
                    Button("Remove session", role: .destructive) { draft.events[sessionEvent].sessions.remove(at: index); activeSession = nil }
                }
            }
        }
        Section {
            Button("Add session", systemImage: "plus") {
                draft.events[sessionEvent].sessions.append(SessionDraft(day: Day.string(from: draft.events[sessionEvent].details.startDate), timeZoneID: draft.events[sessionEvent].timeZoneID))
                activeSession = draft.events[sessionEvent].sessions.count - 1
            }
            if season && draft.events.count > 1 {
                DisclosureGroup("Copy sessions to other events", isExpanded: $copyExpanded) {
                    ForEach(draft.resolvedEvents().filter { $0.id != draft.events[sessionEvent].id }) { event in
                        Toggle(event.displayTitle, isOn: Binding(get: { copyTargets.contains(event.id) }, set: { if $0 { copyTargets.insert(event.id) } else { copyTargets.remove(event.id) } }))
                    }
                    Toggle("Include session times", isOn: $copyTimes)
                    Text("Copies use each destination event’s timezone and retain local clock times. They are added as tentative, with coverage undecided.").font(.caption).foregroundStyle(.secondary)
                    Button("Copy sessions") {
                        do {
                            try draft.copySessions(from: draft.events[sessionEvent].id, to: copyTargets, includingTimes: copyTimes)
                            copyNotice = copyTargets.count == 1 ? "Sessions copied to 1 event." : "Sessions copied to \(copyTargets.count) events."; copyExpanded = false; copyTargets = []
                        } catch { self.error = error.localizedDescription }
                    }.disabled(copyTargets.isEmpty || draft.events[sessionEvent].sessions.isEmpty)
                }
                if !copyNotice.isEmpty { Text(copyNotice).foregroundStyle(.secondary) }
            }
        }
    }
    @ViewBuilder private var workPage: some View {
        Section("Roles") {
            ForEach(Array(Set(roles.map(\.name)).union(draft.shared.roleNames)).sorted(), id: \.self) { name in
                Toggle(name, isOn: Binding(get: { draft.shared.roleNames.contains(name) }, set: { if $0 { draft.shared.roleNames.insert(name) } else { draft.shared.roleNames.remove(name) } }))
            }
            HStack {
                DaybookTextField("New role", text: $newRole)
                Button("Add") { let name = newRole.trimmingCharacters(in: .whitespacesAndNewlines); if !name.isEmpty { draft.shared.roleNames.insert(name); newRole = "" } }.disabled(newRole.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        Section {
            DaybookPicker("Arrangement", selection: $draft.shared.workArrangement, identifier: "work-arrangement") { ForEach(WorkArrangement.allCases, id: \.self) { Text($0.title).tag($0) } }
            LocationSearchField(text: $draft.shared.location)
            if !draft.shared.trackPlaceID.isEmpty { SavedTrackView(placeID: draft.shared.trackPlaceID) }
            Button(draft.shared.trackPlaceID.isEmpty ? "Choose track location" : "Change track location", systemImage: "mappin.and.ellipse") { choosingTrack = true }.accessibilityIdentifier("choose-track")
            if !draft.shared.trackPlaceID.isEmpty { Button("Remove track location", role: .destructive) { draft.shared.trackPlaceID = "" } }
            WorkTimeZoneField(draft: $draft.shared, date: workDate)
        } header: { Text("Where you’ll work") } footer: {
            if season { Text("Timezone offsets are shown for the first event, \(workDate.formatted(date: .abbreviated, time: .omitted)). Sessions use their event’s timezone.") }
        }
    }
    @ViewBuilder private var paymentPage: some View {
        Section {
            FeeFields(draft: fee)
        } header: { Text(season ? "Fee per event" : "Overall fee") } footer: { Text("Enter 0 only for explicitly unpaid work. Empty means unknown.") }
        Section {
            Toggle("Provide fee breakdown", isOn: $breakdown)
            if breakdown { FeeBreakdownFields(draft: fee) }
            else if !fee.wrappedValue.lines.isEmpty { Text("Your breakdown is retained.").font(.caption).foregroundStyle(.secondary) }
        }
        if !season {
            Section("Payment received") {
                DaybookTextField("Amount received", text: $draft.payment.amount).keyboardType(.decimalPad)
                if !draft.payment.amount.isEmpty { DatePicker("Received", selection: $draft.payment.date, displayedComponents: .date) }
            }
        }
    }
    @ViewBuilder private var reviewPage: some View {
        Section(season ? "Event calendar" : "Event") { eventRows }
        Section("Summary") {
            WizardSummaryRow("Booking", value: draft.shared.bookingStatus.title)
            if !draft.shared.clientName.isEmpty { WizardSummaryRow("Client", value: draft.shared.clientName) }
            if !draft.shared.projectName.isEmpty { WizardSummaryRow("Project", value: draft.shared.projectName) }
            if !draft.shared.seriesNames.isEmpty { WizardSummaryRow("Series", value: draft.shared.seriesNames.sorted().joined(separator: ", ")) }
            if !draft.shared.roleNames.isEmpty || draft.shared.workArrangement != .unspecified || !draft.shared.location.isEmpty {
                Button {
                    selected.insert(.work); path = Array(route.dropFirst().prefix { $0 != .work }) + [.work]
                } label: {
                    WizardSummaryRow("Work", value: (draft.shared.roleNames.sorted() + (draft.shared.workArrangement == .unspecified ? [] : [draft.shared.workArrangement.title]) + (draft.shared.location.isEmpty ? [] : [draft.shared.location])).joined(separator: " · "))
                }.buttonStyle(.plain).accessibilityHint("Edit role and location")
            }
            if draft.shared.workArrangement == .remote || draft.shared.workArrangement == .hybrid { WizardSummaryRow("Your timezone", value: zoneLabel(draft.shared.timeZoneID, date: workDate)) }
            let count = draft.events.reduce(0) { $0 + $1.sessions.count }
            if count > 0 { WizardSummaryRow("Sessions", value: "\(count)") }
            WizardSummaryRow(season ? "Fee per event" : "Fee", value: (try? fee.wrappedValue.value().amount).map { Money.format($0, currency: fee.wrappedValue.currency) } ?? "Unknown")
            if let total = try? FeeValue(lines: fee.wrappedValue.lines).total(), !fee.wrappedValue.lines.isEmpty,
               total != (try? Money.parse(fee.wrappedValue.amount)) { WizardSummaryRow("Breakdown total", value: Money.format(total, currency: fee.wrappedValue.currency)).foregroundStyle(Color("AmberText")) }
            if !season, let received = try? Money.parse(draft.payment.amount) { WizardSummaryRow("Received", value: Money.format(received, currency: fee.wrappedValue.currency)) }
        }
        Section {
            Menu("Edit details") {
                ForEach(EventWizardStep.optional, id: \.self) { item in
                    Button(item.rawValue) { selected.insert(item); path = Array(route.dropFirst().prefix { $0 != item }) + [item] }
                }
            }
            Button("Change setup") { path = [] }
        }
    }
    @ViewBuilder private var eventRows: some View {
        ForEach(draft.resolvedEvents()) { event in
            Button { editingEvent = event.id } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text(event.displayTitle).font(.headline).foregroundStyle(.primary)
                    Text(event.details.startDate.formatted(date: .abbreviated, time: .omitted) + (Day.string(from: event.details.startDate) == Day.string(from: event.details.endDate) ? "" : " – " + event.details.endDate.formatted(date: .abbreviated, time: .omitted))).foregroundStyle(.secondary)
                    Text("Event timezone: " + zoneLabel(event.timeZoneID, date: event.details.startDate)).font(.caption).foregroundStyle(.secondary)
                    if !event.details.seriesNames.isEmpty { Text(event.details.seriesNames.sorted().joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.buttonStyle(.plain).accessibilityHint("Edit event")
        }
    }
    private func advance(from current: EventWizardStep) {
        guard let index = route.firstIndex(of: current), index + 1 < route.count else { return }
        do {
            if current == .sessions {
                for event in draft.resolvedEvents() { for session in event.sessions { try session.validate() } }
            }
            if current == .payment {
                _ = try fee.wrappedValue.value()
                if !season, !draft.payment.amount.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    guard let amount = try Money.parse(draft.payment.amount), amount > 0 else { throw RecordError.invalid("Enter a positive received amount, or leave it empty.") }
                }
            }
            path.append(route[index + 1])
        } catch { self.error = error.localizedDescription }
    }
    private func save() {
        do {
            for (eventIndex, event) in draft.resolvedEvents().enumerated() {
                for (sessionIndex, session) in event.sessions.enumerated() {
                    do { try session.validate() } catch {
                        selected.insert(.sessions); sessionEvent = eventIndex; activeSession = sessionIndex
                        path = route.dropFirst().prefix { $0 != .sessions }.map { $0 } + [.sessions]
                        throw error
                    }
                }
            }
            do { _ = try fee.wrappedValue.value() } catch {
                selected.insert(.payment); breakdown = !fee.wrappedValue.lines.isEmpty
                path = route.dropFirst().prefix { $0 != .payment }.map { $0 } + [.payment]
                throw error
            }
            let ids = try draft.save(in: context); if let id = ids.first { onSave?(id) }; dismiss()
        } catch { self.error = error.localizedDescription }
    }
}
private struct EventEditID: Identifiable { let id: UUID }

struct FeeBreakdownFields: View {
    @Binding var draft: FeeDraft
    var body: some View {
        ForEach($draft.lines) { $line in
            VStack(alignment: .leading, spacing: 12) {
                DaybookTextField("Description", text: $line.description)
                DaybookTextField("Quantity", text: $line.quantity).keyboardType(.decimalPad)
                DaybookTextField("Rate", text: $line.rate).keyboardType(.numbersAndPunctuation)
                if let total = try? line.total() { LabeledContent("Line total", value: Money.format(total, currency: draft.currency)) }
                Button("Remove item", role: .destructive) { draft.lines.removeAll { $0.id == line.id } }
            }
        }
        Button("Add breakdown item", systemImage: "plus") { draft.lines.append(FeeLine()) }
        if !draft.lines.isEmpty, let total = try? FeeValue(lines: draft.lines).total() {
            LabeledContent("Breakdown total", value: Money.format(total, currency: draft.currency))
            Button("Use breakdown total as overall fee") { draft.amount = Money.text(total) }.disabled(total < 0)
        }
    }
}

struct WizardSummaryRow: View {
    let title: String
    let value: String
    @Environment(\.dynamicTypeSize) private var typeSize
    init(_ title: String, value: String) { self.title = title; self.value = value }
    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                Text(value).foregroundStyle(Color("SecondaryText")).fixedSize(horizontal: false, vertical: true)
            }.accessibilityElement(children: .combine)
        } else { LabeledContent(title, value: value) }
    }
}
