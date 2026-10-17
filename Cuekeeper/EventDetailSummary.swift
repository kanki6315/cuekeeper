import CoreData
import Foundation

enum EventTab: String, CaseIterable, Hashable {
    case schedule, money, details
}

/// Whose clock the run of show reads in. Only remote/hybrid work offers a choice.
enum EventTimeChoice: String, CaseIterable, Hashable {
    case yours, track
}

// MARK: - Facts read from the store

struct EventSessionFact: Equatable, Identifiable {
    let id: UUID
    let title: String
    /// Civil day in the event timezone; empty when neither a date nor a time is known.
    let day: String
    let start: Date?
    let end: Date?
    let call: Date?
    let confirmed: Bool
    let coverage: String
    var series: [String] = []
}

struct EventExpenseFact: Equatable, Identifiable {
    let id: UUID
    let merchant: String
    let amount: Int64?
    let currency: String
}

enum EventFeeFact: Equatable {
    case value(FeeValue)
    case conflict
}

enum EventBillingFact: Equatable {
    case notInvoiced
    case directPayments(paid: Int64, currency: String)
    case draft(invoiceID: UUID)
    case sent(invoiceID: UUID, reference: String, currency: String, total: Int64, balance: Int64, dueDay: String, otherEvents: Int)
    case review(message: String, invoiceID: UUID?)
}

/// Plain values describing one event, so the detail page's derived state is testable without a store.
struct EventDetailFacts: Equatable {
    var bookingStatus: String
    var hasClient: Bool
    var startDay: String
    var endDay: String
    var eventZone: TimeZone
    /// Set only when the user works remotely in a different zone from the event.
    var workZone: TimeZone?
    var sessions: [EventSessionFact]
    var fee: EventFeeFact
    var billing: EventBillingFact
    var expenseDrafts: [EventExpenseFact]
    /// Required invoicing details the client is missing.
    var clientDetailsMissing: [String] = []
    /// Receipts still saved as drafts; these hold up invoicing.
    var blockingReceipts = 0
}

// MARK: - Derived page state

struct RunOfShowDay: Equatable, Identifiable {
    /// Empty for sessions with no date yet.
    let key: String
    let sessions: [EventSessionFact]
    var id: String { key }
    var coveringCount: Int { sessions.filter { $0.coverage == "covering" }.count }
}

struct NextCall: Equatable {
    let session: EventSessionFact
    /// The call time when known, otherwise the session start.
    let at: Date
    /// The session is on air right now; `at` is its start.
    var isLive = false
    var isCallTime: Bool { !isLive && session.call != nil }
}

struct OpenItem: Equatable, Identifiable {
    enum Kind: String, Equatable {
        case tentativeBooking, sessionTime, sessionConfirmation, sessionCoverage, clientMissing
        case feeConflict, feeUnknown, clientDetails, readyToInvoice, invoiceDraft, balanceOwed, billingReview, expenseDraft
        /// Raised by Upcoming only: a booked or tentative event whose last day has passed.
        case eventOver
    }
    enum Action: Equatable {
        case markBooked
        case markCompleted
        case editSession(UUID)
        case editEvent
        case openFee
        case addToInvoice
        case editClientInvoicing
        case openInvoice(UUID)
        case reviewBilling(UUID?)
        case reviewExpense(UUID)
        case recordDirectPayment
    }
    let kind: Kind
    let title: String
    let detail: String?
    let tab: EventTab
    let action: Action
    var id: String {
        switch action {
        case .editSession(let id), .openInvoice(let id), .reviewExpense(let id): return "\(kind.rawValue)-\(id.uuidString)"
        default: return kind.rawValue
        }
    }
}

enum InvoiceProgress: Equatable {
    case none
    case draft
    /// The invoice bills this event alone, so its receipts belong to this event.
    case single(total: Int64, paid: Int64, currency: String)
    /// Receipts settle the whole invoice and are never split per event.
    case shared(reference: String, otherEvents: Int, total: Int64, balance: Int64, currency: String)
}

struct EventDetailSummary: Equatable {
    static let heroWindow: TimeInterval = 7 * 24 * 3600

