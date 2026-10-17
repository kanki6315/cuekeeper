import CoreData
import Foundation

// MARK: - Facts

/// One session as an Events row needs it.
struct EventsListSession: Equatable {
    /// Day key in the event's timezone; empty when the session has no date yet.
    var day: String
    var title: String
    /// Start time already formatted in the event's timezone.
    var time: String?
}

/// Plain values describing one event row, so the list is testable without a store.
struct EventsListFacts: Equatable {
    var objectID: NSManagedObjectID?
    /// Stable identity for the row.
    var key: String
    var title: String
    var client: String?
    var series: [String]
    var bookingStatus: String
    var startDay: String
    var endDay: String
    /// Sessions in schedule order.
    var sessions: [EventsListSession]
    /// Billing position. Read only once the work is over.
    var payment: EventReadiness?
}

// MARK: - A row

/// One line beside the rail, under the title and client.
enum EventsListLine: Equatable {
    /// A day of the event and the sessions on it, possibly none.
    case day(String, [EventsListSession])
    /// The event has no dated sessions yet; the day key is nil when the event has no dates.
    case scheduleToCome(String?)
    /// Days past the second, folded into the last line of a long event.
    case more(days: [String], sessions: Int)
    /// Keeps a two-day row the same height as longer ones.
    case blank
}

enum EventsBadgeTone: Equatable { case accent, positive, amber, muted }

struct EventsBadge: Equatable {
    let text: String
    let tone: EventsBadgeTone
}

struct EventsListRow: Equatable, Identifiable {
    let facts: EventsListFacts
    /// One line for single-day events; always three for multi-day events.
    let lines: [EventsListLine]
    /// The line the rail's end day sits beside. Nil for single-day events.
    let endLine: Int?
    let badge: EventsBadge
    /// The work is over (completed, or its last day has passed).
    let finished: Bool
    var id: String { facts.key }
    var multiDay: Bool { endLine != nil }

    init(_ facts: EventsListFacts, today: String) {
        self.facts = facts
        let finished = facts.bookingStatus == "completed" || (!facts.endDay.isEmpty && facts.endDay < today)
        self.finished = finished
        badge = Self.badge(facts, finished: finished, today: today)

        let days = EventsCalendar.days(from: facts.startDay, to: facts.endDay)
        guard let first = days.first else {
            lines = [.scheduleToCome(nil)]; endLine = nil; return
        }
        let placed = facts.sessions.filter { !$0.day.isEmpty && $0.day >= first.key && $0.day <= (days.last?.key ?? first.key) }
        func sessions(on day: String) -> [EventsListSession] { placed.filter { $0.day == day } }
        if days.count == 1 {
            lines = [placed.isEmpty ? .scheduleToCome(first.key) : .day(first.key, placed)]
            endLine = nil
            return
        }
        var result: [EventsListLine] = days.prefix(days.count > 3 ? 2 : 3).map { .day($0.key, sessions(on: $0.key)) }
        if days.count > 3 {
            let rest = days.dropFirst(2).map(\.key)
            result.append(.more(days: rest, sessions: placed.filter { $0.day >= rest[0] }.count))
        }
        if placed.isEmpty { result[0] = .scheduleToCome(first.key) }
        endLine = min(days.count, 3) - 1
        while result.count < 3 { result.append(.blank) }
        lines = result
    }

    private static func badge(_ facts: EventsListFacts, finished: Bool, today: String) -> EventsBadge {
        if facts.bookingStatus == "cancelled" { return EventsBadge(text: "Cancelled", tone: .muted) }
        guard finished else {
            let tentative = facts.bookingStatus == "tentative"
            return EventsBadge(text: facts.bookingStatus.capitalized, tone: tentative ? .amber : .positive)
        }
        // Once the work is over, what matters is the money.
        switch facts.payment?.state {
        case .paid, .directPaid: return EventsBadge(text: "Paid", tone: .muted)
        case let .invoiced(_, _, _, dueDay):
            return !dueDay.isEmpty && dueDay < today ? EventsBadge(text: "Overdue", tone: .amber) : EventsBadge(text: "Invoiced", tone: .accent)
        case .draft: return EventsBadge(text: "Draft invoice", tone: .amber)
        case .ready: return EventsBadge(text: "Ready to invoice", tone: .accent)
        case .heldUp, .directPartial: return EventsBadge(text: "To settle", tone: .amber)
        case .review: return EventsBadge(text: "Needs review", tone: .amber)
        case .noFee: return EventsBadge(text: "No fee", tone: .muted)
        case .upcoming, .cancelled, nil: return EventsBadge(text: "Completed", tone: .muted)
        }
    }

    /// What is still owed for this event, when its work is over: the open balance or the amount to invoice.
    var toCollect: (currency: String, amount: Int64)? {
        guard finished, let payment = facts.payment else { return nil }
        switch payment.state {
        case let .invoiced(_, balance, currency, _): return (currency, balance)
        case let .directPartial(_, remaining?, currency): return remaining > 0 ? (currency, remaining) : nil
        case .ready, .draft, .heldUp:
            guard let currency = payment.currency, let amount = payment.amount, amount > 0 else { return nil }
            return (currency, amount)
        default: return nil
        }
    }
}

