import CoreData
import SwiftUI

/// The guided invoice editor's pages. Choosing a client only appears when nothing chose one already.
enum InvoiceEditorStep: Equatable {
    case client, lines, record
}

/// Pick, then record: choose what the invoice bills, then record how it went out.
/// Each entry point hands over what it already knows, so most invoices open with their work ticked.
struct InvoiceEditorView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Client.name, ascending: true)]) private var clients: FetchedResults<Client>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Job.startDay, ascending: false)]) private var jobs: FetchedResults<Job>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Invoice.createdAt, ascending: false)]) private var invoices: FetchedResults<Invoice>
    @FetchRequest(sortDescriptors: []) private var invoiceRevisions: FetchedResults<InvoiceRevision>
    @FetchRequest(sortDescriptors: []) private var payments: FetchedResults<PaymentRecord>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Expense.createdAt, ascending: true)]) private var expenses: FetchedResults<Expense>
    @Environment(\.dynamicTypeSize) private var typeSize

    /// The saved invoice being edited. Becomes an open draft when the person adds to one.
    @State private var invoice: Invoice?
    @State private var step: InvoiceEditorStep
    @State private var draft: InvoiceDraft
    @State private var initial: InvoiceDraft
    @State private var amounts: [UUID: String]
    @State private var initialAmounts: [UUID: String]
    @State private var hasClient: Bool
    @State private var seeded = false
    @State private var referenceBasis: String?
    @State private var showsNotes = false
    /// Receipts on an open draft whose totals were corrected since they were added.
    @State private var refreshedReceipts = false
    @State private var search = ""
    @State private var details = InvoicingDraft()
    @State private var detailsBaseline = InvoicingDraft()
    @State private var error: String?
    @State private var discard = false
    private let startedAtClient: Bool
    /// The event the editor was opened from, named in the lines header.
    private let origin: (id: UUID, title: String)?

    /// A blank invoice, from Payments: starts by choosing a client.
    init() {
        let value = InvoiceDraft(clientID: UUID(), currency: UserDefaults.standard.string(forKey: "defaultCurrency") ?? "USD")
        self.init(draft: value, amounts: [:], step: .client, hasClient: false, origin: nil)
    }

    /// From an event: that event is ticked, with its receipts, and the rest of the client's work is offered.
    init(job: Job) {
        let fee = try? job.currentFee()
        var value = InvoiceDraft(clientID: job.client?.id ?? UUID(), currency: fee?.currency ?? UserDefaults.standard.string(forKey: "defaultCurrency") ?? "USD")
        var amounts: [UUID: String] = [:]
        if let id = job.id, job.client != nil {
            value.value.lines = [BilledLine(jobID: id, jobName: job.displayName, amount: fee?.amount ?? 0)]
            amounts[id] = Money.inputText(fee?.amount, currency: value.value.currency)
        }
        let origin = job.id.map { (id: $0, title: job.displayName) }
        self.init(draft: value, amounts: amounts, step: job.client == nil ? .client : .lines, hasClient: job.client?.id != nil, origin: origin)
    }

    /// From ready work: those events and the receipts offered for rebilling.
    /// A whole client group skips to recording; the readiness sheet opens on the lines.
    init(ready: ReadyInvoice, startsOnRecord: Bool = false) {
        var value = InvoiceDraft(clientID: ready.clientID, currency: ready.currency)
        var amounts: [UUID: String] = [:]
        value.value.lines = ready.jobs.compactMap { job in
            guard let id = job.id else { return nil }
            let amount = (try? job.currentFee().amount).flatMap { $0 }
            amounts[id] = Money.inputText(amount, currency: ready.currency)
            return BilledLine(jobID: id, jobName: job.displayName, amount: amount ?? 0)
        }
        let receipts = ready.expenses.compactMap { Self.billed($0) }
        value.value.expenseLines = receipts
        let origin = ready.jobs.count == 1 ? ready.jobs.first.flatMap { job in job.id.map { (id: $0, title: job.displayName) } } : nil
        self.init(draft: value, amounts: amounts, step: startsOnRecord && !value.value.lines.isEmpty ? .record : .lines, hasClient: true, origin: origin)
    }

    /// Editing a saved invoice, or reviewing one version of a conflicting edit.
    init(invoice: Invoice, draft: InvoiceDraft) {
        let amounts = Dictionary(draft.value.lines.map { ($0.jobID, Money.inputText($0.amount, currency: draft.value.currency)) }, uniquingKeysWith: { a, _ in a })
        self.init(draft: draft, amounts: amounts, step: .record, hasClient: true, origin: nil)
        _invoice = State(initialValue: invoice)
        _showsNotes = State(initialValue: !draft.value.notes.isEmpty)
    }

    private init(draft: InvoiceDraft, amounts: [UUID: String], step: InvoiceEditorStep, hasClient: Bool, origin: (id: UUID, title: String)?) {
        _draft = State(initialValue: draft); _initial = State(initialValue: draft)
        _amounts = State(initialValue: amounts); _initialAmounts = State(initialValue: amounts)
        _step = State(initialValue: step); _hasClient = State(initialValue: hasClient)
        startedAtClient = step == .client
        self.origin = origin
    }

    static func billed(_ expense: Expense) -> BilledExpense? {
        let value = expense.value
        guard let id = expense.id, let amount = try? Money.parse(value.amount, currency: value.currency) else { return nil }
        let day = Day.date(from: value.day)?.formatted(.dateTime.day().month(.abbreviated)) ?? value.day
        return BilledExpense(expenseID: id, label: [value.merchant, day].filter { !$0.isEmpty }.joined(separator: " · "), amount: amount)
    }

    // MARK: Derived state

    private var locked: Bool { invoice?.revisions?.contains { $0.value?.status == "sent" } ?? false }
    private var changed: Bool { draft != initial || amounts != initialAmounts }
    private var currency: String { draft.value.currency }
    private var client: Client? { hasClient ? clients.first { $0.id == draft.value.clientID } : nil }
    private var savedValue: InvoiceValue? { try? invoice?.currentValue() }
    private var canGoBack: Bool {
        switch step {
        case .client: false
        case .lines: startedAtClient
        case .record: !locked
        }
    }

    /// Every event's readiness, rebuilt per render like Payments so sync and edits never leave it stale.
    private func readiness() -> [EventReadiness] {
        let index = InvoiceIndex(in: context)
        let saved = Set(savedValue?.lines.map(\.jobID) ?? [])
        let today = Day.string(from: Date())
        return jobs.filter { job in job.id.map { job.deletedAt == nil || saved.contains($0) } ?? false }
            .map { EventReadiness(ReadinessFacts(job: $0, context: context, index: index), today: today) }
    }

    private func candidates(_ events: [EventReadiness]) -> InvoiceCandidates {
        var billed: [UUID: [EventExpenseFact]] = [:]
        for line in savedValue?.expenseLines ?? [] {
            guard let jobID = expenses.first(where: { $0.id == line.expenseID })?.job?.id else { continue }
            billed[jobID, default: []].append(EventExpenseFact(id: line.expenseID, merchant: line.label, amount: line.amount, currency: currency))
        }
        return InvoiceCandidates(events: events, clientID: draft.value.clientID, currency: currency,
                                 onThisInvoice: Set(savedValue?.lines.map(\.jobID) ?? []), billedReceipts: billed)
    }

    /// Other open drafts the person could add to instead of starting a new invoice.
    private func openDrafts(clientID: UUID? = nil, currency: String? = nil) -> [(invoice: Invoice, value: InvoiceValue)] {
        let index = InvoiceIndex(in: context)
        return invoices.compactMap { candidate in
            guard candidate.objectID != invoice?.objectID, let value = try? candidate.currentValue(), value.status == "draft",
                  candidate.issue(in: context, index: index) == nil else { return nil }
            if let clientID, value.clientID != clientID { return nil }
            if let currency, value.currency != currency { return nil }
            return (candidate, value)
        }
    }

    private func parsedAmount(_ jobID: UUID) -> Int64? {
        let amount: Int64?? = try? Money.parseInput(amounts[jobID] ?? "", currency: currency)
        return amount ?? nil
    }

    private var liveTotal: Int64 {
        draft.value.lines.reduce(Int64(0)) { $0 + (parsedAmount($1.jobID) ?? 0) } + draft.value.expenseLines.reduce(0) { $0 + $1.amount }
    }

    private var nothingSelected: Bool { draft.value.lines.isEmpty && draft.value.expenseLines.isEmpty }

    private var unknownAmounts: Int { draft.value.lines.filter { parsedAmount($0.jobID) == nil }.count }

    private var selectionSummary: String {
        let events = draft.value.lines.count, receipts = draft.value.expenseLines.count
        var parts = events == 0 ? [] : [events == 1 ? "1 event" : "\(events) events"]
        if receipts > 0 { parts.append(receipts == 1 ? "1 receipt" : "\(receipts) receipts") }
        if unknownAmounts > 0 { parts.append(unknownAmounts == 1 ? "1 amount to enter" : "\(unknownAmounts) amounts to enter") }
        return parts.joined(separator: " · ")
    }

    // MARK: Body

    var body: some View {
        // Revision, payment and receipt arrivals must refresh eligibility even when job rows do not change.
        _ = invoiceRevisions.count + payments.count + expenses.count
        return NavigationStack {
            Group {
                switch step {
                case .client: clientStep
                case .lines: linesStep
                case .record: recordStep
                }
            }
            .navigationTitle(invoice == nil ? "New invoice" : "Edit invoice").navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbar }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .confirmationDialog("Discard changes?", isPresented: $discard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .onChange(of: draft.value.status) { _, status in
                // Terms on file set an empty due date, which then follows the sent date; a chosen due date is kept.
                if status == "sent" { draft.value.markSent(today: Day.string(from: Date()), terms: client?.invoicing) }
            }
            .onChange(of: draft.value.sentDay) { _, _ in draft.value.followTerms(client?.invoicing) }
            .task { seed() }
            .saveErrorAlert($error).interactiveDismissDisabled(changed)
            .preservesDraftOnTodayLink()
        }
        .presentationSizing(.page)
        .presentationDetents([.large])
        .presentationBackground(Color.theme.page)
    }

    @ToolbarContentBuilder private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            if canGoBack {
                Button { goBack() } label: { Label(step == .record ? "Lines" : "Clients", systemImage: "chevron.backward").labelStyle(.titleAndIcon) }
                    .accessibilityIdentifier("invoice-back")
            } else {
                Button("Cancel") { cancel() }.accessibilityIdentifier("cancel-invoice")
            }
        }
        ToolbarItem(placement: .principal) {
            VStack(spacing: 0) {
                Text(invoice == nil ? "New invoice" : "Edit invoice").font(.headline)
                if !locked { Text(step == .record ? "Step 2 of 2" : "Step 1 of 2").font(.caption).foregroundStyle(Color.theme.secondaryText) }
            }.accessibilityElement(children: .combine)
        }
        if canGoBack {
            ToolbarItem(placement: .topBarTrailing) { Button("Cancel") { cancel() }.accessibilityIdentifier("cancel-invoice") }
        }
    }

    @ViewBuilder private var bottomBar: some View {
        switch step {
        case .client: EmptyView()
        case .lines:
            let large = typeSize.isAccessibilitySize
            let layout = large ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(Money.format(liveTotal, currency: currency)).font(.title3.bold()).monospacedDigit()
                        .lineLimit(1).minimumScaleFactor(0.6)
                    // Accessibility sizes keep the bar short; the selection itself shows the count.
                    if !large {
                        Text(nothingSelected ? "Choose the work to bill" : selectionSummary)
                            .font(.footnote).foregroundStyle(Color.theme.secondaryText)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("invoice-running-total")
                if !large { Spacer(minLength: 0) }
                Button { step = .record } label: { Text("Next").frame(maxWidth: large ? .infinity : nil) }
                    .buttonStyle(DaybookPrimaryButton()).disabled(nothingSelected)
                    .accessibilityIdentifier("invoice-next")
            }
            .padding(.horizontal, 20).padding(.vertical, large ? 8 : 12).background(.bar)
        case .record:
            Button { save() } label: { Text(saveTitle).frame(maxWidth: .infinity) }
                .buttonStyle(DaybookPrimaryButton()).accessibilityIdentifier("save-invoice")
                .padding(.horizontal, 20).padding(.vertical, typeSize.isAccessibilitySize ? 8 : 12).background(.bar)
        }
    }

    private var saveTitle: String {
        if invoice != nil && draft.value.status != "void" { return "Save" }
        switch draft.value.status {
        case "sent": return "Save sent invoice"
        case "void": return "Void invoice"
        default: return "Save draft"
        }
    }

    // MARK: Step 1a — client

    private var clientStep: some View {
        let events = readiness()
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let matches: (String) -> Bool = { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }
        let options = InvoiceClientOption.ready(from: events).filter { matches($0.name) }
        let readyClients = Set(options.map(\.clientID))
        let drafts = openDrafts().filter { matches($0.invoice.client?.name ?? "") }
        let others = clients.filter { client in client.id.map { !readyClients.contains($0) } ?? false && matches(client.name) }
        let splitCurrencies = Set(options.map(\.clientID)).count < options.count
        return DaybookForm(topPadding: 8) {
            Section { InvoiceStepBar(recording: false) }.containerValue(\.daybookUnframed, true)
            Section { DaybookPageHeading(title: "Who is it for?", subtitle: "Choose a client and their ready work is ticked for you.") }
                .containerValue(\.daybookUnframed, true)
            Section {
                Label { DaybookTextField("Search clients", text: $search).accessibilityIdentifier("invoice-client-search") }
                    icon: { Image(systemName: "magnifyingglass").foregroundStyle(Color.theme.secondaryText) }
            }
            if clients.isEmpty {
                Section { Text("Add a client in Settings or on an event before creating an invoice.").foregroundStyle(Color.theme.secondaryText) }
            }
            if !options.isEmpty {
                Section {
                    ForEach(options) { option in
                        InvoiceChoiceRow(title: option.name, detail: option.summary, amount: Money.format(option.total, currency: option.currency)) {
                            choose(clientID: option.clientID, currency: option.currency, tickReady: true, events: events)
                        }.accessibilityIdentifier("invoice-client-\(option.name)-\(option.currency)")
                    }
                } header: { Text("Work ready to bill") } footer: {
                    if splitCurrencies { Text("A client billed in two currencies gets a row for each.") }
                }
            }
            if !drafts.isEmpty {
                Section("Or continue a draft") {
                    ForEach(drafts, id: \.invoice.objectID) { item in
                        InvoiceChoiceRow(title: item.invoice.client?.name ?? "Client syncing", badge: "Draft",
                                         detail: [item.value.reference.isEmpty ? nil : item.value.reference, item.value.lines.count == 1 ? "1 event" : "\(item.value.lines.count) events"].compactMap { $0 }.joined(separator: " · "),
                                         amount: (try? item.value.total()).map { Money.format($0, currency: item.value.currency) } ?? "") {
                            open(item.invoice, keepingSelection: false)
                        }.accessibilityIdentifier("invoice-draft-\(item.invoice.client?.name ?? "")")
                    }
                }
            }
            if !others.isEmpty {
                Section {
                    ForEach(others, id: \.objectID) { client in
                        let missing = !client.invoicing.isComplete
                        InvoiceChoiceRow(title: client.name, detail: missing ? "Invoicing details to add" : "Nothing ready", detailIsWarning: missing, amount: "") {
                            if let id = client.id { choose(clientID: id, currency: client.defaultCurrency, tickReady: false, events: events) }
                        }.accessibilityIdentifier("invoice-client-\(client.name)")
                    }
                } header: { Text(options.isEmpty && drafts.isEmpty ? "Clients" : "Other clients") } footer: {
                    Text("Track an invoice you create elsewhere. Cuekeeper does not send documents.")
                }
            }
        }
    }

    // MARK: Step 1b — what's on it

    private var linesStep: some View {
        let events = readiness()
        let work = candidates(events)
        let drafts = invoice == nil ? openDrafts(clientID: draft.value.clientID, currency: currency) : []
        return DaybookForm(topPadding: 8) {
            Section { InvoiceStepBar(recording: false) }.containerValue(\.daybookUnframed, true)
            Section { linesHeader }.containerValue(\.daybookUnframed, true)
            if let client, !client.invoicing.isComplete {
                Section {
                    clientInvoicingRows($details, highlight: true)
                    Button("Save details") { saveDetails(client) }
                        .buttonStyle(DaybookPrimaryButton()).disabled(details == detailsBaseline)
                        .accessibilityIdentifier("save-invoicing")
                } header: { Text("\(client.name) invoicing details") } footer: {
                    Text("Work counts as ready once these are saved. You can still record this invoice now.")
                }
            }
            Section {
                if work.ready.isEmpty {
                    Text("Nothing is ready for \(client?.name ?? "this client") in \(currency).").foregroundStyle(Color.theme.secondaryText)
                }
                ForEach(work.ready) { candidate in candidateRows(candidate, ready: true) }
            } header: { Text("Ready to bill") } footer: {
                Text("Fees fill in from each event. You can adjust billed amounts on the next step.")
            }
            if !work.notReady.isEmpty {
                Section {
                    ForEach(work.notReady) { candidate in candidateRows(candidate, ready: false) }
                } header: { Text("Not ready yet") } footer: {
                    Text("You can still include these. Enter any unknown fee on the next step.")
                }
            }
            if !work.receiptsOnly.isEmpty {
                Section {
                    ForEach(work.receiptsOnly) { candidate in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(candidate.title).fontWeight(.semibold)
                            Text([candidate.dates, candidate.note].joined(separator: " · ")).font(.subheadline).foregroundStyle(Color.theme.secondaryText)
                        }.accessibilityElement(children: .combine)
                        receiptRows(candidate.receipts, enabled: true)
                    }
                } header: { Text("Receipts to bill on their own") } footer: {
                    Text("These events' fees are already invoiced or billed in another currency. Their \(currency) receipts can go on this invoice without billing the fee again; amounts are never converted.")
                }
            }
            if !drafts.isEmpty {
                Section("Or add to a draft") {
                    ForEach(drafts, id: \.invoice.objectID) { item in
                        InvoiceChoiceRow(title: item.value.reference.isEmpty ? "Draft invoice" : item.value.reference, badge: "Draft",
                                         detail: item.value.lines.count == 1 ? "1 event" : "\(item.value.lines.count) events",
                                         amount: (try? item.value.total()).map { Money.format($0, currency: item.value.currency) } ?? "") {
                            open(item.invoice, keepingSelection: true)
                        }.accessibilityIdentifier("invoice-add-to-draft")
                    }
                }
            }
            if work.alreadyInvoiced > 0 {
                Section {
                    Text(work.alreadyInvoiced == 1 ? "1 more event is already on another invoice." : "\(work.alreadyInvoiced) more events are already on other invoices.")
                        .font(.footnote).foregroundStyle(Color.theme.secondaryText)
                }.containerValue(\.daybookUnframed, true)
            }
        }
    }

    private var linesHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(client?.name ?? "Client syncing").font(.title2.bold()).accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if invoice == nil {
                    Button("Change") { step = .client }.font(.subheadline.weight(.semibold)).accessibilityIdentifier("invoice-change-client")
                }
            }
            HStack(spacing: 4) {
                Menu {
                    Picker("Currency", selection: Binding(get: { currency }, set: { changeCurrency($0) })) {
                        ForEach(CurrencyPreferences.supported, id: \.self) { Text(Self.currencyName($0)).tag($0) }
                    }
                } label: {
                    HStack(spacing: 3) {
                        Text("\(Self.currencyName(currency)) invoice")
                        Image(systemName: "chevron.up.chevron.down").font(.caption2)
                    }
                }
                .accessibilityIdentifier("invoice-currency")
                if let origin { Text("· from \(origin.title)").foregroundStyle(Color.theme.secondaryText).lineLimit(1) }
            }.font(.subheadline)
        }
    }

    @ViewBuilder private func candidateRows(_ candidate: InvoiceCandidate, ready: Bool) -> some View {
        let included = draft.value.lines.contains { $0.jobID == candidate.id }
        Toggle(isOn: Binding(get: { included }, set: { toggle(candidate, on: $0) })) {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.title).fontWeight(.semibold)
                Text(candidate.dates).font(.subheadline).foregroundStyle(Color.theme.secondaryText)
                if !candidate.note.isEmpty { Text(candidate.note).font(.subheadline).foregroundStyle(Color.theme.caution) }
            }
        } trailing: {
            Text(candidate.event.amount.map { Money.format($0, currency: currency) } ?? "Fee to enter")
                .monospacedDigit().foregroundStyle(included || candidate.event.amount == nil ? Color.primary : Color.theme.secondaryText)
                .font(candidate.event.amount == nil ? .subheadline : .body)
        }
        .toggleStyle(InvoiceCheckStyle(size: .event))
        .accessibilityIdentifier("invoice-line-\(candidate.title)")
        receiptRows(candidate.receipts, enabled: included)
    }

    @ViewBuilder private func receiptRows(_ receipts: [EventExpenseFact], enabled: Bool) -> some View {
        ForEach(receipts) { receipt in
            let on = draft.value.expenseLines.contains { $0.expenseID == receipt.id }
            Toggle(isOn: Binding(get: { on }, set: { toggle(receipt: receipt, on: $0) })) {
                (Text(receipt.merchant.isEmpty ? "Receipt" : receipt.merchant) + Text(" · receipt").foregroundStyle(Color.theme.secondaryText)).font(.subheadline)
            } trailing: {
                Text(receipt.amount.map { Money.format($0, currency: currency) } ?? "").font(.subheadline).monospacedDigit()
            }
            .toggleStyle(InvoiceCheckStyle(size: .receipt))
            .disabled(!enabled)
            .accessibilityIdentifier("invoice-receipt-\(receipt.merchant)")
        }
    }

    // MARK: Step 2 — record it

    private var recordStep: some View {
        let statuses = locked ? ["sent", "void"] : (invoice == nil ? ["draft", "sent"] : ["draft", "sent", "void"])
        return DaybookForm(topPadding: 8) {
            if !locked { Section { InvoiceStepBar(recording: true) }.containerValue(\.daybookUnframed, true) }
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(client?.name ?? "Client syncing").font(.subheadline).foregroundStyle(Color.theme.secondaryText)
                    Text(Money.format(liveTotal, currency: currency)).font(.largeTitle.bold()).monospacedDigit()
                        .accessibilityIdentifier("invoice-total")
                }.accessibilityElement(children: .combine)
            }.containerValue(\.daybookUnframed, true)
            Section {
                DaybookSegments(title: invoice == nil ? "Have you sent it?" : "Status", selection: $draft.value.status, options: statuses,
                                identifier: "invoice-status", label: { statusLabel($0) })
            } header: { Text(invoice == nil ? "Have you sent it?" : "Status") }
                .containerValue(\.daybookUnframed, true)
            Section {
                InvoiceFieldRow(label: "Reference") {
                    TextField("Reference", text: $draft.value.reference, prompt: Text(draft.value.status == "sent" ? "Required" : "Optional").foregroundStyle(Color.theme.secondaryText))
                        .multilineTextAlignment(.trailing).monospacedDigit()
                        .textInputAutocapitalization(.characters).autocorrectionDisabled()
                        .accessibilityIdentifier("invoice-reference")
                }
                if draft.value.status == "sent" {
                    InvoiceFieldRow(label: "Sent", centered: true) {
                        DatePicker("Sent", selection: dayBinding($draft.value.sentDay), displayedComponents: .date).labelsHidden()
                            .accessibilityIdentifier("invoice-sent-day")
                    }
                }
                Toggle("Due date", isOn: Binding(get: { !draft.value.dueDay.isEmpty }, set: { on in
                    draft.value.showDue(on, today: Day.string(from: Date()), terms: client?.invoicing)
                })).accessibilityIdentifier("invoice-due-toggle")
                if !draft.value.dueDay.isEmpty {
                    InvoiceFieldRow(label: "Due", centered: true) {
                        DatePicker("Due", selection: dayBinding(Binding(get: { draft.value.dueDay }, set: { draft.value.chooseDue($0) })), displayedComponents: .date).labelsHidden()
                            .accessibilityIdentifier("invoice-due-day")
                    }
                }
                if draft.value.status == "void" {
                    Text("Voiding keeps the history and releases bookings for rebilling. Reverse any payments first.").foregroundStyle(Color.theme.secondaryText)
                }
            } footer: {
                if let note = recordFootnote { Text(note) }
            }
            Section {
                ForEach(draft.value.lines) { line in
                    InvoiceFieldRow(label: line.jobName, labelIsTitle: true) {
                        TextField("Amount", text: Binding(get: { amounts[line.jobID] ?? "" }, set: { amounts[line.jobID] = $0 }),
                                  prompt: Text("Amount").foregroundStyle(Color.theme.caution))
                            .keyboardType(.decimalPad).multilineTextAlignment(.trailing).monospacedDigit()
                            .disabled(locked)
                            .accessibilityLabel("Billed amount for \(line.jobName)")
                            .accessibilityIdentifier("billed-\(line.jobName)")
                    }
                }
                ForEach(draft.value.expenseLines) { line in
                    LabeledContent {
                        Text(Money.format(line.amount, currency: currency)).monospacedDigit().foregroundStyle(.primary)
                    } label: { Text(line.label).foregroundStyle(Color.theme.secondaryText) }
                    .font(.subheadline)
                }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Billed amounts")
                    Spacer()
                    if !locked {
                        Button("Edit lines") { step = .lines }.font(.subheadline.weight(.semibold)).foregroundStyle(Color.theme.accent)
                            .accessibilityIdentifier("invoice-edit-lines")
                    }
                }
            } footer: {
                Text(locked || draft.value.status == "sent" ? "Sent invoices keep these amounts, whatever fees or receipts change later."
                     : (refreshedReceipts ? "Receipt totals were updated from corrected receipts. " : "") + "Each booking can belong to one active invoice. Unknown fees need an explicit billed amount, including 0 for unpaid work.")
            }
            if showsNotes || !draft.value.notes.isEmpty {
                Section("Notes") {
                    DaybookTextField("Invoice notes", text: $draft.value.notes, axis: .vertical).lineLimit(3...8)
                        .accessibilityIdentifier("invoice-notes")
                }
            } else {
                Section {
                    Button { showsNotes = true } label: { Label("Add a note", systemImage: "plus") }
                        .font(.subheadline.weight(.semibold)).accessibilityIdentifier("invoice-add-note")
                }.containerValue(\.daybookUnframed, true)
            }
        }
    }

    private func statusLabel(_ status: String) -> String {
        switch status {
        case "draft": invoice == nil ? "Not yet" : "Draft"
        case "sent": invoice == nil ? "Yes, sent" : "Sent"
        default: "Void"
        }
    }

    private var recordFootnote: String? {
        var parts: [String] = []
        if let referenceBasis, invoice == nil { parts.append("Reference follows \(referenceBasis).") }
        if let name = client?.name, let terms = client?.invoicing.termsDays, draft.value.status != "void" {
            parts.append(draft.value.status == "sent" ? "The due date uses the \(terms)-day terms on file for \(name)." : "When you mark it sent, the due date follows the \(terms)-day terms on file for \(name).")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    // MARK: Actions

    private func cancel() { if changed { discard = true } else { dismiss() } }

    private func goBack() {
        switch step {
        case .record: step = .lines
        case .lines: step = .client
        case .client: break
        }
    }

    /// Fills in what the entry point could not: the origin's receipts, the next reference, the client's details.
    private func seed() {
        guard !seeded else { return }
        seeded = true
        if let origin, invoice == nil, draft.value.expenseLines.isEmpty, draft.value.lines.contains(where: { $0.jobID == origin.id }),
           let candidate = candidates(readiness()).all.first(where: { $0.id == origin.id }) {
            for receipt in candidate.receipts { toggle(receipt: receipt, on: true) }
        }
        // A draft bills receipts as they are now; only a sent invoice keeps the totals it went out with.
        if invoice != nil, !locked, draft.value.status == "draft" {
            let current = draft.value.expenseLines.map { line in expenses.first { $0.id == line.expenseID }.flatMap(Self.billed) ?? line }
            if current != draft.value.expenseLines { draft.value.expenseLines = current; refreshedReceipts = true }
        }
        suggestReference()
        loadDetails()
        // What the entry point supplied is the starting point, not an unsaved change.
        if invoice == nil { initial = draft; initialAmounts = amounts }
    }

    private func choose(clientID: UUID, currency: String, tickReady: Bool, events: [EventReadiness]) {
        let sameClient = hasClient && draft.value.clientID == clientID && draft.value.currency == currency
        draft.value.clientID = clientID; draft.value.currency = currency; hasClient = true
        if !sameClient {
            draft.value.lines = []; draft.value.expenseLines = []; amounts = [:]
            draft.value.reference = ""; referenceBasis = nil
            if tickReady { for candidate in candidates(events).ready { toggle(candidate, on: true) } }
        }
        suggestReference(); loadDetails()
        step = .lines
    }

    private func changeCurrency(_ code: String) {
        guard code != currency, !locked else { return }
        draft.value.currency = code
        draft.value.lines = []; draft.value.expenseLines = []; amounts = [:]
    }

    private func toggle(_ candidate: InvoiceCandidate, on: Bool) {
        if on {
            guard !draft.value.lines.contains(where: { $0.jobID == candidate.id }) else { return }
            let saved = savedValue?.lines.first { $0.jobID == candidate.id }
            let amount = saved?.amount ?? candidate.event.amount
            draft.value.lines.append(BilledLine(jobID: candidate.id, jobName: candidate.title, amount: amount ?? 0))
            amounts[candidate.id] = Money.inputText(amount, currency: currency)
            for receipt in candidate.receipts { toggle(receipt: receipt, on: true) }
        } else {
            draft.value.lines.removeAll { $0.jobID == candidate.id }
            amounts.removeValue(forKey: candidate.id)
            for receipt in candidate.receipts { toggle(receipt: receipt, on: false) }
        }
    }

    private func toggle(receipt: EventExpenseFact, on: Bool) {
        var lines = draft.value.expenseLines.filter { $0.expenseID != receipt.id }
        if on {
            if let expense = expenses.first(where: { $0.id == receipt.id }), let line = Self.billed(expense) { lines.append(line) }
            else if let saved = savedValue?.expenseLines.first(where: { $0.expenseID == receipt.id }) { lines.append(saved) }
        }
        draft.value.expenseLines = lines
    }

    /// Opens a saved draft in this editor. Keeping the selection adds the work already ticked here to it.
    private func open(_ other: Invoice, keepingSelection: Bool) {
        do {
            let saved = try InvoiceDraft(invoice: other)
            let savedAmounts = Dictionary(saved.value.lines.map { ($0.jobID, Money.inputText($0.amount, currency: saved.value.currency)) }, uniquingKeysWith: { a, _ in a })
            var merged = saved, mergedAmounts = savedAmounts
            if keepingSelection && saved.value.currency == currency {
                for line in draft.value.lines where !merged.value.lines.contains(where: { $0.jobID == line.jobID }) {
                    merged.value.lines.append(line); mergedAmounts[line.jobID] = amounts[line.jobID]
                }
                let receipts = merged.value.expenseLines + draft.value.expenseLines.filter { line in !merged.value.expenseLines.contains { $0.expenseID == line.expenseID } }
                merged.value.expenseLines = receipts
            }
            invoice = other; hasClient = true; referenceBasis = nil
            draft = merged; amounts = mergedAmounts
            initial = saved; initialAmounts = savedAmounts
            showsNotes = !saved.value.notes.isEmpty
            loadDetails()
            step = keepingSelection ? .lines : .record
        } catch { self.error = error.localizedDescription }
    }

    /// Suggests the reference after the client's latest one. A typed reference is never replaced.
    private func suggestReference() {
        guard invoice == nil, hasClient, draft.value.reference.isEmpty else { return }
        let previous = invoices.lazy.compactMap { invoice -> String? in
            guard invoice.client?.id == self.draft.value.clientID, let value = try? invoice.currentValue() else { return nil }
            let reference = value.reference.trimmingCharacters(in: .whitespacesAndNewlines)
            return reference.isEmpty ? nil : reference
        }.first
        let used = Set(invoices.compactMap { try? $0.currentValue().reference.trimmingCharacters(in: .whitespacesAndNewlines) })
        guard let previous, let next = InvoiceReference.next(after: previous, avoiding: used) else { return }
        draft.value.reference = next; referenceBasis = previous
    }

    private func loadDetails() {
        let value = InvoicingDraft(client?.invoicing ?? ClientInvoicing())
        details = value; detailsBaseline = value
    }

    private func saveDetails(_ client: Client) {
        do {
            try Client.saveInvoicing(try details.value(), client: client.objectID, in: context)
            loadDetails()
        } catch { self.error = error.localizedDescription }
    }

    private func save() {
        do {
            var save = draft; save.value = try preparedValue()
            try save.save(in: context, editing: invoice?.objectID); dismiss()
        } catch { self.error = error.localizedDescription }
    }

    private func preparedValue() throws -> InvoiceValue {
        guard hasClient else { throw RecordError.invalid("Choose a client.") }
        var value = draft.value
        value.reference = value.reference.trimmingCharacters(in: .whitespacesAndNewlines)
        for index in value.lines.indices {
            guard let amount = try Money.parseInput(amounts[value.lines[index].jobID] ?? "", currency: value.currency) else { throw RecordError.invalid("Enter a billed amount for each included booking.") }
            value.lines[index].amount = amount
        }
        try value.validate(); return value
    }

    private func dayBinding(_ binding: Binding<String>) -> Binding<Date> {
        Binding(get: { Day.date(from: binding.wrappedValue) ?? Date() }, set: { binding.wrappedValue = Day.string(from: $0) })
    }

    static func currencyName(_ code: String) -> String {
        Locale.current.localizedString(forCurrencyCode: code).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? code
    }
}

// MARK: - Pieces

/// The two-step progress line. Choosing a client is part of the first step.
private struct InvoiceStepBar: View {
    let recording: Bool
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            segment("What's on it", done: true, current: !recording)
            segment("Record it", done: recording, current: recording)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(recording ? "Step 2 of 2, record it" : "Step 1 of 2, what's on it")
    }
    private func segment(_ title: String, done: Bool, current: Bool) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Capsule().fill(done ? Color.theme.accent : Color.primary.opacity(0.12)).frame(height: 4)
            Text(title).font(.footnote.weight(current ? .semibold : .regular))
                .foregroundStyle(current ? Color.theme.accent : Color.theme.secondaryText)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A tappable row that moves the editor on: a client, or a draft to continue.
private struct InvoiceChoiceRow: View {
    let title: String
    var badge: String? = nil
    let detail: String
    var detailIsWarning = false
    let amount: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(title).fontWeight(.semibold)
                        if let badge { BookingBadge(status: badge.lowercased()) }
                    }
                    Text(detail).font(.subheadline).foregroundStyle(detailIsWarning ? Color.theme.caution : Color.theme.secondaryText)
                }
                Spacer(minLength: 8)
                if !amount.isEmpty { Text(amount).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7) }
                Image(systemName: "chevron.forward").font(.footnote.weight(.semibold)).foregroundStyle(Color.theme.secondaryText)
            }
            .foregroundStyle(.primary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A label on the left with an editable value on the right, stacking at accessibility sizes.
private struct InvoiceFieldRow<Field: View>: View {
    @Environment(\.dynamicTypeSize) var typeSize
    let label: String
    var labelIsTitle = false
    /// Controls drawn as pills, such as date pickers, align by centre rather than text baseline.
    var centered = false
    @ViewBuilder var field: Field
    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: centered ? .center : .firstTextBaseline, spacing: 12))
        layout {
            Text(label).lineLimit(labelIsTitle ? 2 : 1)
            field.frame(maxWidth: .infinity, alignment: typeSize.isAccessibilitySize ? .leading : .trailing)
        }
    }
}

