import CoreData
import SwiftUI

/// Payments as a month close: every event in the month with its four invoicing gates,
/// grouped by client, then money still open from earlier months.
struct PaymentsView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Invoice.createdAt, ascending: false)]) private var invoices: FetchedResults<Invoice>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Job.startDay, ascending: true)]) private var jobs: FetchedResults<Job>
    @FetchRequest(sortDescriptors: []) private var payments: FetchedResults<PaymentRecord>
    @FetchRequest(sortDescriptors: []) private var invoiceRevisions: FetchedResults<InvoiceRevision>
    @FetchRequest(sortDescriptors: []) private var expenses: FetchedResults<Expense>
    @FetchRequest(sortDescriptors: []) private var clients: FetchedResults<Client>
    @AppStorage("displayCurrencies") private var displayCurrencies = CurrencyPreferences.defaultDisplay
    @State private var month = PaymentsView.currentMonth
    @State private var width: CGFloat = 0
    @State private var adding = false
    @State private var invoicing: ReadyInvoice?
    @State private var readiness: Presented<Job>?
    @State private var detailsClient: Presented<Client>?

    static var currentMonth: String { String(Day.string(from: Date()).prefix(7)) }
    private var wide: Bool { width >= 900 && !typeSize.isAccessibilitySize }

    var body: some View {
        // Revision, receipt, expense and client arrivals must refresh readiness even when job rows do not change.
        _ = invoiceRevisions.count + payments.count + expenses.count + clients.count
        let summary = PaymentsMonth.load(month: month, jobs: Array(jobs), invoices: Array(invoices), context: context,
                                         displayed: CurrencyPreferences.displayed(displayCurrencies))
        return Group {
            if wide { wideBody(summary) } else { compactBody(summary) }
        }
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(sizeClass == .compact ? .hidden : .visible, for: .navigationBar)
        .sheet(isPresented: $adding) { InvoiceEditorView() }
        .sheet(item: $invoicing) { InvoiceEditorView(ready: $0) }
        .sheet(item: $readiness) { ReadinessSheet(job: $0.object) }
        .sheet(item: $detailsClient) { ClientInvoicingEditor(client: $0.object) }
    }

    // MARK: Compact

    private func compactBody(_ summary: PaymentsMonth) -> some View {
        DaybookForm(topPadding: 12) {
            Section { header }.containerValue(\.daybookUnframed, true).containerValue(\.daybookFlushTop, true)
            Section { PendingExpensesPrompt() }
            Section { MonthStepper(month: $month, eventCount: summary.events.count) }.containerValue(\.daybookUnframed, true)
            if !summary.currencies.isEmpty {
                Section { MonthMoneyPanel(currencies: summary.currencies) }
            }
            if summary.groups.isEmpty {
                Section { Text("No events in \(MonthStepper.title(month)).").foregroundStyle(Color("SecondaryText")) }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("By client").font(.title3.bold()).accessibilityAddTraits(.isHeader)
                        StepBarKey()
                    }
                }.containerValue(\.daybookUnframed, true)
                ForEach(summary.groups) { group in
                    Section {
                        ClientGroupHeader(group: group, clientObject: client(group.clientID), onDetails: { detailsClient = Presented($0) }) { currency in
                            if let clientID = group.clientID { invoicing = readyInvoice(clientID: clientID, currency: currency, group: group) }
                        }
                        ForEach(group.events) { event in eventRow(event, showsClient: false) }
                    }
                }
            }
            if !summary.earlier.isEmpty {
                Section {
                    ForEach(summary.earlier) { item in earlierRow(item) }
                } header: { Text("Still open from earlier") }
            }
            Section {
                DaybookLink { PaymentsLedgerView() } label: { Label("All invoices and payments", systemImage: "list.bullet.rectangle") }
                    .accessibilityIdentifier("payments-ledger")
            }
        }
    }

    private var header: some View {
        DaybookTabHeader {
            Button { adding = true } label: { Label("Invoice", systemImage: "plus") }
                .buttonStyle(DaybookPrimaryButton())
                .accessibilityLabel("Add Invoice")
                .accessibilityIdentifier("add-invoice-overview")
        }
    }

    @ViewBuilder private func eventRow(_ event: EventReadiness, showsClient: Bool) -> some View {
        if let job = job(event.id) {
            if event.showsGates && event.state != .ready {
                Button { readiness = Presented(job) } label: { EventReadinessRow(event: event, showsClient: showsClient) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("readiness-\(event.facts.title)")
            } else {
                DaybookLink { JobDetailView(job: job) } label: { EventReadinessRow(event: event, showsClient: showsClient) }
                    .accessibilityIdentifier("readiness-\(event.facts.title)")
            }
        }
    }

    @ViewBuilder private func earlierRow(_ item: EarlierItem) -> some View {
        switch item {
        case let .invoice(id, reference, clientName, balance, currency, dueDay, draft, paid, total):
            if let invoice = invoices.first(where: { $0.id == id }) {
                DaybookLink { InvoiceDetailView(invoice: invoice) } label: {
                    OpenInvoiceRow(reference: reference, clientName: clientName, balance: balance, currency: currency, dueDay: dueDay, draft: draft, paid: paid, total: total)
                }
            }
        case .event(let event):
            eventRow(event, showsClient: true)
        }
    }

    // MARK: Wide

    private func wideBody(_ summary: PaymentsMonth) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 16) {
                    MonthStepper(month: $month, eventCount: summary.events.count, inline: true)
                    Spacer(minLength: 0)
                    PendingExpensesPrompt().fixedSize()
                    Button { adding = true } label: { Label("Invoice", systemImage: "plus") }
                        .buttonStyle(DaybookPrimaryButton())
                        .accessibilityLabel("Add Invoice")
                        .accessibilityIdentifier("add-invoice-overview")
                }
                HStack(alignment: .top, spacing: 24) {
                    VStack(alignment: .leading, spacing: 12) {
                        if summary.groups.isEmpty {
                            Text("No events in \(MonthStepper.title(month)).").foregroundStyle(Color("SecondaryText"))
                        } else {
                            MonthLedgerTable(groups: summary.groups, job: job, client: client,
                                             onReadiness: { readiness = Presented($0) }, onDetails: { detailsClient = Presented($0) },
                                             onInvoice: { group, currency in if let id = group.clientID { invoicing = readyInvoice(clientID: id, currency: currency, group: group) } })
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .topLeading)
                    VStack(alignment: .leading, spacing: 20) {
                        if !summary.currencies.isEmpty { WidePanel { MonthMoneyPanel(currencies: summary.currencies) } }
                        if !summary.earlier.isEmpty {
                            VStack(alignment: .leading, spacing: 9) {
                                Text("Still open from earlier").font(.headline).accessibilityAddTraits(.isHeader)
                                WidePanel(padded: false) {
                                    ForEach(Array(summary.earlier.enumerated()), id: \.element.id) { index, item in
                                        if index > 0 { Divider().padding(.leading, 16) }
                                        earlierRow(item).padding(.horizontal, 16).padding(.vertical, 12)
                                    }
                                }
                            }
                        }
                        WidePanel {
                            DaybookLink { PaymentsLedgerView() } label: { Label("All invoices and payments", systemImage: "list.bullet.rectangle") }
                                .accessibilityIdentifier("payments-ledger")
                        }
                    }
                    .frame(width: 340)
                }
            }
            .frame(maxWidth: 1240)
            .padding(.horizontal, 28)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity)
        }
        .daybookSurface()
    }

    // MARK: Lookups

    private func job(_ id: UUID) -> Job? { jobs.first { $0.id == id } }
    private func client(_ id: UUID?) -> Client? { id.flatMap { id in clients.first { $0.id == id } } }
    private func readyInvoice(clientID: UUID, currency: String, group: ClientMonthGroup) -> ReadyInvoice {
        let ready = group.ready.filter { $0.currency == currency }
        let jobs = ready.compactMap { job($0.id) }
        let expenseIDs = Set(ready.flatMap { $0.facts.rebillable.filter { $0.currency == currency }.map(\.id) })
        return ReadyInvoice(clientID: clientID, currency: currency, jobs: jobs, expenses: expenses.filter { $0.id.map(expenseIDs.contains) ?? false })
    }
}

