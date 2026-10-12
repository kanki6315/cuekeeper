import CoreData
import XCTest
@testable import Cuekeeper

@MainActor
final class PersistenceTests: XCTestCase {
    private var directory: URL!
    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    private func openStore() async throws -> PersistenceController {
        let store = PersistenceController(storeURL: directory.appending(path: "test.sqlite"), cloudEnabled: false)
        for _ in 0..<100 {
            if store.isLoaded { return store }
            if let error = store.loadError { throw NSError(domain: error, code: 1) }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "Store timed out", code: 2)
    }

    func testJobSurvivesStoreReopenWithoutCloud() async throws {
        let first = try await openStore()
        let start = try XCTUnwrap(Day.date(from: "2026-10-12"))
        let end = try XCTUnwrap(Day.date(from: "2026-10-14"))
        try JobDraft(name: "  Courtside Live  ", startDate: start, endDate: end).save(in: first.container.viewContext)
        let original = try XCTUnwrap(first.container.viewContext.fetch(NSFetchRequest<Job>(entityName: "Job")).first)
        let id = original.id
        first.container.viewContext.reset()
        for store in first.container.persistentStoreCoordinator.persistentStores {
            try first.container.persistentStoreCoordinator.remove(store)
        }
        let second = try await openStore()
        let jobs = try second.container.viewContext.fetch(NSFetchRequest<Job>(entityName: "Job"))
        XCTAssertEqual(jobs.count, 1)
        XCTAssertEqual(jobs[0].id, id)
        XCTAssertNotNil(id)
        XCTAssertEqual(jobs[0].name, "Courtside Live")
        XCTAssertEqual(jobs[0].startDay, "2026-10-12")
        XCTAssertEqual(jobs[0].endDay, "2026-10-14")
        XCTAssertEqual(jobs[0].bookingStatus, "tentative")
    }

    func testInvalidDraftsDoNotInsertRecords() async throws {
        let store = try await openStore()
        let start = try XCTUnwrap(Day.date(from: "2026-10-14"))
        let end = try XCTUnwrap(Day.date(from: "2026-10-12"))
        XCTAssertThrowsError(try JobDraft(name: " \n ").save(in: store.container.viewContext))
        XCTAssertThrowsError(try JobDraft(name: "Bad dates", startDate: start, endDate: end).save(in: store.container.viewContext))
        XCTAssertEqual(try store.container.viewContext.count(for: NSFetchRequest<Job>(entityName: "Job")), 0)
        XCTAssertFalse(store.container.viewContext.hasChanges)
    }

    func testCivilDatesRetainTheirDayAcrossTimeZonesAndDST() throws {
        for zone in ["America/New_York", "Europe/London", "Pacific/Auckland"] {
            let timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            for day in ["2026-03-08", "2026-11-01", "2026-12-31"] {
                let localDate = try XCTUnwrap(Day.date(from: day, timeZone: timeZone))
                XCTAssertEqual(Day.string(from: localDate, timeZone: timeZone), day)
            }
        }
    }
}
