import CoreData
import Foundation

// MARK: - Gates

/// One of the four things an event needs before it can be invoiced.
enum ReadinessGate: String, CaseIterable, Hashable {
    case fee, client, work, receipts
    var label: String {
        switch self {
        case .work: "Work"
        case .fee: "Fee"
        case .receipts: "Receipts"
        case .client: "Client"
        }
    }
}

enum GateState: Equatable {
    case done, missing, notYet
}

/// A gap that stops an event being invoiced, worded for the row that shows it.
struct ReadinessGap: Equatable {
    let gate: ReadinessGate
    let text: String
}

// MARK: - Facts read from the store

/// Plain values describing one event's billing position, so readiness is testable without a store.
struct ReadinessFacts: Equatable {
    var jobID: UUID
    var title: String
    var startDay: String
    var endDay: String
    var bookingStatus: String
    var clientID: UUID?
    var clientName: String?
    /// Required invoicing details the client is missing. Empty when complete or when there is no client.
    var clientDetailsMissing: [String]
    var fee: EventFeeFact
    var billing: EventBillingFact
    /// What this event is billed at on its active invoice, when it has one.
    var billedAmount: Int64?
    /// Receipts on the event still saved as drafts. Any draft holds up invoicing so the
    /// bookkeeping gets finished; finished non-reimbursable receipts never do.
    var blockingReceipts: [EventExpenseFact]
    /// Finished reimbursable receipts not yet on an active invoice.
    var rebillable: [EventExpenseFact]
}

enum PaymentState: Equatable {
    case review(String)
    case paid(reference: String)
    case invoiced(reference: String, balance: Int64, currency: String, dueDay: String)
    case draft
    case directPaid
    case noFee
    case ready
    case heldUp
    case upcoming
    case cancelled

    /// Bucket used for the month's money bar.
    var bucket: MoneyBucket? {
        switch self {
        case .paid, .directPaid: .paid
        case .invoiced, .draft: .invoiced
        case .ready: .ready
        case .heldUp, .review: .heldUp
        case .upcoming: .toHappen
        case .noFee, .cancelled: nil
        }
    }
}

enum MoneyBucket: String, CaseIterable, Hashable {
    case paid, invoiced, ready, heldUp, toHappen
    var label: String {
        switch self {
        case .paid: "Paid"
        case .invoiced: "Invoiced"
        case .ready: "Ready to invoice"
        case .heldUp: "Held up"
        case .toHappen: "Still to happen"
        }
    }
}

// MARK: - One event

struct EventReadiness: Equatable, Identifiable {
    let facts: ReadinessFacts
    let gates: [ReadinessGate: GateState]
    let gaps: [ReadinessGap]
    let state: PaymentState
    var id: UUID { facts.jobID }

    /// The amount this event contributes: what it is billed at, else its agreed fee.
    var amount: Int64? {
        if let billed = facts.billedAmount { return billed }
        if case .value(let fee) = facts.fee { return fee.amount }
        return nil
    }
    var currency: String? {
        switch facts.billing {
        case let .sent(_, _, currency, _, _, _, _): return currency
        case let .directPayments(_, currency): return currency
        default:
            if case .value(let fee) = facts.fee { return fee.currency }
            return nil
        }
    }
    var showsGates: Bool { [.ready, .heldUp, .upcoming].contains(state) }

    init(_ facts: ReadinessFacts, today: String) {
        self.facts = facts
        let finished = facts.bookingStatus == "completed"
        var gates: [ReadinessGate: GateState] = [:]
        var gaps: [ReadinessGap] = []

        var feeAmount: Int64?
        switch facts.fee {
        case .conflict:
            gates[.fee] = .missing
            gaps.append(ReadinessGap(gate: .fee, text: "Fee needs review"))
        case .value(let fee):
            feeAmount = fee.amount
            if fee.amount == nil {
                gates[.fee] = .missing
                gaps.append(ReadinessGap(gate: .fee, text: "Fee to agree"))
            } else { gates[.fee] = .done }
        }

        if facts.clientID == nil {
            gates[.client] = .missing
            gaps.append(ReadinessGap(gate: .client, text: "Client to add"))
        } else if !facts.clientDetailsMissing.isEmpty {
            gates[.client] = .missing
            // The client header names the missing details; rows stay short.
            gaps.append(ReadinessGap(gate: .client, text: "Client details missing"))
        } else { gates[.client] = .done }

        if finished { gates[.work] = .done }
        else if facts.endDay < today && facts.bookingStatus != "cancelled" {
            gates[.work] = .missing
            gaps.append(ReadinessGap(gate: .work, text: "Mark completed"))
        } else { gates[.work] = .notYet }

        if facts.blockingReceipts.isEmpty { gates[.receipts] = .done }
        else {
            gates[.receipts] = .missing
            let count = facts.blockingReceipts.count
            gaps.append(ReadinessGap(gate: .receipts, text: count == 1 ? "1 receipt to finish" : "\(count) receipts to finish"))
        }

        self.gates = gates
        self.gaps = gaps
        self.state = Self.state(facts: facts, gates: gates, feeAmount: feeAmount, finished: finished)
    }

