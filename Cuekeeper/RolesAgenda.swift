import CoreData
import Foundation

// MARK: - Facts

/// One saved role as the Roles page needs it.
struct RoleFact: Equatable, Identifiable {
    var objectID: NSManagedObjectID?
    /// Stable identity, also used to remember the selected chip.
    var key: String
    var name: String
    var id: String { key }
}

/// An event and the roles held on it: the booking's roles plus any a session overrides.
struct RoleEventFact: Equatable {
    var facts: EventsListFacts
    var roleKeys: Set<String>
}

// MARK: - The page

/// Every role's events on one agenda, filtered by the selected role. Derived on each render; nothing is stored.
struct RolesAgenda: Equatable {
    struct Chip: Equatable, Identifiable {
        /// Nil for All.
        let role: RoleFact?
        /// Events that were not cancelled.
        let count: Int
        var id: String { role?.key ?? "" }
    }

    struct Row: Equatable, Identifiable {
        let row: EventsListRow
        /// Roles to tag the row with: all of them under All, the others when one role is selected.
        let roles: [String]
        var id: String { row.id }
    }

    struct Year: Equatable, Identifiable {
        let year: String
        let rows: [Row]
        var id: String { year }
    }

    struct ClientCount: Equatable {
        let name: String
        let count: Int
    }

    /// What the summary panel shows for the selected role.
    struct Focus: Equatable {
        let role: RoleFact
        let eventCount: Int
        let sinceDay: String?
        /// The calendar year of `today`.
        let year: String
        /// Events per month of `year`, January first.
        let months: [Int]
        /// Clients worked for in this role, most events first, at most three.
        let clients: [ClientCount]
        var yearCount: Int { months.reduce(0, +) }
    }

    let today: String
    /// All first, then roles with the most events.
    let chips: [Chip]
    /// Nil when All is selected.
    let focus: Focus?
    /// Events still to come or in progress, soonest first; undated events last.
    let upcoming: [Row]
    /// Finished and cancelled events by year, newest first.
    let past: [Year]
    /// Events with no role at all, which only the Events tab lists.
    let untagged: Int
    var isEmpty: Bool { upcoming.isEmpty && past.isEmpty }

