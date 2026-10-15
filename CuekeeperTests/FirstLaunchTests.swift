import CoreData
import XCTest
@testable import Cuekeeper

@MainActor
final class FirstLaunchTests: XCTestCase {
    func testPreferencesOnlySeedNewDraftsAndPreserveEventTimezone() throws {
        let keys = ["defaultRole", "homeTimeZone", "defaultCurrency"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
        }
        UserDefaults.standard.set("Presenter", forKey: "defaultRole")
        UserDefaults.standard.set("America/New_York", forKey: "homeTimeZone")
        UserDefaults.standard.set("EUR", forKey: "defaultCurrency")
        var draft = EventCreationDraft()
        XCTAssertEqual(draft.shared.roleNames, ["Presenter"])
        XCTAssertEqual(draft.shared.fee?.currency, "EUR")
        XCTAssertEqual(draft.shared.timeZoneID, "America/New_York")
        XCTAssertEqual(draft.events[0].timeZoneID, "")
        draft.events[0].timeZoneID = "Europe/London"
        draft.shared.workArrangement = .remote
        XCTAssertEqual(draft.resolvedEvents()[0].details.timeZoneID, "America/New_York")
        draft.shared.workArrangement = .onSite
        XCTAssertEqual(draft.resolvedEvents()[0].details.timeZoneID, "Europe/London")
        UserDefaults.standard.set("Producer", forKey: "defaultRole")
        UserDefaults.standard.set("Asia/Tokyo", forKey: "homeTimeZone")
        XCTAssertEqual(draft.shared.roleNames, ["Presenter"])
        XCTAssertEqual(draft.shared.timeZoneID, "America/New_York")
    }

    func testSyncStatusDoesNotPromiseExistingDataOrCompletion() {
        var activity = SyncActivity()
        XCTAssertEqual(activity.launchMessage(hasRecords: false), "Checking iCloud for existing work")
        let id = UUID()
        activity.record(id: id, kind: .receiving, ended: false, succeeded: false, error: nil)
        XCTAssertEqual(activity.launchMessage(hasRecords: true), "Syncing your data")
        activity.record(id: id, kind: .receiving, ended: true, succeeded: true, error: nil)
        XCTAssertEqual(activity.launchMessage(hasRecords: false), "Checking iCloud for existing work")
        XCTAssertEqual(activity.launchMessage(hasRecords: true), "Your daybook is ready to open")
        activity.offline = true
        XCTAssertEqual(activity.launchMessage(hasRecords: true), "Offline — you can continue on this device")
        activity.accountIssue = "Sign in to iCloud in device Settings"
        XCTAssertEqual(activity.launchMessage(hasRecords: true), activity.accountIssue)
    }

    func testRestoreWaitsForAllImportsAndSuccessfulRetry() {
        var activity = SyncActivity()
        XCTAssertTrue(activity.awaitingInitialImport)
        XCTAssertNotNil(activity.restoreUnavailableReason)
        let first = UUID(), second = UUID()
        activity.record(id: first, kind: .receiving, ended: false, succeeded: false, error: nil)
        activity.record(id: second, kind: .receiving, ended: false, succeeded: false, error: nil)
        activity.record(id: first, kind: .receiving, ended: true, succeeded: true, error: nil)
        XCTAssertFalse(activity.awaitingInitialImport)
        XCTAssertNotNil(activity.restoreUnavailableReason)
        activity.record(id: second, kind: .receiving, ended: true, succeeded: false, error: "Retry needed")
        XCTAssertNotNil(activity.restoreUnavailableReason)
        activity.record(id: second, kind: .receiving, ended: true, succeeded: true, error: nil)
        XCTAssertNil(activity.restoreUnavailableReason)
    }

    func testUpgradeDetectionHappensBeforeStoreCreation() async throws {
        let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appending(path: "test.sqlite")
        let first = PersistenceController(storeURL: url, cloudEnabled: false)
        XCTAssertFalse(first.hadExistingStore)
        try await first.waitUntilLoaded()
        for store in first.container.persistentStoreCoordinator.persistentStores {
            try first.container.persistentStoreCoordinator.remove(store)
        }
        let reopened = PersistenceController(storeURL: url, cloudEnabled: false)
        XCTAssertTrue(reopened.hadExistingStore)
        try await reopened.waitUntilLoaded()
        for store in reopened.container.persistentStoreCoordinator.persistentStores {
            try reopened.container.persistentStoreCoordinator.remove(store)
        }
        try FileManager.default.removeItem(at: directory)
    }
}
