import AppKit
import CloudKit
import CoreData
import Foundation
import Security

// A separate signed executable and local store; no dependency on the iOS app lifecycle.
func initializeSchema() async throws {
    guard CommandLine.arguments.contains("--initialize-development-schema") else {
        throw NSError(domain: "CuekeeperSchemaHelper", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "Run this helper through ./cloudkit.sh init."])
    }
    guard let task = SecTaskCreateFromSelf(nil),
          SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-container-environment" as CFString, nil) as? String == "Development" else {
        throw NSError(domain: "CuekeeperSchemaHelper", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "Refusing schema initialization without a signed Development entitlement."])
    }
    FileHandle.standardOutput.write(Data("Checking this Mac’s iCloud account…\n".utf8))
    let identifier = "iCloud.com.arjunakankipati.cuekeeper"
    guard try await CKContainer(identifier: identifier).accountStatus() == .available else {
        throw NSError(domain: "CuekeeperSchemaHelper", code: 3, userInfo: [
            NSLocalizedDescriptionKey: "Sign in to iCloud in this Mac's System Settings, then retry."])
    }
    FileHandle.standardOutput.write(Data("Loading the shared Core Data model and setup store…\n".utf8))
    let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
        .appendingPathComponent("CuekeeperSchemaHelper", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let container = NSPersistentCloudKitContainer(name: "Cuekeeper")
    let description = NSPersistentStoreDescription(url: directory.appendingPathComponent("Schema.sqlite"))
    description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
    description.cloudKitContainerOptions = NSPersistentCloudKitContainerOptions(containerIdentifier: identifier)
    container.persistentStoreDescriptions = [description]
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
        container.loadPersistentStores { _, error in
            if let error { continuation.resume(throwing: error) }
            else { continuation.resume() }
        }
    }
    FileHandle.standardOutput.write(Data("Initializing Development schema…\n".utf8))
    try container.initializeCloudKitSchema(options: [])
}

let application = NSApplication.shared
application.setActivationPolicy(.prohibited)
Task.detached {
    do {
        try await initializeSchema()
        FileHandle.standardOutput.write(Data("CUEKEEPER_SCHEMA_INIT_OK\n".utf8))
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("Schema initialization failed: \(error)\n".utf8))
        exit(1)
    }
}
application.run()