/// A round selection mark for invoice lines; receipts sit indented under their event.
private struct InvoiceCheckStyle: ToggleStyle {
    enum Size { case event, receipt }
    let size: Size
    func makeBody(configuration: Configuration) -> some View { InvoiceCheck(configuration: configuration, size: size) }
}

private struct InvoiceCheck: View {
    let configuration: ToggleStyleConfiguration
    let size: InvoiceCheckStyle.Size
    @Environment(\.isEnabled) var enabled
    var body: some View {
        HStack(alignment: size == .event ? .top : .center, spacing: 12) {
            Image(systemName: configuration.isOn ? "checkmark.circle.fill" : "circle")
                .font(size == .event ? .title3 : .body)
                .foregroundStyle(configuration.isOn ? Color.theme.accent : Color.primary.opacity(enabled ? 0.35 : 0.16))
                .padding(.leading, size == .receipt ? 34 : 0)
                .accessibilityHidden(true)
            configuration.label.frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(enabled ? 1 : 0.55)
        .contentShape(Rectangle())
        .onTapGesture { if enabled { configuration.isOn.toggle() } }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(configuration.isOn ? [.isToggle, .isSelected] : [.isToggle])
        .accessibilityValue(configuration.isOn ? "Included" : "Not included")
        .accessibilityAction { if enabled { configuration.isOn.toggle() } }
    }
}

/// A line label with a trailing value, such as an amount.
private struct InvoiceLineLabel<Leading: View, Trailing: View>: View {
    @Environment(\.dynamicTypeSize) var typeSize
    let leading: Leading
    let trailing: Trailing
    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) { leading; trailing.lineLimit(1).minimumScaleFactor(0.7) }
        } else {
            HStack { leading; Spacer(minLength: 8); trailing.lineLimit(1).fixedSize() }
        }
    }
}

private extension Toggle {
    /// A toggle whose label carries a trailing value, such as an amount.
    init<Leading: View, Trailing: View>(isOn: Binding<Bool>, @ViewBuilder label: () -> Leading, @ViewBuilder trailing: () -> Trailing) where Label == InvoiceLineLabel<Leading, Trailing> {
        let line = InvoiceLineLabel(leading: label(), trailing: trailing())
        self.init(isOn: isOn) { line }
    }
}
