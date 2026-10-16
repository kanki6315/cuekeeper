import CloudKit
import CoreData
import SwiftUI
import UniformTypeIdentifiers

/// Status first: the last backup and Back Up Now lead; saved iCloud copies fill the
/// remaining space. Fine print lives behind the About backups button.
struct BackupView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.dynamicTypeSize) private var typeSize
    @EnvironmentObject private var persistence: PersistenceController
    @StateObject private var workflow = BackupWorkflow()
    @State private var entries: [CloudBackupStore.Entry] = []
    @State private var loaded = false
    @State private var deleting: CloudBackupStore.Entry?
    @State private var confirmDelete = false
    @State private var importing = false
    @State private var exporting = false
    @State private var showInfo = false
    private let cloud: any CloudBacking
    private let preview: Bool
    init(cloud: any CloudBacking = CloudBackupStore(), preview: Bool = false) { self.cloud = cloud; self.preview = preview }

    private var twoPane: Bool { sizeClass == .regular && !typeSize.isAccessibilitySize }
    private var cloudAvailable: Bool { persistence.cloudEnabled || preview }
    private var latest: CloudBackupStore.Entry? { entries.filter { $0.date != nil }.max { $0.date! < $1.date! } }

    var body: some View {
        ScrollView {
            Group {
                if twoPane {
                    HStack(alignment: .top, spacing: 24) {
                        DaybookSections { statusSection; filesSection }
                            .frame(minWidth: 280, idealWidth: 340, maxWidth: 360)
                        Group {
                            if loaded && entries.isEmpty { emptyList }
                            else { DaybookSections { savedSection } }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .frame(maxWidth: 1080)
                } else {
                    DaybookSections { statusSection; savedSection }
                        .frame(maxWidth: 760)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .refreshable { await reload() }
        .accessibilityIdentifier("daybook-form")
        .daybookSurface()
        .navigationTitle("Backups").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !twoPane {
                ToolbarItem(placement: .topBarTrailing) { filesMenu }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("About backups", systemImage: "info.circle") { showInfo = true }
                    .accessibilityIdentifier("backup-info")
                    .popover(isPresented: $showInfo) {
                        BackupInfoView()
                            .frame(minWidth: 320, idealWidth: 380, idealHeight: 500)
                            .presentationDetents([.medium, .large])
                            .presentationCompactAdaptation(.sheet)
                    }
            }
        }
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
            refresh()
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

    // MARK: Sections

    @ViewBuilder private var statusSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 0) {
                VStack(alignment: .leading, spacing: 4) {
                    if !cloudAvailable {
                        Text("iCloud backups are off").font(.title3.weight(.semibold))
                        Text("Export a copy to Files instead.").font(.subheadline).foregroundStyle(Color("SecondaryText"))
                    } else if !loaded {
                        Text("Checking iCloud…").font(.title3.weight(.semibold)).foregroundStyle(Color("SecondaryText"))
                    } else if let latest, let date = latest.date {
                        Text("Last backup").font(.subheadline).foregroundStyle(Color("SecondaryText"))
                        Text(Self.relative.string(from: date)).font(.title3.weight(.semibold))
                        Text(latest.details).font(.subheadline).foregroundStyle(Color("SecondaryText"))
                    } else {
                        Text("No backups yet").font(.title3.weight(.semibold))
                        Text("Keep a copy of your daybook in iCloud.").font(.subheadline).foregroundStyle(Color("SecondaryText"))
                    }
                    if persistence.syncActivity.message != nil {
                        Label("Changes from other devices may still be arriving.", systemImage: "arrow.triangle.2.circlepath")
                            .font(.subheadline).foregroundStyle(Color("AmberText")).padding(.top, 4)
                    }
                    if let reason = persistence.syncActivity.restoreUnavailableReason {
                        Text(reason).font(.subheadline).foregroundStyle(Color("SecondaryText")).padding(.top, 4)
                    }
                }
                .accessibilityElement(children: .combine)
                .padding(.bottom, 12)
                Button { backUp() } label: {
                    Label("Back Up Now", systemImage: "icloud.and.arrow.up").frame(maxWidth: .infinity)
                }
                    .buttonStyle(DaybookPrimaryButton())
                    .disabled(workflow.busy || !cloudAvailable)
                    .accessibilityIdentifier("backup-now")
                if workflow.busy { BackupProgressView(workflow: workflow).padding(.top, 12) }
                if let notice = workflow.notice {
                    Text(notice).font(.subheadline).padding(.top, 12).accessibilityIdentifier("backup-notice")
                }
            }
        }
    }

    @ViewBuilder private var filesSection: some View {
        Section {
            Button("Export to Files", systemImage: "square.and.arrow.up") { export() }
                .frame(minHeight: 44).disabled(workflow.busy).accessibilityIdentifier("backup-export")
            Button("Import a Backup", systemImage: "square.and.arrow.down") { startImport() }
                .frame(minHeight: 44).disabled(workflow.busy).accessibilityIdentifier("backup-import")
        } header: { Text("Files") } footer: { Text("ZIP files aren’t encrypted.") }
    }

    private var filesMenu: some View {
        Menu {
            Section {
                Button("Export to Files", systemImage: "square.and.arrow.up") { export() }
                    .accessibilityIdentifier("backup-export")
                Button("Import a Backup", systemImage: "square.and.arrow.down") { startImport() }
                    .accessibilityIdentifier("backup-import")
            } header: { Text("ZIP files aren’t encrypted.") }
        } label: { Label("Files", systemImage: "folder") }
            .disabled(workflow.busy)
            .accessibilityIdentifier("backup-files")
    }

    @ViewBuilder private var savedSection: some View {
        if cloudAvailable && !entries.isEmpty {
            Section {
                ForEach(entries) { entry in row(entry) }
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text("In iCloud")
                    Spacer()
                    Text("\(entries.count) of \(CloudBackupStore.maximumBackups)")
                        .font(.subheadline).monospacedDigit().foregroundStyle(Color("SecondaryText"))
                        .accessibilityLabel("\(entries.count) of \(CloudBackupStore.maximumBackups) backups")
                }
            }
        }
    }

    /// Keeps the list column occupied on wide layouts; the status panel already names the empty state.
    private var emptyList: some View {
        VStack(spacing: 8) {
            Image(systemName: "icloud").font(.title2).foregroundStyle(Color("SecondaryText"))
            Text("Your iCloud backups will appear here.").font(.subheadline).foregroundStyle(Color("SecondaryText"))
        }
        .frame(maxWidth: .infinity, minHeight: 180)
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.16), style: StrokeStyle(lineWidth: 1, dash: [4, 4])) }
    }

    private func row(_ entry: CloudBackupStore.Entry) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) { summary(entry); Spacer(minLength: 0); actions(entry) }
            VStack(alignment: .leading, spacing: 8) { summary(entry); HStack(spacing: 12) { actions(entry) } }
        }
        .contextMenu {
            Button("Restore", systemImage: "arrow.uturn.backward") { restore(entry) }.disabled(workflow.busy || !entry.canRestore)
            Button("Delete Backup", systemImage: "trash", role: .destructive) { deleting = entry; confirmDelete = true }.disabled(workflow.busy)
        }
    }

    private func summary(_ entry: CloudBackupStore.Entry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(Self.rowTitle(entry)).font(.subheadline.weight(.semibold)).monospacedDigit()
            Text(entry.details).font(.footnote).foregroundStyle(entry.canRestore ? Color("SecondaryText") : Color("AmberText"))
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private func actions(_ entry: CloudBackupStore.Entry) -> some View {
        Button("Restore") { restore(entry) }
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(Color.accentColor)
            .buttonStyle(.glass).buttonBorderShape(.capsule)
            .frame(minHeight: 44)
            .disabled(workflow.busy || !entry.canRestore)
            .accessibilityLabel("Restore")
        Menu {
            Button("Delete Backup", systemImage: "trash", role: .destructive) { deleting = entry; confirmDelete = true }
        } label: {
            Image(systemName: "ellipsis").foregroundStyle(Color("SecondaryText"))
                .frame(minWidth: 44, minHeight: 44).contentShape(Rectangle())
        }
        .disabled(workflow.busy)
        .accessibilityLabel("More actions for \(entry.title)")
        .accessibilityIdentifier("backup-more")
    }

    // MARK: Actions

    private func backUp() {
        workflow.run("Preparing backup…") { control in
            let file = try await workflow.prepare(context: context, control: control)
            try control.check()
            workflow.stage = "Uploading to iCloud…"; workflow.fraction = nil; workflow.canCancel = false
            try await cloud.save(file: file.url, date: file.date, events: file.events)
            try control.check()
            // The status panel and list already show the new backup; confirm it for VoiceOver only.
            AccessibilityNotification.Announcement("Backup saved to iCloud.").post()
            let result = try await cloud.list(); try control.check(); entries = result; loaded = true
        }
    }
    private func startImport() {
        #if DEBUG
        if UITestBackupFiles.enabled {
            if let url = UITestBackupFiles.newest() { workflow.importFile(url, context: context) }
            else { workflow.error = "No exported backup is available to import." }
            return
        }
        #endif
        importing = true
    }
    private func export() {
        workflow.run("Preparing export…") { control in
            let file = try await workflow.prepare(context: context, control: control)
            try control.check()
            #if DEBUG
            if UITestBackupFiles.enabled {
                try UITestBackupFiles.save(file.url)
                workflow.notice = "Backup exported. Keep the file in a safe place."
                return
            }
            #endif
            workflow.export = file
            workflow.notice = "Ready to export: \(counted(file.events, "event", "events")) · \(counted(file.receipts, "receipt", "receipts")) · \(ByteCountFormatter.string(fromByteCount: file.bytes, countStyle: .file))."
            exporting = true
        }
    }
    private func restore(_ entry: CloudBackupStore.Entry) {
        workflow.run("Downloading backup…") { control in
            let url = try await cloud.load(entry)
            defer { try? FileManager.default.removeItem(at: url) }
            try control.check()
            try await workflow.read(url, context: context, control: control)
        }
    }
    private func refresh() {
        guard cloudAvailable else { return }
        workflow.run("Loading iCloud backups…") { control in
            let result = try await cloud.list(); try control.check(); entries = result; loaded = true
        }
    }
    private func reload() async {
        guard cloudAvailable, !workflow.busy else { return }
        do { entries = try await cloud.list(); loaded = true }
        catch { workflow.error = error.localizedDescription }
    }

    /// “Oct 8, 6:10 PM”; the year appears only for earlier years.
    private static func rowTitle(_ entry: CloudBackupStore.Entry) -> String {
        guard let date = entry.date else { return entry.title }
        let style = Date.FormatStyle.dateTime.month(.abbreviated).day().hour().minute()
        return Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
            ? date.formatted(style) : date.formatted(style.year())
    }

    /// “Yesterday at 9:42 PM”, “Oct 8, 2026 at 6:10 PM”.
    private static let relative: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium; formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}