/// Events and receipts chosen to start an invoice from a ready client group.
struct ReadyInvoice: Identifiable {
    let id = UUID()
    let clientID: UUID
    let currency: String
    let jobs: [Job]
    let expenses: [Expense]
}

/// Every invoice and payment, by status. Reached from the month close.
struct PaymentsLedgerView: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Invoice.createdAt, ascending: false)]) private var invoices: FetchedResults<Invoice>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Job.startDay, ascending: false)]) private var jobs: FetchedResults<Job>
    @FetchRequest(sortDescriptors: []) private var invoiceRevisions: FetchedResults<InvoiceRevision>
    var body: some View {
        _ = invoiceRevisions.count
        let index = InvoiceIndex(in: context)
        let flagged = invoices.filter { $0.issue(in: context, index: index) != nil }
        let unknownFees = jobs.filter { $0.deletedAt == nil && (try? $0.currentFee()) == nil }
        return DaybookForm(title: "Invoices & payments") {
            if !flagged.isEmpty || !unknownFees.isEmpty {
                Section {
                    ForEach(flagged, id: \.objectID) { invoice in
                        DaybookLink { InvoiceDetailView(invoice: invoice) } label: {
                            VStack(alignment: .leading, spacing: 6) { Text(invoice.title); Text(invoice.issue(in: context, index: index) ?? "Needs review").font(.subheadline).foregroundStyle(Color("SecondaryText")) }
                        }
                    }
                    ForEach(unknownFees, id: \.objectID) { job in
                        DaybookLink("\(job.displayName) · Fee needs review") { FeeDetailView(job: job) }
                    }
                } header: { Text("Needs review") }
            }
            invoiceSection("Draft invoices") { value, _ in value.status == "draft" }
            invoiceSection("Awaiting payment") { $0.status == "sent" && $1 > 0 }
            invoiceSection("Paid invoices") { $0.status == "sent" && $1 <= 0 }
            if jobs.contains(where: { !($0.payments ?? []).isEmpty }) {
                Section("Direct payments") {
                    ForEach(jobs.filter { !($0.payments ?? []).isEmpty }, id: \.objectID) { job in
                        if job.deletedAt == nil {
                            DaybookLink { JobDetailView(job: job) } label: {
                                VStack(alignment: .leading, spacing: 4) { Text(job.displayName); Text(job.billingSummary(in: context, index: index)).font(.subheadline).foregroundStyle(Color("SecondaryText")) }
                            }
                        } else {
                            DisclosureGroup(job.displayName + " (deleted)") {
                                ForEach(Array(job.payments ?? []).sorted { ($0.receivedAt ?? .distantPast) > ($1.receivedAt ?? .distantPast) }, id: \.objectID) { payment in
                                    DaybookLink { ReceiptDetailView(payment: payment) } label: { Text(Money.format(payment.amount, currency: payment.currency)) }
                                }
                            }
                        }
                    }
                }
            }
            invoiceSection("Voided invoices") { value, _ in value.status == "void" }
            if jobs.isEmpty && invoices.isEmpty {
                Section { Text("No invoices or payments yet.").foregroundStyle(Color("SecondaryText")) }
            }
        }
        .navigationTitle("Invoices & payments").navigationBarTitleDisplayMode(.inline)
    }
    @ViewBuilder private func invoiceSection(_ title: String, matching: @escaping (InvoiceValue, Int64) -> Bool) -> some View {
        let matches = invoices.filter { invoice in
            guard let value = try? invoice.currentValue() else { return false }
            return matching(value, (try? invoice.balance()) ?? 1)
        }
        if !matches.isEmpty {
            Section(title) {
                ForEach(matches, id: \.objectID) { invoice in
                    DaybookLink { InvoiceDetailView(invoice: invoice) } label: { InvoiceRow(invoice: invoice) }
                }
            }
        }
    }
}