    let days: [RunOfShowDay]
    let nextCall: NextCall?
    let offersTimeChoice: Bool
    let defaultTimeChoice: EventTimeChoice
    let openItems: [OpenItem]
    let defaultTab: EventTab
    let invoiceProgress: InvoiceProgress
    private let eventZone: TimeZone
    private let workZone: TimeZone?

    init(facts: EventDetailFacts, now: Date) {
        eventZone = facts.eventZone
        workZone = facts.workZone.flatMap { $0.identifier == facts.eventZone.identifier ? nil : $0 }
        offersTimeChoice = workZone != nil
        defaultTimeChoice = workZone == nil ? .track : .yours
        days = Self.days(facts.sessions)
        nextCall = facts.bookingStatus == "cancelled" ? nil : Self.nextCall(facts.sessions, now: now)
        openItems = Self.openItems(facts, now: now)
        let closed = facts.bookingStatus == "completed" || facts.bookingStatus == "cancelled"
        defaultTab = closed && openItems.contains { $0.tab == .money } ? .money : .schedule
        invoiceProgress = Self.progress(facts.billing)
    }

    func zone(for choice: EventTimeChoice) -> TimeZone {
        choice == .yours ? workZone ?? eventZone : eventZone
    }

    func count(in tab: EventTab) -> Int { openItems.filter { $0.tab == tab }.count }

    // MARK: Schedule

    private static func days(_ sessions: [EventSessionFact]) -> [RunOfShowDay] {
        let sorted = sessions.sorted {
            ($0.day.isEmpty ? 1 : 0, $0.day, $0.start ?? .distantFuture, $0.title, $0.id.uuidString)
                < ($1.day.isEmpty ? 1 : 0, $1.day, $1.start ?? .distantFuture, $1.title, $1.id.uuidString)
        }
        var result: [RunOfShowDay] = []
        for session in sorted {
            if let last = result.last, last.key == session.day {
                result[result.count - 1] = RunOfShowDay(key: last.key, sessions: last.sessions + [session])
            } else {
                result.append(RunOfShowDay(key: session.day, sessions: [session]))
            }
        }
        return result
    }

    private static func nextCall(_ sessions: [EventSessionFact], now: Date) -> NextCall? {
        // A session on air outranks whatever is next.
        let live = sessions.filter { session in
            guard session.coverage == "covering", let start = session.start, let end = session.end else { return false }
            return start <= now && end > now
        }.min { ($0.end!, $0.id.uuidString) < ($1.end!, $1.id.uuidString) }
        if let live, let start = live.start { return NextCall(session: live, at: start, isLive: true) }
        return sessions.compactMap { session -> NextCall? in
            guard session.coverage == "covering", let at = session.call ?? session.start,
                  at > now, at.timeIntervalSince(now) <= heroWindow else { return nil }
            return NextCall(session: session, at: at)
        }.min { ($0.at, $0.session.id.uuidString) < ($1.at, $1.session.id.uuidString) }
    }

    // MARK: Open items

