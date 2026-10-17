import CoreData
import Foundation

struct BilledLine: Codable, Equatable, Identifiable {
    var jobID: UUID
    var jobName: String
    var amount: Int64
    var id: UUID { jobID }
}

/// A reimbursable receipt billed on an invoice.
struct BilledExpense: Codable, Equatable, Identifiable {
    var expenseID: UUID
    var label: String
    var amount: Int64
    var id: UUID { expenseID }
}

/// What a client needs on file before their work can be invoiced.
struct ClientInvoicing: Codable, Equatable {
    var billingName = ""
    var email = ""
    var address = ""
    var termsDays: Int?
    var taxID = ""
    /// Missing required details, in the order a person would fill them in.
    var missing: [String] {
        var gaps: [String] = []
        if billingName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { gaps.append("billing name") }
        if email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { gaps.append("billing email") }
        if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { gaps.append("address") }
        if termsDays == nil { gaps.append("payment terms") }
        return gaps
    }
    var isComplete: Bool { missing.isEmpty }
    func validate() throws {
        if let termsDays, !(0...365).contains(termsDays) { throw RecordError.invalid("Payment terms must be between 0 and 365 days.") }
        let email = email.trimmingCharacters(in: .whitespacesAndNewlines)
        if !email.isEmpty && (!email.contains("@") || email.contains(" ")) { throw RecordError.invalid("Enter a valid billing email.") }
    }
    /// The due day for an invoice sent on `sentDay`, when terms are known.
    func dueDay(sent sentDay: String) -> String? {
        guard let termsDays, let sent = Day.date(from: sentDay), let due = Calendar.current.date(byAdding: .day, value: termsDays, to: sent) else { return nil }
        return Day.string(from: due)
    }
}

extension Client {
    var invoicing: ClientInvoicing {
        guard !invoicingJSON.isEmpty, let value = try? JSONDecoder().decode(ClientInvoicing.self, from: Data(invoicingJSON.utf8)) else { return ClientInvoicing() }
        return value
    }
    static func saveInvoicing(_ value: ClientInvoicing, client id: NSManagedObjectID, in context: NSManagedObjectContext) throws {
        try value.validate()
        let writer = isolatedWriter(context)
        let client = try writer.existingObject(with: id) as! Client
        client.invoicingJSON = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try writer.save(); context.refreshAllObjects()
    }
}

struct InvoiceValue: Codable, Equatable {
    var clientID: UUID
    var currency = "USD"
    var reference = ""
    var status = "draft"
    var sentDay = ""
    var dueDay = ""
    var notes = ""
    var lines: [BilledLine] = []
    var expenseLines: [BilledExpense] = []
    /// True while the due date follows the client's terms from the sent date. A chosen due date clears it.
    var dueDayAutomatic = false
    /// The form references are compared in: one client cannot have two active invoices with the same one.
    static func referenceKey(_ reference: String) -> String { reference.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() }

