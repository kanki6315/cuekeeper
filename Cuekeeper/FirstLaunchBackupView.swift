import CloudKit
import CoreData
import SwiftUI
import UniformTypeIdentifiers

/// Recovery-only presentation of the existing merge restore; no creation or deletion here.
struct FirstLaunchBackupView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var persistence: PersistenceController
    @State private var entries: [CloudBackupStore.Entry] = []
    @State private var selected: CKRecord.ID?
    @State private var loaded = false
    @StateObject private var workflow = BackupWorkflow()
    @State private var importing = false
    private var busy: Bool { workflow.busy }
    @State private var restored = false
    @State private var resultMessage = ""
    private let cloud: any CloudBacking
    let onRestore: () -> Void

    init(cloud: any CloudBacking = CloudBackupStore(), onRestore: @escaping () -> Void) {
        self.cloud = cloud; self.onRestore = onRestore
    }

    var body: some View {
        LaunchPage {
            LaunchHeading("Choose a backup")
            if let reason = persistence.syncActivity.restoreUnavailableReason {
                Text(reason).font(.subheadline).foregroundStyle(Color("SecondaryText"))
            }
            if busy { BackupProgressView(workflow: workflow) }
            if workflow.canRetryRestore {
                HStack {
                    Button("Review restore again") { workflow.reviewAgain() }
                        .accessibilityIdentifier("setup-retry-restore")
                    Spacer()
                    Button("Discard", role: .destructive) { workflow.discardArchive() }
                }.frame(minHeight: 44)
            }
            if loaded && entries.isEmpty {
                ContentUnavailableView("No backups found", systemImage: "archivebox")
            }
            if !entries.isEmpty {
                DaybookSections {
                    Section {
                        ForEach(entries) { entry in
                            Button { selected = entry.id } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(entry.title).font(.headline)
                                        Text(entry.details).font(.subheadline).foregroundStyle(Color("SecondaryText"))
                                    }
                                    Spacer()
                                    Image(systemName: selected == entry.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected == entry.id ? Color.accentColor : Color("SecondaryText"))
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).disabled(!entry.canRestore).accessibilityAddTraits(selected == entry.id ? .isSelected : [])
                        }
                    }
                }
            }
            if !busy && (entries.isEmpty || entries.contains { !$0.canRestore } || workflow.error != nil) {
                Button("Refresh", action: refresh).frame(minHeight: 44)
            }
            Button("Import from Files") { importing = true }.frame(minHeight: 44).disabled(busy)
                .accessibilityIdentifier("setup-import-backup")
            Text("Choose a Cuekeeper ZIP backup. Exported files contain personal and financial records and are not encrypted.")
                .font(.footnote).foregroundStyle(Color("SecondaryText"))
            Spacer(minLength: 0)
        } actions: {
            Button("Review restore", action: review).buttonStyle(LaunchPrimaryButton())
                .disabled(selected == nil || busy).accessibilityIdentifier("setup-review-restore")
        }
        .task { if !loaded { refresh() } }
        .onDisappear { workflow.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            workflow.invalidate()
            entries = []; selected = nil; loaded = false
            workflow.error = "Your iCloud account changed. Refresh to load its backups."
        }
        .saveErrorAlert($workflow.error)
        .fileImporter(isPresented: $importing, allowedContentTypes: [.zip]) { result in
            switch result {
            case .success(let url): workflow.importFile(url, context: context)
            case .failure(let error): workflow.error = error.localizedDescription
            }
        }
        .confirmationDialog("Restore this backup?", isPresented: $workflow.reviewing, titleVisibility: .visible) {
            Button("Restore Backup") {
                workflow.restore(context: context, syncActivity: { persistence.syncActivity }) { result in
                    resultMessage = "Added \(result.added) records and recovered \(result.recovered) deleted records."
                    restored = true
                }
            }
            .disabled(persistence.syncActivity.restoreUnavailableReason != nil)
            Button("Cancel", role: .cancel) { workflow.discardArchive() }
        } message: { Text(persistence.syncActivity.restoreUnavailableReason ?? [persistence.syncActivity.restoreCaution, workflow.reviewSummary].compactMap { $0 }.joined(separator: "\n\n")) }

        .alert("Backup recovered", isPresented: $restored) {
            Button("Continue setup", action: onRestore)
        } message: { Text(resultMessage) }
    }

    private func refresh() {
        workflow.run("Loading backups…") { control in
            let values = try await cloud.list()
            try control.check()
            entries = values; loaded = true; selected = values.first(where: { $0.canRestore })?.id
        }
    }
    private func review() {
        guard let entry = entries.first(where: { $0.id == selected }) else { return }
        workflow.run("Downloading backup…") { control in
            let url = try await cloud.load(entry)
            defer { try? FileManager.default.removeItem(at: url) }
            try control.check()
            try await workflow.read(url, context: context, control: control)
        }
    }
}
