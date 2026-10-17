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

/// Something waiting in the Expenses inbox.
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
    var group = InboxGroup.recent
    var amount: Int64?
    var currency = ""
    var id: String {
        switch kind {
        case .draft(let id): id.uuidString
        case let .repeatDue(template, day, _): "\(template.uuidString)-\(day)"
        }
    }
    var actionTitle: String { if case .repeatDue = kind { "Add" } else { "Finish" } }
    var draftID: UUID? { if case .draft(let id) = kind { id } else { nil } }
}

/// Why something is in the inbox, in the order the inbox shows them.
enum InboxGroup: Int, CaseIterable, Hashable, Comparable {
    case blocking, recent, due, stale
    /// Unassigned drafts older than this are probably personal purchases.
    static let staleDays = 30
    var title: String {
        switch self {
        case .blocking: "Holding up invoicing"
        case .recent: "New"
        case .due: "Repeating costs due"
        case .stale: "Older than 30 days"
        }
    }
    static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
}

struct InboxSection: Equatable, Identifiable {
    let group: InboxGroup
    var items: [FinishItem]
    var id: InboxGroup { group }
}

/// Unfinished drafts from any date plus repeating costs that are due. It has no period: it is a queue to empty.
struct ExpenseInbox: Equatable {
    var sections: [InboxSection] = []
    var count = 0
    /// Draft totals per currency. Drafts without a readable amount are counted but not totalled.
    var amounts: [String: Int64] = [:]

    init(items: [FinishItem]) {
        count = items.count
        sections = InboxGroup.allCases.compactMap { group in
            let matching = items.filter { $0.group == group }
            return matching.isEmpty ? nil : InboxSection(group: group, items: matching)
        }
        for item in items where item.draftID != nil {
            if let amount = item.amount { amounts[item.currency, default: 0] += amount }
        }
    }
    var drafts: Int { sections.flatMap(\.items).filter { $0.draftID != nil }.count }
}

/// The Ledger's time span. Expense days are compared by month, so no time zone is involved.
struct LedgerPeriod: Hashable {
    enum Kind: String, CaseIterable, Hashable {
        case month = "Month", quarter = "Quarter", year = "Year", all = "All time"
    }
    var kind: Kind
    /// Any month inside the period, as YYYY-MM. Kept when switching kinds, so October becomes Q4 and back.
    var anchor: String

    static func current(_ kind: Kind = .month, today: String = Day.string(from: Date())) -> LedgerPeriod {
        LedgerPeriod(kind: kind, anchor: String(today.prefix(7)))
    }

    private var yearMonth: (year: Int, month: Int)? {
        let parts = anchor.split(separator: "-")
        guard parts.count == 2, let year = Int(parts[0]), let month = Int(parts[1]), (1...12).contains(month) else { return nil }
        return (year, month)
    }
    private static func key(_ year: Int, _ month: Int) -> String { String(format: "%04d-%02d", year, month) }

    /// First and last month, inclusive. Nil for all time.
    var months: (first: String, last: String)? {
        guard let (year, month) = yearMonth else { return nil }
        switch kind {
        case .month: return (anchor, anchor)
        case .quarter:
            let first = (month - 1) / 3 * 3 + 1
            return (Self.key(year, first), Self.key(year, first + 2))
        case .year: return (Self.key(year, 1), Self.key(year, 12))
        case .all: return nil
        }
    }
    func contains(_ day: String) -> Bool {
        guard let months else { return true }
        let month = String(day.prefix(7))
        return month >= months.first && month <= months.last
    }
    func shifted(_ steps: Int) -> LedgerPeriod {
        guard kind != .all, let (year, month) = yearMonth else { return self }
        let size = kind == .quarter ? 3 : kind == .year ? 12 : 1
        let index = year * 12 + month - 1 + steps * size
        return LedgerPeriod(kind: kind, anchor: Self.key(index / 12, index % 12 + 1))
    }
    var title: String {
        guard let (year, month) = yearMonth else { return kind == .all ? Kind.all.rawValue : anchor }
        switch kind {
        case .month: return MonthStepper.title(anchor)
        case .quarter: return "Q\((month - 1) / 3 + 1) \(String(year))"
        case .year: return String(year)
        case .all: return Kind.all.rawValue
        }
    }
}

/// Where a finished expense's money stands, as the Ledger filters it.
enum LedgerState: String, CaseIterable, Hashable {
    case any = "Any state", toRebill = "To rebill", onInvoice = "On an invoice", paidBack = "Paid back", yourCost = "Your cost"
    func includes(_ state: ExpenseState) -> Bool {
        switch self {
        case .any: true
        case .toRebill: state.bucket == .toRebill
        case .onInvoice: state.bucket == .onInvoice
        case .paidBack: state.bucket == .paidBack
        case .yourCost: state.bucket == .yourCost
        }
    }
}

struct ExpenseLedgerFilter: Equatable {
    var period: LedgerPeriod
    var state = LedgerState.any
    var type = ExpenseFilter.all
    var clientID: UUID?