/// The fine print, kept to what someone needs before relying on a backup.
struct BackupInfoView: View {
    @Environment(\.dismiss) private var dismiss
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth = 26
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    item("square.stack.3d.up", "What’s included", "Events, clients, fees, invoices, payments, expenses and receipt photos. Not calendar connections or device settings.")
                    Divider()
                    item("arrow.uturn.backward", "Restoring", "Adds missing records and brings back deleted ones. Never overwrites newer edits or payments.")
                    Divider()
                    item("doc.zipper", "Exported files", "ZIP files aren’t encrypted. Keep them somewhere you trust.")
                    Divider()
                    item("icloud", "iCloud", "Uses your iCloud storage. Keeps up to \(CloudBackupStore.maximumBackups) backups.")
                }
                .padding(.horizontal, 20)
            }
            .navigationTitle("About backups").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .daybookSurface()
        }
        .accessibilityIdentifier("backup-info-sheet")
    }
    private func item(_ symbol: String, _ title: String, _ text: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.subheadline.weight(.semibold))
                Text(text).font(.subheadline).foregroundStyle(Color("SecondaryText")).fixedSize(horizontal: false, vertical: true)
            }
        } icon: {
            Image(systemName: symbol).foregroundStyle(Color.accentColor).frame(width: iconWidth)
        }
        .padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

#if DEBUG
/// Parallel UI tests run on simulator clones, where taps on the out-of-process Files picker are dropped
/// under load. With `--ui-test-backup-files`, Export copies the archive into a test folder and Import
/// opens the newest copy through the same workflow calls the pickers use. The real pickers are exercised
/// serially by the `Cuekeeper - System Pickers` scheme.
enum UITestBackupFiles {
    static var enabled: Bool { ProcessInfo.processInfo.arguments.contains("--ui-test-backup-files") }
    private static var folder: URL { FileManager.default.temporaryDirectory.appendingPathComponent("ui-test-backups", isDirectory: true) }
    static func save(_ url: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: url, to: folder.appendingPathComponent("\(UUID().uuidString)-\(url.lastPathComponent)"))
    }
    static func newest() -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.max { modified($0) < modified($1) }
    }
    private static func modified(_ url: URL) -> Date {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
    }
}
#endif