    private static func openItems(_ facts: EventDetailFacts, now: Date) -> [OpenItem] {
        let status = facts.bookingStatus
        let lastDay = facts.endDay.isEmpty ? facts.startDay : facts.endDay
        let past = !lastDay.isEmpty && lastDay < DaySchedule.dayKey(now, zone: facts.eventZone)
        let upcoming = !past && (status == "tentative" || status == "booked")
        var items: [OpenItem] = []

        if status == "tentative" && !past {
            items.append(OpenItem(kind: .tentativeBooking, title: "Dates are on hold", detail: "Booking not confirmed yet", tab: .schedule, action: .markBooked))
        }
        if upcoming {
            for day in days(facts.sessions) {
                for session in day.sessions where session.coverage != "notCovering" {
                    if let item = sessionItem(session, zone: facts.eventZone) { items.append(item) }
                }
            }
        }
        if !facts.hasClient && status != "cancelled" {
            items.append(OpenItem(kind: .clientMissing, title: "Client to add", detail: "Needed before invoicing", tab: .details, action: .editEvent))
        }

        var fee: FeeValue?
        switch facts.fee {
        case .conflict:
            items.append(OpenItem(kind: .feeConflict, title: "Fee needs review", detail: "Two versions were saved", tab: .money, action: .openFee))
        case .value(let value):
            fee = value
            if value.amount == nil && (status == "booked" || status == "completed") {
                items.append(OpenItem(kind: .feeUnknown, title: "Fee not agreed", detail: "Saved as unknown, not zero", tab: .money, action: .openFee))
            }
        }

        switch facts.billing {
        case .notInvoiced:
            if status == "completed", facts.hasClient, let fee, let amount = fee.amount, amount > 0, facts.blockingReceipts == 0 {
                if facts.clientDetailsMissing.isEmpty {
                    items.append(OpenItem(kind: .readyToInvoice, title: "Ready to invoice", detail: Money.format(amount, currency: fee.currency), tab: .money, action: .addToInvoice))
                } else {
                    let list = ListFormatter.localizedString(byJoining: facts.clientDetailsMissing)
                    items.append(OpenItem(kind: .clientDetails, title: "Invoicing details to add", detail: list.prefix(1).uppercased() + list.dropFirst() + " missing", tab: .money, action: .editClientInvoicing))
                }
            }
        case let .directPayments(paid, currency):
            // Money received directly settles only what it covers; the rest of the fee is still to collect.
            if status != "cancelled", let fee, let amount = fee.amount, fee.currency == currency, paid < amount {
                items.append(OpenItem(kind: .balanceOwed, title: "\(Money.format(amount - paid, currency: currency)) still to collect",
                                      detail: "\(Money.format(paid, currency: currency)) received directly", tab: .money, action: .recordDirectPayment))
            }
        case .draft(let id):
            items.append(OpenItem(kind: .invoiceDraft, title: "Invoice not sent", detail: "On a draft invoice", tab: .money, action: .openInvoice(id)))
        case let .sent(id, reference, currency, _, balance, dueDay, others):
            if balance > 0 {
                let due = dueDay.isEmpty ? nil : "due " + shortDay(dueDay)
                let owed = Money.format(balance, currency: currency)
                if others == 0 {
                    let detail = [reference.isEmpty ? nil : reference, due].compactMap { $0 }.joined(separator: " · ")
                    items.append(OpenItem(kind: .balanceOwed, title: "\(owed) owed", detail: detail.isEmpty ? nil : detail, tab: .money, action: .openInvoice(id)))
                } else {
                    let shared = "Shared with \(counted(others, "other event", "other events"))"
                    let detail = [shared, due].compactMap { $0 }.joined(separator: " · ")
                    items.append(OpenItem(kind: .balanceOwed, title: "\(owed) owed on \(reference.isEmpty ? "invoice" : reference)", detail: detail, tab: .money, action: .openInvoice(id)))
                }
            }
        case let .review(message, id):
            items.append(OpenItem(kind: .billingReview, title: "Billing needs review", detail: message, tab: .money, action: .reviewBilling(id)))
        }

        for expense in facts.expenseDrafts {
            let merchant = expense.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
            let amount = expense.amount.map { Money.format($0, currency: expense.currency) }
            let detail = [merchant.isEmpty ? nil : merchant, amount].compactMap { $0 }.joined(separator: " · ")
            items.append(OpenItem(kind: .expenseDraft, title: "Receipt to review", detail: detail.isEmpty ? "Details to confirm" : detail, tab: .money, action: .reviewExpense(expense.id)))
        }

        if status == "cancelled" {
            let money: Set<OpenItem.Kind> = [.feeConflict, .clientDetails, .invoiceDraft, .balanceOwed, .billingReview, .expenseDraft]
            items = items.filter { money.contains($0.kind) }
        }
        return items
    }