    /// Type and client, without period or state.
    func inScope(_ fact: ExpenseFact) -> Bool {
        switch type {
        case .all: break
        case .events: guard fact.jobID != nil else { return false }
        case .business: guard fact.isBusiness else { return false }
        }
        return clientID == nil || fact.clientID == clientID
    }
    func includes(_ fact: ExpenseFact) -> Bool { period.contains(fact.day) && state.includes(fact.state) && inScope(fact) }
    /// Filters beyond the period, which the empty state offers to clear.
    var isNarrowed: Bool { state != .any || type != .all || clientID != nil }
}

struct LedgerClient: Equatable, Identifiable {
    let id: UUID
    let name: String
}

struct ExpenseMonthGroup: Equatable, Identifiable {
    let month: String
    var days: [ExpenseDay]
    var id: String { month }
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

/// Reimbursable receipts from before the period, still not on an invoice.
struct EarlierRebill: Equatable {
    var count = 0
    var amounts: [String: Int64] = [:]
}

struct ExpenseDay: Equatable, Identifiable {
    let day: String
    var expenses: [ExpenseFact]
    var id: String { day }
}

/// The Expenses tab, derived on each render from the expenses themselves: the inbox of unfinished work,
/// and the Ledger of finished expenses for a period and filters.
struct ExpensesLedger: Equatable {
    let filter: ExpenseLedgerFilter
    var currencies: [ExpenseCurrency] = []
    var inbox: ExpenseInbox
    var rebill: [RebillGroup] = []
    var earlier = EarlierRebill()
    /// Finished expenses matching the filter, newest first. Drafts stay in the inbox.
    var expenses: [ExpenseFact] = []
    /// Drafts dated in the period, which the Ledger points to rather than lists.
    var draftsInPeriod = 0
    /// Clients with a finished expense, for the client filter.
    var clients: [LedgerClient] = []

    var count: Int { expenses.count }

    init(filter: ExpenseLedgerFilter, facts: [ExpenseFact], today: String) {
        self.filter = filter
        inbox = ExpenseInbox(items: Self.finishItems(facts, today: today))
        expenses = facts.filter { $0.state != .toFinish && filter.includes($0) }
            .sorted { $0.day != $1.day ? $0.day > $1.day : $0.created > $1.created }
        draftsInPeriod = facts.filter { $0.state == .toFinish && !$0.eventDeleted && filter.period.contains($0.day) }.count

        var names: [UUID: String] = [:]
        for fact in facts where fact.state != .toFinish { if let id = fact.clientID, let name = fact.clientName { names[id] = name } }
        clients = names.map { LedgerClient(id: $0.key, name: $0.value) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        var byCurrency: [String: ExpenseCurrency] = [:]
        for fact in expenses where !fact.eventDeleted {
            guard let amount = fact.amount, amount > 0 else { continue }
            byCurrency[fact.currency, default: ExpenseCurrency(currency: fact.currency)].amounts[fact.state.bucket, default: 0] += amount
        }
        currencies = byCurrency.values.sorted { $0.total != $1.total ? $0.total > $1.total : $0.currency < $1.currency }

        guard filter.state == .any || filter.state == .toRebill else { return }
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

        guard let first = filter.period.months?.first else { return }
        for fact in facts where fact.state == .toRebill && !fact.eventDeleted && fact.month < first && filter.inScope(fact) {
            earlier.count += 1
            earlier.amounts[fact.currency, default: 0] += fact.amount ?? 0
        }
    }

    /// Expenses by month, then by day.
    var months: [ExpenseMonthGroup] {
        var months: [ExpenseMonthGroup] = []
        for fact in expenses {
            if months.last?.month != fact.month { months.append(ExpenseMonthGroup(month: fact.month, days: [])) }
            var days = months[months.count - 1].days
            if days.last?.day == fact.day { days[days.count - 1].expenses.append(fact) } else { days.append(ExpenseDay(day: fact.day, expenses: [fact])) }
            months[months.count - 1].days = days
        }
        return months
    }

    /// Unfinished receipts from any date, plus repeating business costs that are due. Oldest first.
    static func finishItems(_ facts: [ExpenseFact], today: String) -> [FinishItem] {
        let recent = EventsCalendar.day(today, adding: -InboxGroup.staleDays) ?? today
        var items: [FinishItem] = facts.filter { $0.state == .toFinish && !$0.eventDeleted }.map { fact in
            // A draft on an event holds up that event's invoice; an unassigned one goes stale after a month.
            let group: InboxGroup = fact.jobID != nil ? .blocking : fact.day >= recent ? .recent : .stale
            return FinishItem(kind: .draft(fact.id),
                              title: [fact.title, fact.displayAmount].compactMap { $0 }.joined(separator: " · "),
                              detail: [shortDay(fact.day), fact.eventTitle ?? "No event yet"].joined(separator: " · "),
                              rankDay: fact.day, group: group, amount: fact.amount, currency: fact.currency)
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
                                    detail: "Due \(shortDay(due)) · Monthly", rankDay: due, group: .due))
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

    static func load(filter: ExpenseLedgerFilter, expenses: [Expense], context: NSManagedObjectContext, today: String = Day.string(from: Date())) -> ExpensesLedger {
        let index = InvoiceIndex(in: context)
        return ExpensesLedger(filter: filter, facts: expenses.compactMap { ExpenseFact(expense: $0, index: index) }, today: today)
    }
}
