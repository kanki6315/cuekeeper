import Combine
import CoreData
import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class BackupWorkflow: ObservableObject {
    @Published var busy = false
    @Published var canCancel = false
    @Published var stage = ""
    @Published var fraction: Double?
    @Published var error: String?
    @Published var notice: String?
    @Published var archive: BackupArchive?
    @Published var export: BackupFile?
    @Published var reviewing = false
    private var task: Task<Void, Never>?
    private var token = UUID()
    private var control = BackupControl()

    func run(_ stage: String, cancellable: Bool = true, work: @escaping (BackupControl) async throws -> Void) {
        guard !busy else { return }
        busy = true; canCancel = cancellable; error = nil; notice = nil; fraction = nil; self.stage = stage
        let current = UUID(); token = current
        control = BackupControl { [weak self] text, value in
            Task { @MainActor in
                guard let self, self.token == current, self.busy else { return }
                self.stage = text; self.fraction = value
            }
        }
        let control = control
        task = Task {
            defer { if token == current { busy = false; canCancel = false; fraction = nil } }
            do { try await work(control) }
            catch is CancellationError { if token == current { notice = "Cancelled. Your daybook is unchanged." } }
            catch { if token == current { self.error = error.localizedDescription } }
        }
    }
    func cancel() { guard canCancel else { return }; control.cancel(); task?.cancel() }
    func invalidate() {
        control.cancel(); task?.cancel(); token = UUID(); busy = false; canCancel = false
        archive = nil; reviewing = false; export = nil
    }
    func prepare(context: NSManagedObjectContext, control: BackupControl) async throws -> BackupFile {
        let coordinator = context.persistentStoreCoordinator!
        return try await BackupWorker.perform(coordinator: coordinator, control: control) { reader in
            try BackupArchive.capture(in: reader, control: control).writePackage(control: control)
        }
    }
    func read(_ url: URL, context: NSManagedObjectContext, control: BackupControl) async throws {
        let coordinator = context.persistentStoreCoordinator!
        let result = try await BackupWorker.perform(coordinator: coordinator, control: control) { reader in
            try BackupArchive.readPackage(url, model: reader.persistentStoreCoordinator!.managedObjectModel, control: control)
        }
        try control.check(); archive = result; reviewing = true
    }
    func importFile(_ url: URL, context: NSManagedObjectContext) {
        run("Opening backup file…") { control in
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            let coordinator = context.persistentStoreCoordinator!
            let snapshot = try await BackupWorker.perform(coordinator: coordinator, control: control) { reader in
                var coordinationError: NSError?
                var result: Result<BackupArchive, Error>?
                NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { source in
                    result = Result { try BackupArchive.readPackage(source, model: reader.persistentStoreCoordinator!.managedObjectModel, control: control) }
                }
                if let coordinationError { throw coordinationError }
                guard let result else { throw RecordError.invalid("The file provider could not open this backup. Download it in Files and try again.") }
                return try result.get()
            }
            try control.check(); self.archive = snapshot; self.reviewing = true
        }
    }
    func restore(context: NSManagedObjectContext, syncActivity: @escaping () -> SyncActivity, completion: @escaping (BackupArchive.RestoreResult) -> Void = { _ in }) {
        guard !busy, let snapshot = archive else { return }
        if let reason = syncActivity().restoreUnavailableReason { error = reason; return }
        guard !context.hasChanges else { error = "Save your current changes before restoring a backup."; return }
        run("Checking backup…", cancellable: false) { control in
            // Read live state again: an import may have started since confirmation.
            if let reason = syncActivity().restoreUnavailableReason { throw RecordError.invalid(reason) }
            self.archive = nil
            let result = try await BackupWorker.perform(coordinator: context.persistentStoreCoordinator!, control: control) { writer in
                try snapshot.restore(in: writer, control: control)
            }
            try control.check()
            context.refreshAllObjects()
            self.notice = "Restore complete. Added \(result.added) records and recovered \(result.recovered) deleted records. Existing edits and payments were kept."
            completion(result)
        }
    }
    var reviewSummary: String {
        guard let archive else { return "" }
        return "\(archive.records.filter { $0.key.entity == "Job" }.count) events and \(archive.attachments.count) receipt images. This adds missing records and recovers deleted records without replacing newer edits or payments. Recovered events can return to Calendar. These changes sync to your other devices."
    }
}

struct BackupProgressView: View {
    @ObservedObject var workflow: BackupWorkflow
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fraction = workflow.fraction { ProgressView(workflow.stage, value: fraction) }
            else { ProgressView(workflow.stage) }
            if workflow.canCancel { Button("Cancel", role: .cancel) { workflow.cancel() }.frame(minHeight: 44) }
        }.accessibilityIdentifier("backup-progress")
    }
}

/// Export the already-built file without loading the entire ZIP into a FileDocument's Data.
struct BackupFileExporter: UIViewControllerRepresentable {
    let file: URL
    let completion: (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let completion: (Bool) -> Void
        init(completion: @escaping (Bool) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { completion(!urls.isEmpty) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { completion(false) }
    }
}