    /// Marks the invoice sent, today unless a sent date is set. An empty due date then follows the client's terms.
    mutating func markSent(today: String, terms: ClientInvoicing?) {
        if sentDay.isEmpty { sentDay = today }
        if dueDay.isEmpty { dueDayAutomatic = true }
        followTerms(terms)
    }
    /// Moves an automatic due date with the sent date. A chosen due date stays put.
    mutating func followTerms(_ terms: ClientInvoicing?) {
        guard dueDayAutomatic else { return }
        if let due = terms?.dueDay(sent: sentDay) { dueDay = due } else if dueDay.isEmpty { dueDayAutomatic = false }
    }
    /// Turns the due date on from the client's terms when known, else today; off clears it.
    mutating func showDue(_ on: Bool, today: String, terms: ClientInvoicing?) {
        guard on else { dueDay = ""; dueDayAutomatic = false; return }
        dueDayAutomatic = true; dueDay = ""
        followTerms(terms)
        if dueDay.isEmpty { chooseDue(today) }
    }
    mutating func chooseDue(_ day: String) { dueDay = day; dueDayAutomatic = false }
    func total() throws -> Int64 {
        try Money.minorUnits(lines.reduce(Decimal(0)) { $0 + Decimal($1.amount) } + expenseLines.reduce(Decimal(0)) { $0 + Decimal($1.amount) })
    }
    func validate() throws {
        guard CurrencyPreferences.supported.contains(currency), ["draft", "sent", "void"].contains(status) else { throw RecordError.invalid("Choose a valid invoice currency and status.") }
        // A receipts-only invoice bills late or other-currency receipts without billing their event again.
        guard !lines.isEmpty || !expenseLines.isEmpty, Set(lines.map(\.jobID)).count == lines.count, lines.allSatisfy({ $0.amount >= 0 && $0.amount <= Money.limit }) else {
            throw RecordError.invalid("Include at least one job or receipt, each once, with a nonnegative billed amount.")
        }
        guard Set(expenseLines.map(\.expenseID)).count == expenseLines.count, expenseLines.allSatisfy({ $0.amount >= 0 && $0.amount <= Money.limit }) else {
            throw RecordError.invalid("Include each receipt once, with a nonnegative amount.")
        }
        if status == "sent" && (reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || Day.date(from: sentDay) == nil) {
            throw RecordError.invalid("Add an invoice reference and sent date before marking it sent.")
        }
        if !dueDay.isEmpty && (Day.date(from: dueDay) == nil || (!sentDay.isEmpty && dueDay < sentDay)) { throw RecordError.invalid("The due date must be on or after the sent date.") }
        _ = try total()
    }
    func sameBilledTerms(as other: InvoiceValue) -> Bool { clientID == other.clientID && currency == other.currency && lines == other.lines && expenseLines == other.expenseLines }
}

@objc(Invoice)
final class Invoice: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var createdAt: Date?
    @NSManaged var client: Client?
    @NSManaged var revisions: Set<InvoiceRevision>?
    @NSManaged var payments: Set<PaymentRecord>?
    func heads() throws -> [InvoiceRevision] {
        let records = Array(revisions ?? [])
        let ids = Set(records.compactMap(\.id)); var parents = Set<UUID>()
        guard !records.isEmpty, ids.count == records.count else { throw RecordError.invalid("Invoice history is incomplete. Wait for sync before editing or recording payments.") }
        for record in records {
            guard let value = record.value, let prior = try? JSONDecoder().decode([UUID].self, from: Data(record.parentsJSON.utf8)), Set(prior).isSubset(of: ids) else {
                throw RecordError.invalid("Invoice history is still syncing or unreadable. No financial history has been discarded.")
            }
            try value.validate(); parents.formUnion(prior)
        }
        let heads = records.filter { !parents.contains($0.id!) }.sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        guard !heads.isEmpty else { throw RecordError.invalid("Invoice history could not be resolved.") }
        return heads
    }
    func currentValue() throws -> InvoiceValue {
        let heads = try heads()
        guard heads.count == 1, let value = heads.first?.value else { throw RecordError.invalid("This invoice has conflicting edits. Review the versions before recording payments.") }
        return value
    }
    var title: String { (try? currentValue()).map { $0.reference.isEmpty ? "Draft invoice" : $0.reference } ?? "Invoice needs review" }
    func paid() throws -> Int64 { try PaymentLedger.net(Array(payments ?? [])) }
    func balance() throws -> Int64 {
        let value = try currentValue()
        return value.status == "void" ? 0 : try value.total() - paid()
    }
    func issue(in context: NSManagedObjectContext, index: InvoiceIndex? = nil) -> String? {
        do {
            let value = try currentValue(); _ = try paid()
            if value.status == "void" { return nil }
            let index = index ?? InvoiceIndex(in: context)
            for line in value.lines {
                let request = NSFetchRequest<Job>(entityName: "Job"); request.predicate = NSPredicate(format: "id == %@", line.jobID as CVarArg)
                guard let job = try context.fetch(request).first else { return "An included job is still syncing." }
                if try job.activeInvoices(in: context, index: index).count > 1 { return "A job appears on multiple active invoices. Void the duplicate invoice to resolve this." }
                if try job.directPaid() > 0 { return "An included job also has direct payments. Review and reverse the receipt if it belongs on this invoice." }
            }
            for line in value.expenseLines {
                let request = NSFetchRequest<Expense>(entityName: "Expense"); request.predicate = NSPredicate(format: "id == %@", line.expenseID as CVarArg)
                guard let expense = try context.fetch(request).first else { return "An included receipt is still syncing." }
                if try expense.activeInvoices(index: index).count > 1 { return "A receipt appears on multiple active invoices. Void the duplicate invoice to resolve this." }
            }
            return nil
        } catch { return error.localizedDescription }
    }
    /// A reference this invoice shares with another of the client's active invoices, such as after offline edits sync.
    /// Both records are kept; changing one reference or voiding the duplicate resolves it.
    func duplicateReference(index: InvoiceIndex) -> String? {
        guard let value = try? currentValue(), value.status != "void", !index.invoices(sharing: value.reference, client: value.clientID, excluding: objectID).isEmpty else { return nil }
        return "Another invoice for this client also uses \(value.reference). Edit one reference, or void the duplicate."
    }
    var overdue: Bool { guard let value = try? currentValue(), value.status == "sent", !value.dueDay.isEmpty, value.dueDay < Day.string(from: Date()), let balance = try? balance() else { return false }; return balance > 0 }
}

