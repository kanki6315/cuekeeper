import CoreData
import SwiftUI

struct PaymentsView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Invoice.createdAt, ascending: false)]) private var invoices: FetchedResults<Invoice>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Job.startDay, ascending: false)]) private var jobs: FetchedResults<Job>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \PaymentRecord.receivedAt, ascending: false)]) private var payments: FetchedResults<PaymentRecord>
    @FetchRequest(sortDescriptors: []) private var invoiceRevisions: FetchedResults<InvoiceRevision>
    @State private var adding = false
    var body: some View {
        // Revision arrivals must refresh eligibility even when job rows do not change.
        _ = invoiceRevisions.count
        let index = InvoiceIndex(in: context)
        let ready = readyJobs(index: index)
        return DaybookForm(topPadding: 12) {
            Section {
                DaybookTabHeader {
                    Button { adding = true } label: { Label("Invoice", systemImage: "plus") }
                        .buttonStyle(DaybookPrimaryButton())
                        .accessibilityLabel("Add Invoice")
                        .accessibilityIdentifier("add-invoice-overview")
                }
            }.containerValue(\.daybookUnframed, true)
                .containerValue(\.daybookFlushTop, true)
            Section { PendingExpensesPrompt(alwaysVisible: true) }
            Section {
                if typeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 20) {
                        ForEach(0..<3) { kind in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(["Expected booking fees", "Invoiced outstanding", "Payments received"][kind]).font(.headline)
                                Text("USD · \(total("USD", kind: kind))").monospacedDigit()
                                Text("EUR · \(total("EUR", kind: kind))").monospacedDigit()
                            }
                        }
                    }
                } else {
                Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 16) {
                    GridRow { Text(""); Text("USD"); Text("EUR") }.font(.caption.weight(.semibold)).foregroundStyle(Color("SecondaryText"))
                    ForEach(0..<3) { kind in
                        if kind > 0 { Divider().gridCellColumns(3) }
                        GridRow {
                            Text(["Expected booking fees", "Invoiced outstanding", "Payments received"][kind]).font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                            Text(total("USD", kind: kind)).monospacedDigit().fontWeight(kind == 1 ? .semibold : .regular)
                            Text(total("EUR", kind: kind)).monospacedDigit().fontWeight(kind == 1 ? .semibold : .regular)
                        }.font(.subheadline)
                    }
                }.fixedSize(horizontal: false, vertical: true)
                }
            }
            if invoices.contains(where: { $0.issue(in: context, index: index) != nil }) || jobs.contains(where: { $0.deletedAt == nil && (try? $0.currentFee()) == nil }) {
            Section {
                ForEach(invoices.filter { $0.issue(in: context, index: index) != nil }, id: \.objectID) { invoice in
                    DaybookLink { InvoiceDetailView(invoice: invoice) } label: {
                        VStack(alignment: .leading, spacing: 6) { Text(invoice.title); Text(invoice.issue(in: context, index: index) ?? "Needs review").font(.subheadline).foregroundStyle(Color("SecondaryText")) }
                    }
                }
                ForEach(jobs.filter { $0.deletedAt == nil && (try? $0.currentFee()) == nil }, id: \.objectID) { job in
                    DaybookLink("\(job.displayName) · Fee needs review") { FeeDetailView(job: job) }
                }
            } header: { Text("Needs review") }
            }
            if !ready.isEmpty {
            Section("Ready to invoice") {
                ForEach(readyClientGroups(jobs: ready), id: \.client.objectID) { group in
                    ReadyClientRow(client: group.client, jobs: group.jobs)
                }
            }
            }
            invoiceSection("Draft invoices", status: "draft")
            if invoices.contains(where: { (try? $0.currentValue().status) == "sent" && ((try? $0.balance()) ?? 0) > 0 }) {
            Section("Awaiting payment") {
                ForEach(invoices.filter { (try? $0.currentValue().status) == "sent" && ((try? $0.balance()) ?? 0) > 0 }, id: \.objectID) { invoice in
                    DaybookLink { InvoiceDetailView(invoice: invoice) } label: { InvoiceRow(invoice: invoice) }
                }
            }
            }
            if invoices.contains(where: { (try? $0.currentValue().status) == "sent" && ((try? $0.balance()) ?? 1) <= 0 }) {
            Section("Paid invoices") {
                ForEach(invoices.filter { (try? $0.currentValue().status) == "sent" && ((try? $0.balance()) ?? 1) <= 0 }, id: \.objectID) { invoice in
                    DaybookLink { InvoiceDetailView(invoice: invoice) } label: { InvoiceRow(invoice: invoice) }
                }
            }
            }
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
            invoiceSection("Voided invoices", status: "void")
            if jobs.isEmpty && invoices.isEmpty {
                Section { Text("Add events and fees to start tracking invoices and payments. You can leave fees unknown until they’re agreed.").foregroundStyle(Color("SecondaryText")) }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(sizeClass == .compact ? .hidden : .visible, for: .navigationBar)
        .sheet(isPresented: $adding) { InvoiceEditorView() }
    }
    private func readyJobs(index: InvoiceIndex) -> [Job] {
        jobs.filter { $0.deletedAt == nil && $0.bookingStatus != "cancelled" && $0.client != nil && (try? $0.activeInvoices(in: context, index: index).isEmpty) == true && (try? $0.directPaid()) == 0 && (try? $0.currentFee().amount) != nil }
    }
    private func readyClientGroups(jobs: [Job]) -> [(client: Client, jobs: [Job])] {
        Dictionary(grouping: jobs, by: { $0.client! }).map { (client: $0.key, jobs: $0.value) }
            .sorted {
                let order = $0.client.name.localizedStandardCompare($1.client.name)
                return order == .orderedSame
                    ? $0.client.objectID.uriRepresentation().absoluteString < $1.client.objectID.uriRepresentation().absoluteString
                    : order == .orderedAscending
            }
    }
    @ViewBuilder private func invoiceSection(_ title: String, status: String) -> some View {
        if invoices.contains(where: { (try? $0.currentValue().status) == status }) {
        Section(title) {
            ForEach(invoices.filter { (try? $0.currentValue().status) == status }, id: \.objectID) { invoice in
                DaybookLink { InvoiceDetailView(invoice: invoice) } label: { InvoiceRow(invoice: invoice) }
            }
        }
    }
    }
    private func total(_ currency: String, kind: Int) -> String {
        // Observe receipts directly as well as their parent relationships.
        _ = payments.count
        do {
            var sum = Decimal(0)
            if kind == 0 {
                for job in jobs where job.deletedAt == nil && job.bookingStatus != "cancelled" {
                    guard let fee = try? job.currentFee(), fee.currency == currency, let amount = fee.amount else { continue }
                    sum += Decimal(amount)
                }
            } else if kind == 1 {
                for invoice in invoices where invoice.issue(in: context) == nil {
                    let value = try invoice.currentValue()
                    if value.currency == currency && value.status == "sent" { sum += Decimal(max(0, try invoice.balance())) }
                }
            } else {
                var groups: [String: [PaymentRecord]] = [:]
                for record in payments {
                    let key: String
                    if let id = record.invoice?.id, record.job == nil { key = "invoice/\(id)" }
                    else if let id = record.job?.id, record.invoice == nil { key = "job/\(id)" }
                    else { throw RecordError.invalid("A receipt is still syncing.") }
                    groups[key, default: []].append(record)
                }
                for records in groups.values {
                    let net = try PaymentLedger.net(records)
                    if records.first?.currency == currency { sum += Decimal(net) }
                }
            }
            return Money.format(try Money.minorUnits(sum), currency: currency)
        } catch { return "Needs review" }
    }
}