    private static func state(facts: ReadinessFacts, gates: [ReadinessGate: GateState], feeAmount: Int64?, finished: Bool) -> PaymentState {
        switch facts.billing {
        case let .review(message, _): return .review(message)
        case let .sent(_, reference, currency, _, balance, dueDay, _):
            return balance <= 0 ? .paid(reference: reference) : .invoiced(reference: reference, balance: balance, currency: currency, dueDay: dueDay)
        case .draft: return .draft
        case .directPayments: return .directPaid
        case .notInvoiced: break
        }
        if facts.bookingStatus == "cancelled" { return .cancelled }
        if feeAmount == 0 { return .noFee }
        if gates.values.allSatisfy({ $0 == .done }) { return .ready }
        return gates[.work] == .notYet ? .upcoming : .heldUp
    }
}

// MARK: - A month

struct CurrencyBuckets: Equatable, Identifiable {
    let currency: String
    var amounts: [MoneyBucket: Int64] = [:]
    /// Events in the month whose fee is still unknown.
    var unknownFees = 0
    var id: String { currency }
    var total: Int64 { amounts.values.reduce(0, +) }
}

struct ClientMonthGroup: Equatable, Identifiable {
    let clientID: UUID?
    let name: String
    let detailsMissing: [String]
    let termsDays: Int?
    let events: [EventReadiness]
    var id: String { clientID?.uuidString ?? "no-client" }
    var ready: [EventReadiness] { events.filter { $0.state == .ready } }
    /// Whether anything here may still need an invoice, so the client's details matter.
    var billable: Bool { events.contains { [.ready, .heldUp, .upcoming].contains($0.state) } }
    /// Ready totals per currency; invoices are made one currency at a time.
    var readyTotals: [(currency: String, amount: Int64)] {
        Dictionary(grouping: ready.compactMap { event in event.currency.flatMap { c in event.amount.map { (c, $0) } } }, by: \.0)
            .map { (currency: $0.key, amount: $0.value.reduce(0) { $0 + $1.1 }) }
            .sorted { $0.currency < $1.currency }
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.clientID == rhs.clientID && lhs.name == rhs.name && lhs.detailsMissing == rhs.detailsMissing && lhs.events == rhs.events }
}

/// Money still open from before the selected month.
enum EarlierItem: Equatable, Identifiable {
    case invoice(id: UUID, reference: String, clientName: String, balance: Int64, currency: String, dueDay: String, draft: Bool, paidSoFar: Int64, total: Int64)
    case event(EventReadiness)
    var id: String {
        switch self {
        case .invoice(let id, _, _, _, _, _, _, _, _): "invoice-\(id)"
        case .event(let event): "event-\(event.id)"
        }
    }
}

struct PaymentsMonth: Equatable {
    /// "yyyy-MM".
    let month: String
    let groups: [ClientMonthGroup]
    let currencies: [CurrencyBuckets]
    let earlier: [EarlierItem]
    var events: [EventReadiness] { groups.flatMap(\.events) }

    struct ClientInfo: Equatable {
        let id: UUID
        let name: String
        let detailsMissing: [String]
        let termsDays: Int?
    }

    struct OpenInvoice: Equatable {
        let id: UUID
        let reference: String
        let clientName: String
        let balance: Int64
        let currency: String
        let dueDay: String
        let draft: Bool
        let paid: Int64
        let total: Int64
        /// Start days of the events it bills.
        let eventDays: [String]
    }

