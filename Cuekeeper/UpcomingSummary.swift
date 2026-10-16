import CoreData
import Foundation

enum UpcomingMode: String, CaseIterable, Hashable {
    case now, plan
    var title: String { self == .now ? "Now" : "Plan" }
}

// MARK: - Facts read from the store

/// One event as Upcoming sees it: the event page's facts plus the labels its rows need.
struct UpcomingJobFact: Equatable, Identifiable {
    let id: UUID
    let title: String
    let client: String?
    /// Roles and arrangement, e.g. "Commentator · Remote".
    let work: String
    let arrangement: WorkArrangement
    let facts: EventDetailFacts
    var lastDay: String { facts.endDay.isEmpty ? facts.startDay : facts.endDay }
}

/// A captured expense that has not been attached to an event yet.
struct UpcomingReceiptFact: Equatable, Identifiable {
    let id: UUID
    let merchant: String
    let amount: Int64?
    let currency: String
    /// Purchase day when known, otherwise the capture day.
    let day: String
}

// MARK: - Derived state

struct UpcomingItem: Equatable, Identifiable {
    enum Category: Equatable { case booking, schedule, money }
    let item: OpenItem
    let jobID: UUID?
    let eventTitle: String?
    /// Items sort by the day they are tied to; past days come first.
    let rankDay: String
    var category: Category {
        switch item.kind {
        case .tentativeBooking, .eventOver, .clientMissing: return .booking
        case .sessionTime, .sessionConfirmation, .sessionCoverage: return .schedule
        default: return .money
        }
    }
    var id: String { "\(jobID?.uuidString ?? "receipt")-\(item.id)" }
    /// The event and the item's own detail, for rows that list items from many events.
    var context: String? {
        let parts = (item.kind == .eventOver ? [] : [eventTitle]) + [item.detail]
        let text = parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
        return text.isEmpty ? nil : text
    }
}

struct UpcomingSessionRow: Equatable, Identifiable {
    let session: EventSessionFact
    let jobID: UUID
    let jobTitle: String
    /// The clock this row reads in.
    let zone: TimeZone
    /// True when the row reads in a different zone from the rest of the run of show.
    let showsZone: Bool
    /// Free time since the previous covered session of a different job on the same day.
    let gapBefore: TimeInterval?
    var id: UUID { session.id }
}

struct UpcomingDay: Equatable, Identifiable {
    let key: String
    let rows: [UpcomingSessionRow]
    var id: String { key }
    var runOfShow: RunOfShowDay { RunOfShowDay(key: key, sessions: rows.map(\.session)) }
}

enum StripMark: Equatable { case covering, notCovering, tbc }

struct StripDay: Equatable, Identifiable {
    let key: String
    let date: Date
    let marks: [StripMark]
    let isToday: Bool
    let isPast: Bool
    var id: String { key }
}

struct ComingUpEntry: Equatable, Identifiable {
    let job: UpcomingJobFact
    let summary: String
    let openCount: Int
    var id: UUID { job.id }
}

struct UpcomingNextWork: Equatable {
    let job: UpcomingJobFact
    let daysUntil: Int
    /// The first session's call or start, when the schedule is known.
    let first: EventSessionFact?
}

struct UpcomingSummary: Equatable {
    static let inFlightWindow: TimeInterval = 72 * 3600
    /// Booking and schedule gaps only surface for events starting within this horizon.
    static let settleHorizon: TimeInterval = 30 * 24 * 3600
    static let comingUpLimit = 8

    let inFlight: [UpcomingJobFact]
    let nextCall: (jobID: UUID, call: NextCall)?
    /// Zone the run of show reads in when no row says otherwise.
    let displayZone: TimeZone
    let days: [UpcomingDay]
    let afterThis: UpcomingJobFact?
    let nextWork: UpcomingNextWork?
    let items: [UpcomingItem]
    let fortnight: [StripDay]
    let comingUp: [ComingUpEntry]