@objc(InvoiceRevision)
final class InvoiceRevision: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var createdAt: Date?
    @NSManaged var parentsJSON: String
    @NSManaged var valueJSON: String
    @NSManaged var invoice: Invoice?
    var value: InvoiceValue? { try? JSONDecoder().decode(InvoiceValue.self, from: Data(valueJSON.utf8)) }
}

@objc(PaymentRecord)
final class PaymentRecord: NSManagedObject {
    @NSManaged var id: UUID?
    @NSManaged var createdAt: Date?
    @NSManaged var receivedAt: Date?
    @NSManaged var amount: Int64
    @NSManaged var currency: String
    @NSManaged var note: String
    @NSManaged var reversesID: UUID?
    @NSManaged var job: Job?
    @NSManaged var invoice: Invoice?
}

enum PaymentLedger {
    static func net(_ records: [PaymentRecord]) throws -> Int64 {
        guard records.allSatisfy({ $0.id != nil && $0.receivedAt != nil && $0.createdAt != nil && CurrencyPreferences.supported.contains($0.currency) && $0.amount != 0 }) else {
            throw RecordError.invalid("Payment history is incomplete. Wait for sync before changing this balance.")
        }
        var originals: [UUID: PaymentRecord] = [:]
        for record in records where record.reversesID == nil {
            guard let id = record.id, record.amount > 0, originals[id] == nil else { throw RecordError.invalid("Payment history contains an incomplete or duplicate receipt. Review sync before changing this balance.") }
            originals[id] = record
        }
        var reversed = Set<UUID>()
        for record in records {
            if let id = record.reversesID {
                guard let original = originals[id], record.amount == -original.amount, record.currency == original.currency else { throw RecordError.invalid("A payment correction is waiting for its original receipt to sync.") }
                reversed.insert(id) // Concurrent corrections reverse a receipt only once.
            }
        }
        guard Set(records.map(\.currency)).count <= 1 else { throw RecordError.invalid("Payment currencies do not match. Review this record before using its balance.") }
        return try Money.minorUnits(originals.filter { !reversed.contains($0.key) }.values.reduce(Decimal(0)) { $0 + Decimal($1.amount) })
    }
    static func reverse(_ payment: PaymentRecord, in context: NSManagedObjectContext) throws {
        let writer = isolatedWriter(context)
        let original = try writer.existingObject(with: payment.objectID) as! PaymentRecord
        guard original.reversesID == nil, let id = original.id else { throw RecordError.invalid("Only an original payment can be reversed.") }
        let siblings = original.invoice?.payments ?? original.job?.payments ?? []
        guard !siblings.contains(where: { $0.reversesID == id }) else { throw RecordError.invalid("This payment has already been reversed.") }
        let reversal = PaymentRecord(entity: NSEntityDescription.entity(forEntityName: "PaymentRecord", in: writer)!, insertInto: writer)
        reversal.id = UUID(); reversal.createdAt = Date(); reversal.receivedAt = Date()
        reversal.amount = -original.amount; reversal.currency = original.currency; reversal.note = "Reversal of \(original.note.isEmpty ? "payment" : original.note)"
        reversal.reversesID = id; reversal.invoice = original.invoice; reversal.job = original.job
        try writer.save(); context.refreshAllObjects()
    }
}