    init(month: String, events all: [EventReadiness], clients: [UUID: ClientInfo], openInvoices: [OpenInvoice], displayed: [String]) {
        self.month = month
        let inMonth = all.filter { $0.facts.startDay.hasPrefix(month) && $0.state != .cancelled }
        let grouped = Dictionary(grouping: inMonth, by: { $0.facts.clientID })
        groups = grouped.map { clientID, events in
            let info = clientID.flatMap { clients[$0] }
            return ClientMonthGroup(clientID: clientID, name: info?.name ?? "No client yet", detailsMissing: info?.detailsMissing ?? [],
                                    termsDays: info?.termsDays,
                                    events: events.sorted { ($0.facts.startDay, $0.facts.title) < ($1.facts.startDay, $1.facts.title) })
        }.sorted { lhs, rhs in
            // Clients with something to do first, then alphabetical; events without a client last.
            if (lhs.clientID == nil) != (rhs.clientID == nil) { return rhs.clientID == nil }
            let lw = lhs.events.contains { $0.state == .ready || $0.state == .heldUp }, rw = rhs.events.contains { $0.state == .ready || $0.state == .heldUp }
            if lw != rw { return lw }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }

        var buckets: [String: CurrencyBuckets] = [:]
        for code in displayed { buckets[code] = CurrencyBuckets(currency: code) }
        for event in inMonth {
            guard let bucket = event.state.bucket else { continue }
            guard let currency = event.currency else { continue }
            if let amount = event.amount { buckets[currency, default: CurrencyBuckets(currency: currency)].amounts[bucket, default: 0] += amount }
            else { buckets[currency, default: CurrencyBuckets(currency: currency)].unknownFees += 1 }
        }
        currencies = buckets.values.filter { displayed.contains($0.currency) || $0.total > 0 || $0.unknownFees > 0 }
            .sorted { (displayed.firstIndex(of: $0.currency) ?? 99, $0.currency) < (displayed.firstIndex(of: $1.currency) ?? 99, $1.currency) }

        let start = month + "-01"
        let invoices: [EarlierItem] = openInvoices
            .filter { invoice in !invoice.eventDays.isEmpty && invoice.eventDays.allSatisfy { $0 < start } }
            .sorted { ($0.dueDay.isEmpty ? "9" : $0.dueDay, $0.reference) < ($1.dueDay.isEmpty ? "9" : $1.dueDay, $1.reference) }
            .map { .invoice(id: $0.id, reference: $0.reference, clientName: $0.clientName, balance: $0.balance, currency: $0.currency,
                            dueDay: $0.dueDay, draft: $0.draft, paidSoFar: $0.paid, total: $0.total) }
        let work: [EarlierItem] = all
            .filter { $0.facts.startDay < start && ($0.state == .ready || $0.state == .heldUp) }
            .sorted { $0.facts.startDay < $1.facts.startDay }
            .map { .event($0) }
        earlier = invoices + work
    }
}

// MARK: - Reading the store

extension ReadinessFacts {
    init(job: Job, context: NSManagedObjectContext, index: InvoiceIndex) {
        let fee: EventFeeFact
        do { fee = .value(try job.currentFee()) } catch { fee = .conflict }
        let expenses = (job.expenses ?? []).filter { $0.value.discarded != true }
            .sorted { ($0.createdAt ?? .distantPast) < ($1.createdAt ?? .distantPast) }
        func fact(_ expense: Expense) -> EventExpenseFact? {
            guard let id = expense.id else { return nil }
            let value = expense.value
            return EventExpenseFact(id: id, merchant: value.merchant, amount: (try? Money.parse(value.amount, currency: value.currency)).flatMap { $0 }, currency: value.currency)
        }
        var billed: Int64?
        if let invoice = try? job.activeInvoices(in: context, index: index).first, let value = try? invoice.currentValue() {
            billed = value.lines.first { $0.jobID == job.id }?.amount
        }
        self.init(
            jobID: job.id ?? UUID(),
            title: job.displayName,
            startDay: job.eventStartDay,
            endDay: job.eventEndDay,
            bookingStatus: job.bookingStatus,
            clientID: job.client?.id,
            clientName: job.client?.name,
            clientDetailsMissing: job.client?.invoicing.missing ?? [],
            fee: fee,
            billing: EventDetailFacts.billing(job: job, context: context, index: index),
            billedAmount: billed,
            blockingReceipts: expenses.filter(\.isDraft).compactMap(fact),
            rebillable: expenses.filter { $0.isRebillable && ((try? $0.activeInvoices(index: index).isEmpty) ?? false) }.compactMap(fact)
        )
    }
}

extension PaymentsMonth {
    /// Builds the month from the store. Rebuild on each render; nothing here is cached.
    static func load(month: String, jobs: [Job], invoices: [Invoice], context: NSManagedObjectContext, displayed: [String], today: String = Day.string(from: Date())) -> PaymentsMonth {
        let index = InvoiceIndex(in: context)
        let events = jobs.filter { $0.deletedAt == nil && $0.id != nil }.map { EventReadiness(ReadinessFacts(job: $0, context: context, index: index), today: today) }
        var clients: [UUID: ClientInfo] = [:]
        for job in jobs { if let client = job.client, let id = client.id { clients[id] = ClientInfo(id: id, name: client.name, detailsMissing: client.invoicing.missing, termsDays: client.invoicing.termsDays) } }
        let starts = Dictionary(jobs.compactMap { job in job.id.map { ($0, job.eventStartDay) } }, uniquingKeysWith: { a, _ in a })
        let open: [OpenInvoice] = invoices.compactMap { invoice in
            guard let id = invoice.id, invoice.issue(in: context, index: index) == nil, let value = try? invoice.currentValue(), value.status != "void",
                  let balance = try? invoice.balance(), let total = try? value.total() else { return nil }
            guard value.status == "draft" || balance > 0 else { return nil }
            return OpenInvoice(id: id, reference: value.reference.isEmpty ? "Draft invoice" : value.reference, clientName: invoice.client?.name ?? "Client syncing",
                               balance: balance, currency: value.currency, dueDay: value.dueDay, draft: value.status == "draft",
                               paid: (try? invoice.paid()) ?? 0, total: total, eventDays: value.lines.compactMap { starts[$0.jobID] })
        }
        return PaymentsMonth(month: month, events: events, clients: clients, openInvoices: open, displayed: displayed)
    }
}
