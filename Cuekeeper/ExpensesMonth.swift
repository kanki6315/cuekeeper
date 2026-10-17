import CoreData
import Foundation

/// Where a month's expense money stands, per currency.
enum ExpenseBucket: String, CaseIterable, Hashable {
    case paidBack, onInvoice, toRebill, toFinish, yourCost
    var label: String {
        switch self {
        case .paidBack: "Paid back"
        case .onInvoice: "On an invoice"
        case .toRebill: "To rebill"
        case .toFinish: "To finish"
        case .yourCost: "Your cost"
        }
    }
}

/// One expense's state, derived from its draft flag, event, reimbursable flag and invoices.
enum ExpenseState: Equatable {
    case toFinish, yourCost, business, toRebill, paidBack, review
    case onInvoice(reference: String)
    var bucket: ExpenseBucket {
        switch self {
        case .toFinish: .toFinish
        case .yourCost, .business: .yourCost
        case .toRebill: .toRebill
        case .paidBack: .paidBack
        case .onInvoice, .review: .onInvoice
        }
    }
}

enum ExpenseFilter: String, CaseIterable, Hashable {
    case all = "All", events = "Events", business = "Business"
}

/// The values the Expenses tab needs from one expense. Nothing here is stored.
struct ExpenseFact: Equatable, Identifiable {
    let id: UUID
    var day: String
    var created: Date = .distantPast
    var merchant = ""
    var amount: Int64?
    var currency = ""
    var category = "Other"
    var state: ExpenseState
    var jobID: UUID?
    var eventTitle: String?
    var clientID: UUID?
    var clientName: String?
    var eventDeleted = false
    /// The event is on no active invoice yet, so a new invoice can carry these receipts.
    var eventInvoiceable = false
    var photoSaved = false
    var repeats = false
    var seriesID: UUID?

    var month: String { String(day.prefix(7)) }
    var isBusiness: Bool { state == .business }
    var displayAmount: String? { amount.map { Money.format($0, currency: currency) } }
    var title: String { merchant.isEmpty ? (photoSaved ? "Receipt photo" : "Expense to complete") : merchant }
}

extension ExpenseFact {
    init?(expense: Expense, index: InvoiceIndex) {
        let value = expense.value
        guard let id = expense.id, value.discarded != true else { return nil }
        let job = expense.job
        self.init(id: id,
                  day: value.day.isEmpty ? Day.string(from: expense.createdAt ?? Date()) : value.day,
                  created: expense.createdAt ?? .distantPast,
                  merchant: value.merchant,
                  amount: ExpenseValue.currencies.contains(value.currency) ? (try? Money.parse(value.amount, currency: value.currency)).flatMap { $0 } : nil,
                  currency: value.currency, category: value.category,
                  state: Self.state(expense, index: index),
                  jobID: job?.id, eventTitle: job?.eventTitle, clientID: job?.client?.id, clientName: job?.client?.name,
                  eventDeleted: job?.deletedAt != nil,
                  eventInvoiceable: job.flatMap { job in job.managedObjectContext.flatMap { try? job.activeInvoices(in: $0, index: index).isEmpty } } ?? false,
                  photoSaved: expense.photo != nil,
                  repeats: value.repeatsMonthly == true, seriesID: value.seriesID)
    }

    static func state(_ expense: Expense, index: InvoiceIndex) -> ExpenseState {
        if expense.isDraft { return .toFinish }
        if expense.job == nil { return .business }
        guard expense.value.reimbursable else { return .yourCost }
        do {
            let invoices = try expense.activeInvoices(index: index)
            guard invoices.count <= 1 else { return .review }
            guard let invoice = invoices.first else { return .toRebill }
            let value = try invoice.currentValue()
            if value.status == "sent", try invoice.balance() <= 0 { return .paidBack }
            return .onInvoice(reference: value.status == "draft" ? "" : value.reference)
        } catch { return .review }
    }
}

struct ExpenseCurrency: Equatable, Identifiable {
    let currency: String
    var amounts: [ExpenseBucket: Int64] = [:]
    var id: String { currency }
    var total: Int64 { amounts.values.reduce(0, +) }
}

/// Something to do before the month's expenses are complete.
struct FinishItem: Equatable, Identifiable {
    enum Kind: Equatable {
        /// An unfinished receipt or Wallet capture.
        case draft(UUID)
        /// The next month of a repeating business cost, offered from its latest expense.
        case repeatDue(template: UUID, day: String)
    }
    let kind: Kind
    let title: String
    let detail: String
    let rankDay: String
    var id: String {
        switch kind {
        case .draft(let id): id.uuidString
        case let .repeatDue(template, day): "\(template.uuidString)-\(day)"
        }
    }
    var actionTitle: String { if case .repeatDue = kind { "Add" } else { "Finish" } }
}

/// Finished reimbursable receipts not yet on an invoice, for one client and currency.
struct RebillGroup: Equatable, Identifiable {
    let clientID: UUID?
    let name: String
    let currency: String
    var events: [String] = []
    var receipts: [UUID] = []
    /// Events of these receipts that no active invoice includes yet.
    var invoiceableJobs: [UUID] = []
    var amount: Int64 = 0
    var id: String { "\(clientID?.uuidString ?? "none")-\(currency)" }
    var canInvoice: Bool { clientID != nil && !invoiceableJobs.isEmpty }
}

