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
    /// The event fee's currency. Receipts in another currency are billed on an invoice of their own.
    var eventCurrency: String?
    var photoSaved = false
    var repeats = false
    var seriesID: UUID?
    var repeatDay: Int?

    var month: String { String(day.prefix(7)) }
    var isBusiness: Bool { state == .business }
    var displayAmount: String? { amount.map { Money.format($0, currency: currency) } }
    var title: String { merchant.isEmpty ? (photoSaved ? "Receipt photo" : "Expense to complete") : merchant }
}

extension ExpenseFact {
    init?(expense: Expense, index: InvoiceIndex) {
        let value = expense.value
        guard let id = expense.id, !value.discarded else { return nil }
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
                  eventCurrency: (try? job?.currentFee())?.currency,
                  photoSaved: expense.photo != nil,
                  repeats: value.repeatsMonthly, seriesID: value.seriesID, repeatDay: value.repeatDay)
    }

    static func state(_ expense: Expense, index: InvoiceIndex) -> ExpenseState {
        if expense.isDraft { return .toFinish }
        if expense.job == nil { return .business }
        // What an invoice bills comes first: a billed receipt is never "your cost", whatever its flag says now.
        do {
            let invoices = try expense.activeInvoices(index: index)
            guard invoices.count <= 1 else { return .review }
            guard let invoice = invoices.first else { return expense.value.reimbursable ? .toRebill : .yourCost }
            let value = try invoice.currentValue()
            if value.status == "sent", try invoice.balance() <= 0 { return .paidBack }
            return .onInvoice(reference: value.status == "draft" ? "" : value.reference)
        } catch { return expense.value.reimbursable ? .review : .yourCost }
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
        case repeatDue(template: UUID, day: String, repeatDay: Int)
    }
    let kind: Kind
    let title: String
    let detail: String
    let rankDay: String
    var id: String {
        switch kind {
        case .draft(let id): id.uuidString
        case let .repeatDue(template, day, _): "\(template.uuidString)-\(day)"
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
    /// Events of these receipts that no active invoice includes yet and whose fee is in this currency.
    /// The other receipts, such as late ones or those in another currency, are billed without their event.
    var invoiceableJobs: [UUID] = []
    var amount: Int64 = 0
    var id: String { "\(clientID?.uuidString ?? "none")-\(currency)" }
    var canInvoice: Bool { clientID != nil && !receipts.isEmpty }
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
            if let job = fact.jobID, fact.eventInvoiceable, fact.eventCurrency == fact.currency, !group.invoiceableJobs.contains(job) { group.invoiceableJobs.append(job) }
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
        // A series stops when its latest month is saved without "Repeats monthly"; turning it back on
        // resumes from that month's anchor.
        for members in series.values {
            guard let latest = members.max(by: { ($0.day, $0.created) < ($1.day, $1.created) }), latest.repeats,
                  let anchor = latest.repeatDay ?? legacyRepeatDay(latest, series: members),
                  let due = nextMonth(latest.day, repeatDay: anchor), due <= today else { continue }
            items.append(FinishItem(kind: .repeatDue(template: latest.id, day: due, repeatDay: anchor),
                                    title: [latest.title, latest.displayAmount].compactMap { $0 }.joined(separator: " · "),
                                    detail: "Due \(shortDay(due)) · Monthly", rankDay: due))
        }
        return items.sorted { $0.rankDay != $1.rankDay ? $0.rankDay < $1.rankDay : $0.title < $1.title }
    }

    static func shortDay(_ day: String) -> String {
        Day.date(from: day)?.formatted(.dateTime.day().month(.abbreviated)) ?? day
    }

    /// The anchor day next month, clamped to that month's last day. Computed from the anchor, not
    /// from `day`, so Jan 31 → Feb 28 → Mar 31 rather than drifting to the 28th.
    static func nextMonth(_ day: String, repeatDay: Int? = nil) -> String? {
        guard let parts = Day.components(day), let year = parts.year, let month = parts.month,
              let anchor = repeatDay ?? parts.day, (1...31).contains(anchor) else { return nil }
        let next = String(format: "%04d-%02d-01", month == 12 ? year + 1 : year, month == 12 ? 1 : month + 1)
        return String(next.prefix(8)) + String(format: "%02d", clamped(anchor, in: next))
    }

    /// `anchor` limited to the length of the month containing `day`.
    static func clamped(_ anchor: Int, in day: String) -> Int {
        guard let first = Day.components(String(day.prefix(8)) + "01").flatMap({ utc.date(from: $0) }),
              let length = utc.range(of: .day, in: .month, for: first)?.count else { return anchor }
        return min(anchor, length)
    }

    /// Costs saved before anchors were kept: a latest month on its month's last day was probably
    /// clamped, so the series' largest day is the intent. Already-drifted days are left as they are.
    static func legacyRepeatDay(_ latest: ExpenseFact, series: [ExpenseFact]) -> Int? {
        guard let day = Day.components(latest.day)?.day else { return nil }
        guard clamped(31, in: latest.day) == day else { return day }
        return series.compactMap { Day.components($0.day)?.day }.max().map { max($0, day) }
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }()

    static func load(month: String, expenses: [Expense], context: NSManagedObjectContext, today: String = Day.string(from: Date())) -> ExpensesMonth {
        let index = InvoiceIndex(in: context)
        return ExpensesMonth(month: month, facts: expenses.compactMap { ExpenseFact(expense: $0, index: index) }, today: today)
    }
}
