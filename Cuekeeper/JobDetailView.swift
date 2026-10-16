import CoreData
import SwiftUI

extension EventTab {
    var title: String { rawValue.capitalized }
}

extension EventTimeChoice {
    var title: String { self == .yours ? "Your time" : "Track" }
}

/// One client event: what needs settling, then Schedule, Money and Details.
struct JobDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.managedObjectContext) private var context
    @ObservedObject var job: Job
    // Related records change without publishing through the job; observing them keeps the summary current.
    @FetchRequest(sortDescriptors: []) private var eventRecords: FetchedResults<WorkEvent>
    @FetchRequest(sortDescriptors: []) private var invoices: FetchedResults<Invoice>
    @FetchRequest(sortDescriptors: []) private var invoiceRevisions: FetchedResults<InvoiceRevision>
    @FetchRequest(sortDescriptors: []) private var payments: FetchedResults<PaymentRecord>
    @FetchRequest private var sessions: FetchedResults<WorkSession>
    @FetchRequest private var expenses: FetchedResults<Expense>
    @FetchRequest private var feeRevisions: FetchedResults<FeeRevision>
    @SceneStorage private var storedTab: String
    @AppStorage("eventTimeDisplay") private var storedTime = ""
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var width: CGFloat = 0
    @StateObject private var weather = EventWeatherLoader()
    /// Columns replace tabs when the detail column itself is wide, not merely on regular size classes:
    /// an iPad showing the sidebar and agenda leaves too little room.
    private var wide: Bool { width >= 820 && !typeSize.isAccessibilitySize }
    @State private var error: String?
    @State private var editing = false
    @State private var confirmingDeletion = false
    @State private var duplicating = false
    @State private var batch = false
    @State private var addingSession = false
    @State private var addingInvoice = false
    @State private var addingPayment = false
    @State private var showingFee = false
    @State private var editingSession: WorkSession?
    @State private var reviewingExpense: Expense?
    @State private var scanningReceipt = false
    @State private var openedInvoice: Invoice?

    init(job: Job) {
        self.job = job
        _sessions = FetchRequest(sortDescriptors: [], predicate: NSPredicate(format: "job == %@", job))
        _expenses = FetchRequest(sortDescriptors: [], predicate: NSPredicate(format: "job == %@", job))
        _feeRevisions = FetchRequest(sortDescriptors: [], predicate: NSPredicate(format: "job == %@", job))
        _storedTab = SceneStorage(wrappedValue: "", "eventTab-\(job.id?.uuidString ?? job.objectID.uriRepresentation().absoluteString)")
    }

    var body: some View {
        let _ = (eventRecords.count, invoices.count, invoiceRevisions.count, payments.count, sessions.count, expenses.count, feeRevisions.count)
        let summary = EventDetailSummary(facts: EventDetailFacts(job: job, context: context), now: Date())
        let tab = EventTab(rawValue: storedTab) ?? summary.defaultTab
        let choice = summary.offersTimeChoice ? EventTimeChoice(rawValue: storedTime) ?? summary.defaultTimeChoice : .track
        ScrollView {
            // A pinned bar would cover most of the screen at accessibility sizes.
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: typeSize.isAccessibilitySize ? [] : [.sectionHeaders]) {
                Section {
                    VStack(alignment: .leading, spacing: 20) {
                        EventHeader(job: job, onStatus: updateBookingStatus, onEditDates: { editing = true })
                        OpenItemsPanel(items: summary.openItems, perform: perform)
                    }.padding(.bottom, 16)
                }
                if wide {
                    HStack(alignment: .top, spacing: 32) {
                        schedule(summary, choice: choice)
                            .frame(width: max(0, (min(width - 40, 1240) - 32) * 1.45 / 2.45))
                        VStack(alignment: .leading, spacing: 28) {
                            EventSectionTitle("Money")
                            money(summary)
                            EventSectionTitle("Details")
                            details
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                } else {
                Section {
                    Group {
                        switch tab {
                        case .schedule: schedule(summary, choice: choice)
                        case .money: money(summary)
                        case .details: details
                        }
                    }.padding(.top, 16)
                } header: {
                    DaybookSegments(title: "Event sections", selection: Binding(get: { tab }, set: { storedTab = $0.rawValue }),
                                    options: EventTab.allCases, identifier: "event-tab", label: { $0.title },
                                    badge: { summary.count(in: $0) })
                        .padding(.vertical, 4)
                        .background(Color("PageBackground"))
                }
                }
            }
            .frame(maxWidth: wide ? 1240 : 760)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .eventWeather(weather, request: job.weatherRequest)
        .accessibilityIdentifier("daybook-form")
        .daybookSurface()
        .saveErrorAlert($error)
        .navigationTitle("Event")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) { Button("Edit Event") { editing = true }.accessibilityIdentifier("edit-event") }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    Button("Duplicate Event", systemImage: "plus.square.on.square") { duplicating = true }
                    Button("Delete Event", systemImage: "trash", role: .destructive) { confirmingDeletion = true }
                } label: { Label("More", systemImage: "ellipsis") }
                    .accessibilityIdentifier("event-more")
            }
        }
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
        .navigationDestination(isPresented: $showingFee) { FeeDetailView(job: job) }
        .navigationDestination(item: $openedInvoice) { InvoiceDetailView(invoice: $0) }
        .sheet(isPresented: $editing) { JobEditorView(job: job) }
        .sheet(isPresented: $duplicating) { JobEditorView(job: job, duplicating: true) }
        .sheet(isPresented: $batch) { SessionBatchEditorView(anchor: job) }
        .sheet(isPresented: $addingSession) { SessionEditorView(job: job) }
        .sheet(isPresented: $addingInvoice) { InvoiceEditorView(job: job) }
        .sheet(isPresented: $addingPayment) { PaymentEditorView(job: job) }
        .sheet(isPresented: Binding(get: { editingSession != nil }, set: { if !$0 { editingSession = nil } })) {
            if let editingSession { SessionEditorView(job: job, session: editingSession) }
        }
        .sheet(item: $reviewingExpense) { ExpenseEditorView(job: job, expense: $0) }
        .sheet(isPresented: $scanningReceipt) { ExpenseEditorView(job: job) }
    }

    // MARK: Schedule

    @ViewBuilder private func schedule(_ summary: EventDetailSummary, choice: EventTimeChoice) -> some View {
        let zone = summary.zone(for: choice)
        VStack(alignment: .leading, spacing: 24) {
            if let next = summary.nextCall {
                NextCallPanel(next: next, zone: zone,
                              otherZone: summary.offersTimeChoice ? summary.zone(for: choice == .yours ? .track : .yours) : nil,
                              showsYourTime: choice == .yours, series: job.eventSeriesNames,
                              weather: weather.day(next.session.day, request: job.weatherRequest).map(WeatherFormat.headline))
            }
            VStack(alignment: .leading, spacing: 14) {
                EventSectionTitle(title: "Run of show") {
                    if summary.offersTimeChoice {
                        DaybookSegments(title: "Times shown in", selection: Binding(get: { choice }, set: { storedTime = $0.rawValue }),
                                        options: EventTimeChoice.allCases, identifier: "event-time", label: { $0.title })
                            .frame(maxWidth: 200)
                    }
                }
                if summary.days.isEmpty {
                    Text("No sessions yet. Event dates remain useful until the schedule arrives.")
                        .font(.subheadline).foregroundStyle(Color("SecondaryText"))
                }
                ForEach(summary.days) { day in
                    RunOfShowDayView(day: day, weather: weather.day(day.key, request: job.weatherRequest).map(WeatherFormat.headline)) { fact in
                        sessionRow(fact, zone: zone, trackZone: wide && choice == .yours ? summary.zone(for: .track) : nil)
                    }
                }
                HStack(spacing: 12) {
                    Button("Session", systemImage: "plus") { addingSession = true }
                        .buttonStyle(DaybookSecondaryButton())
                        .accessibilityLabel("Add Session").accessibilityIdentifier("add-session")
                    if !summary.days.isEmpty {
                        Button("Edit several", systemImage: "checklist") { batch = true }
                            .font(.subheadline).frame(minHeight: 44).accessibilityIdentifier("batch-sessions")
                    }
                }
            }
            WeatherStatusFooter(loader: weather, request: job.weatherRequest)
        }
    }

    @ViewBuilder private func sessionRow(_ fact: EventSessionFact, zone: TimeZone, trackZone: TimeZone?) -> some View {
        if let session = sessions.first(where: { $0.id == fact.id }) {
            HStack(spacing: 0) {
                NavigationLink { SessionDetailView(session: session) } label: { RunOfShowRow(session: fact, zone: zone, trackZone: trackZone, eventSeries: job.eventSeriesNames) }
                    .buttonStyle(.plain)
                    .accessibilityHint("Opens the session")
                if fact.start == nil && fact.coverage != "notCovering" {
                    Button("Add time") { editingSession = session }
                        .font(.subheadline.weight(.semibold)).frame(minHeight: 44).padding(.trailing, 14)
                }
            }
        } else {
            RunOfShowRow(session: fact, zone: zone)
        }
    }

    // MARK: Money

    @ViewBuilder private func money(_ summary: EventDetailSummary) -> some View {
        let fee: EventFeeFact = (try? job.currentFee()).map(EventFeeFact.value) ?? .conflict
        VStack(alignment: .leading, spacing: 24) {
            NavigationLink { FeeDetailView(job: job) } label: {
                MoneySummaryPanel(fee: fee, progress: summary.invoiceProgress, chevron: true)
                    .foregroundStyle(Color.primary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .eventPanel()
            .accessibilityHint("Opens the fee and breakdown")
            .accessibilityIdentifier("job-fee")
            DaybookSections {
                JobBillingSection(job: job, onInvoice: { addingInvoice = true }, onPayment: { addingPayment = true })
                EventExpensesSection(job: job) { expense in
                    if let expense { reviewingExpense = expense } else { scanningReceipt = true }
                }
            }
        }
    }

    // MARK: Details

    private var details: some View {
        DaybookSections {
            Section {
                if let client = job.client {
                    DaybookLink { LibraryDetailView(record: client, kind: .client) } label: { LabeledContent("Client", value: client.name) }
                } else {
                    Button("Add client") { editing = true }
                }
                LabeledContent("Role", value: job.roleNames.isEmpty ? "None" : job.roleNames.joined(separator: ", "))
                LabeledContent("Working", value: workDescription)
                LabeledContent("Event timezone", value: zoneLabel(TimeZone.effective(job.eventTimeZoneID).identifier, date: eventDate))
                if !job.eventLocation.isEmpty { LabeledContent("Location", value: job.eventLocation) }
            }
            if !job.eventTrackPlaceID.isEmpty {
                Section("Track location") { SavedTrackView(placeID: job.eventTrackPlaceID) }
            }
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
            if !job.eventNotes.isEmpty { Section("Event notes") { Text(job.eventNotes).textSelection(.enabled) } }
            if !job.notes.isEmpty { Section("Previous booking notes") { Text(job.notes).textSelection(.enabled) } }
            Section {
                Button("Duplicate Event", systemImage: "plus.square.on.square") { duplicating = true }
                    .accessibilityIdentifier("duplicate-job")
            } footer: { Text("Create a new event with this client and fee. Existing sessions and payment history stay here.") }
            Section {
                Button("Delete Event", systemImage: "trash", role: .destructive) { confirmingDeletion = true }
                    .accessibilityIdentifier("delete-job")
            }
        }
    }

    private var eventDate: Date { Day.date(from: job.eventStartDay) ?? Date() }

    private var workDescription: String {
        let arrangement = WorkArrangement(rawValue: job.workArrangement) ?? .unspecified
        guard job.hasWorkTimeZone, let work = TimeZone(identifier: job.workTimeZoneID) else { return arrangement.title }
        let event = TimeZone.effective(job.eventTimeZoneID)
        let place = job.location.isEmpty ? arrangement.title : "\(arrangement.title) from \(job.location)"
        let offset = EventTimeText.offset(of: work, from: event, at: eventDate)
        return ([place, EventTimeText.abbreviation(work, at: eventDate)] + (offset.map { [$0] } ?? [])).joined(separator: " · ")
    }

    // MARK: Actions

    private func perform(_ item: OpenItem) {
        switch item.action {
        case .markBooked: updateBookingStatus(.booked)
        case .editSession(let id): editingSession = sessions.first { $0.id == id }
        case .editEvent: editing = true
        case .openFee: showingFee = true
        case .addToInvoice: addingInvoice = true
        case .openInvoice(let id): openedInvoice = invoices.first { $0.id == id }
        case .reviewBilling(let id):
            if let invoice = id.flatMap({ id in invoices.first { $0.id == id } }) { openedInvoice = invoice } else { storedTab = EventTab.money.rawValue }
        case .reviewExpense(let id): reviewingExpense = expenses.first { $0.id == id }
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
