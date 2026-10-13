import CoreData
import SwiftUI

struct InvoiceEditorView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Client.name, ascending: true)]) private var clients: FetchedResults<Client>
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Job.startDay, ascending: false)]) private var jobs: FetchedResults<Job>
    let invoice: Invoice?
    let locked: Bool
    @State private var draft: InvoiceDraft
    @State private var initial: InvoiceDraft
    @State private var clientID: String
    @State private var amounts: [UUID: String]
    @State private var initialAmounts: [UUID: String]
    @State private var error: String?
    @State private var discard = false
    init(invoice: Invoice? = nil, draft: InvoiceDraft? = nil, job: Job? = nil) {
        self.invoice = invoice
        locked = invoice?.revisions?.contains { $0.value?.status == "sent" } ?? false
        var value = draft ?? InvoiceDraft(clientID: job?.client?.id ?? UUID(), currency: (try? job?.currentFee().currency) ?? UserDefaults.standard.string(forKey: "defaultCurrency") ?? "USD")
        var amounts: [UUID: String] = [:]
        if let job, let id = job.id {
            let amount = try? job.currentFee().amount
            value.value.lines = [BilledLine(jobID: id, jobName: job.name, amount: amount ?? 0)]
            amounts[id] = Money.text(amount)
        } else { for line in value.value.lines { amounts[line.jobID] = Money.text(line.amount) } }
        _draft = State(initialValue: value); _initial = State(initialValue: value)
        _clientID = State(initialValue: (draft?.value.clientID ?? job?.client?.id)?.uuidString ?? "")
        _amounts = State(initialValue: amounts); _initialAmounts = State(initialValue: amounts)
    }
    private var changed: Bool { draft != initial || amounts != initialAmounts || clientID != (invoice == nil && initial.value.lines.isEmpty ? "" : initial.value.clientID.uuidString) }
    private var candidates: [Job] { jobs.filter { $0.client?.id?.uuidString == clientID && (try? $0.currentFee().currency) == draft.value.currency } }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Invoice reference", text: $draft.value.reference).accessibilityIdentifier("invoice-reference")
                    Picker("Client", selection: $clientID) {
                        Text("Choose client").tag("")
                        ForEach(clients, id: \.objectID) { if let id = $0.id { Text($0.name).tag(id.uuidString) } }
                    }.disabled(invoice != nil).accessibilityIdentifier("invoice-client")
                    Picker("Currency", selection: $draft.value.currency) { Text("USD").tag("USD"); Text("EUR").tag("EUR") }.disabled(locked)
                    if clients.isEmpty { Text("Add a client in Settings or on a job before creating an invoice.").foregroundStyle(.secondary) }
                } header: { Text("Invoice") } footer: { Text("Track an invoice you create elsewhere. Cuekeeper does not send documents.") }
                Section {
                    if !locked {
                        ForEach(candidates, id: \.objectID) { job in
                            if let id = job.id {
                                Toggle(job.name, isOn: Binding(get: { draft.value.lines.contains { $0.jobID == id } }, set: { selected in
                                    if selected {
                                        let amount = try? job.currentFee().amount
                                        draft.value.lines.append(BilledLine(jobID: id, jobName: job.name, amount: amount ?? 0)); amounts[id] = Money.text(amount)
                                    } else { draft.value.lines.removeAll { $0.jobID == id }; amounts.removeValue(forKey: id) }
                                }))
                                .disabled(!draft.value.lines.contains { $0.jobID == id } && !eligible(job))
                                .accessibilityIdentifier("invoice-job-\(job.name)")
                                if !eligible(job) && !draft.value.lines.contains(where: { $0.jobID == id }) {
                                    Text(job.billingSummary(in: context)).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    ForEach(draft.value.lines) { line in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(line.jobName)
                            TextField("Billed amount", text: Binding(get: { amounts[line.jobID] ?? "" }, set: { amounts[line.jobID] = $0 }))
                                .keyboardType(.decimalPad).disabled(locked).accessibilityIdentifier("billed-\(line.jobName)")
                        }
                    }
                    if draft.value.lines.isEmpty { Text("Select jobs for this client and currency.").foregroundStyle(.secondary) }
                    if let value = try? preparedValue(), let total = try? value.total() { LabeledContent("Total", value: Money.format(total, currency: value.currency)) }
                } header: { Text("Included jobs") } footer: { Text(locked ? "Billed amounts and jobs are preserved on sent invoices, independently of later fee changes." : "Each job can belong to one active invoice. Unknown fees need an explicit billed amount, including 0 for unpaid work.") }
                Section {
                    Picker("Status", selection: $draft.value.status) {
                        if !locked { Text("Draft").tag("draft") }
                        Text("Sent").tag("sent")
                        if invoice != nil { Text("Void").tag("void") }
                    }.pickerStyle(.menu).accessibilityIdentifier("invoice-status")
                    if draft.value.status == "sent" {
                        DatePicker("Sent", selection: dayBinding($draft.value.sentDay), displayedComponents: .date)
                    }
                    Toggle("Due date", isOn: Binding(get: { !draft.value.dueDay.isEmpty }, set: { draft.value.dueDay = $0 ? Day.string(from: Date()) : "" }))
                    if !draft.value.dueDay.isEmpty { DatePicker("Due", selection: dayBinding($draft.value.dueDay), displayedComponents: .date) }
                    if draft.value.status == "void" { Text("Voiding keeps the history and releases jobs for rebilling. Reverse any payments first.").foregroundStyle(.secondary) }
                }
                Section("Notes") { TextField("Invoice notes", text: $draft.value.notes, axis: .vertical).lineLimit(3...8) }
            }
            .navigationTitle(invoice == nil ? "Add Invoice" : "Edit Invoice").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if changed { discard = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do {
                            var save = draft; save.value = try preparedValue()
                            try save.save(in: context, editing: invoice?.objectID); dismiss()
                        } catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("save-invoice")
                }
            }
            .onChange(of: clientID) { _, value in
                if let id = UUID(uuidString: value) { draft.value.clientID = id }
                draft.value.lines = []; amounts = [:]
                if let client = clients.first(where: { $0.id?.uuidString == value }) { draft.value.currency = client.defaultCurrency }
            }
            .onChange(of: draft.value.currency) { _, _ in if !locked { draft.value.lines = []; amounts = [:] } }
            .onChange(of: draft.value.status) { _, status in if status == "sent" && draft.value.sentDay.isEmpty { draft.value.sentDay = Day.string(from: Date()) } }
            .saveErrorAlert($error).interactiveDismissDisabled(changed)
            .confirmationDialog("Discard changes?", isPresented: $discard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }; Button("Keep Editing", role: .cancel) {}
            }
        }
        .presentationSizing(.page)
        .presentationDetents([.large])
    }
    private func eligible(_ job: Job) -> Bool {
        guard let invoices = try? job.activeInvoices(in: context, excluding: invoice?.objectID), invoices.isEmpty,
              (try? job.directPaid()) == 0 else { return false }
        return true
    }
    private func preparedValue() throws -> InvoiceValue {
        guard let client = UUID(uuidString: clientID) else { throw RecordError.invalid("Choose a client.") }
        var value = draft.value; value.clientID = client
        for index in value.lines.indices {
            guard let amount = try Money.parse(amounts[value.lines[index].jobID] ?? "") else { throw RecordError.invalid("Enter a billed amount for each included job.") }
            value.lines[index].amount = amount
        }
        try value.validate(); return value
    }
    private func dayBinding(_ binding: Binding<String>) -> Binding<Date> {
        Binding(get: { Day.date(from: binding.wrappedValue) ?? Date() }, set: { binding.wrappedValue = Day.string(from: $0) })
    }
}
