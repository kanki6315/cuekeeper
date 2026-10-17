import Foundation

// MARK: - What an invoice could bill

/// One event the invoice could bill for the chosen client and currency, with the receipts it can carry.
struct InvoiceCandidate: Equatable, Identifiable {
    let event: EventReadiness
    /// Finished reimbursable receipts in the invoice currency, plus any already on the invoice being edited.
    let receipts: [EventExpenseFact]
    /// What still holds the event up, when it is not ready. Empty for ready events.
    let note: String
    var id: UUID { event.id }
    var title: String { event.facts.title }
    var dates: String {
        let start = event.facts.startDay, end = event.facts.endDay
        return start == end || end.isEmpty ? Day.display(start) : "\(Day.display(start)) – \(Day.display(end))"
    }
}

/// The client's work in one currency, split the way the guided editor lists it.
struct InvoiceCandidates: Equatable {
    /// Ready to bill, plus anything already on the invoice being edited.
    let ready: [InvoiceCandidate]
    /// Unbilled work that a gate still holds up. It can be included on purpose.
    let notReady: [InvoiceCandidate]
    /// Events already on another invoice, which this one cannot bill again.
    let alreadyInvoiced: Int
    /// Receipts in this currency whose event this invoice cannot bill: the event is already invoiced (a late
    /// receipt) or its fee is in another currency. They are billed alone, so the fee is never billed twice.
    let receiptsOnly: [InvoiceCandidate]

    /// - Parameters:
    ///   - onThisInvoice: events on the saved invoice being edited; they stay selectable whatever their state.
    ///   - billedReceipts: receipts already on that invoice, by event.
    init(events: [EventReadiness], clientID: UUID, currency: String, onThisInvoice: Set<UUID> = [], billedReceipts: [UUID: [EventExpenseFact]] = [:]) {
        var ready: [InvoiceCandidate] = [], notReady: [InvoiceCandidate] = [], separate: [InvoiceCandidate] = [], invoiced = 0
        for event in events where event.facts.clientID == clientID {
            let receipts = (billedReceipts[event.id] ?? []) + event.facts.rebillable.filter { $0.currency == currency }
            let billable = event.currency == currency && (onThisInvoice.contains(event.id) || [.ready, .heldUp, .upcoming].contains(event.state))
            if !billable, !receipts.isEmpty, !onThisInvoice.contains(event.id) {
                if case .review = event.state {} else { separate.append(InvoiceCandidate(event: event, receipts: receipts, note: Self.separateNote(event, currency: currency))) }
            }
            guard event.currency == currency else { continue }
            if onThisInvoice.contains(event.id) {
                ready.append(InvoiceCandidate(event: event, receipts: receipts, note: ""))
                continue
            }
            switch event.state {
            case .ready: ready.append(InvoiceCandidate(event: event, receipts: receipts, note: ""))
            case .heldUp, .upcoming: notReady.append(InvoiceCandidate(event: event, receipts: receipts, note: Self.note(event)))
            case .draft, .invoiced, .paid: invoiced += 1
            case .review, .directPaid, .noFee, .cancelled: break
            }
        }
        // Most recent work first: it is usually what the person came to bill.
        let order: (InvoiceCandidate, InvoiceCandidate) -> Bool = { ($0.event.facts.startDay, $0.title) > ($1.event.facts.startDay, $1.title) }
        self.ready = ready.sorted(by: order)
        self.notReady = notReady.sorted(by: order)
        receiptsOnly = separate.sorted(by: order)
        alreadyInvoiced = invoiced
    }

    var all: [InvoiceCandidate] { ready + notReady }

    static func separateNote(_ event: EventReadiness, currency: String) -> String {
        if let fee = event.currency, fee != currency { return "Fee billed in \(fee)" }
        switch event.state {
        case .invoiced(let reference, _, _, _), .paid(let reference): return reference.isEmpty ? "Fee already invoiced" : "Fee on \(reference)"
        case .draft: return "Fee on a draft invoice"
        default: return "Fee not billed here"
        }
    }

    static func note(_ event: EventReadiness) -> String {
        var parts = event.gaps.filter { $0.gate != .work || event.state != .upcoming }.map(\.text)
        if event.state == .upcoming { parts.insert("Work still to happen", at: 0) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Choosing a client

/// A client and currency with work ready to bill: one row in the client chooser.
struct InvoiceClientOption: Equatable, Identifiable {
    let clientID: UUID
    let name: String
    let currency: String
    let events: Int
    let receipts: Int
    /// Known amounts for the ready events and their receipts.
    let total: Int64
    /// Start day of the longest-waiting ready event.
    let oldestDay: String
    var id: String { "\(clientID.uuidString)-\(currency)" }

    var summary: String {
        var parts = [events == 1 ? "1 event" : "\(events) events"]
        if receipts > 0 { parts.append(receipts == 1 ? "1 receipt" : "\(receipts) receipts") }
        return parts.joined(separator: " · ")
    }

    /// One option per client and currency with ready work, longest waiting first.
    static func ready(from events: [EventReadiness]) -> [InvoiceClientOption] {
        let ready = events.filter { $0.state == .ready && $0.facts.clientID != nil && $0.currency != nil }
        let grouped = Dictionary(grouping: ready) { "\($0.facts.clientID!.uuidString)-\($0.currency!)" }
        return grouped.values.compactMap { group -> InvoiceClientOption? in
            guard let first = group.first, let clientID = first.facts.clientID, let currency = first.currency else { return nil }
            let receipts = group.flatMap { $0.facts.rebillable.filter { $0.currency == currency } }
            let total = group.compactMap(\.amount).reduce(0, +) + receipts.compactMap(\.amount).reduce(0, +)
            return InvoiceClientOption(clientID: clientID, name: first.facts.clientName ?? "Client", currency: currency,
                                       events: group.count, receipts: receipts.count, total: total,
                                       oldestDay: group.map(\.facts.startDay).min() ?? "")
        }.sorted { ($0.oldestDay, $0.name, $0.currency) < ($1.oldestDay, $1.name, $1.currency) }
    }
}

// MARK: - References

enum InvoiceReference {
    /// The reference after `previous`, incrementing its last run of digits and keeping its padding:
    /// NS-2026-014 → NS-2026-015, INV-099 → INV-100. Nil when there is no number to follow.
    static func next(after previous: String) -> String? {
        let characters = Array(previous.trimmingCharacters(in: .whitespacesAndNewlines))
        let digit: (Character) -> Bool = { $0.isASCII && $0.isNumber }
        guard let last = characters.lastIndex(where: digit) else { return nil }
        var first = last
        while first > 0 && digit(characters[first - 1]) { first -= 1 }
        let digits = String(characters[first...last])
        guard let number = Int(digits), number < Int.max else { return nil }
        let next = String(number + 1)
        let padded = String(repeating: "0", count: max(0, digits.count - next.count)) + next
        return String(characters[..<first]) + padded + String(characters[(last + 1)...])
    }

    /// The first reference after `previous` that no other invoice uses yet.
    static func next(after previous: String, avoiding used: Set<String>) -> String? {
        var candidate = next(after: previous)
        for _ in 0..<100 {
            guard let current = candidate else { return nil }
            if !used.contains(current) { return current }
            candidate = next(after: current)
        }
        return nil
    }
}