struct InvoiceRow: View {
    @ObservedObject var invoice: Invoice
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack { Text(invoice.title).font(.headline); Spacer() }
            Text(invoice.client?.name ?? "Client syncing").font(.subheadline)
            if let value = try? invoice.currentValue(), let balance = try? invoice.balance() {
                Text(value.status == "void" ? "Voided" : value.status == "draft" ? "Draft · \(Money.format((try? value.total()) ?? 0, currency: value.currency))" : balance < 0 ? "Credit · \(Money.format(-balance, currency: value.currency))" : "\(invoice.overdue ? "Overdue · " : "")\(Money.format(balance, currency: value.currency)) remaining")
                    .font(.subheadline).foregroundStyle(Color("SecondaryText")).monospacedDigit()
            }
        }.padding(.vertical, 4)
    }
}

private struct PresentedInvoice: Identifiable { let id = UUID(); let draft: InvoiceDraft }

struct InvoiceDetailView: View {
    @ObservedObject var invoice: Invoice
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: []) private var jobs: FetchedResults<Job>
    @State private var editing: PresentedInvoice?
    @State private var payment = false
    @State private var error: String?
    var body: some View {
        DaybookForm(title: invoice.title, subtitle: invoice.client?.name ?? "Client syncing") {
            if let issue = invoice.issue(in: context) { Section("Needs review") { Text(issue) } }
            if let value = try? invoice.currentValue() {
                Section {
                    BookingBadge(status: value.status)
                    if !value.sentDay.isEmpty { DaybookMetadata(symbol: "paperplane", text: "Sent · \(Day.display(value.sentDay))") }
                    if !value.dueDay.isEmpty { DaybookMetadata(symbol: "calendar", text: "\(invoice.overdue ? "Overdue since" : "Due") · \(Day.date(from: value.dueDay)?.formatted(date: .abbreviated, time: .omitted) ?? value.dueDay)") }
                    DaybookMetadata(symbol: CurrencyPreferences.symbol(value.currency), text: value.currency)
                }.containerValue(\.daybookUnframed, true)
                Section {
                    ForEach(value.lines) { line in
                        if let job = jobs.first(where: { $0.id == line.jobID && $0.deletedAt == nil }) {
                            DaybookLink { JobDetailView(job: job) } label: { LabeledContent(line.jobName, value: Money.format(line.amount, currency: value.currency)) }
                        } else { LabeledContent(line.jobName, value: Money.format(line.amount, currency: value.currency)) }
                    }
                } header: { Text("Billed bookings") } footer: { Text("Payments settle this invoice as a whole. Partial payments are not assigned to individual bookings.") }
                Section("Balance") {
                    LabeledContent("Total") { Text(Money.format((try? value.total()) ?? 0, currency: value.currency)).monospacedDigit().foregroundStyle(.primary) }
                        .padding(.vertical, 4)
                    if let paid = try? invoice.paid() { LabeledContent("Received") { Text(Money.format(paid, currency: value.currency)).monospacedDigit().foregroundStyle(.primary) }.padding(.vertical, 4) }
                    if let balance = try? invoice.balance() {
                        LabeledContent(balance < 0 ? "Credit" : "Remaining") { Text(Money.format(abs(balance), currency: value.currency)).fontWeight(.semibold).monospacedDigit().foregroundStyle(.primary) }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(balance < 0 ? "Credit" : "Remaining balance")
                            .accessibilityValue(Money.format(abs(balance), currency: value.currency))
                            .accessibilityIdentifier("invoice-balance")
                    }
                }
                if value.status == "sent" {
                    Section {
                        Button { payment = true } label: { Label("Record Payment", systemImage: "plus").frame(maxWidth: .infinity) }
                            .buttonStyle(DaybookPrimaryButton()).disabled(invoice.issue(in: context) != nil).accessibilityIdentifier("record-payment")
                    }
                }
                if !value.notes.isEmpty { Section("Notes") { Text(value.notes).textSelection(.enabled) } }
                Section("Payments") {
                    ReceiptLinks(records: Array(invoice.payments ?? []))

                }
            }
            if let heads = try? invoice.heads(), heads.count > 1 {
                Section("Resolve conflicting edits") {
                    ForEach(heads, id: \.objectID) { revision in
                        if let value = revision.value {
                            DisclosureGroup("\(value.reference.isEmpty ? "Draft invoice" : value.reference) · \(value.status.capitalized)") {
                                InvoiceSnapshot(value: value)
                                Button("Review This Version") { editing = PresentedInvoice(draft: InvoiceDraft(value: value, parents: Set(heads.compactMap(\.id)))) }
                            }
                        }
                    }
                }
            }
            Section("Invoice history") {
                ForEach((invoice.revisions ?? []).sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }, id: \.objectID) { revision in
                    if let value = revision.value {
                        DisclosureGroup("\(value.status.capitalized) · \(revision.createdAt?.formatted() ?? "Date unknown")") { InvoiceSnapshot(value: value) }
                    }
                }
            }
        }
        .navigationTitle("Invoice details").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if (try? invoice.currentValue()) != nil {
                Button("Edit") { do { editing = PresentedInvoice(draft: try InvoiceDraft(invoice: invoice)) } catch { self.error = error.localizedDescription } }.accessibilityIdentifier("edit-invoice")
            }
        }
        .sheet(item: $editing) { InvoiceEditorView(invoice: invoice, draft: $0.draft) }
        .sheet(isPresented: $payment) { PaymentEditorView(invoice: invoice) }
        .saveErrorAlert($error)
    }
}