    var defaultMode: UpcomingMode { inFlight.isEmpty ? .plan : .now }
    /// Identifies the in-flight set; a manual mode choice holds only while this stays the same.
    var inFlightKey: String { inFlight.map(\.id.uuidString).sorted().joined(separator: ",") }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.inFlight == rhs.inFlight && lhs.nextCall?.jobID == rhs.nextCall?.jobID && lhs.nextCall?.call == rhs.nextCall?.call
            && lhs.displayZone == rhs.displayZone && lhs.days == rhs.days && lhs.afterThis == rhs.afterThis
            && lhs.nextWork == rhs.nextWork && lhs.items == rhs.items && lhs.fortnight == rhs.fortnight && lhs.comingUp == rhs.comingUp
    }

    init(jobs: [UpcomingJobFact], receipts: [UpcomingReceiptFact], now: Date, zone: TimeZone = .current) {
        let active = jobs.filter { $0.facts.bookingStatus == "tentative" || $0.facts.bookingStatus == "booked" }
        let flying = active.filter { Self.isInFlight($0, now: now) }
            .sorted { ($0.facts.startDay, $0.title, $0.id.uuidString) < ($1.facts.startDay, $1.title, $1.id.uuidString) }
        inFlight = flying
        let shown = Self.displayZone(flying, device: zone)
        displayZone = shown
        days = Self.days(flying, display: shown, now: now)
        nextCall = flying.compactMap { job in
            EventDetailSummary(facts: job.facts, now: now).nextCall.map { (jobID: job.id, call: $0) }
        }.min { ($0.call.at, $0.jobID.uuidString) < ($1.call.at, $1.jobID.uuidString) }

        let flyingIDs = Set(flying.map(\.id))
        let later = active.filter { job in
            !flyingIDs.contains(job.id) && !job.facts.startDay.isEmpty
                && job.facts.startDay >= DaySchedule.dayKey(now, zone: job.facts.eventZone)
        }.sorted { ($0.facts.startDay, $0.title, $0.id.uuidString) < ($1.facts.startDay, $1.title, $1.id.uuidString) }
        afterThis = later.first
        nextWork = flying.isEmpty ? later.first.map { Self.nextWork($0, now: now, zone: zone) } : nil

        let items = Self.items(jobs, receipts: receipts, now: now)
        self.items = items
        fortnight = Self.fortnight(jobs, now: now, zone: zone)
        comingUp = Self.comingUp(active, items: items, now: now)
    }

    /// "2 bookings · 1 schedule · 2 money"
    var categorySummary: String {
        let bookings = items.filter { $0.category == .booking }.count
        let schedule = items.filter { $0.category == .schedule }.count
        let money = items.filter { $0.category == .money }.count
        return [bookings > 0 ? counted(bookings, "booking", "bookings") : nil,
                schedule > 0 ? "\(schedule) schedule" : nil,
                money > 0 ? "\(money) money" : nil].compactMap { $0 }.joined(separator: " · ")
    }

    func openCount(for jobID: UUID) -> Int { items.filter { $0.jobID == jobID }.count }

    // MARK: Now

    static func isInFlight(_ job: UpcomingJobFact, now: Date) -> Bool {
        let facts = job.facts
        let end = now.addingTimeInterval(inFlightWindow)
        if !facts.startDay.isEmpty {
            let today = DaySchedule.dayKey(now, zone: facts.eventZone)
            let last = DaySchedule.dayKey(end, zone: facts.eventZone)
            if facts.startDay <= last && job.lastDay >= today { return true }
        }
        return facts.sessions.contains { session in
            guard session.coverage != "notCovering" else { return false }
            if let at = session.call ?? session.start, at >= now, at <= end { return true }
            if let start = session.start, let finish = session.end, start <= now, finish > now { return true }
            return false
        }
    }

    /// On-site work in one shared zone reads in that zone; anything else reads in the user's own clock.
    private static func displayZone(_ jobs: [UpcomingJobFact], device: TimeZone) -> TimeZone {
        let zones = Set(jobs.map(\.facts.eventZone.identifier))
        if !jobs.isEmpty, jobs.allSatisfy({ $0.facts.workZone == nil && $0.arrangement == .onSite }), zones.count == 1 {
            return jobs[0].facts.eventZone
        }
        return device
    }

    private static func days(_ jobs: [UpcomingJobFact], display: TimeZone, now: Date) -> [UpcomingDay] {
        let today = DaySchedule.dayKey(now, zone: display)
        var grouped: [String: [UpcomingSessionRow]] = [:]
        for job in jobs {
            let onSiteElsewhere = job.arrangement == .onSite && job.facts.workZone == nil
                && job.facts.eventZone.identifier != display.identifier
            let zone = onSiteElsewhere ? job.facts.eventZone : display
            for session in job.facts.sessions {
                let key = session.start.map { DaySchedule.dayKey($0, zone: display) } ?? session.day
                guard !key.isEmpty, key >= today else { continue }
                grouped[key, default: []].append(UpcomingSessionRow(session: session, jobID: job.id, jobTitle: job.title,
                                                                    zone: zone, showsZone: onSiteElsewhere, gapBefore: nil))
            }
        }
        return grouped.keys.sorted().map { key in
            let sorted = grouped[key]!.sorted {
                ($0.session.start ?? .distantFuture, $0.session.title, $0.id.uuidString) < ($1.session.start ?? .distantFuture, $1.session.title, $1.id.uuidString)
            }
            var rows: [UpcomingSessionRow] = []
            var previous: UpcomingSessionRow?
            for row in sorted {
                var gap: TimeInterval?
                if row.session.coverage == "covering", let begins = row.session.call ?? row.session.start,
                   let previous, previous.jobID != row.jobID, let ended = previous.session.end, begins > ended {
                    gap = begins.timeIntervalSince(ended)
                }
                rows.append(UpcomingSessionRow(session: row.session, jobID: row.jobID, jobTitle: row.jobTitle,
                                               zone: row.zone, showsZone: row.showsZone, gapBefore: gap))
                if row.session.coverage == "covering", row.session.end != nil { previous = row }
            }
            return UpcomingDay(key: key, rows: rows)
        }
    }

    private static func nextWork(_ job: UpcomingJobFact, now: Date, zone: TimeZone) -> UpcomingNextWork {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let start = Day.date(from: job.facts.startDay, timeZone: zone) ?? now
        let days = calendar.dateComponents([.day], from: calendar.startOfDay(for: now), to: calendar.startOfDay(for: start)).day ?? 0
        let first = job.facts.sessions.filter { $0.coverage != "notCovering" && ($0.call ?? $0.start) != nil }
            .min { ($0.call ?? $0.start!, $0.id.uuidString) < ($1.call ?? $1.start!, $1.id.uuidString) }
        return UpcomingNextWork(job: job, daysUntil: max(days, 0), first: first)
    }

    // MARK: Plan

    private static func items(_ jobs: [UpcomingJobFact], receipts: [UpcomingReceiptFact], now: Date) -> [UpcomingItem] {
        var result: [UpcomingItem] = []
        for job in jobs {
            let facts = job.facts
            let status = facts.bookingStatus
            let today = DaySchedule.dayKey(now, zone: facts.eventZone)
            let horizon = DaySchedule.dayKey(now.addingTimeInterval(settleHorizon), zone: facts.eventZone)
            let past = !job.lastDay.isEmpty && job.lastDay < today
            let near = facts.startDay.isEmpty || facts.startDay <= horizon
            let detail = EventDetailSummary(facts: facts, now: now)
            for item in detail.openItems {
                let wrapped = UpcomingItem(item: item, jobID: job.id, eventTitle: job.title, rankDay: rankDay(item, job: job))
                if wrapped.category != .money && !near && !past { continue }
                result.append(wrapped)
            }
            if past && (status == "tentative" || status == "booked") {
                let day = shortDay(job.lastDay, zone: facts.eventZone)
                let detailText = [day, job.client].compactMap { $0 }.joined(separator: " · ")
                let item = OpenItem(kind: .eventOver, title: "\(job.title) is over", detail: detailText, tab: .schedule, action: .markCompleted)
                result.append(UpcomingItem(item: item, jobID: job.id, eventTitle: job.title, rankDay: job.lastDay))
            }
        }
        for receipt in receipts {
            let merchant = receipt.merchant.trimmingCharacters(in: .whitespacesAndNewlines)
            let amount = receipt.amount.map { Money.format($0, currency: receipt.currency) }
            let detail = [merchant.isEmpty ? nil : merchant, amount, "no event yet"].compactMap { $0 }.joined(separator: " · ")
            let item = OpenItem(kind: .expenseDraft, title: "Receipt to finish", detail: detail, tab: .money, action: .reviewExpense(receipt.id))
            result.append(UpcomingItem(item: item, jobID: nil, eventTitle: nil, rankDay: receipt.day))
        }
        return result.sorted { ($0.rankDay, $0.item.title, $0.id) < ($1.rankDay, $1.item.title, $1.id) }
    }

    /// The day an item is tied to: the event's end once it is over, invoices by their due day, everything else by the start.
    private static func rankDay(_ item: OpenItem, job: UpcomingJobFact) -> String {
        switch item.kind {
        case .eventOver, .readyToInvoice, .invoiceDraft, .billingReview, .expenseDraft: return job.lastDay
        case .balanceOwed:
            if case let .sent(_, _, _, _, _, due, _) = job.facts.billing, !due.isEmpty { return due }
            return job.lastDay
        default: return job.facts.startDay
        }
    }

    private static func fortnight(_ jobs: [UpcomingJobFact], now: Date, zone: TimeZone) -> [StripDay] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone; calendar.firstWeekday = 2
        guard let monday = calendar.dateInterval(of: .weekOfYear, for: now)?.start else { return [] }
        let today = DaySchedule.dayKey(now, zone: zone)
        let dates = (0..<14).compactMap { calendar.date(byAdding: .day, value: $0, to: monday) }
        let keys = dates.map { DaySchedule.dayKey($0, zone: zone) }
        var marks: [String: [StripMark]] = [:]
        for job in jobs where job.facts.bookingStatus != "cancelled" {
            if job.facts.sessions.isEmpty {
                guard job.facts.bookingStatus != "completed", !job.facts.startDay.isEmpty else { continue }
                for key in keys where key >= job.facts.startDay && key <= job.lastDay && key >= today { marks[key, default: []].append(.tbc) }
                continue
            }
            for session in job.facts.sessions {
                let key = session.start.map { DaySchedule.dayKey($0, zone: zone) } ?? session.day
                guard keys.contains(key) else { continue }
                let mark: StripMark = session.coverage == "notCovering" ? .notCovering : session.start == nil ? .tbc : .covering
                marks[key, default: []].append(mark)
            }
        }
        return zip(keys, dates).map { key, date in
            StripDay(key: key, date: date, marks: (marks[key] ?? []).sorted { order($0) < order($1) }, isToday: key == today, isPast: key < today)
        }
    }

    private static func order(_ mark: StripMark) -> Int {
        switch mark { case .covering: 0; case .notCovering: 1; case .tbc: 2 }
    }

    private static func comingUp(_ active: [UpcomingJobFact], items: [UpcomingItem], now: Date) -> [ComingUpEntry] {
        active.filter { job in
            let facts = job.facts
            guard !facts.startDay.isEmpty else { return false }
            let today = DaySchedule.dayKey(now, zone: facts.eventZone)
            let horizon = DaySchedule.dayKey(now.addingTimeInterval(settleHorizon), zone: facts.eventZone)
            return job.lastDay >= today && facts.startDay <= horizon
        }
        .sorted { ($0.facts.startDay, $0.title, $0.id.uuidString) < ($1.facts.startDay, $1.title, $1.id.uuidString) }
        .prefix(comingUpLimit)
        .map { job in
            ComingUpEntry(job: job, summary: comingUpSummary(job), openCount: items.filter { $0.jobID == job.id }.count)
        }
    }

    private static func comingUpSummary(_ job: UpcomingJobFact) -> String {
        let sessions = job.facts.sessions
        var coverage: String
        if sessions.isEmpty { coverage = "schedule to come" }
        else {
            let covering = sessions.filter { $0.coverage == "covering" }.count
            let undecided = sessions.filter { $0.coverage == "undecided" }.count
            coverage = [covering > 0 ? "\(covering) covering" : nil, undecided > 0 ? "\(undecided) undecided" : nil]
                .compactMap { $0 }.joined(separator: ", ")
            if coverage.isEmpty { coverage = "not covering" }
        }
        let place: String? = switch job.arrangement {
        case .remote: "remote"
        case .onSite: "on site"
        case .hybrid: "hybrid"
        case .unspecified: nil
        }
        let status = job.facts.bookingStatus == "tentative" ? "tentative" : nil
        return [job.client ?? "Client to add", place, status, coverage].compactMap { $0 }.joined(separator: " · ")
    }

    static func shortDay(_ key: String, zone: TimeZone) -> String {
        guard let date = Day.date(from: key, timeZone: zone) else { return key }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).day().month(.abbreviated)
        style.timeZone = zone
        return date.formatted(style)
    }
}

