import CoreData
import Foundation

/// One invoice, direct payment, or fee that needs review, flattened for the Invoices view.
struct LedgerEntry: Identifiable, Equatable {
    enum Kind: Equatable { case invoice, directPayment, feeReview }
    enum State: Equatable { case review(String), overdue, unpaid, draft, paid, direct, void }

    /// The invoice's or event's own id; `id` also carries the kind, since one event can have both a fee to review and direct payments.
    let recordID: UUID
    var kind: Kind = .invoice
    var title: String
    var clientName: String
    var detail: String
    var currency: String
    var total: Int64
    var received: Int64 = 0
    var state: State
    var sentDay = ""
    var dueDay = ""
    var createdDay = ""
    /// The day it was paid in full, paid directly, or voided.
    var settledDay = ""
    /// A review entry for a sent invoice still counts toward what is owed.
    var sent = false

    var id: String { "\(kind)-\(recordID)" }
    var remaining: Int64 { state == .void ? 0 : total - received }
    var year: String { String([settledDay, sentDay, createdDay].first { !$0.isEmpty }?.prefix(4) ?? "") }
    var isOwed: Bool {
        switch state {
        case .overdue, .unpaid: true
        case .review: kind == .invoice && sent && remaining > 0
        default: false
        }
    }
    var needsAttention: Bool { if case .review = state { true } else { state == .overdue } }
    var isHistory: Bool { state == .paid || state == .direct || state == .void }

    /// The one line under the client that says where this stands.
    func status(today: String) -> String {
        let part = received > 0 ? " · \(Money.format(received, currency: currency)) of \(Money.format(total, currency: currency)) received" : ""
        switch state {
        case .review(let message): return message
        case .overdue:
            let days = LedgerEntry.days(from: dueDay, to: today)
            return "Overdue \(days == 1 ? "1 day" : "\(days) days")" + (part.isEmpty ? " · due \(LedgerEntry.short(dueDay))" : part)
        case .unpaid:
            guard !dueDay.isEmpty else { return "No due date" + part }
            let days = LedgerEntry.days(from: today, to: dueDay)
            return (days == 0 ? "Due today" : days == 1 ? "Due tomorrow" : "Due in \(days) days") + (part.isEmpty ? " · \(LedgerEntry.short(dueDay))" : part)
        case .draft: return createdDay.isEmpty ? "Not sent" : "Not sent · started \(LedgerEntry.short(createdDay))"
        case .paid: return settledDay.isEmpty ? "Paid" : "Paid \(LedgerEntry.short(settledDay))"
        case .direct: return settledDay.isEmpty ? "Paid directly" : "Paid directly · \(LedgerEntry.short(settledDay))"
        case .void: return settledDay.isEmpty ? "Voided" : "Voided \(LedgerEntry.short(settledDay))"
        }
    }

    /// The amount on the right: what is still owed for open invoices, otherwise the total.
    var shownAmount: Int64 { isOwed ? remaining : total }

    func matches(_ query: String) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }
        let amount = Decimal(total) / pow(10, Money.decimals(currency))
        return [title, clientName, detail, Money.format(total, currency: currency), Money.format(remaining, currency: currency), "\(amount)"]
            .contains { $0.localizedCaseInsensitiveContains(query) }
    }

    static func days(from start: String, to end: String) -> Int {
        guard let start = Day.date(from: start), let end = Day.date(from: end) else { return 0 }
        return Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
    }
    static func short(_ day: String) -> String {
        Day.date(from: day)?.formatted(.dateTime.month(.abbreviated).day()) ?? day
    }
}

enum LedgerStatus: String, CaseIterable, Identifiable {
    case all, owed, overdue, drafts, paid, voided
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .owed: "Owed"
        case .overdue: "Overdue"
        case .drafts: "Drafts"
        case .paid: "Paid"
        case .voided: "Voided"
        }
    }
    fileprivate var noun: String {
        switch self {
        case .all: "invoices or payments"
        case .owed: "unpaid invoices"
        case .overdue: "overdue invoices"
        case .drafts: "draft invoices"
        case .paid: "paid invoices"
        case .voided: "voided invoices"
        }
    }
    func includes(_ entry: LedgerEntry) -> Bool {
        switch self {
        case .all: true
        case .owed: entry.isOwed || entry.needsAttention
        case .overdue: entry.state == .overdue
        case .drafts: entry.state == .draft
        case .paid: entry.state == .paid || entry.state == .direct
        case .voided: entry.state == .void
        }
    }
}

struct LedgerFilter: Equatable {
    var status: LedgerStatus = .all
    var client = ""
    var year = ""
    var query = ""
    var isScoped: Bool { !client.isEmpty || !year.isEmpty }
    var isActive: Bool { status != .all || isScoped || !query.trimmingCharacters(in: .whitespaces).isEmpty }
}

