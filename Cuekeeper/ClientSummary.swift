import CoreData
import Foundation

// MARK: - Facts

/// One of the client's invoices as the client screens need it.
struct ClientInvoiceFact: Equatable, Identifiable {
    var objectID: NSManagedObjectID?
    var key: String
    var reference: String
    /// Titles of the events billed on it.
    var events: [String]
    var currency: String
    var total: Int64
    var balance: Int64
    /// "draft", "sent" or "void"; nil when the invoice needs review.
    var status: String?
    var sentDay: String
    var dueDay: String
    var id: String { key }

    enum State: Equatable { case review, draft, void, credit, paid, open(overdue: Bool) }

    func state(today: String) -> State {
        switch status {
        case nil: return .review
        case "draft": return .draft
        case "void": return .void
        default:
            if balance < 0 { return .credit }
            if balance == 0 { return .paid }
            return .open(overdue: !dueDay.isEmpty && dueDay < today)
        }
    }
}

// MARK: - Summary

/// Everything the client screens show, derived from plain values on each render.
struct ClientSummary: Equatable {
    struct Year: Equatable, Identifiable {
        let year: String
        let rows: [EventsListRow]
        var id: String { year }
    }

    let today: String
    let invoicing: ClientInvoicing
    let currency: String
    /// Events still to come or in progress, soonest first; undated events last.
    let upcoming: [EventsListRow]
    /// Finished and cancelled events by year, newest first.
    let past: [Year]
    /// Each event's billing position, for the money view.
    let readiness: [EventReadiness]
    /// Open, draft and review invoices first, then settled ones newest first.
    let invoices: [ClientInvoiceFact]
    /// The client's first event day.
    let sinceDay: String?
    /// Events that were not cancelled.
    let eventCount: Int
    /// Last finished event day, for clients with nothing coming up.
    let lastDay: String?

    init(events: [EventsListFacts], readiness: [EventReadiness] = [], invoices: [ClientInvoiceFact] = [],
         invoicing: ClientInvoicing = ClientInvoicing(), currency: String = "USD", today: String) {
        self.today = today; self.invoicing = invoicing; self.currency = currency; self.readiness = readiness
        let rows = events.map { EventsListRow($0, today: today) }
        upcoming = rows.filter { !$0.finished && $0.facts.bookingStatus != "cancelled" }.sorted { lhs, rhs in
            if lhs.facts.startDay.isEmpty != rhs.facts.startDay.isEmpty { return rhs.facts.startDay.isEmpty }
            return (lhs.facts.startDay, lhs.facts.title) < (rhs.facts.startDay, rhs.facts.title)
        }
        let earlier = rows.filter { $0.finished || $0.facts.bookingStatus == "cancelled" }
            .sorted { ($0.facts.startDay, $0.facts.title) > ($1.facts.startDay, $1.facts.title) }
        past = Dictionary(grouping: earlier) { String($0.facts.startDay.prefix(4)) }
            .map { Year(year: $0.key, rows: $0.value) }
            .sorted { $0.year > $1.year }
        let counted = events.filter { $0.bookingStatus != "cancelled" }
        eventCount = counted.count
        sinceDay = counted.map(\.startDay).filter { !$0.isEmpty }.min()
        lastDay = earlier.filter { $0.facts.bookingStatus != "cancelled" }.map(\.facts.endDay).filter { !$0.isEmpty }.max()

        func rank(_ invoice: ClientInvoiceFact) -> Int {
            switch invoice.state(today: today) {
            case .review: 0
            case .open(overdue: true): 1
            case .open: 2
            case .draft: 3
            case .credit: 4
            case .paid: 5
            case .void: 6
            }
        }
        self.invoices = invoices.sorted { lhs, rhs in
            let l = rank(lhs), r = rank(rhs)
            if l != r { return l < r }
            // Open invoices by due day; settled ones newest first.
            if l <= 2 { return (lhs.dueDay.isEmpty ? "9" : lhs.dueDay, lhs.reference) < (rhs.dueDay.isEmpty ? "9" : rhs.dueDay, rhs.reference) }
            return (lhs.sentDay, lhs.reference) > (rhs.sentDay, rhs.reference)
        }
    }

    /// Open balances on sent invoices, per currency.
    var owed: [CurrencyAmount] { totals(invoices.filter { if case .open = $0.state(today: today) { true } else { false } }) }
    /// The part of `owed` past its due day.
    var overdue: [CurrencyAmount] { totals(invoices.filter { $0.state(today: today) == .open(overdue: true) }) }

    private func totals(_ invoices: [ClientInvoiceFact]) -> [CurrencyAmount] {
        Dictionary(grouping: invoices, by: \.currency)
            .map { CurrencyAmount(currency: $0.key, amount: $0.value.reduce(0) { $0 + $1.balance }) }
            .sorted { $0.currency < $1.currency }
    }

