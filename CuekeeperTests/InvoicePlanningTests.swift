import XCTest
@testable import Cuekeeper

final class InvoicePlanningTests: XCTestCase {
    private let today = "2026-10-16"
    private let northside = UUID()
    private let apex = UUID()

    private func event(_ title: String, start: String = "2026-10-10", status: String = "completed", client: UUID? = nil, name: String = "Northside",
                       amount: Int64? = 100_000, currency: String = "EUR", billing: EventBillingFact = .notInvoiced,
                       blocking: Int = 0, rebillable: [EventExpenseFact] = []) -> EventReadiness {
        let facts = ReadinessFacts(jobID: UUID(), title: title, startDay: start, endDay: start, bookingStatus: status,
                                   clientID: client ?? northside, clientName: name, clientDetailsMissing: [],
                                   fee: .value(FeeValue(amount: amount, currency: currency)), billing: billing, billedAmount: nil,
                                   blockingReceipts: (0..<blocking).map { _ in EventExpenseFact(id: UUID(), merchant: "Fuel", amount: 3840, currency: currency) },
                                   rebillable: rebillable)
        return EventReadiness(facts, today: today)
    }

    private func receipt(_ merchant: String, _ amount: Int64, currency: String = "EUR") -> EventExpenseFact {
        EventExpenseFact(id: UUID(), merchant: merchant, amount: amount, currency: currency)
    }

    // MARK: Candidates

    func testCandidatesSplitReadyFromHeldUpAndCountOtherInvoices() {
        let parking = receipt("Parking", 2580)
        let events = [
            event("Brands Hatch", start: "2026-10-03"),
            event("Silverstone", start: "2026-10-16", rebillable: [parking, receipt("Hotel", 9000, currency: "USD")]),
            event("Oulton Park", start: "2026-10-09", blocking: 1),
            event("Donington", start: "2026-10-24", status: "booked"),
            event("Cup final", billing: .sent(invoiceID: UUID(), reference: "NS-014", currency: "EUR", total: 100_000, balance: 100_000, dueDay: "", otherEvents: 0)),
            event("Spa", billing: .draft(invoiceID: UUID())),
            event("Monza", currency: "USD"),
            event("Indy", client: apex, name: "Apex"),
        ]
        let candidates = InvoiceCandidates(events: events, clientID: northside, currency: "EUR")
        XCTAssertEqual(candidates.ready.map(\.title), ["Silverstone", "Brands Hatch"])
        XCTAssertEqual(candidates.ready.first?.receipts, [parking])
        XCTAssertEqual(candidates.notReady.map(\.title), ["Donington", "Oulton Park"])
        XCTAssertEqual(candidates.notReady.map(\.note), ["Work still to happen", "1 receipt to finish"])
        XCTAssertEqual(candidates.alreadyInvoiced, 2)
    }

    func testEventsOnTheEditedInvoiceStaySelectableWithTheirBilledReceipts() {
        let draftID = UUID()
        let spa = event("Spa", billing: .draft(invoiceID: draftID))
        let billed = receipt("Paddock pass", 4500)
        let candidates = InvoiceCandidates(events: [spa], clientID: northside, currency: "EUR",
                                           onThisInvoice: [spa.id], billedReceipts: [spa.id: [billed]])
        XCTAssertEqual(candidates.ready.map(\.title), ["Spa"])
        XCTAssertEqual(candidates.ready.first?.receipts, [billed])
        XCTAssertEqual(candidates.alreadyInvoiced, 0)
    }

    func testUnknownFeeIsNotReadyButCanStillBeOffered() {
        let candidates = InvoiceCandidates(events: [event("Studio day", amount: nil)], clientID: northside, currency: "EUR")
        XCTAssertTrue(candidates.ready.isEmpty)
        XCTAssertEqual(candidates.notReady.first?.note, "Fee to agree")
        XCTAssertNil(candidates.notReady.first?.event.amount)
    }

    // MARK: Client options

    func testClientOptionsAreOnePerClientAndCurrencyLongestWaitingFirst() throws {
        let events = [
            event("Silverstone", start: "2026-10-16", rebillable: [receipt("Parking", 2580), receipt("Train", 6450)]),
            event("Brands Hatch", start: "2026-10-03", amount: 120_000),
            event("Indy", start: "2026-09-26", client: apex, name: "Apex", amount: 85_000, currency: "USD"),
            event("Imola", start: "2026-10-11", client: apex, name: "Apex", amount: 60_000),
            event("Oulton Park", blocking: 1),
        ]
        let options = InvoiceClientOption.ready(from: events)
        XCTAssertEqual(options.map(\.name), ["Apex", "Northside", "Apex"])
        XCTAssertEqual(options.map(\.currency), ["USD", "EUR", "EUR"])
        let northsideOption = try XCTUnwrap(options.first { $0.clientID == northside })
        XCTAssertEqual(northsideOption.total, 100_000 + 120_000 + 2580 + 6450)
        XCTAssertEqual(northsideOption.summary, "2 events · 2 receipts")
        XCTAssertEqual(northsideOption.oldestDay, "2026-10-03")
    }

    // MARK: References

    func testNextReferenceIncrementsTheLastNumberAndKeepsPadding() {
        XCTAssertEqual(InvoiceReference.next(after: "NS-2026-014"), "NS-2026-015")
        XCTAssertEqual(InvoiceReference.next(after: "INV-099"), "INV-100")
        XCTAssertEqual(InvoiceReference.next(after: "INV-0414"), "INV-0415")
        XCTAssertEqual(InvoiceReference.next(after: "42"), "43")
        XCTAssertEqual(InvoiceReference.next(after: "Q3-07 rev"), "Q3-08 rev")
        XCTAssertNil(InvoiceReference.next(after: "Draft"))
        XCTAssertNil(InvoiceReference.next(after: ""))
    }

    func testNextReferenceSkipsOnesAnotherInvoiceAlreadyUses() {
        XCTAssertEqual(InvoiceReference.next(after: "INV-0409", avoiding: ["INV-0410", "INV-0411"]), "INV-0412")
        XCTAssertEqual(InvoiceReference.next(after: "INV-0409", avoiding: []), "INV-0410")
        XCTAssertNil(InvoiceReference.next(after: "Draft", avoiding: []))
    }
}
