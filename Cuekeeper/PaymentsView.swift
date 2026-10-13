import CoreData
import SwiftUI

struct PaymentsView: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Invoice.createdAt, ascending: false)]) private var invoices: FetchedResults<Invoice>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Job.startDay, ascending: false)]) private var jobs: FetchedResults<Job>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \PaymentRecord.receivedAt, ascending: false)]) private var payments: FetchedResults<PaymentRecord>
    @State private var adding = false
    var body: some View {
        List {
            ForEach(["USD", "EUR"], id: \.self) { currency in
                Section {
                    LabeledContent("Expected job fees") { Text(total(currency, kind: 0)).foregroundStyle(.primary) }
                    LabeledContent("Invoiced outstanding") { Text(total(currency, kind: 1)).foregroundStyle(.primary) }
                    LabeledContent("Payments received") { Text(total(currency, kind: 2)).foregroundStyle(.primary) }
                } header: { Text(currency) } footer: {
                    if currency == "EUR" { Text("Expected fees include known fees on non-cancelled jobs, including invoiced jobs. They are not added to invoice balances. Records needing review are excluded from outstanding totals.") }
                }
            }
            if invoices.contains(where: { $0.issue(in: context) != nil }) || jobs.contains(where: { (try? $0.currentFee()) == nil }) {
            Section {
                ForEach(invoices.filter { $0.issue(in: context) != nil }, id: \.objectID) { invoice in
                    NavigationLink { InvoiceDetailView(invoice: invoice) } label: {
                        VStack(alignment: .leading, spacing: 6) { Text(invoice.title); Text(invoice.issue(in: context) ?? "Needs review").font(.subheadline).foregroundStyle(.secondary) }
                    }
                }
                ForEach(jobs.filter { (try? $0.currentFee()) == nil }, id: \.objectID) { job in
                    NavigationLink("\(job.name) · Fee needs review") { FeeDetailView(job: job) }
                }
            } header: { Text("Needs review") }
            }
            if !readyJobs.isEmpty {
            Section("Ready to invoice") {
                ForEach(readyJobs, id: \.objectID) { job in
                    NavigationLink { JobDetailView(job: job) } label: {
                        LabeledContent(job.name, value: job.feeSummary)
                    }
                }
            }
            }
            invoiceSection("Draft invoices", status: "draft")
            if invoices.contains(where: { (try? $0.currentValue().status) == "sent" && ((try? $0.balance()) ?? 0) > 0 }) {
            Section("Sent · Outstanding") {
                ForEach(invoices.filter { (try? $0.currentValue().status) == "sent" && ((try? $0.balance()) ?? 0) > 0 }, id: \.objectID) { invoice in
                    NavigationLink { InvoiceDetailView(invoice: invoice) } label: { InvoiceRow(invoice: invoice) }
                }
            }
            }
            if invoices.contains(where: { (try? $0.currentValue().status) == "sent" && ((try? $0.balance()) ?? 1) <= 0 }) {
            Section("Paid invoices") {
                ForEach(invoices.filter { (try? $0.currentValue().status) == "sent" && ((try? $0.balance()) ?? 1) <= 0 }, id: \.objectID) { invoice in
                    NavigationLink { InvoiceDetailView(invoice: invoice) } label: { InvoiceRow(invoice: invoice) }
                }
            }
            }
            if jobs.contains(where: { !($0.payments ?? []).isEmpty }) {
            Section("Direct payments") {
                ForEach(jobs.filter { !($0.payments ?? []).isEmpty }, id: \.objectID) { job in
                    NavigationLink { JobDetailView(job: job) } label: {
                        VStack(alignment: .leading, spacing: 4) { Text(job.name); Text(job.billingSummary(in: context)).font(.subheadline).foregroundStyle(.secondary) }
                    }
                }
            }
            }
            invoiceSection("Voided invoices", status: "void")
            if jobs.isEmpty && invoices.isEmpty {
                Section { Text("Add jobs and their fees to start tracking invoices and payments. You can leave fees unknown until they’re agreed.").foregroundStyle(.secondary) }
            }
        }
        .navigationTitle("Payments")
        .toolbar { Button("Add Invoice", systemImage: "plus") { adding = true }.accessibilityIdentifier("add-invoice-overview") }
        .sheet(isPresented: $adding) { InvoiceEditorView() }
    }
    private var readyJobs: [Job] {
        jobs.filter { $0.bookingStatus != "cancelled" && $0.client != nil && (try? $0.activeInvoices(in: context).isEmpty) == true && (try? $0.directPaid()) == 0 && (try? $0.currentFee().amount) != nil }
    }
    @ViewBuilder private func invoiceSection(_ title: String, status: String) -> some View {
        if invoices.contains(where: { (try? $0.currentValue().status) == status }) {
        Section(title) {
            ForEach(invoices.filter { (try? $0.currentValue().status) == status }, id: \.objectID) { invoice in
                NavigationLink { InvoiceDetailView(invoice: invoice) } label: { InvoiceRow(invoice: invoice) }
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
                for job in jobs where job.bookingStatus != "cancelled" {
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

struct InvoiceRow: View {
    @ObservedObject var invoice: Invoice
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(invoice.title).font(.headline)
            Text(invoice.client?.name ?? "Client syncing").font(.subheadline)
            if let value = try? invoice.currentValue(), let balance = try? invoice.balance() {
                Text(value.status == "void" ? "Voided" : value.status == "draft" ? "Draft · \(Money.format((try? value.total()) ?? 0, currency: value.currency))" : balance < 0 ? "Credit · \(Money.format(-balance, currency: value.currency))" : "\(invoice.overdue ? "Overdue · " : "")\(Money.format(balance, currency: value.currency)) remaining")
                    .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
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
        Form {
            if let issue = invoice.issue(in: context) { Section("Needs review") { Text(issue) } }
            if let value = try? invoice.currentValue() {
                Section("Invoice") {
                    LabeledContent("Client", value: invoice.client?.name ?? "Syncing")
                    LabeledContent("Status", value: value.status.capitalized)
                    LabeledContent("Total", value: Money.format((try? value.total()) ?? 0, currency: value.currency))
                    if let paid = try? invoice.paid() { LabeledContent("Received", value: Money.format(paid, currency: value.currency)) }
                    if let balance = try? invoice.balance() {
                        LabeledContent(balance < 0 ? "Credit" : "Remaining") { Text(Money.format(abs(balance), currency: value.currency)).foregroundStyle(.primary) }
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel(balance < 0 ? "Credit" : "Remaining balance")
                            .accessibilityValue(Money.format(abs(balance), currency: value.currency))
                            .accessibilityIdentifier("invoice-balance")
                    }
                    if !value.sentDay.isEmpty { LabeledContent("Sent", value: value.sentDay) }
                    if !value.dueDay.isEmpty { LabeledContent(invoice.overdue ? "Overdue since" : "Due", value: value.dueDay) }
                }
                Section {
                    ForEach(value.lines) { line in
                        if let job = jobs.first(where: { $0.id == line.jobID }) {
                            NavigationLink { JobDetailView(job: job) } label: { LabeledContent(line.jobName, value: Money.format(line.amount, currency: value.currency)) }
                        } else { LabeledContent(line.jobName, value: Money.format(line.amount, currency: value.currency)) }
                    }
                } header: { Text("Billed jobs") } footer: { Text("Payments settle this invoice as a whole. Partial payments are not assigned to individual jobs.") }
                if !value.notes.isEmpty { Section("Notes") { Text(value.notes).textSelection(.enabled) } }
                Section("Payments") {
                    ReceiptLinks(records: Array(invoice.payments ?? []))
                    if value.status == "sent" { Button("Record Payment", systemImage: "plus") { payment = true }.disabled(invoice.issue(in: context) != nil).accessibilityIdentifier("record-payment") }
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
        .navigationTitle(invoice.title).navigationBarTitleDisplayMode(.inline)
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
            Form {
                Section {
                    LabeledContent("For", value: invoice?.title ?? job?.name ?? "")
                    LabeledContent("Currency", value: currency)
                    TextField("Amount received", text: $draft.amount).keyboardType(.decimalPad).accessibilityIdentifier("payment-amount")
                    DatePicker("Received", selection: $draft.date, displayedComponents: .date)
                    TextField("Reference or note (optional)", text: $draft.note, axis: .vertical)
                } footer: { Text("Each receipt is kept in history. To correct it later, reverse the receipt and record the corrected payment.") }
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
    }
}

struct ReceiptLinks: View {
    let records: [PaymentRecord]
    var body: some View {
        if records.isEmpty { Text("No payments recorded").foregroundStyle(.secondary) }
        ForEach(records.sorted { ($0.receivedAt ?? .distantPast) > ($1.receivedAt ?? .distantPast) }, id: \.objectID) { payment in
            NavigationLink { ReceiptDetailView(payment: payment) } label: {
                VStack(alignment: .leading, spacing: 4) {
                    Text(Money.format(payment.amount, currency: payment.currency)).monospacedDigit()
                    Text("\(payment.reversesID == nil ? "Received" : "Reversal") · \(payment.receivedAt?.formatted(date: .abbreviated, time: .omitted) ?? "Date unknown")").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }
}

private struct ReceiptDetailView: View {
    @ObservedObject var payment: PaymentRecord
    @Environment(\.managedObjectContext) private var context
    @State private var reverse = false
    @State private var error: String?
    private var reversed: Bool { (payment.invoice?.payments ?? payment.job?.payments ?? []).contains { $0.reversesID == payment.id } }
    var body: some View {
        Form {
            Section {
                Text(Money.format(payment.amount, currency: payment.currency)).font(.title2).monospacedDigit()
                LabeledContent("Received", value: payment.receivedAt?.formatted(date: .abbreviated, time: .omitted) ?? "Unknown")
                LabeledContent("For", value: payment.invoice?.title ?? payment.job?.name ?? "Syncing")
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
                NavigationLink { InvoiceDetailView(invoice: invoice) } label: { InvoiceRow(invoice: invoice) }
            }
            if (try? job.activeInvoices(in: context).isEmpty) == true {
                if job.client != nil && (try? job.directPaid()) == 0 { Button("Add to Invoice", action: onInvoice).accessibilityIdentifier("add-job-invoice") }
                else if job.client == nil { Text("Add a client to include this job on an invoice.").font(.subheadline).foregroundStyle(.secondary) }
                Button("Record Direct Payment", action: onPayment).accessibilityIdentifier("record-direct-payment")
            }
            ReceiptLinks(records: Array(job.payments ?? []))
        } header: { Text("Invoices & payments") }
    }
}