struct LedgerSection: Identifiable, Equatable {
    let id: String
    let title: String
    var meta = ""
    let entries: [LedgerEntry]
}

struct LedgerOwed: Identifiable, Equatable {
    var id: String { currency }
    let currency: String
    let owed: Int64
    let overdue: Int64
}

struct LedgerTotals: Identifiable, Equatable {
    var id: String { currency }
    let currency: String
    let billed: Int64
    let received: Int64
    var owed: Int64 { billed - received }
}

/// Every invoice and direct payment, across all months.
struct InvoiceLedger {
    let entries: [LedgerEntry]
    let today: String
    var displayed: [String] = CurrencyPreferences.supported

    var clients: [String] { Array(Set(entries.map(\.clientName).filter { !$0.isEmpty })).sorted() }
    var years: [String] { Array(Set(entries.map(\.year).filter { !$0.isEmpty })).sorted(by: >) }

    private func ordered(_ currencies: Set<String>) -> [String] {
        currencies.sorted { (displayed.firstIndex(of: $0) ?? .max, $0) < (displayed.firstIndex(of: $1) ?? .max, $1) }
    }

    /// What clients owe, per currency, within the chosen client.
    func owed(client: String = "") -> [LedgerOwed] {
        let open = entries.filter { $0.isOwed && (client.isEmpty || $0.clientName == client) }
        return ordered(Set(open.map(\.currency))).map { currency in
            let rows = open.filter { $0.currency == currency }
            return LedgerOwed(currency: currency, owed: rows.reduce(0) { $0 + $1.remaining },
                              overdue: rows.filter { $0.state == .overdue }.reduce(0) { $0 + $1.remaining })
        }.filter { $0.owed > 0 }
    }

    /// Billed, received and owed for a client and/or year. Drafts and voided invoices are not billed.
    func totals(_ filter: LedgerFilter) -> [LedgerTotals] {
        let rows = entries.filter { entry in
            entry.kind != .feeReview && entry.state != .draft && entry.state != .void && (entry.kind == .directPayment || entry.sent)
                && (filter.client.isEmpty || entry.clientName == filter.client) && (filter.year.isEmpty || entry.year == filter.year)
        }
        return ordered(Set(rows.map(\.currency))).map { currency in
            let rows = rows.filter { $0.currency == currency }
            return LedgerTotals(currency: currency, billed: rows.reduce(0) { $0 + $1.total }, received: rows.reduce(0) { $0 + $1.received })
        }
    }

    func filtered(_ filter: LedgerFilter) -> [LedgerEntry] {
        entries.filter { entry in
            filter.status.includes(entry) && entry.matches(filter.query)
                && (filter.client.isEmpty || entry.clientName == filter.client)
                && (filter.year.isEmpty || entry.year == filter.year)
        }
    }

    /// Needs attention, then unpaid by due date, drafts, and paid/voided history by month.
    func sections(_ filter: LedgerFilter) -> [LedgerSection] {
        let rows = filtered(filter)
        let byDue: (LedgerEntry, LedgerEntry) -> Bool = { ($0.dueDay.isEmpty ? "9999" : $0.dueDay, $0.title) < ($1.dueDay.isEmpty ? "9999" : $1.dueDay, $1.title) }
        var sections: [LedgerSection] = []
        let attention = rows.filter(\.needsAttention).sorted(by: byDue)
        if !attention.isEmpty { sections.append(LedgerSection(id: "attention", title: "Needs attention", entries: attention)) }
        let unpaid = rows.filter { $0.state == .unpaid }.sorted(by: byDue)
        if !unpaid.isEmpty { sections.append(LedgerSection(id: "unpaid", title: "Unpaid", entries: unpaid)) }
        let drafts = rows.filter { $0.state == .draft }.sorted { $0.createdDay > $1.createdDay }
        if !drafts.isEmpty { sections.append(LedgerSection(id: "drafts", title: "Drafts", entries: drafts)) }
        let history = rows.filter(\.isHistory).sorted { ($0.settledDay, $0.title) > ($1.settledDay, $1.title) }
        var months: [(key: String, entries: [LedgerEntry])] = []
        for entry in history {
            let key = String(entry.settledDay.prefix(7))
            if months.last?.key == key { months[months.count - 1].entries.append(entry) } else { months.append((key, [entry])) }
        }
        for month in months {
            let received = ordered(Set(month.entries.map(\.currency))).compactMap { currency -> String? in
                let sum = month.entries.filter { $0.currency == currency && $0.state != .void }.reduce(0) { $0 + $1.received }
                return sum > 0 ? Money.format(sum, currency: currency) : nil
            }
            sections.append(LedgerSection(id: "month-\(month.key)", title: MonthStepper.date(month.key).map { $0.formatted(.dateTime.month(.wide).year()) } ?? "Earlier",
                                          meta: received.isEmpty ? "" : "Received " + received.joined(separator: " · "), entries: month.entries))
        }
        return sections
    }