    /// - Parameters:
    ///   - selected: The remembered role key; empty, or a role that no longer exists, selects All.
    ///   - query: Narrows the agenda to events whose title, client or roles match.
    init(roles: [RoleFact], events: [RoleEventFact], selected: String, query: String = "", today: String) {
        self.today = today
        let names = Dictionary(roles.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
        let tagged = events.map { RoleEventFact(facts: $0.facts, roleKeys: $0.roleKeys.filter { names[$0] != nil }) }
        untagged = tagged.filter { $0.roleKeys.isEmpty }.count
        let live = tagged.filter { $0.facts.bookingStatus != "cancelled" }

        func uses(_ role: RoleFact) -> Int { live.filter { $0.roleKeys.contains(role.key) }.count }
        func before(_ lhs: Chip, _ rhs: Chip) -> Bool {
            if lhs.count != rhs.count { return lhs.count > rhs.count }
            return (lhs.role?.name ?? "").localizedStandardCompare(rhs.role?.name ?? "") == .orderedAscending
        }
        let ranked = roles.map { Chip(role: $0, count: uses($0)) }.sorted(by: before)
        chips = [Chip(role: nil, count: live.filter { !$0.roleKeys.isEmpty }.count)] + ranked

        let role = roles.first { $0.key == selected }
        let shown = tagged.filter { event in
            if let role { return event.roleKeys.contains(role.key) }
            return !event.roleKeys.isEmpty
        }
        let year = String(today.prefix(4))
        focus = role.map { role in
            let worked = shown.filter { $0.facts.bookingStatus != "cancelled" }
            var months = Array(repeating: 0, count: 12)
            for event in worked where event.facts.startDay.hasPrefix(year + "-") {
                if let month = Int(event.facts.startDay.dropFirst(5).prefix(2)), (1...12).contains(month) { months[month - 1] += 1 }
            }
            var perClient: [String: Int] = [:]
            for event in worked { if let client = event.facts.client, !client.isEmpty { perClient[client, default: 0] += 1 } }
            let clients: [ClientCount] = perClient.map { ClientCount(name: $0.key, count: $0.value) }
                .sorted { lhs, rhs in lhs.count != rhs.count ? lhs.count > rhs.count : lhs.name < rhs.name }
            return Focus(role: role, eventCount: worked.count, sinceDay: worked.map(\.facts.startDay).filter { !$0.isEmpty }.min(),
                         year: year, months: months, clients: Array(clients.prefix(3)))
        }

        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let rows = shown.map { event in
            Row(row: EventsListRow(event.facts, today: today),
                roles: event.roleKeys.filter { $0 != role?.key }.compactMap { names[$0] }.sorted())
        }.filter { row in
            needle.isEmpty || ([row.row.facts.title, row.row.facts.client ?? ""] + row.roles).contains { $0.localizedCaseInsensitiveContains(needle) }
        }
        upcoming = rows.filter { !$0.row.finished && $0.row.facts.bookingStatus != "cancelled" }.sorted { lhs, rhs in
            if lhs.row.facts.startDay.isEmpty != rhs.row.facts.startDay.isEmpty { return rhs.row.facts.startDay.isEmpty }
            return (lhs.row.facts.startDay, lhs.row.facts.title) < (rhs.row.facts.startDay, rhs.row.facts.title)
        }
        let earlier = rows.filter { $0.row.finished || $0.row.facts.bookingStatus == "cancelled" }
            .sorted { ($0.row.facts.startDay, $0.row.facts.title) > ($1.row.facts.startDay, $1.row.facts.title) }
        past = Dictionary(grouping: earlier) { String($0.row.facts.startDay.prefix(4)) }
            .map { Year(year: $0.key, rows: $0.value) }
            .sorted { $0.year > $1.year }
    }

    /// The selected chip's key; empty for All.
    var selectedKey: String { focus?.role.key ?? "" }
}

// MARK: - Reading the store

extension RoleFact {
    init(role: WorkRole) {
        self.init(objectID: role.objectID, key: role.id?.uuidString ?? role.objectID.uriRepresentation().absoluteString, name: role.name)
    }
}

extension RolesAgenda {
    init(roles: [WorkRole], jobs: [Job], selected: String, query: String, context: NSManagedObjectContext,
         today: String = Day.string(from: Date())) {
        let facts = roles.map(RoleFact.init(role:))
        let keys = Dictionary(zip(roles.map(\.objectID), facts.map(\.key)), uniquingKeysWith: { a, _ in a })
        let index = InvoiceIndex(in: context)
        let events = jobs.filter { $0.deletedAt == nil }.map { job in
            RoleEventFact(facts: EventsListFacts(job: job, today: today, context: context, index: index),
                          roleKeys: Set(job.heldRoles.compactMap { keys[$0.objectID] }))
        }
        self.init(roles: facts, events: events, selected: selected, query: query, today: today)
    }
}

extension Job {
    /// The booking's roles plus those a live session sets in their place.
    var heldRoles: Set<WorkRole> {
        activeSessions.filter(\.overridesRoles).reduce(roles ?? []) { $0.union($1.roles ?? []) }
    }
}

// MARK: - Changing roles

extension WorkRole {
    /// Moves every booking and session from one role to another, then removes the first.
    static func merge(_ sourceID: NSManagedObjectID, into targetID: NSManagedObjectID, in context: NSManagedObjectContext) throws {
        guard sourceID != targetID else { return }
        let writer = isolatedWriter(context)
        guard let source = try writer.existingObject(with: sourceID) as? WorkRole,
              let target = try writer.existingObject(with: targetID) as? WorkRole else { return }
        for job in source.jobs ?? [] { job.roles = (job.roles ?? []).subtracting([source]).union([target]) }
        for session in source.sessions ?? [] { session.roles = (session.roles ?? []).subtracting([source]).union([target]) }
        writer.delete(source)
        try writer.save()
        context.refreshAllObjects()
    }

    /// Removes the role; bookings and sessions keep everything else.
    static func remove(_ objectID: NSManagedObjectID, in context: NSManagedObjectContext) throws {
        let writer = isolatedWriter(context)
        writer.delete(try writer.existingObject(with: objectID))
        try writer.save()
        context.refreshAllObjects()
    }
}