// MARK: - The list

struct EventsListMonth: Equatable, Identifiable {
    /// "yyyy-MM", or empty for events without dates.
    let month: String
    let rows: [EventsListRow]
    /// Money still to come in from this month's finished events, per currency.
    let toCollect: [CurrencyAmount]
    var id: String { month }
}

struct CurrencyAmount: Equatable {
    let currency: String
    let amount: Int64
}

struct EventsList: Equatable {
    static let windowDays = 14

    let months: [EventsListMonth]
    /// Events hidden because they ended before the window began.
    let hiddenEarlier: Int
    /// First day of the window.
    let cutoff: String
    /// The row that "Today" is drawn above: the first event not yet over, with something before it.
    let todayBefore: String?
    var rows: [EventsListRow] { months.flatMap(\.rows) }

    /// - Parameters:
    ///   - windowed: Whether to hide events that ended more than two weeks ago.
    ///   - showEarlier: Whether the reader asked to see those events anyway.
    init(events: [EventsListFacts], today: String, windowed: Bool, showEarlier: Bool) {
        let cutoff = EventsCalendar.day(today, adding: -Self.windowDays) ?? today
        self.cutoff = cutoff
        let old = windowed ? events.filter { !$0.endDay.isEmpty && $0.endDay < cutoff } : []
        hiddenEarlier = old.count
        let oldKeys = Set(old.map(\.key))
        let shown = events.filter { showEarlier || !oldKeys.contains($0.key) }
            .sorted { lhs, rhs in
                // Events without dates go last.
                if lhs.startDay.isEmpty != rhs.startDay.isEmpty { return rhs.startDay.isEmpty }
                return (lhs.startDay, lhs.title) < (rhs.startDay, rhs.title)
            }
            .map { EventsListRow($0, today: today) }

        var months: [EventsListMonth] = []
        var current: [EventsListRow] = []
        func close() {
            guard let first = current.first else { return }
            var totals: [String: Int64] = [:]
            for row in current { if let owed = row.toCollect { totals[owed.currency, default: 0] += owed.amount } }
            months.append(EventsListMonth(month: String(first.facts.startDay.prefix(7)), rows: current,
                                          toCollect: totals.sorted { $0.key < $1.key }.map { CurrencyAmount(currency: $0.key, amount: $0.value) }))
            current = []
        }
        for row in shown {
            if let last = current.last, last.facts.startDay.prefix(7) != row.facts.startDay.prefix(7) { close() }
            current.append(row)
        }
        close()
        self.months = months

        let next = shown.firstIndex { $0.facts.startDay.isEmpty || $0.facts.endDay >= today }
        todayBefore = next.flatMap { $0 > 0 ? shown[$0].id : nil }
    }
}

// MARK: - Days

enum EventsCalendar {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }
    private static func date(_ key: String) -> Date? { Day.date(from: key, timeZone: TimeZone(identifier: "UTC")!) }
    private static func key(_ date: Date) -> String { Day.string(from: date, timeZone: TimeZone(identifier: "UTC")!) }

    static func day(_ key: String, adding days: Int) -> String? {
        date(key).flatMap { calendar.date(byAdding: .day, value: days, to: $0) }.map(Self.key)
    }

    /// Every day from start to end inclusive. Capped at a year so a mistyped end can't run away.
    static func days(from start: String, to end: String) -> [(key: String, date: Date)] {
        guard let first = date(start) else { return [] }
        let last = date(end).map { max($0, first) } ?? first
        var result: [(String, Date)] = []
        var day = first
        while day <= last && result.count < 366 {
            result.append((key(day), day))
            guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
            day = next
        }
        return result
    }
}

// MARK: - Reading the store

extension EventsListFacts {
    init(job: Job, today: String, context: NSManagedObjectContext, index: InvoiceIndex, readsPayment: Bool = true) {
        let finished = job.bookingStatus == "completed" || (!job.eventEndDay.isEmpty && job.eventEndDay < today)
        self.init(
            objectID: job.objectID,
            key: job.objectID.uriRepresentation().absoluteString,
            title: job.eventTitle,
            client: job.client?.name,
            series: job.eventSeriesNames,
            bookingStatus: job.bookingStatus,
            startDay: job.eventStartDay,
            endDay: job.eventEndDay,
            sessions: job.eventSessions.map { session in
                EventsListSession(day: session.startTime == nil ? session.day : session.eventDay, title: session.title,
                                  time: session.startTime.map(session.shortTime))
            },
            payment: readsPayment && finished && job.bookingStatus != "cancelled"
                ? EventReadiness(ReadinessFacts(job: job, context: context, index: index), today: today) : nil
        )
    }
}