    /// Finished events ready for an invoice, per currency; invoices are made one currency at a time.
    var readyToInvoice: [(currency: String, events: [EventReadiness])] {
        Dictionary(grouping: readiness.filter { $0.state == .ready && $0.currency != nil }) { $0.currency! }
            .map { (currency: $0.key, events: $0.value.sorted { $0.facts.startDay < $1.facts.startDay }) }
            .sorted { $0.currency < $1.currency }
    }

    /// Years with events, newest first.
    var years: [String] {
        Array(Set(readiness.map { String($0.facts.startDay.prefix(4)) }.filter { !$0.isEmpty })).sorted(by: >)
    }

    /// The year the money view opens on: this year when it has work, else the latest year that does.
    var defaultYear: String {
        let current = String(today.prefix(4))
        return years.contains(current) ? current : years.first ?? current
    }

    /// One year's money by state, per currency, as the Payments month shows it.
    func money(in year: String) -> [CurrencyBuckets] {
        var buckets: [String: CurrencyBuckets] = [:]
        for event in readiness where event.facts.startDay.hasPrefix(year) {
            guard let bucket = event.state.bucket, let currency = event.currency else { continue }
            if let amount = event.amount { buckets[currency, default: CurrencyBuckets(currency: currency)].amounts[bucket, default: 0] += amount }
            else { buckets[currency, default: CurrencyBuckets(currency: currency)].unknownFees += 1 }
        }
        return buckets.values.filter { $0.total > 0 || $0.unknownFees > 0 }.sorted { $0.currency < $1.currency }
    }

    /// Required invoicing details still missing, worth raising only while there is work to bill.
    var detailsNeeded: [String] {
        let billable = !upcoming.isEmpty || readiness.contains { [.ready, .heldUp].contains($0.state) }
        return billable ? invoicing.missing : []
    }

    /// The one thing the roster row should flag: overdue money, then money owed, then a billing gap.
    var standing: EventsBadge? {
        if !overdue.isEmpty { return EventsBadge(text: Self.amounts(overdue) + " overdue", tone: .amber) }
        if !owed.isEmpty { return EventsBadge(text: Self.amounts(owed) + " owed", tone: .muted) }
        if let first = detailsNeeded.first { return EventsBadge(text: "Needs " + first, tone: .amber) }
        return nil
    }

    static func amounts(_ values: [CurrencyAmount]) -> String {
        values.map { Money.format($0.amount, currency: $0.currency) }.joined(separator: " · ")
    }
}

// MARK: - Reading the store

extension ClientSummary {
    /// Builds a client's summary. `detailed` also reads each event's billing position, which the roster can skip.
    init(client: Client, context: NSManagedObjectContext, index: InvoiceIndex, detailed: Bool, today: String = Day.string(from: Date())) {
        let jobs = (client.jobs ?? []).filter { $0.deletedAt == nil }
        let readiness = detailed ? jobs.filter { $0.id != nil }.map { EventReadiness(ReadinessFacts(job: $0, context: context, index: index), today: today) } : []
        let byID = Dictionary(readiness.map { ($0.facts.jobID, $0) }, uniquingKeysWith: { a, _ in a })
        let events = jobs.map { job in
            var facts = EventsListFacts(job: job, today: today, context: context, index: index, readsPayment: false)
            facts.payment = job.id.flatMap { byID[$0] }
            return facts
        }
        let titles = Dictionary(jobs.compactMap { job in job.id.map { ($0, job.eventTitle) } }, uniquingKeysWith: { a, _ in a })
        let invoices: [ClientInvoiceFact] = (client.invoices ?? []).map { invoice in
            let value = invoice.issue(in: context, index: index) == nil ? try? invoice.currentValue() : nil
            return ClientInvoiceFact(objectID: invoice.objectID, key: invoice.objectID.uriRepresentation().absoluteString,
                                     reference: invoice.title, events: value?.lines.map { titles[$0.jobID] ?? $0.jobName } ?? [],
                                     currency: value?.currency ?? client.defaultCurrency, total: (try? value?.total()) ?? 0,
                                     balance: value == nil ? 0 : (try? invoice.balance()) ?? 0, status: value?.status,
                                     sentDay: value?.sentDay ?? "", dueDay: value?.dueDay ?? "")
        }
        self.init(events: events, readiness: readiness, invoices: invoices, invoicing: client.invoicing,
                  currency: client.defaultCurrency, today: today)
    }
}

extension String {
    /// Up to two initials for a monogram.
    var initials: String {
        let words = split { !$0.isLetter && !$0.isNumber }
        let letters = (words.count > 1 ? [words[0], words[1]] : words.prefix(1).map { $0 }).compactMap(\.first)
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}