/// A context-local snapshot. Rebuild for each render/transaction so sync and edits
/// cannot leave eligibility cached across financial writes.
struct InvoiceIndex {
    private var active: [UUID: [Invoice]] = [:]
    private var activeExpenses: [UUID: [Invoice]] = [:]
    private var blockedJobs: [UUID: Set<NSManagedObjectID>] = [:]
    private var blockedExpenses: [UUID: Set<NSManagedObjectID>] = [:]
    private var blockedClients: [UUID: Set<NSManagedObjectID>] = [:]
    private var unknown: Set<NSManagedObjectID> = []
    /// Non-void invoices by client and reference key, from every head so a synced duplicate is never hidden.
    private var references: [String: Set<NSManagedObjectID>] = [:]
    private var fetchError: Error?

    init(in context: NSManagedObjectContext) {
        do {
            let request = NSFetchRequest<Invoice>(entityName: "Invoice")
            request.relationshipKeyPathsForPrefetching = ["revisions", "client"]
            for invoice in try context.fetch(request) {
                do {
                    let heads = try invoice.heads()
                    let live = heads.compactMap(\.value).filter { $0.status != "void" }
                    for job in Set(live.flatMap { $0.lines.map(\.jobID) }) { active[job, default: []].append(invoice) }
                    for expense in Set(live.flatMap { $0.expenseLines.map(\.expenseID) }) { activeExpenses[expense, default: []].append(invoice) }
                    for value in live where !value.reference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        references[Self.referenceKey(client: value.clientID, value.reference), default: []].insert(invoice.objectID)
                    }
                } catch {
                    let records = Array(invoice.revisions ?? [])
                    let values = records.compactMap(\.value)
                    for job in Set(values.flatMap { $0.lines.map(\.jobID) }) {
                        blockedJobs[job, default: []].insert(invoice.objectID)
                    }
                    for expense in Set(values.flatMap { $0.expenseLines.map(\.expenseID) }) {
                        blockedExpenses[expense, default: []].insert(invoice.objectID)
                    }
                    // Missing/unreadable history may contain additional jobs. Limit
                    // that uncertainty to known clients, including historical ones.
                    let ids = Set(records.compactMap(\.id))
                    let incomplete = records.isEmpty || values.count != records.count || records.contains {
                        guard let parents = try? JSONDecoder().decode([UUID].self, from: Data($0.parentsJSON.utf8)) else { return true }
                        return !Set(parents).isSubset(of: ids)
                    }
                    if incomplete {
                        var clients = Set(values.map(\.clientID))
                        if let client = invoice.client?.id { clients.insert(client) }
                        if clients.isEmpty { unknown.insert(invoice.objectID) }
                        for client in clients { blockedClients[client, default: []].insert(invoice.objectID) }
                    }
                }
            }
        } catch { fetchError = error }
    }

    private static func referenceKey(client: UUID, _ reference: String) -> String { "\(client.uuidString)|\(InvoiceValue.referenceKey(reference))" }

    /// Other non-void invoices for `client` that use `reference`. Void invoices keep their reference as history.
    func invoices(sharing reference: String, client: UUID, excluding excluded: NSManagedObjectID? = nil) -> Set<NSManagedObjectID> {
        guard !InvoiceValue.referenceKey(reference).isEmpty else { return [] }
        var found = references[Self.referenceKey(client: client, reference)] ?? []
        if let excluded { found.remove(excluded) }
        return found
    }

    func invoices(for job: Job, excluding excluded: NSManagedObjectID? = nil) throws -> [Invoice] {
        if let fetchError { throw fetchError }
        guard let id = job.id else { return [] }
        var blocked = unknown.union(blockedJobs[id] ?? [])
        if let client = job.client?.id { blocked.formUnion(blockedClients[client] ?? []) }
        if let excluded { blocked.remove(excluded) }
        guard blocked.isEmpty else { throw RecordError.invalid("An invoice that may include this job needs review. Wait for sync or resolve its history before billing this job.") }
        return (active[id] ?? []).filter { $0.objectID != excluded }
    }

    func invoices(for expense: Expense, excluding excluded: NSManagedObjectID? = nil) throws -> [Invoice] {
        if let fetchError { throw fetchError }
        guard let id = expense.id else { return [] }
        var blocked = unknown.union(blockedExpenses[id] ?? [])
        if let client = expense.job?.client?.id { blocked.formUnion(blockedClients[client] ?? []) }
        if let excluded { blocked.remove(excluded) }
        guard blocked.isEmpty else { throw RecordError.invalid("An invoice that may include this receipt needs review. Wait for sync or resolve its history before billing it.") }
        return (activeExpenses[id] ?? []).filter { $0.objectID != excluded }
    }
}