    /// Says which filters left nothing, so the person knows what to change.
    func emptyMessage(_ filter: LedgerFilter) -> String {
        var text = "No \(filter.status.noun)"
        if !filter.client.isEmpty { text += " for \(filter.client)" }
        if !filter.year.isEmpty { text += " in \(filter.year)" }
        let query = filter.query.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { text += " matching “\(query)”" }
        return text + "."
    }
}

// MARK: - Loading

extension InvoiceLedger {
    static func load(invoices: [Invoice], jobs: [Job], context: NSManagedObjectContext, today: String = Day.string(from: Date()),
                     displayed: [String] = CurrencyPreferences.supported) -> InvoiceLedger {
        let index = InvoiceIndex(in: context)
        var entries = invoices.compactMap { entry(for: $0, context: context, index: index, today: today) }
        for job in jobs {
            if job.deletedAt == nil, (try? job.currentFee()) == nil, let id = job.id {
                entries.append(LedgerEntry(recordID: id, kind: .feeReview, title: job.displayName, clientName: job.client?.name ?? "",
                                           detail: "Fee", currency: "", total: 0, state: .review("Fee has conflicting edits · choose a version")))
            }
            guard let id = job.id, let records = job.payments, !records.isEmpty else { continue }
            let name = job.displayName + (job.deletedAt == nil ? "" : " (deleted)")
            do {
                let received = try job.directPaid()
                guard received > 0, let currency = records.first?.currency else { continue }
                entries.append(LedgerEntry(recordID: id, kind: .directPayment, title: "Direct payment", clientName: job.client?.name ?? "", detail: name,
                                           currency: currency, total: received, received: received, state: .direct,
                                           settledDay: lastReceipt(Array(records)).map { Day.string(from: $0) } ?? ""))
            } catch {
                entries.append(LedgerEntry(recordID: id, kind: .directPayment, title: "Direct payment", clientName: job.client?.name ?? "", detail: name,
                                           currency: records.first?.currency ?? "", total: 0, state: .review(error.localizedDescription)))
            }
        }
        return InvoiceLedger(entries: entries, today: today, displayed: displayed)
    }

    private static func entry(for invoice: Invoice, context: NSManagedObjectContext, index: InvoiceIndex, today: String) -> LedgerEntry? {
        guard let id = invoice.id else { return nil }
        let heads = (try? invoice.heads()) ?? []
        // A conflicted or incomplete history still shows, using the newest readable version.
        let value = (try? invoice.currentValue()) ?? heads.last?.value
            ?? (invoice.revisions ?? []).sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }.last?.value
        let created = invoice.createdAt.map { Day.string(from: $0) } ?? ""
        guard let value else {
            return LedgerEntry(recordID: id, title: "Invoice", clientName: invoice.client?.name ?? "Client syncing", detail: "", currency: "",
                               total: 0, state: .review("Invoice history is still syncing"), createdDay: created)
        }
        let total = (try? value.total()) ?? 0
        let received = (try? invoice.paid()) ?? 0
        var entry = LedgerEntry(recordID: id, title: value.status == "draft" && value.reference.isEmpty ? "Draft" : value.reference,
                                clientName: invoice.client?.name ?? "Client syncing", detail: (value.lines.map(\.jobName) + (value.lines.isEmpty ? value.expenseLines.map(\.label) : [])).joined(separator: ", "),
                                currency: value.currency, total: total, received: received, state: .draft,
                                sentDay: value.sentDay, dueDay: value.dueDay, createdDay: created, sent: value.status == "sent")
        if let issue = invoice.issue(in: context, index: index) ?? invoice.duplicateReference(index: index) {
            entry.state = .review(issue)
        } else if value.status == "draft" {
            entry.state = .draft
        } else if value.status == "void" {
            entry.state = .void
            entry.settledDay = heads.last?.createdAt.map { Day.string(from: $0) } ?? ""
        } else if total - received <= 0 {
            entry.state = .paid
            entry.settledDay = lastReceipt(Array(invoice.payments ?? [])).map { Day.string(from: $0) } ?? value.sentDay
        } else if !value.dueDay.isEmpty && value.dueDay < today {
            entry.state = .overdue
        } else {
            entry.state = .unpaid
        }
        return entry
    }

    /// The latest receipt that still counts, ignoring reversed ones.
    private static func lastReceipt(_ records: [PaymentRecord]) -> Date? {
        let reversed = Set(records.compactMap(\.reversesID))
        return records.filter { $0.reversesID == nil && !reversed.contains($0.id ?? UUID()) }.compactMap(\.receivedAt).max()
    }
}
