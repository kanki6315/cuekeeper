import CoreData
import SwiftUI

/// The landing tab: Now for the work in flight, Plan for settling and looking ahead.
struct UpcomingView: View {
    @Binding var path: NavigationPath
    var onShowAllEvents: () -> Void = {}

    @Environment(\.managedObjectContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass
    @EnvironmentObject private var persistence: PersistenceController
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Job.startDay, ascending: true)], predicate: NSPredicate(format: "deletedAt == nil")) private var jobs: FetchedResults<Job>
    // Related records change without publishing through the job; observing them keeps the summary current.
    @FetchRequest(sortDescriptors: []) private var events: FetchedResults<WorkEvent>
    @FetchRequest(sortDescriptors: []) private var sessions: FetchedResults<WorkSession>
    @FetchRequest(sortDescriptors: []) private var invoices: FetchedResults<Invoice>
    @FetchRequest(sortDescriptors: []) private var invoiceRevisions: FetchedResults<InvoiceRevision>
    @FetchRequest(sortDescriptors: []) private var payments: FetchedResults<PaymentRecord>
    @FetchRequest(sortDescriptors: []) private var feeRevisions: FetchedResults<FeeRevision>
    @FetchRequest(sortDescriptors: []) private var clients: FetchedResults<Client>
    @FetchRequest(sortDescriptors: [], predicate: NSPredicate(format: "isDraft == YES")) private var drafts: FetchedResults<Expense>
    @AppStorage(UpcomingView.modeKey) private var storedMode = ""
    @AppStorage(UpcomingView.modeSetKey) private var storedModeSet = ""
    @SceneStorage("upcoming.settleExpanded") private var settleExpanded = false
    @State private var sheet: UpcomingSheet?
    @State private var pendingCapture: Job?
    @State private var error: String?

    static let modeKey = "upcoming.mode"
    static let modeSetKey = "upcoming.modeSet"
    private static let openNow = "open-now"

    /// The Today widget opens Now whatever the user last chose.
    static func requestNow() {
        UserDefaults.standard.set(UpcomingMode.now.rawValue, forKey: modeKey)
        UserDefaults.standard.set(openNow, forKey: modeSetKey)
    }

    var body: some View {
        let _ = (events.count, sessions.count, invoices.count, invoiceRevisions.count, payments.count, feeRevisions.count, clients.count, drafts.count)
        TimelineView(.periodic(from: .now, by: 60)) { timeline in
            let summary = UpcomingSummary(jobs: UpcomingSummary.facts(jobs: Array(jobs), context: context),
                                          receipts: UpcomingSummary.receipts(Array(drafts)), now: timeline.date)
            page(summary, now: timeline.date)
        }
        .daybookSurface()
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar(sizeClass == .compact ? .hidden : .visible, for: .navigationBar)
        .sheet(item: $sheet, onDismiss: {
            if let job = pendingCapture { pendingCapture = nil; sheet = .capture(job) }
        }) { sheet in
            switch sheet {
            case .add:
                EventWizardView { id in
                    if let job = try? context.existingObject(with: id) as? Job { show(job) }
                }
            case .editEvent(let job): JobEditorView(job: job)
            case .session(let job, let session): SessionEditorView(job: job, session: session)
            case .invoice(let job): InvoiceEditorView(job: job)
            case .expense(let job, let expense): ExpenseEditorView(job: job, expense: expense)
            case .notes(let job): UpcomingNotesSheet(job: job) { self.sheet = nil; DispatchQueue.main.async { self.sheet = .editEvent(job) } }
            case .chooseCaptureEvent(let suggested):
                ExpenseEventSelection(suggested: suggested) { id in
                    pendingCapture = jobs.first { $0.objectID == id }
                    self.sheet = nil
                }
            case .capture(let job): ExpenseEditorView(job: job)
            }
        }
        .saveErrorAlert($error)
    }

    // MARK: Page

    private func mode(_ summary: UpcomingSummary) -> UpcomingMode {
        if storedModeSet == Self.openNow { return .now }
        guard storedModeSet == summary.inFlightKey, let mode = UpcomingMode(rawValue: storedMode) else { return summary.defaultMode }
        return mode
    }

    private func setMode(_ mode: UpcomingMode, _ summary: UpcomingSummary) {
        storedMode = mode.rawValue
        storedModeSet = summary.inFlightKey
    }

    private func page(_ summary: UpcomingSummary, now: Date) -> some View {
        let mode = mode(summary)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    header(summary)
                    if jobs.isEmpty {
                        emptyState
                    } else {
                        DaybookSegments(title: "Upcoming view", selection: Binding(get: { mode }, set: { setMode($0, summary) }),
                                        options: UpcomingMode.allCases, identifier: "upcoming-mode", label: { $0.title },
                                        badge: { $0 == .plan ? summary.items.count : 0 })
                        switch mode {
                        case .now: nowContent(summary, now: now)
                        case .plan: planContent(summary, proxy: proxy)
                        }
                    }
                }
                .padding(.horizontal, 20).padding(.top, 12).padding(.bottom, 24)
                .frame(maxWidth: 850).frame(maxWidth: .infinity)
            }
        }
        .accessibilityIdentifier("upcoming")
        .task(id: summary.inFlightKey) {
            // A widget request holds Now for the current set of in-flight jobs only.
            if storedModeSet == Self.openNow { storedModeSet = summary.inFlightKey }
        }
    }

    private func header(_ summary: UpcomingSummary) -> some View {
        DaybookTabHeader { if !jobs.isEmpty { actions(summary) } }
    }

    private func actions(_ summary: UpcomingSummary) -> some View {
        HStack(spacing: 8) {
            Button {
                sheet = .chooseCaptureEvent(summary.inFlight.compactMap { job($0.id) })
            } label: {
                Image(systemName: "doc.viewfinder").foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.glass).buttonBorderShape(.circle).controlSize(.large)
            .accessibilityLabel("Scan Receipt")
            .accessibilityIdentifier("scan-receipt-header")
            Button("Add Event", systemImage: "plus") { sheet = .add }
                .buttonStyle(DaybookPrimaryButton())
                .accessibilityIdentifier("add-job")
        }
    }

    private var emptyState: some View {
        VStack(spacing: 24) {
            CuekeeperMark().fill(Color.accentColor.opacity(0.2), style: FillStyle(eoFill: true))
                .frame(width: 90, height: 104).accessibilityHidden(true)
            Text("Your next event\nstarts here").font(.title2.bold())
            Text("Start with a date. Add the details when you know them.")
                .foregroundStyle(Color("SecondaryText"))
            if persistence.awaitingInitialImport {
                Label("Existing work may still arrive from iCloud. You can add an event now.", systemImage: "icloud.and.arrow.down")
                    .font(.subheadline).foregroundStyle(Color("SecondaryText"))
            }
            Button("Add your first event") { sheet = .add }
                .buttonStyle(LaunchPrimaryButton()).accessibilityIdentifier("add-job")
        }.multilineTextAlignment(.center).frame(maxWidth: 480).padding(.vertical, 48)
            .frame(maxWidth: .infinity)
    }

    // MARK: Now

    @ViewBuilder private func nowContent(_ summary: UpcomingSummary, now: Date) -> some View {
        if summary.inFlight.isEmpty {
            idle(summary)
        } else {
            VStack(alignment: .leading, spacing: 24) {
                if let next = summary.nextCall, let fact = summary.inFlight.first(where: { $0.id == next.jobID }) {
                    let remote = fact.facts.workZone != nil
                    NextCallPanel(next: next.call, zone: remote ? summary.displayZone : fact.facts.eventZone,
                                  otherZone: remote && summary.displayZone.identifier != fact.facts.eventZone.identifier ? fact.facts.eventZone : nil,
                                  showsYourTime: remote,
                                  subtitle: summary.inFlight.count > 1 || fact.client == nil ? fact.title : "\(fact.title) · \(fact.client!)")
                }
                if summary.inFlight.count == 1, let only = summary.inFlight.first {
                    singleJob(only)
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        EventSectionTitle(title: "In flight") {
                            Text(counted(summary.inFlight.count, "job", "jobs")).font(.subheadline).foregroundStyle(Color("SecondaryText"))
                        }
                        VStack(spacing: 0) {
                            ForEach(Array(summary.inFlight.enumerated()), id: \.element.id) { index, fact in
                                if index > 0 { EventPanelDivider() }
                                inFlightRow(fact)
                            }
                        }.eventPanel()
                    }
                    EventSectionTitle("Run of show")
                }
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(summary.days) { day in
                        RunOfShowDayView(day: day.runOfShow) { fact in
                            sessionRow(fact, in: day, multiple: summary.inFlight.count > 1)
                        }
                    }
                    if summary.days.isEmpty {
                        Text("Schedule to come. The dates stay on your daybook until sessions are added.")
                            .font(.subheadline).foregroundStyle(Color("SecondaryText"))
                    }
                }
                if let after = summary.afterThis {
                    Button { setMode(.plan, summary) } label: {
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(summary.inFlight.count > 1 ? "After these" : "After this").font(.footnote).foregroundStyle(Color("SecondaryText"))
                                Text(afterText(after)).font(.subheadline)
                            }.frame(maxWidth: .infinity, alignment: .leading)
                            Text("Plan").font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                        }
                        .padding(.horizontal, 16).padding(.vertical, 12)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain).eventPanel()
                    .accessibilityHint("Shows Plan")
                    .accessibilityIdentifier("upcoming-after-this")
                }
            }
        }
    }

    private func afterText(_ fact: UpcomingJobFact) -> AttributedString {
        var title = AttributedString(fact.title); title.font = .subheadline.weight(.semibold)
        var rest = AttributedString(" · " + UpcomingSummary.shortDay(fact.facts.startDay, zone: fact.facts.eventZone)
                                    + (fact.facts.bookingStatus == "tentative" ? " · tentative" : ""))
        rest.foregroundColor = Color("SecondaryText")
        return title + rest
    }

    private func idle(_ summary: UpcomingSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Nothing in the next 3 days.").font(.subheadline).foregroundStyle(Color("SecondaryText"))
            if let next = summary.nextWork {
                jobButton(next.job.id) {
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(next.daysUntil <= 1 ? (next.daysUntil == 0 ? "Next work today" : "Next work tomorrow") : "Next work in \(next.daysUntil) days")
                                .font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor)
                            Text(next.job.title).font(.title3.bold())
                            Text(nextWorkLine(next)).font(.subheadline).foregroundStyle(Color("SecondaryText"))
                            Text(([next.job.client ?? "Client to add"] + (next.job.work.isEmpty ? [] : [next.job.work])).joined(separator: " · "))
                                .font(.subheadline).foregroundStyle(Color("SecondaryText"))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color("SecondaryText")).accessibilityHidden(true)
                    }
                    .padding(16).contentShape(Rectangle())
                }
                .eventPanel()
                .accessibilityIdentifier("upcoming-next-work")
            } else {
                Text("No upcoming work yet. Add an event when the next booking arrives.").font(.subheadline)
            }
            Button { setMode(.plan, summary) } label: {
                HStack {
                    Text("See the next two weeks in \(Text("Plan").fontWeight(.semibold).foregroundStyle(Color.accentColor))")
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor).accessibilityHidden(true)
                }
                .font(.subheadline)
                .padding(.horizontal, 16).frame(minHeight: 48).contentShape(Rectangle())
            }
            .buttonStyle(.plain).eventPanel()
        }
    }

    private func nextWorkLine(_ next: UpcomingNextWork) -> String {
        let facts = next.job.facts
        let zone = facts.workZone == nil ? facts.eventZone : TimeZone.current
        var parts = [UpcomingSummary.shortDay(facts.startDay, zone: facts.eventZone)]
        if let first = next.first {
            parts.append(first.title)
            if let call = first.call { parts.append("call " + EventTimeText.time(call, in: zone)) }
            else if let start = first.start { parts.append(EventTimeText.time(start, in: zone)) }
        } else {
            parts.append("schedule to come")
        }
        return parts.joined(separator: " · ")
    }

    private func singleJob(_ fact: UpcomingJobFact) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            jobButton(fact.id) {
                HStack(spacing: 10) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(fact.title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
                        Text(([fact.client ?? "Client to add"] + (fact.work.isEmpty ? [] : [fact.work])).joined(separator: " · "))
                            .font(.subheadline).foregroundStyle(Color("SecondaryText"))
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color("SecondaryText")).accessibilityHidden(true)
                }.contentShape(Rectangle())
            }
            if let job = job(fact.id), hasNotes(job) {
                Button("Notes", systemImage: "note.text") { sheet = .notes(job) }
                    .buttonStyle(DaybookSecondaryButton())
                    .accessibilityLabel("Notes for \(fact.title)")
                    .accessibilityIdentifier("upcoming-notes")
            }
        }
    }

    private func inFlightRow(_ fact: UpcomingJobFact) -> some View {
        HStack(spacing: 6) {
            jobButton(fact.id) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fact.title).font(.body.weight(.semibold))
                    Text(([fact.client ?? "Client to add"] + (fact.work.isEmpty ? [] : [fact.work])).joined(separator: " · "))
                        .font(.subheadline).foregroundStyle(Color("SecondaryText"))
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            if let job = job(fact.id), hasNotes(job) {
                Button { sheet = .notes(job) } label: {
                    Image(systemName: "note.text").frame(width: 44, height: 44)
                        .background(Color.accentColor.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain).foregroundStyle(Color.accentColor)
                .accessibilityLabel("Notes for \(fact.title)")
            }
        }
        .padding(.leading, 16).padding(.trailing, 8).padding(.vertical, 6)
    }

    @ViewBuilder private func sessionRow(_ fact: EventSessionFact, in day: UpcomingDay, multiple: Bool) -> some View {
        let meta = day.rows.first { $0.id == fact.id }
        let zone = meta?.zone ?? TimeZone.current
        let abbreviation = meta?.showsZone == true ? fact.start.map { EventTimeText.abbreviation(zone, at: $0) } : nil
        let contextText = [multiple ? meta?.jobTitle : nil, abbreviation].compactMap { $0 }.joined(separator: " · ")
        VStack(spacing: 0) {
            if let gap = meta?.gapBefore, let meta {
                HStack(spacing: 6) {
                    Image(systemName: "clock").accessibilityHidden(true)
                    Text("\(Self.gapText(gap)) before \(meta.jobTitle)")
                }
                .font(.footnote).foregroundStyle(Color("SecondaryText"))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 6)
                .background(Color.accentColor.opacity(0.04))
            }
            HStack(spacing: 0) {
                let row = RunOfShowRow(session: fact, zone: zone, context: contextText.isEmpty ? nil : contextText)
                if let session = sessions.first(where: { $0.id == fact.id }), let job = session.job {
                    NavigationLink(value: ScheduleDestination.session(session.objectID)) { row }
                        .buttonStyle(.plain).accessibilityHint("Opens the session")
                    if fact.start == nil && fact.coverage != "notCovering" {
                        Button("Add time") { sheet = .session(job, session) }
                            .font(.subheadline.weight(.semibold)).frame(minHeight: 44).padding(.trailing, 14)
                    }
                } else {
                    row
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    static func gapText(_ interval: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short; formatter.allowedUnits = [.hour, .minute]; formatter.maximumUnitCount = 2
        return formatter.string(from: interval) ?? ""
    }

    // MARK: Plan

    private func planContent(_ summary: UpcomingSummary, proxy: ScrollViewProxy) -> some View {
        VStack(alignment: .leading, spacing: 28) {
            if !summary.items.isEmpty {
                SettlePanel(items: summary.items, summaryText: summary.categorySummary, expanded: $settleExpanded, perform: perform)
            }
            VStack(alignment: .leading, spacing: 10) {
                EventSectionTitle(title: "Next two weeks") {
                    if let first = summary.fortnight.first, let last = summary.fortnight.last {
                        Text("\(first.date.formatted(.dateTime.day().month(.abbreviated))) – \(last.date.formatted(.dateTime.day().month(.abbreviated)))")
                            .font(.subheadline).foregroundStyle(Color("SecondaryText"))
                    }
                }
                FortnightStrip(days: summary.fortnight) { day in
                    let entry = summary.comingUp.first { $0.job.facts.startDay <= day.key && $0.job.lastDay >= day.key }
                        ?? summary.comingUp.first { $0.job.facts.startDay >= day.key }
                    if let entry { withAnimation(.easeOut(duration: 0.25)) { proxy.scrollTo(entry.id, anchor: .top) } }
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                EventSectionTitle(title: "Coming up") {
                    Button("All events", action: onShowAllEvents).font(.subheadline.weight(.semibold))
                        .frame(minHeight: 44).accessibilityIdentifier("upcoming-all-events")
                }
                if summary.comingUp.isEmpty {
                    Text("Nothing booked in the next 30 days.").font(.subheadline).foregroundStyle(Color("SecondaryText"))
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(summary.comingUp.enumerated()), id: \.element.id) { index, entry in
                            if index > 0 { EventPanelDivider(leading: 76) }
                            comingUpRow(entry).id(entry.id)
                        }
                    }.eventPanel()
                }
            }
        }
    }

    private func comingUpRow(_ entry: ComingUpEntry) -> some View {
        jobButton(entry.job.id) {
            HStack(alignment: .top, spacing: 14) {
                DaybookDateRail(day: entry.job.facts.startDay)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.job.title).font(.headline)
                    Text(entry.summary).font(.subheadline).foregroundStyle(Color("SecondaryText"))
                    if entry.job.lastDay != entry.job.facts.startDay {
                        Text("Until " + UpcomingSummary.shortDay(entry.job.lastDay, zone: entry.job.facts.eventZone))
                            .font(.footnote).foregroundStyle(Color("SecondaryText"))
                    }
                }.frame(maxWidth: .infinity, alignment: .leading)
                if entry.openCount > 0 {
                    Text(entry.openCount, format: .number)
                        .font(.caption.weight(.bold)).monospacedDigit()
                        .foregroundStyle(Color("AmberText"))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .accessibilityLabel(counted(entry.openCount, "item to settle", "items to settle"))
                }
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color("SecondaryText")).accessibilityHidden(true)
            }
            .padding(.horizontal, 14).padding(.vertical, 14)
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier("coming-up-row")
    }

    // MARK: Navigation and actions

    private func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }

    private func hasNotes(_ job: Job) -> Bool { !job.eventNotes.isEmpty || !job.notes.isEmpty }

    private func show(_ job: Job) { path.append(ScheduleDestination.event(job.objectID)) }

    @ViewBuilder private func jobButton<Label: View>(_ id: UUID, @ViewBuilder label: () -> Label) -> some View {
        if let job = job(id) {
            NavigationLink(value: ScheduleDestination.event(job.objectID)) { label() }.buttonStyle(.plain)
        } else {
            label()
        }
    }

    private func perform(_ entry: UpcomingItem) {
        let target = entry.jobID.flatMap { job($0) }
        switch entry.item.action {
        case .markBooked: if let target { setStatus(target, .booked) }
        case .markCompleted: if let target { setStatus(target, .completed) }
        case .editSession(let id):
            if let target, let session = target.activeSessions.first(where: { $0.id == id }) { sheet = .session(target, session) }
        case .editEvent: if let target { sheet = .editEvent(target) }
        case .openFee: if let target { path.append(ScheduleDestination.fee(target.objectID)) }
        case .addToInvoice: if let target { sheet = .invoice(target) }
        case .openInvoice(let id): openInvoice(id, job: target)
        case .reviewBilling(let id):
            if let id { openInvoice(id, job: target) } else if let target { show(target) }
        case .reviewExpense(let id):
            if let expense = drafts.first(where: { $0.id == id }) { sheet = .expense(target, expense) }
        }
    }

    private func openInvoice(_ id: UUID, job: Job?) {
        if let invoice = invoices.first(where: { $0.id == id }) { path.append(ScheduleDestination.invoice(invoice.objectID)) }
        else if let job { show(job) }
    }

    private func setStatus(_ job: Job, _ status: BookingStatus) {
        let baseline = JobDraft(job: job)
        var draft = baseline
        draft.bookingStatus = status
        do { try draft.save(in: context, editing: job.objectID, baseline: baseline) }
        catch { self.error = error.localizedDescription }
    }
}

