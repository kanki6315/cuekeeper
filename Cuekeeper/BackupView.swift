import CloudKit
import CoreData
import SwiftUI
import UniformTypeIdentifiers

struct BackupView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var persistence: PersistenceController
    @StateObject private var workflow = BackupWorkflow()
    @State private var entries: [CloudBackupStore.Entry] = []
    @State private var loaded = false
    @State private var deleting: CloudBackupStore.Entry?
    @State private var confirmDelete = false
    @State private var importing = false
    @State private var exporting = false
    private let cloud: any CloudBacking
    private let preview: Bool
    init(cloud: any CloudBacking = CloudBackupStore(), preview: Bool = false) { self.cloud = cloud; self.preview = preview }

    var body: some View {
        DaybookForm(title: "Backups") {
            Section {
                Text("Save a separate copy of your daybook to iCloud or Files. Each ZIP backup keeps your records and receipt images together.")
                Text("Includes events, sessions, clients, fees, invoices, payments, expenses and receipt photos on this device. Calendar connections and device preferences are not included.")
                    .font(.subheadline).foregroundStyle(Color("SecondaryText"))
                if persistence.syncActivity.message != nil {
                    Text("iCloud may still have changes to deliver. A backup includes only records already on this device.").font(.subheadline).foregroundStyle(Color("AmberText"))
                }
                Button("Back Up Now", systemImage: "icloud.and.arrow.up") {
                    workflow.run("Preparing backup…") { control in
                        let file = try await workflow.prepare(context: context, control: control)
                        try control.check()
                        workflow.stage = "Uploading to iCloud…"; workflow.fraction = nil; workflow.canCancel = false
                        try await cloud.save(file: file.url, date: file.date, events: file.events)
                        try control.check()
                        workflow.notice = "Backup saved to iCloud."
                        let result = try await cloud.list(); try control.check(); entries = result; loaded = true
                    }
                }.buttonStyle(DaybookPrimaryButton()).disabled(workflow.busy || !(persistence.cloudEnabled || preview))
                    .accessibilityIdentifier("backup-now")
                if workflow.busy { BackupProgressView(workflow: workflow) }
                if let notice = workflow.notice { Text(notice).accessibilityIdentifier("backup-notice") }
            }
            Section {
                if let reason = persistence.syncActivity.restoreUnavailableReason {
                    Text(reason).font(.subheadline).foregroundStyle(Color("SecondaryText"))
                }
                Button("Export Backup", systemImage: "square.and.arrow.up") {
                    workflow.run("Preparing export…") { control in
                        let file = try await workflow.prepare(context: context, control: control)
                        try control.check(); workflow.export = file
                        workflow.notice = "Ready to export: \(counted(file.events, "event", "events")) · \(counted(file.receipts, "receipt", "receipts")) · \(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file))."
                        exporting = true
                    }
                }.frame(minHeight: 44).disabled(workflow.busy).accessibilityIdentifier("backup-export")
                Button("Import Backup", systemImage: "square.and.arrow.down") { importing = true }
                    .frame(minHeight: 44).disabled(workflow.busy).accessibilityIdentifier("backup-import")
            } header: { Text("Files") } footer: {
                Text("Exported ZIP files are not encrypted. They contain personal and financial records and receipt images; save them somewhere you trust. Imports are checked before you confirm a restore. Keep enough free device storage for the archive, unpacked images and restored records.")
            }
            Section {
                if loaded && entries.isEmpty { ContentUnavailableView("No backups yet", systemImage: "icloud", description: Text("Tap Back Up Now to save your first copy.")) }
                ForEach(entries) { entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(entry.title).font(.headline)
                        Text(entry.details).font(.subheadline).foregroundStyle(Color("SecondaryText"))
                        ViewThatFits(in: .horizontal) {
                            HStack { actions(entry) }
                            VStack(alignment: .leading) { actions(entry) }
                        }
                    }
                }
                Button("Refresh", systemImage: "arrow.clockwise") { refresh() }.frame(minHeight: 44).disabled(workflow.busy)
            } header: { Text("Saved iCloud backups") } footer: {
                Text("Backups use your iCloud storage. Each archive supports up to 512 MB, including up to 32 MB of record details. Keep up to 50 cloud copies; delete older copies deliberately. Restoring merges records and preserves newer edits and payments.")
            }
        }
        .navigationTitle("Backups").navigationBarTitleDisplayMode(.inline)
        .saveErrorAlert($workflow.error)
        .task { if !loaded { refresh() } }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url): workflow.importFile(url, context: context)
            case .failure(let error): workflow.error = error.localizedDescription
            }
        }
        .sheet(isPresented: $exporting, onDismiss: { workflow.export = nil }) {
            if let file = workflow.export {
                BackupFileExporter(file: file.url) { saved in
                    workflow.notice = saved ? "Backup exported. Keep the file in a safe place." : "Export cancelled. Your daybook is unchanged."
                    exporting = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            workflow.invalidate(); entries = []; loaded = false; deleting = nil; confirmDelete = false
            workflow.notice = "Your iCloud account changed. Refresh to load its backups."
        }
        .confirmationDialog("Restore this backup?", isPresented: $workflow.reviewing, titleVisibility: .visible) {
            Button("Restore Backup") { workflow.restore(context: context, syncActivity: { persistence.syncActivity }) }
            .disabled(persistence.syncActivity.restoreUnavailableReason != nil)
            Button("Cancel", role: .cancel) { workflow.archive = nil }
        } message: { Text(persistence.syncActivity.restoreUnavailableReason ?? workflow.reviewSummary) }
        .confirmationDialog("Delete this iCloud backup?", isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("Delete Backup", role: .destructive) {
                guard let entry = deleting else { return }; deleting = nil
                workflow.run("Deleting backup…", cancellable: false) { control in
                    try await cloud.delete(entry)
                    try control.check()
                    workflow.notice = "Backup deleted. Your daybook is unchanged."
                    let result = try await cloud.list(); try control.check(); entries = result
                }
            }
            Button("Cancel", role: .cancel) { deleting = nil }
        } message: { Text("This permanently removes this backup from iCloud on all your devices. Your current daybook and other backups are kept.") }
    }
    @ViewBuilder private func actions(_ entry: CloudBackupStore.Entry) -> some View {
        Button("Restore", systemImage: "arrow.uturn.backward") {
            workflow.run("Downloading backup…") { control in
                let url = try await cloud.load(entry)
                defer { try? FileManager.default.removeItem(at: url) }
                try control.check()
                try await workflow.read(url, context: context, control: control)
            }
        }.frame(minHeight: 44).disabled(workflow.busy || !entry.canRestore)
        Button("Delete Backup", role: .destructive) { deleting = entry; confirmDelete = true }.frame(minHeight: 44).disabled(workflow.busy)
    }
    private func refresh() {
        guard persistence.cloudEnabled || preview else { return }
        workflow.run("Loading iCloud backups…") { control in
            let result = try await cloud.list(); try control.check(); entries = result; loaded = true
        }
    }
}