private struct InvoiceSnapshot: View {
    let value: InvoiceValue
    var body: some View {
        Text(value.reference.isEmpty ? "No reference" : value.reference)
        ForEach(value.lines) { line in LabeledContent(line.jobName, value: Money.format(line.amount, currency: value.currency)) }
        if !value.sentDay.isEmpty { LabeledContent("Sent", value: Day.display(value.sentDay)) }
        if !value.dueDay.isEmpty { LabeledContent("Due", value: Day.display(value.dueDay)) }
        if !value.notes.isEmpty { Text(value.notes) }
    }
}

struct PaymentEditorView: View {
    var invoice: Invoice? = nil
    var job: Job? = nil
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var draft = PaymentDraft()
    @State private var initial: PaymentDraft?
    @State private var error: String?
    @State private var discard = false
    private var currency: String { (try? invoice?.currentValue().currency) ?? (try? job?.currentFee().currency) ?? "USD" }
    var body: some View {
        NavigationStack {
            DaybookForm {
                Section {
                    VStack(alignment: .leading, spacing: 7) {
                        Text(invoice?.title ?? job?.displayName ?? "").font(.title2.bold())
                        Text(invoice?.client?.name ?? job?.client?.name ?? "").font(.subheadline).foregroundStyle(Color("SecondaryText"))
                    }
                    if let balance = try? invoice?.balance() { LabeledContent("Balance before payment") { Text(Money.format(balance, currency: currency)).fontWeight(.semibold).monospacedDigit() } }
                }
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Amount received").font(.subheadline).foregroundStyle(Color("SecondaryText"))
                        HStack {
                        DaybookTextField("Amount", text: $draft.amount).keyboardType(.decimalPad).font(.title2.weight(.semibold))
                            .accessibilityLabel("Amount received").accessibilityIdentifier("payment-amount")
                        Text(currency).foregroundStyle(Color("SecondaryText"))
                        }
                    }.padding(.vertical, 4)
                    DatePicker("Received", selection: $draft.date, displayedComponents: .date)
                    DaybookTextField("Reference or note (optional)", text: $draft.note, axis: .vertical)
                    if let balance = try? invoice?.balance(), let amount = try? Money.parse(draft.amount, currency: currency), amount >= 0, let remaining = try? Money.minorUnits(Decimal(balance) - Decimal(amount)) {
                        LabeledContent(remaining < 0 ? "Credit after payment" : "Remaining after payment", value: Money.format(abs(remaining), currency: currency)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                } header: { Text("Payment") } footer: { Text("Each receipt is kept in history. To correct it later, reverse the receipt and record the corrected payment.") }
            }
            .navigationTitle("Record Payment").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if draft != initial { discard = true } else { dismiss() } }
                        .confirmationDialog("Discard payment?", isPresented: $discard, titleVisibility: .visible) {
                            Button("Discard Changes", role: .destructive) { dismiss() }
                            Button("Keep Editing", role: .cancel) {}
                        }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try draft.save(in: context, invoiceID: invoice?.objectID, jobID: job?.objectID); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("save-payment")
                }
            }
            .saveErrorAlert($error).interactiveDismissDisabled(draft != initial)
            .preservesDraftOnTodayLink()
            .onAppear { if initial == nil { initial = draft } }
        }
        .presentationSizing(.page)
        .presentationDetents([.large])
        .presentationBackground(Color("PageBackground"))
    }
}

