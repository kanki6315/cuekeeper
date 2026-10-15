import CloudKit
import CoreData
import SwiftUI

struct BackupView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var persistence: PersistenceController
    @State private var entries: [CloudBackupStore.Entry] = []
    @State private var busy = false
    @State private var loaded = false
    @State private var error: String?
    @State private var notice: String?
    @State private var restoring: CloudBackupStore.Entry?
    @State private var deleting: CloudBackupStore.Entry?
    @State private var confirmRestore = false
    @State private var confirmDelete = false
    @State private var archive: BackupArchive?
    @State private var operationTask: Task<Void, Never>?
    private let cloud: any CloudBacking
    private let preview: Bool
    init(cloud: any CloudBacking = CloudBackupStore(), preview: Bool = false) {
        self.cloud = cloud; self.preview = preview
    }

    var body: some View {
        DaybookForm(title: "iCloud Backups") {
            Section {
                Text("Save a separate copy of your daybook in your private iCloud storage. Backups stay unchanged when you edit or delete records.")
                Text("Includes events, sessions, links, clients, fees, invoices and payment history saved on this device. Calendar connections and device preferences are not included.")
                    .font(.subheadline).foregroundStyle(Color("SecondaryText"))
                if persistence.syncActivity.message != nil {
                    Text("iCloud sync may still have changes to deliver. A backup includes only records already on this device.").font(.subheadline).foregroundStyle(Color("AmberText"))
                }
                Button("Back Up Now", systemImage: "icloud.and.arrow.up") {
                    run {
                        let snapshot = try BackupArchive.capture(in: context)
                        try await cloud.save(data: snapshot.encoded(), date: snapshot.createdAt,
                                             events: snapshot.records.filter { $0.key.entity == "Job" }.count)
                        try Task.checkCancellation()
                        notice = "Backup saved to iCloud."
                        let updated = try await cloud.list(); try Task.checkCancellation()
                        entries = updated; loaded = true
                    }
                }.buttonStyle(DaybookPrimaryButton()).disabled(busy || !(persistence.cloudEnabled || preview))
                    .accessibilityIdentifier("backup-now")
                if busy { ProgressView("Working with iCloud…") }
                if let notice { Text(notice).accessibilityIdentifier("backup-notice") }
            }
            Section {
                if loaded && entries.isEmpty {
                    ContentUnavailableView("No backups yet", systemImage: "icloud", description: Text("Tap Back Up Now to save your first copy."))
                }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                        Text("\(entry.events) events · \(ByteCountFormatter.string(fromByteCount: entry.bytes, countStyle: .file))")
                            .font(.subheadline).foregroundStyle(Color("SecondaryText"))
                        ViewThatFits(in: .horizontal) {
                            HStack { actions(entry) }
                            VStack(alignment: .leading) { actions(entry) }
                        }
                    }
                }
                Button("Refresh", systemImage: "arrow.clockwise") { refresh() }.frame(minHeight: 44).disabled(busy)
            } header: { Text("Saved backups") } footer: {
                Text("Backups use your iCloud storage. Keep up to 50 copies; delete older copies when you no longer need them. Restoring adds missing records and recovers deleted records without replacing newer edits. Restored records sync to your other devices.")
            }
        }
        .navigationTitle("iCloud Backups").navigationBarTitleDisplayMode(.inline)
        .saveErrorAlert($error)
        .task { if !loaded { refresh() } }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            operationTask?.cancel()
            entries = []; loaded = false; confirmRestore = false; confirmDelete = false; archive = nil; restoring = nil; deleting = nil
            notice = "Your iCloud account changed. Refresh to load its backups."
        }
        .confirmationDialog("Restore this backup?", isPresented: $confirmRestore, titleVisibility: .visible) {
            Button("Restore Backup") {
                guard let snapshot = archive else { return }
                do {
                    let result = try snapshot.restore(in: context)
                    notice = "Restore complete. Added \(result.added) records and recovered \(result.recovered) deleted records. Existing edits and payments were kept."
                } catch { self.error = error.localizedDescription }
                restoring = nil; archive = nil
            }
            Button("Cancel", role: .cancel) { restoring = nil; archive = nil }
        } message: {
            Text("This adds missing records and restores records deleted since the backup. Existing edits and payments are kept. Recovered events can return to your connected calendar. These changes sync to your other devices.")
        }
        .confirmationDialog("Delete this iCloud backup?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Backup", role: .destructive) {
                guard let entry = deleting else { return }
                deleting = nil
                run {
                    try await cloud.delete(entry)
                    try Task.checkCancellation()
                    notice = "Backup deleted. Your daybook is unchanged."
                    let updated = try await cloud.list(); try Task.checkCancellation(); entries = updated
                }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("This permanently removes this backup from iCloud on all your devices. Your current daybook and other backups are kept.") }
    }

    @ViewBuilder private func actions(_ entry: CloudBackupStore.Entry) -> some View {
        Button("Restore", systemImage: "arrow.uturn.backward") {
            run {
                let data = try await cloud.load(entry)
                try Task.checkCancellation()
                archive = try BackupArchive.decode(data, model: context.persistentStoreCoordinator!.managedObjectModel)
                restoring = entry; confirmRestore = true
            }
        }.frame(minHeight: 44).disabled(busy)
        Button("Delete Backup", role: .destructive) { deleting = entry; confirmDelete = true }.frame(minHeight: 44).disabled(busy)
    }
    private func refresh() {
        guard persistence.cloudEnabled || preview else { return }
        run { let updated = try await cloud.list(); try Task.checkCancellation(); entries = updated; loaded = true }
    }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        operationTask = Task { @MainActor in
            defer { busy = false }
            do { try await operation() }
            catch is CancellationError { }
            catch { self.error = error.localizedDescription }
        }
    }
}