private enum UpcomingSheet: Identifiable {
    case add
    case editEvent(Job)
    case session(Job, WorkSession)
    case invoice(Job)
    case expense(Job?, Expense)
    case notes(Job)
    case chooseCaptureEvent([Job])
    case capture(Job)
    var id: String {
        switch self {
        case .add: "add"
        case .editEvent(let job): "edit-\(job.objectID)"
        case .session(_, let session): "session-\(session.objectID)"
        case .invoice(let job): "invoice-\(job.objectID)"
        case .expense(_, let expense): "expense-\(expense.objectID)"
        case .notes(let job): "notes-\(job.objectID)"
        case .chooseCaptureEvent: "choose-capture"
        case .capture(let job): "capture-\(job.objectID)"
        }
    }
}

// MARK: - To settle

struct SettlePanel: View {
    let items: [UpcomingItem]
    let summaryText: String
    @Binding var expanded: Bool
    let perform: (UpcomingItem) -> Void
    @ScaledMetric(relativeTo: .subheadline) private var iconSize = 28
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { expanded.toggle() }
            } label: {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("To settle").font(.headline)
                            Text(items.count, format: .number)
                                .font(.caption.weight(.bold)).monospacedDigit()
                                .foregroundStyle(Color("AmberText"))
                                .padding(.horizontal, 7).padding(.vertical, 2)
                                .background(Color.orange.opacity(0.18), in: Capsule())
                        }
                        if !expanded { Text(summaryText).font(.subheadline).foregroundStyle(Color("SecondaryText")) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                    if expanded { Text("Show less").font(.subheadline).foregroundStyle(Color.accentColor) }
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(expanded ? Color.accentColor : Color("SecondaryText"))
                        .accessibilityHidden(true)
                }
                .padding(.horizontal, 16).padding(.vertical, 12)
                .frame(minHeight: 56)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("To settle, \(items.count)")
            .accessibilityValue(expanded ? "Expanded" : summaryText)
            .accessibilityHint(expanded ? "Collapses the list" : "Shows every item")
            .accessibilityIdentifier("settle-toggle")
            EventPanelDivider()
            if expanded {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { EventPanelDivider(leading: 16 + iconSize + 10) }
                    row(item, showsDetail: true)
                }
            } else if let first = items.first {
                row(first, showsDetail: false)
            }
        }
        .padding(.bottom, 4)
        .eventPanel()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settle-panel")
    }

    @ViewBuilder private func row(_ entry: UpcomingItem, showsDetail: Bool) -> some View {
        let item = entry.item
        let tint = item.needsAttention ? Color("AmberText") : Color.accentColor
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            HStack(spacing: 10) {
                if showsDetail {
                    Image(systemName: item.symbol).font(.footnote.weight(.semibold)).foregroundStyle(tint)
                        .frame(width: iconSize, height: iconSize)
                        .background((item.needsAttention ? Color.orange.opacity(0.18) : Color.accentColor.opacity(0.1)), in: Circle())
                        .accessibilityHidden(true)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.subheadline.weight(.semibold))
                    if showsDetail, let context = entry.context { Text(context).font(.footnote).foregroundStyle(Color("SecondaryText")) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityElement(children: .combine)
            if item.isPrimary {
                Button(item.actionTitle) { perform(entry) }.buttonStyle(DaybookPrimaryButton()).controlSize(.small)
                    .accessibilityIdentifier("settle-item-\(item.kind.rawValue)")
            } else {
                Button(item.actionTitle) { perform(entry) }.font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("settle-item-\(item.kind.rawValue)")
            }
        }
        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 4)
    }
}

