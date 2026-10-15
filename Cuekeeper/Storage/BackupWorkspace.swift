import Foundation

/// Owns protected temporary backup files and removes them when no longer needed.
final class BackupWorkspace {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("CuekeeperBackup-\(UUID())", isDirectory: true)
        // Apply protection before creating descendants so receipts, metadata and ZIPs
        // inherit access after the first unlock, including while the phone is locked.
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
                                                attributes: Self.protectionAttributes)
        do {
            try FileManager.default.createDirectory(at: url.appendingPathComponent("receipts"),
                                                    withIntermediateDirectories: false,
                                                    attributes: Self.protectionAttributes)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
    static var protectionAttributes: [FileAttributeKey: Any] {
        #if os(iOS)
        return [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        #else
        return [:]
        #endif
    }
    deinit { try? FileManager.default.removeItem(at: url) }
}