    /// One item per session: the most fundamental gap wins.
    private static func sessionItem(_ session: EventSessionFact, zone: TimeZone) -> OpenItem? {
        let day = session.day.isEmpty ? "Date to come" : shortDay(session.day, zone: zone)
        if session.start == nil {
            let detail = session.coverage == "undecided" ? day + " · coverage undecided" : day
            return OpenItem(kind: .sessionTime, title: "\(session.title) has no time", detail: detail, tab: .schedule, action: .editSession(session.id))
        }
        if !session.confirmed {
            return OpenItem(kind: .sessionConfirmation, title: "\(session.title) time not confirmed", detail: day, tab: .schedule, action: .editSession(session.id))
        }
        if session.coverage == "undecided" {
            return OpenItem(kind: .sessionCoverage, title: "\(session.title) coverage undecided", detail: day, tab: .schedule, action: .editSession(session.id))
        }
        return nil
    }

    private static func shortDay(_ key: String, zone: TimeZone = .current) -> String {
        guard let date = Day.date(from: key, timeZone: zone) else { return key }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
        style.timeZone = zone
        return date.formatted(style)
    }

    // MARK: Money

    private static func progress(_ billing: EventBillingFact) -> InvoiceProgress {
        switch billing {
        case .draft: return .draft
        case let .sent(_, reference, currency, total, balance, _, others):
            return others == 0 ? .single(total: total, paid: total - balance, currency: currency)
                : .shared(reference: reference, otherEvents: others, total: total, balance: balance, currency: currency)
        default: return .none
        }
    }
}

// MARK: - Reading a Job

extension EventDetailFacts {
    init(job: Job, context: NSManagedObjectContext, index: InvoiceIndex? = nil) {
        let eventZone = TimeZone.effective(job.eventTimeZoneID)
        let fee: EventFeeFact
        do { fee = .value(try job.currentFee()) } catch { fee = .conflict }
        self.init(
            bookingStatus: job.bookingStatus,
            hasClient: job.client != nil,
            startDay: job.eventStartDay,
            endDay: job.eventEndDay,
            eventZone: eventZone,
            workZone: job.hasWorkTimeZone ? TimeZone(identifier: job.workTimeZoneID) : nil,
            sessions: job.activeSessions.compactMap { session in
                guard let id = session.id else { return nil }
                return EventSessionFact(id: id, title: session.title, day: session.eventDay, start: session.startTime, end: session.endTime,
                                        call: session.callTime, confirmed: session.scheduleStatus == "confirmed", coverage: session.coverage,
                                        series: session.effectiveSeriesNames)
            },
            fee: fee,
            billing: Self.billing(job: job, context: context, index: index),
            expenseDrafts: (job.expenses ?? []).filter { $0.isDraft && !$0.value.discarded }
                .sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }
                .compactMap { expense in
                    guard let id = expense.id else { return nil }
                    let value = expense.value
                    return EventExpenseFact(id: id, merchant: value.merchant, amount: (try? Money.parse(value.amount, currency: value.currency)).flatMap { $0 }, currency: value.currency)
                },
            clientDetailsMissing: job.client?.invoicing.missing ?? [],
            blockingReceipts: (job.expenses ?? []).filter { $0.isDraft && !$0.value.discarded }.count
        )
    }

    static func billing(job: Job, context: NSManagedObjectContext, index: InvoiceIndex?) -> EventBillingFact {
        do {
            let invoices = try job.activeInvoices(in: context, index: index)
            if invoices.count > 1 { return .review(message: "This event is on more than one invoice", invoiceID: invoices.first?.id) }
            let direct = try job.directPaid()
            if let invoice = invoices.first {
                guard let id = invoice.id else { return .review(message: "Invoice is still syncing", invoiceID: nil) }
                if direct > 0 { return .review(message: "Direct payment and invoice both recorded", invoiceID: id) }
                let value = try invoice.currentValue()
                if value.status == "draft" { return .draft(invoiceID: id) }
                let others = Set(value.lines.map(\.jobID)).subtracting(job.id.map { [$0] } ?? []).count
                return .sent(invoiceID: id, reference: value.reference, currency: value.currency, total: try value.total(),
                             balance: try invoice.balance(), dueDay: value.dueDay, otherEvents: others)
            }
            if direct > 0 {
                return .directPayments(paid: direct, currency: job.paymentCurrency ?? (try? job.currentFee().currency) ?? "USD")
            }
            return .notInvoiced
        } catch {
            return .review(message: error.localizedDescription, invoiceID: nil)
        }
    }
}