// MARK: - Two-week strip

struct FortnightStrip: View {
    let days: [StripDay]
    let select: (StripDay) -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorSchemeContrast) private var contrast
    private var weekdays: [String] {
        var calendar = Calendar.current; calendar.firstWeekday = 2
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) { ForEach(days) { cell($0).frame(width: 72) } }.padding(8)
                }.scrollIndicators(.hidden)
            } else {
                VStack(spacing: 2) {
                    HStack(spacing: 4) {
                        ForEach(Array(weekdays.enumerated()), id: \.offset) { _, symbol in
                            Text(symbol).font(.caption.weight(.semibold)).foregroundStyle(Color("SecondaryText")).frame(maxWidth: .infinity)
                        }
                    }.accessibilityHidden(true)
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 2) {
                        ForEach(days) { cell($0) }
                    }
                }.padding(8)
            }
        }
        .eventPanel()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Next two weeks")
        .accessibilityIdentifier("fortnight-strip")
    }

    private func cell(_ day: StripDay) -> some View {
        Button { select(day) } label: {
            VStack(spacing: 4) {
                Text(day.date.formatted(.dateTime.day()))
                    .font(.body.weight(day.isToday ? .bold : (day.marks.isEmpty ? .regular : .semibold))).monospacedDigit()
                    .foregroundStyle(day.isToday ? Color.accentColor : (day.marks.isEmpty || day.isPast ? Color("SecondaryText") : Color.primary))
                ForEach(Array(day.marks.prefix(3).enumerated()), id: \.offset) { _, mark in markView(mark, past: day.isPast) }
            }
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .top)
            .padding(.vertical, 4)
            .background(day.isToday ? Color.accentColor.opacity(0.06) : Color.clear, in: RoundedRectangle(cornerRadius: 10))
            .overlay { if day.isToday { RoundedRectangle(cornerRadius: 10).strokeBorder(Color.accentColor, lineWidth: 1.5) } }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label(day))
        .accessibilityHint(day.marks.isEmpty ? "" : "Shows the event")
    }

    @ViewBuilder private func markView(_ mark: StripMark, past: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 2)
        switch mark {
        case .covering: shape.fill(past ? Color("SecondaryText").opacity(0.5) : Color.accentColor).frame(width: 16, height: 4)
        case .notCovering: shape.strokeBorder(Color.primary.opacity(contrast == .increased ? 0.6 : 0.35), lineWidth: 1).frame(width: 16, height: 4)
        case .tbc: shape.strokeBorder(Color("AmberText"), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])).frame(width: 16, height: 5)
        }
    }

    private func label(_ day: StripDay) -> String {
        let date = day.date.formatted(.dateTime.weekday(.wide).day().month(.wide))
        let covering = day.marks.filter { $0 == .covering }.count
        let skipped = day.marks.filter { $0 == .notCovering }.count
        let tbc = day.marks.filter { $0 == .tbc }.count
        var parts = [day.isToday ? "Today, \(date)" : date]
        if day.marks.isEmpty { parts.append("no work") }
        if covering > 0 { parts.append("\(covering) covering") }
        if skipped > 0 { parts.append("\(skipped) not covering") }
        if tbc > 0 { parts.append("\(tbc) to confirm") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Notes

private struct UpcomingNotesSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var job: Job
    let onEdit: () -> Void
    var body: some View {
        NavigationStack {
            DaybookForm(title: job.eventTitle, subtitle: job.client?.name ?? "") {
                if !job.eventNotes.isEmpty { Section("Event notes") { Text(job.eventNotes).textSelection(.enabled) } }
                if !job.notes.isEmpty { Section("Previous booking notes") { Text(job.notes).textSelection(.enabled) } }
            }
            .navigationTitle("Notes").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button("Edit Event", action: onEdit) }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color("PageBackground"))
    }
}