struct EarlierRebill: Equatable {
    var count = 0
    var amounts: [String: Int64] = [:]
    /// The most recent earlier month holding such a receipt.
    var latestMonth = ""
}

struct ExpenseDay: Equatable, Identifiable {
    let day: String
    var expenses: [ExpenseFact]
    var id: String { day }
}

/// The Expenses tab for one month, derived on each render from the expenses themselves.
struct ExpensesMonth: Equatable {
    let month: String
    var currencies: [ExpenseCurrency] = []
    var finish: [FinishItem] = []
    var rebill: [RebillGroup] = []
    var earlier = EarlierRebill()
    var expenses: [ExpenseFact] = []

    var count: Int { expenses.count }

    init(month: String, facts: [ExpenseFact], today: String) {
        self.month = month
        expenses = facts.filter { $0.month == month }
            .sorted { $0.day != $1.day ? $0.day > $1.day : $0.created > $1.created }

        var byCurrency: [String: ExpenseCurrency] = [:]
        for fact in expenses where !fact.eventDeleted {
            guard let amount = fact.amount, amount > 0 else { continue }
            byCurrency[fact.currency, default: ExpenseCurrency(currency: fact.currency)].amounts[fact.state.bucket, default: 0] += amount
        }
        currencies = byCurrency.values.sorted { $0.total != $1.total ? $0.total > $1.total : $0.currency < $1.currency }

        finish = Self.finishItems(facts, today: today)

        var groups: [String: RebillGroup] = [:]; var order: [String] = []
        for fact in expenses.reversed() where fact.state == .toRebill && !fact.eventDeleted {
            let key = "\(fact.clientID?.uuidString ?? "none")-\(fact.currency)"
            if groups[key] == nil { order.append(key) }
            var group = groups[key] ?? RebillGroup(clientID: fact.clientID, name: fact.clientName ?? "No client", currency: fact.currency)
            if let title = fact.eventTitle, !group.events.contains(title) { group.events.append(title) }
            if let job = fact.jobID, fact.eventInvoiceable, !group.invoiceableJobs.contains(job) { group.invoiceableJobs.append(job) }
            group.receipts.append(fact.id); group.amount += fact.amount ?? 0
            groups[key] = group
        }
        rebill = order.compactMap { groups[$0] }

        for fact in facts where fact.state == .toRebill && !fact.eventDeleted && fact.month < month {
            earlier.count += 1
            earlier.amounts[fact.currency, default: 0] += fact.amount ?? 0
            earlier.latestMonth = max(earlier.latestMonth, fact.month)
        }
    }

    func days(_ filter: ExpenseFilter) -> [ExpenseDay] {
        var days: [ExpenseDay] = []
        for fact in expenses {
            switch filter {
            case .all: break
            case .events: guard fact.jobID != nil else { continue }
            case .business: guard fact.isBusiness else { continue }
            }
            if days.last?.day == fact.day { days[days.count - 1].expenses.append(fact) } else { days.append(ExpenseDay(day: fact.day, expenses: [fact])) }
        }
        return days
    }

    /// Unfinished receipts from any month, plus repeating business costs that are due. Oldest first.
    static func finishItems(_ facts: [ExpenseFact], today: String) -> [FinishItem] {
        var items: [FinishItem] = facts.filter { $0.state == .toFinish && !$0.eventDeleted }.map { fact in
            FinishItem(kind: .draft(fact.id),
                       title: [fact.title, fact.displayAmount].compactMap { $0 }.joined(separator: " · "),
                       detail: [shortDay(fact.day), fact.eventTitle ?? "No event yet"].joined(separator: " · "),
                       rankDay: fact.day)
        }
        let series = Dictionary(grouping: facts.filter { $0.isBusiness && $0.seriesID != nil }, by: { $0.seriesID! })
        for latest in series.values.compactMap({ $0.max { ($0.day, $0.created) < ($1.day, $1.created) } }) where latest.repeats {
            guard let due = nextMonth(latest.day), due <= today else { continue }
            items.append(FinishItem(kind: .repeatDue(template: latest.id, day: due),
                                    title: [latest.title, latest.displayAmount].compactMap { $0 }.joined(separator: " · "),
                                    detail: "Due \(shortDay(due)) · Monthly", rankDay: due))
        }
        return items.sorted { $0.rankDay != $1.rankDay ? $0.rankDay < $1.rankDay : $0.title < $1.title }
    }

    static func shortDay(_ day: String) -> String {
        Day.date(from: day)?.formatted(.dateTime.day().month(.abbreviated)) ?? day
    }

    /// The same day next month, clamped to the month's last day.
    static func nextMonth(_ day: String) -> String? {
        guard let date = Day.date(from: day), let next = Calendar(identifier: .gregorian).date(byAdding: .month, value: 1, to: date) else { return nil }
        return Day.string(from: next)
    }

    static func load(month: String, expenses: [Expense], context: NSManagedObjectContext, today: String = Day.string(from: Date())) -> ExpensesMonth {
        let index = InvoiceIndex(in: context)
        return ExpensesMonth(month: month, facts: expenses.compactMap { ExpenseFact(expense: $0, index: index) }, today: today)
    }
}
