import CoreData
import XCTest
@testable import Cuekeeper

final class RolesAgendaTests: XCTestCase {
    private let today = "2026-10-17"
    private let commentator = RoleFact(objectID: nil, key: "c", name: "Commentator")
    private let pit = RoleFact(objectID: nil, key: "p", name: "Pit reporter")
    private let floor = RoleFact(objectID: nil, key: "f", name: "Floor manager")

    private func event(_ title: String, start: String, client: String? = "Northline TV", status: String = "booked",
                       roles: Set<String>) -> RoleEventFact {
        RoleEventFact(facts: EventsListFacts(objectID: nil, key: title, title: title, client: client, series: [], bookingStatus: status,
                                             startDay: start, endDay: start, sessions: [], payment: nil),
                      roleKeys: roles)
    }

    private var events: [RoleEventFact] {
        [
            event("Brands Hatch", start: "2026-10-24", roles: ["c"]),
            event("Portimão", start: "2026-11-07", client: "Gridcast", status: "tentative", roles: ["c", "p"]),
            event("Donington", start: "2026-10-03", status: "completed", roles: ["c", "p"]),
            event("Snetterton", start: "2026-03-12", client: "Apex Media", status: "completed", roles: ["c"]),
            event("Oulton", start: "2025-06-01", client: "Apex Media", status: "completed", roles: ["c"]),
            event("Dropped", start: "2026-12-01", status: "cancelled", roles: ["c"]),
            event("No role", start: "2026-10-30", roles: []),
            event("Gone role", start: "2026-10-31", roles: ["deleted"]),
        ]
    }

    func testChipsLeadWithAllThenMostUsedRolesExcludingCancelledAndUntagged() {
        let agenda = RolesAgenda(roles: [floor, pit, commentator], events: events, selected: "", today: today)
        XCTAssertEqual(agenda.chips.map { $0.role?.name ?? "All" }, ["All", "Commentator", "Pit reporter", "Floor manager"])
        XCTAssertEqual(agenda.chips.map(\.count), [5, 5, 2, 0])
        XCTAssertEqual(agenda.untagged, 2, "Events whose only role was removed count as untagged")
    }

    func testAllListsTaggedEventsWithEveryRoleName() {
        let agenda = RolesAgenda(roles: [commentator, pit], events: events, selected: "", today: today)
        XCTAssertNil(agenda.focus)
        XCTAssertEqual(agenda.upcoming.map(\.row.facts.title), ["Brands Hatch", "Portimão"])
        XCTAssertEqual(agenda.upcoming[1].roles, ["Commentator", "Pit reporter"])
        XCTAssertEqual(agenda.past.map(\.year), ["2026", "2025"])
        XCTAssertEqual(agenda.past[0].rows.map(\.row.facts.title), ["Dropped", "Donington", "Snetterton"])
    }

    func testSelectingARoleNarrowsTheAgendaAndShowsOtherRolesOnly() {
        let agenda = RolesAgenda(roles: [commentator, pit], events: events, selected: "p", today: today)
        XCTAssertEqual(agenda.selectedKey, "p")
        XCTAssertEqual(agenda.upcoming.map(\.row.facts.title), ["Portimão"])
        XCTAssertEqual(agenda.upcoming[0].roles, ["Commentator"])
        XCTAssertEqual(agenda.past.flatMap(\.rows).map(\.row.facts.title), ["Donington"])
    }

    func testFocusSummarisesTheYearByMonthAndTopClients() throws {
        let agenda = RolesAgenda(roles: [commentator, pit], events: events, selected: "c", today: today)
        let focus = try XCTUnwrap(agenda.focus)
        XCTAssertEqual(focus.eventCount, 5, "Cancelled work is not counted")
        XCTAssertEqual(focus.sinceDay, "2025-06-01")
        XCTAssertEqual(focus.year, "2026")
        XCTAssertEqual(focus.months, [0, 0, 1, 0, 0, 0, 0, 0, 0, 2, 1, 0])
        XCTAssertEqual(focus.yearCount, 4)
        XCTAssertEqual(focus.clients, [.init(name: "Apex Media", count: 2), .init(name: "Northline TV", count: 2), .init(name: "Gridcast", count: 1)])
        XCTAssertEqual(RolesView.focusSubtitle(focus).hasSuffix("5 events · 4 in 2026"), true)
    }

    func testUnknownSelectionFallsBackToAllAndUnusedRoleIsEmpty() {
        XCTAssertNil(RolesAgenda(roles: [commentator], events: events, selected: "missing", today: today).focus)
        let unused = RolesAgenda(roles: [commentator, floor], events: events, selected: "f", today: today)
        XCTAssertEqual(unused.focus?.eventCount, 0)
        XCTAssertTrue(unused.isEmpty)
        XCTAssertEqual(RolesView.focusSubtitle(unused.focus!), "Not used on any event yet")
    }

    func testSearchMatchesTitleClientOrRole() {
        let byClient = RolesAgenda(roles: [commentator, pit], events: events, selected: "", query: "gridcast", today: today)
        XCTAssertEqual(byClient.upcoming.map(\.row.facts.title), ["Portimão"])
        let byRole = RolesAgenda(roles: [commentator, pit], events: events, selected: "", query: "pit", today: today)
        XCTAssertEqual((byRole.upcoming + byRole.past.flatMap(\.rows)).map(\.row.facts.title), ["Portimão", "Donington"])
    }
}

@MainActor
final class RoleChangesTests: XCTestCase {
    func testHeldRolesIncludeSessionOverridesAndMergeMovesEveryLink() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let store = PersistenceController(storeURL: folder.appendingPathComponent("test.sqlite"), cloudEnabled: false)
        try await store.waitUntilLoaded()
        defer {
            store.container.viewContext.reset()
            for persistent in store.container.persistentStoreCoordinator.persistentStores { try? store.container.persistentStoreCoordinator.remove(persistent) }
            try? FileManager.default.removeItem(at: folder)
        }
        let context = store.container.viewContext
        func insert<T: NSManagedObject>(_ entity: String) -> T {
            T(entity: NSEntityDescription.entity(forEntityName: entity, in: context)!, insertInto: context)
        }
        func role(_ name: String) -> WorkRole {
            let role: WorkRole = insert("WorkRole"); role.id = UUID(); role.name = name; return role
        }
        let commentator = role("Commentator"), pitLane = role("Pit lane reporter"), pit = role("Pit reporter")
        let job: Job = insert("Job")
        job.id = UUID(); job.startDay = "2026-10-24"; job.endDay = "2026-10-24"; job.bookingStatus = "booked"
        job.roles = [commentator]
        let session: WorkSession = insert("WorkSession")
        session.id = UUID(); session.job = job; session.overridesRoles = true; session.roles = [pitLane]
        try context.save()
        XCTAssertEqual(Set(job.heldRoles.map(\.name)), ["Commentator", "Pit lane reporter"])

        try WorkRole.merge(pitLane.objectID, into: pit.objectID, in: context)
        XCTAssertEqual(Set(job.heldRoles.map(\.name)), ["Commentator", "Pit reporter"])
        let remaining = try context.fetch(NSFetchRequest<WorkRole>(entityName: "WorkRole")).map(\.name).sorted()
        XCTAssertEqual(remaining, ["Commentator", "Pit reporter"])

        try WorkRole.remove(commentator.objectID, in: context)
        XCTAssertEqual(job.heldRoles.map(\.name), ["Pit reporter"])
        XCTAssertEqual(job.roles?.count, 0)
    }
}