private struct ReadyClientRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ObservedObject var client: Client
    let jobs: [Job]
    @State private var expanded = false

    private var totals: [(currency: String, amount: String)] {
        let fees = jobs.compactMap { try? $0.currentFee() }
        return Dictionary(grouping: fees, by: \.currency).sorted { $0.key < $1.key }.map { currency, fees in
            let sum = fees.reduce(Decimal(0)) { $0 + Decimal($1.amount ?? 0) }
            let amount = (try? Money.minorUnits(sum)).map { Money.format($0, currency: currency) } ?? "Needs review"
            return (currency, amount)
        }
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            VStack(spacing: 0) {
                ForEach(jobs, id: \.objectID) { job in
                    Divider().padding(.vertical, 10)
                    DaybookLink { JobDetailView(job: job) } label: {
                        let layout = typeSize.isAccessibilitySize
                            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                            : AnyLayout(HStackLayout(spacing: 12))
                        layout {
                            VStack(alignment: .leading, spacing: 5) {
                                Text(job.displayName).font(.headline)
                                Text(dateRange(job)).font(.subheadline).foregroundStyle(Color("SecondaryText"))
                            }
                            if !typeSize.isAccessibilitySize { Spacer() }
                            Text(job.feeSummary).font(.subheadline).monospacedDigit()
                        }.frame(minHeight: 44)
                    }
                }
            }
        } label: {
            let layout = typeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8))
                : AnyLayout(HStackLayout(spacing: 12))
            layout {
                VStack(alignment: .leading, spacing: 5) {
                    Text(client.name).font(.headline)
                    Text("\(jobs.count) \(jobs.count == 1 ? "event" : "events")")
                        .font(.subheadline).foregroundStyle(Color("SecondaryText"))
                }
                if !typeSize.isAccessibilitySize { Spacer() }
                VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 4) {
                    ForEach(totals, id: \.currency) { total in
                        Text("\(total.currency) · \(total.amount)").font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                }
            }.foregroundStyle(Color.primary).frame(minHeight: 44)
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
                    if !value.sentDay.isEmpty { DaybookMetadata(symbol: "paperplane", text: "Sent · \(Day.date(from: value.sentDay)?.formatted(date: .abbreviated, time: .omitted) ?? value.sentDay)") }
                    if !value.dueDay.isEmpty { DaybookMetadata(symbol: "calendar", text: "\(invoice.overdue ? "Overdue since" : "Due") · \(Day.date(from: value.dueDay)?.formatted(date: .abbreviated, time: .omitted) ?? value.dueDay)") }
                    DaybookMetadata(symbol: "dollarsign.circle", text: value.currency)
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
        if !value.sentDay.isEmpty { LabeledContent("Sent", value: value.sentDay) }
        if !value.dueDay.isEmpty { LabeledContent("Due", value: value.dueDay) }
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
                    if let balance = try? invoice?.balance(), let amount = try? Money.parse(draft.amount), amount >= 0, let remaining = try? Money.minorUnits(Decimal(balance) - Decimal(amount)) {
                        LabeledContent(remaining < 0 ? "Credit after payment" : "Remaining after payment", value: Money.format(abs(remaining), currency: currency)).font(.subheadline.weight(.semibold)).monospacedDigit()
                    }
                } header: { Text("Payment") } footer: { Text("Each receipt is kept in history. To correct it later, reverse the receipt and record the corrected payment.") }
            }
            .navigationTitle("Record Payment").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if draft != initial { discard = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try draft.save(in: context, invoiceID: invoice?.objectID, jobID: job?.objectID); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("save-payment")
                }
            }
            .saveErrorAlert($error).interactiveDismissDisabled(draft != initial)
            .onAppear { if initial == nil { initial = draft } }
            .confirmationDialog("Discard payment?", isPresented: $discard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }; Button("Keep Editing", role: .cancel) {}
            }
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