extension Expense {
    func activeInvoices(excluding excluded: NSManagedObjectID? = nil, index: InvoiceIndex) throws -> [Invoice] {
        try index.invoices(for: self, excluding: excluded)
    }
    /// A finished reimbursable receipt that can be billed to its event's client.
    var isRebillable: Bool { !isDraft && value.reimbursable && !value.discarded && job != nil && job?.deletedAt == nil }
}

extension Job {
    func activeInvoices(in context: NSManagedObjectContext, excluding excluded: NSManagedObjectID? = nil, index: InvoiceIndex? = nil) throws -> [Invoice] {
        try (index ?? InvoiceIndex(in: context)).invoices(for: self, excluding: excluded)
    }
    func directPaid() throws -> Int64 { try PaymentLedger.net(Array(payments ?? [])) }
    func billingSummary(in context: NSManagedObjectContext, index: InvoiceIndex? = nil) -> String {
        do {
            let invoices = try activeInvoices(in: context, index: index)
            if invoices.count > 1 { return "Duplicate billing needs review" }
            if try !invoices.isEmpty && directPaid() > 0 { return "Direct payment and invoice need review" }
            if let invoice = invoices.first {
                let value = try invoice.currentValue()
                if value.status == "draft" { return "On draft invoice" }
                let remaining = try invoice.balance()
                if remaining < 0 { return "Invoice credit: \(Money.format(-remaining, currency: value.currency))" }
                return remaining > 0 ? "Invoice balance: \(Money.format(remaining, currency: value.currency))" : "Invoice paid"
            }
            let received = try directPaid()
            return received > 0 ? "Direct payments: \(Money.format(received, currency: try currentFee().currency))" : "Not invoiced"
        } catch { return "Billing needs review" }
    }
}