// MARK: - Reading the store

extension UpcomingSummary {
    static func facts(jobs: [Job], context: NSManagedObjectContext) -> [UpcomingJobFact] {
        let index = InvoiceIndex(in: context)
        var seen = Set<NSManagedObjectID>()
        return jobs.compactMap { job in
            guard job.deletedAt == nil, let id = job.id, seen.insert(job.eventKey).inserted else { return nil }
            let arrangement = WorkArrangement(rawValue: job.workArrangement) ?? .unspecified
            let work = (job.roleNames + (arrangement == .unspecified ? [] : [arrangement.title])).joined(separator: " · ")
            return UpcomingJobFact(id: id, title: job.eventTitle, client: job.client?.name, work: work, arrangement: arrangement,
                                   facts: EventDetailFacts(job: job, context: context, index: index))
        }
    }

    static func receipts(_ expenses: [Expense]) -> [UpcomingReceiptFact] {
        expenses.filter { $0.job == nil && $0.needsCompletion }.compactMap { expense in
            guard let id = expense.id else { return nil }
            let value = expense.value
            let day = value.day.isEmpty ? Day.string(from: expense.createdAt ?? Date()) : value.day
            return UpcomingReceiptFact(id: id, merchant: value.merchant, amount: (try? Money.parse(value.amount)).flatMap { $0 },
                                       currency: value.currency, day: day)
        }
    }
}