struct ReceiptLinks: View {
    let records: [PaymentRecord]
    var body: some View {
        if records.isEmpty { Text("No payments recorded").foregroundStyle(Color("SecondaryText")) }
        ForEach(records.sorted { ($0.receivedAt ?? .distantPast) > ($1.receivedAt ?? .distantPast) }, id: \.objectID) { payment in
            DaybookLink { ReceiptDetailView(payment: payment) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Money.format(payment.amount, currency: payment.currency)).monospacedDigit()
                    Text("\(payment.reversesID == nil ? "Received" : "Reversal") · \(payment.receivedAt?.formatted(date: .abbreviated, time: .omitted) ?? "Date unknown")").font(.caption).foregroundStyle(Color("SecondaryText"))
                }
            }
        }
    }
}

struct ReceiptDetailView: View {
    @ObservedObject var payment: PaymentRecord
    @Environment(\.managedObjectContext) private var context
    @State private var reverse = false
    @State private var error: String?
    private var reversed: Bool { (payment.invoice?.payments ?? payment.job?.payments ?? []).contains { $0.reversesID == payment.id } }
    var body: some View {
        DaybookForm {
            Section {
                Text(Money.format(payment.amount, currency: payment.currency)).font(.title2).monospacedDigit()
                LabeledContent("Received", value: payment.receivedAt?.formatted(date: .abbreviated, time: .omitted) ?? "Unknown")
                LabeledContent("For", value: payment.invoice?.title ?? payment.job?.displayName ?? "Syncing")
                if !payment.note.isEmpty { Text(payment.note).textSelection(.enabled) }
                if reversed { Text("This receipt has been reversed. Both entries remain in history.") }
                else if payment.reversesID == nil { Button("Reverse Payment", role: .destructive) { reverse = true } }
            }
        }.navigationTitle(payment.reversesID == nil ? "Payment" : "Reversal").navigationBarTitleDisplayMode(.inline)
            .saveErrorAlert($error)
            .confirmationDialog("Reverse this payment? The original receipt will remain in history.", isPresented: $reverse, titleVisibility: .visible) {
                Button("Reverse Payment", role: .destructive) { do { try PaymentLedger.reverse(payment, in: context) } catch { self.error = error.localizedDescription } }
            }
    }
}

struct JobBillingSection: View {
    @ObservedObject var job: Job
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Invoice.createdAt, ascending: false)]) private var invoices: FetchedResults<Invoice>
    let onInvoice: () -> Void
    let onPayment: () -> Void
    var body: some View {
        Section {
            Text(job.billingSummary(in: context))
            ForEach(invoices.filter { invoice in (try? invoice.heads().contains { $0.value?.lines.contains { $0.jobID == job.id } ?? false }) == true }, id: \.objectID) { invoice in
                DaybookLink { InvoiceDetailView(invoice: invoice) } label: { InvoiceRow(invoice: invoice) }
            }
            if (try? job.activeInvoices(in: context).isEmpty) == true {
                if job.client != nil && (try? job.directPaid()) == 0 { Button("Add to Invoice", action: onInvoice).accessibilityIdentifier("add-job-invoice") }
                else if job.client == nil { Text("Add a client to include this booking on an invoice.").font(.subheadline).foregroundStyle(Color("SecondaryText")) }
                Button("Record Direct Payment", action: onPayment).accessibilityIdentifier("record-direct-payment")
            }
            ReceiptLinks(records: Array(job.payments ?? []))
        } header: { Text("Invoices & payments") }
    }
}