struct InvoiceDraft: Equatable {
    var value: InvoiceValue
    var parentIDs: Set<UUID> = []
    init(clientID: UUID, currency: String) { value = InvoiceValue(clientID: clientID, currency: currency) }
    init(invoice: Invoice) throws { value = try invoice.currentValue(); parentIDs = Set(try invoice.heads().compactMap(\.id)) }
    init(value: InvoiceValue, parents: Set<UUID>) { self.value = value; parentIDs = parents }
    @discardableResult
    func save(in context: NSManagedObjectContext, editing id: NSManagedObjectID? = nil) throws -> NSManagedObjectID {
        try value.validate()
        if id == nil && value.status == "void" { throw RecordError.invalid("Create a draft or sent invoice before voiding it.") }
        let writer = isolatedWriter(context)
        let invoice = try id.map { try writer.existingObject(with: $0) as! Invoice }
            ?? Invoice(entity: NSEntityDescription.entity(forEntityName: "Invoice", in: writer)!, insertInto: writer)
        var previouslySent = false
        if id != nil {
            guard Set(try invoice.heads().compactMap(\.id)) == parentIDs else { throw RecordError.invalid("This invoice changed while the editor was open. Cancel and review its latest history before saving.") }
            let sent = (invoice.revisions ?? []).compactMap(\.value).filter { $0.status == "sent" }
            previouslySent = !sent.isEmpty
            if !sent.isEmpty {
                guard value.status != "draft", sent.contains(where: { value.sameBilledTerms(as: $0) }) else { throw RecordError.invalid("Sent invoice amounts, currency, and jobs are preserved. Void the invoice and create a new one to change its billed terms.") }
            }
            if try value.status == "void" && invoice.paid() != 0 { throw RecordError.invalid("Reverse the invoice’s payments before voiding it.") }
        }
        let clients = NSFetchRequest<Client>(entityName: "Client"); clients.predicate = NSPredicate(format: "id == %@", value.clientID as CVarArg)
        guard let client = try writer.fetch(clients).first else { throw RecordError.invalid("Choose a saved client for this invoice.") }
        let index = InvoiceIndex(in: writer)
        if value.status != "void" {
            // A reference already saved on this invoice stays editable so a synced duplicate can be resolved here.
            let saved = id == nil ? nil : try? invoice.currentValue()
            let kept = saved.map { $0.clientID == value.clientID && InvoiceValue.referenceKey($0.reference) == InvoiceValue.referenceKey(value.reference) } ?? false
            if !kept, !index.invoices(sharing: value.reference, client: value.clientID, excluding: invoice.objectID).isEmpty {
                throw RecordError.invalid("Another \(client.name) invoice already uses \(value.reference.trimmingCharacters(in: .whitespacesAndNewlines)). Choose a different reference, or void the other invoice first.")
            }
        }
        for line in value.lines {
            let request = NSFetchRequest<Job>(entityName: "Job"); request.predicate = NSPredicate(format: "id == %@", line.jobID as CVarArg)
            guard let job = try writer.fetch(request).first else { throw RecordError.invalid("Every included job must belong to the selected client.") }
            if value.status != "void" {
                if !previouslySent {
                guard job.client?.id == value.clientID else { throw RecordError.invalid("Every job must belong to the selected client.") }
                guard try job.currentFee().currency == value.currency else { throw RecordError.invalid("All jobs on an invoice must use the same currency.") }
                guard try job.directPaid() == 0 else { throw RecordError.invalid("A job with direct payments cannot also be invoiced. Reverse those receipts first if they should belong to an invoice.") }
                }
                guard try job.activeInvoices(in: writer, excluding: invoice.objectID, index: index).isEmpty else { throw RecordError.invalid("A selected job is already on another active invoice. Review or void that invoice before billing it again.") }
            }
        }
        for line in value.expenseLines where value.status != "void" {
            let request = NSFetchRequest<Expense>(entityName: "Expense"); request.predicate = NSPredicate(format: "id == %@", line.expenseID as CVarArg)
            guard let expense = try writer.fetch(request).first else { throw RecordError.invalid("An included receipt is still syncing.") }
            if !previouslySent {
                guard expense.isRebillable else { throw RecordError.invalid("Only finished, reimbursable receipts can be billed.") }
                guard expense.job?.client?.id == value.clientID else { throw RecordError.invalid("Every receipt must belong to an event for the selected client.") }
                guard expense.value.currency == value.currency else { throw RecordError.invalid("Receipts on an invoice must use the invoice currency.") }
            }
            guard try expense.activeInvoices(excluding: invoice.objectID, index: index).isEmpty else { throw RecordError.invalid("A selected receipt is already on another active invoice.") }
        }
        if invoice.id == nil { invoice.id = UUID(); invoice.createdAt = Date() }
        invoice.client = client
        let revision = InvoiceRevision(entity: NSEntityDescription.entity(forEntityName: "InvoiceRevision", in: writer)!, insertInto: writer)
        revision.id = UUID(); revision.createdAt = Date(); revision.invoice = invoice
        revision.parentsJSON = String(decoding: try JSONEncoder().encode(parentIDs.sorted { $0.uuidString < $1.uuidString }), as: UTF8.self)
        revision.valueJSON = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try writer.save(); context.refreshAllObjects(); return invoice.objectID
    }
}

