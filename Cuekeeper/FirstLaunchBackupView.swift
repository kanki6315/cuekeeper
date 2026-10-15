import CloudKit
import CoreData
import SwiftUI

/// Recovery-only presentation of the existing merge restore; no creation or deletion here.
struct FirstLaunchBackupView: View {
    @Environment(\.managedObjectContext) private var context
    @State private var entries: [CloudBackupStore.Entry] = []
    @State private var selected: CKRecord.ID?
    @State private var loaded = false
    @State private var busy = false
    @State private var error: String?
    @State private var archive: BackupArchive?
    @State private var reviewing = false
    @State private var restored = false
    @State private var resultMessage = ""
    @State private var generation = UUID()
    @State private var operation: Task<Void, Never>?
    private let cloud: any CloudBacking
    let onRestore: () -> Void

    init(cloud: any CloudBacking = CloudBackupStore(), onRestore: @escaping () -> Void) {
        self.cloud = cloud; self.onRestore = onRestore
    }

    var body: some View {
        LaunchPage {
            LaunchHeading("Choose a backup")
            if busy { ProgressView(loaded ? "Loading backup…" : "Loading backups…") }
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
                                        Text(entry.date.formatted(date: .abbreviated, time: .shortened)).font(.headline)
                                        Text(entry.events == 1 ? "1 event" : "\(entry.events) events").font(.subheadline).foregroundStyle(Color("SecondaryText"))
                                    }
                                    Spacer()
                                    Image(systemName: selected == entry.id ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(selected == entry.id ? Color.accentColor : Color("SecondaryText"))
                                }.frame(minHeight: 44).contentShape(Rectangle())
                            }.buttonStyle(.plain).accessibilityAddTraits(selected == entry.id ? .isSelected : [])
                        }
                    }
                }
            }
            if !busy && (entries.isEmpty || error != nil) {
                Button("Refresh", action: refresh).frame(minHeight: 44)
            }
            Spacer(minLength: 0)
        } actions: {
            Button("Review restore", action: review).buttonStyle(LaunchPrimaryButton())
                .disabled(selected == nil || busy).accessibilityIdentifier("setup-review-restore")
        }
        .task { if !loaded { refresh() } }
        .onDisappear { operation?.cancel() }
        .onReceive(NotificationCenter.default.publisher(for: .CKAccountChanged)) { _ in
            operation?.cancel(); generation = UUID(); busy = false
            entries = []; selected = nil; archive = nil; reviewing = false; loaded = false
            error = "Your iCloud account changed. Refresh to load its backups."
        }
        .saveErrorAlert($error)
        .confirmationDialog("Restore this backup?", isPresented: $reviewing, titleVisibility: .visible) {
            Button("Restore Backup") {
                guard let archive else { return }
                do {
                    let result = try archive.restore(in: context)
                    resultMessage = "Added \(result.added) records and recovered \(result.recovered) deleted records."
                    restored = true
                } catch { self.error = error.localizedDescription }
                self.archive = nil
            }
            Button("Cancel", role: .cancel) { archive = nil }
        } message: {
            Text("This adds missing records and restores records deleted since the backup. Existing edits and payments are kept. Recovered events can return to your connected calendar. These changes sync to your other devices.")
        }
        .alert("Backup recovered", isPresented: $restored) {
            Button("Continue setup", action: onRestore)
        } message: { Text(resultMessage) }
    }

    private func refresh() {
        run {
            let values = try await cloud.list()
            try Task.checkCancellation()
            entries = values; loaded = true; selected = values.first?.id
        }
    }
    private func review() {
        guard let entry = entries.first(where: { $0.id == selected }) else { return }
        run {
            let data = try await cloud.load(entry)
            try Task.checkCancellation()
            archive = try BackupArchive.decode(data, model: context.persistentStoreCoordinator!.managedObjectModel)
            reviewing = true
        }
    }
    private func run(_ work: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy = true; error = nil
        let current = generation
        operation = Task { @MainActor in
            defer { if generation == current { busy = false } }
            do { try await work() }
            catch is CancellationError { }
            catch { if generation == current { self.error = error.localizedDescription } }
        }
    }
}