struct PaymentDraft: Equatable {
    var amount = ""
    var date = Date()
    var note = ""
    func save(in context: NSManagedObjectContext, invoiceID: NSManagedObjectID? = nil, jobID: NSManagedObjectID? = nil, transaction: NSManagedObjectContext? = nil) throws {
        guard (invoiceID == nil) != (jobID == nil) else { throw RecordError.invalid("Enter a positive payment amount and choose one invoice or direct-payment job.") }
        let writer = transaction ?? isolatedWriter(context)
        var invoice: Invoice?; var job: Job?; let currency: String
        if let invoiceID {
            invoice = try writer.existingObject(with: invoiceID) as? Invoice
            let value = try invoice!.currentValue()
            let index = InvoiceIndex(in: writer)
            guard value.status == "sent" else { throw RecordError.invalid("Mark the invoice sent before recording payment.") }
            for line in value.lines {
                let request = NSFetchRequest<Job>(entityName: "Job"); request.predicate = NSPredicate(format: "id == %@", line.jobID as CVarArg)
                guard let job = try writer.fetch(request).first, try job.activeInvoices(in: writer, index: index).count == 1, try job.directPaid() == 0 else { throw RecordError.invalid("Resolve duplicate billing before recording a payment.") }
            }
            for line in value.expenseLines {
                let request = NSFetchRequest<Expense>(entityName: "Expense"); request.predicate = NSPredicate(format: "id == %@", line.expenseID as CVarArg)
                guard let expense = try writer.fetch(request).first, try expense.activeInvoices(index: index).count == 1 else { throw RecordError.invalid("Resolve duplicate billing before recording a payment.") }
            }
            _ = try invoice!.paid(); currency = value.currency
        } else {
            job = try writer.existingObject(with: jobID!) as? Job
            guard try job!.activeInvoices(in: writer).isEmpty else { throw RecordError.invalid("This job belongs to an invoice. Record payment on that invoice instead.") }
            _ = try job!.directPaid(); currency = try job!.currentFee().currency
        }
        guard let amount = try Money.parseInput(amount, currency: currency), amount > 0 else { throw RecordError.invalid("Enter a positive payment amount and choose one invoice or direct-payment job.") }
        let payment = PaymentRecord(entity: NSEntityDescription.entity(forEntityName: "PaymentRecord", in: writer)!, insertInto: writer)
        payment.id = UUID(); payment.createdAt = Date(); payment.receivedAt = date; payment.amount = amount
        payment.currency = currency; payment.note = note; payment.invoice = invoice; payment.job = job
        _ = try PaymentLedger.net(Array(invoice?.payments ?? job?.payments ?? []))
        if transaction == nil { try writer.save(); context.refreshAllObjects() }
    }
}
