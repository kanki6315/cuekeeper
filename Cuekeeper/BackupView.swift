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
        // After the form identifier, which would otherwise replace the toast's own.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BackupNoticeToast(notice: $workflow.notice).padding(.horizontal, 20).padding(.bottom, 12)
        }
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
            Button("Cancel", role: .cancel) { workflow.discardArchive() }
        } message: { Text(persistence.syncActivity.restoreUnavailableReason ?? [persistence.syncActivity.restoreCaution, workflow.reviewSummary].compactMap { $0 }.joined(separator: "\n\n")) }
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
                    if let reason = persistence.syncActivity.restoreUnavailableReason {
                        Text(reason).font(.subheadline).foregroundStyle(Color("SecondaryText")).padding(.top, 4)
                    }
                    if let issue = persistence.identityIssue {
                        NavigationLink { IdentityReviewView() } label: {
                            Label { Text(issue + " Review") } icon: { Image(systemName: "exclamationmark.triangle") }
                                .font(.subheadline).foregroundStyle(Color("AmberText")).padding(.top, 4)
                        }
                        .accessibilityIdentifier("identity-review")
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
                if workflow.busy { BackupProgressView(workflow: workflow).padding(.top, 8) }
                if workflow.canRetryRestore {
                    HStack {
                        Button("Review Restore Again") { workflow.reviewAgain() }
                            .accessibilityIdentifier("backup-retry-restore")
                        Spacer()
                        Button("Discard", role: .destructive) { workflow.discardArchive() }
                    }.frame(minHeight: 44).padding(.top, 12)
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
            workflow.notice = "Backup saved to iCloud."
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

// MARK: Record review

/// Records that arrived as differing copies of one UUID. Events and other
/// editable records are combined field by field; financial history keeps one
/// whole copy. Nothing changes until the person saves a choice.
struct IdentityReviewView: View {
    @Environment(\.managedObjectContext) private var context
    @EnvironmentObject private var persistence: PersistenceController
    @State private var conflicts: [IdentityReconciliation.Conflict] = []
    @State private var error: String?

    var body: some View {
        DaybookForm(title: "Review records", subtitle: "These records were saved twice with different details, usually after a backup was restored before iCloud finished. Choose what to keep.") {
            Section {
                if conflicts.isEmpty {
                    Text("Nothing to review. Copies that match are combined automatically.")
                        .foregroundStyle(Color("SecondaryText"))
                }
                ForEach(conflicts) { conflict in
                    DaybookLink {
                        IdentityConflictView(conflict: conflict, onResolved: reload)
                    } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(ConflictText.title(conflict.copies.first.flatMap { try? context.existingObject(with: $0) })).font(.headline)
                            Text(ConflictText.summary(conflict, in: context)).font(.subheadline).foregroundStyle(Color("SecondaryText"))
                        }
                    }
                    .accessibilityIdentifier("identity-conflict")
                }
            }
        }
        .navigationTitle("Review").navigationBarTitleDisplayMode(.inline)
        .saveErrorAlert($error)
        .onAppear(perform: reload)
    }

    private func reload() {
        do { conflicts = try IdentityReconciliation.conflicts(in: context) }
        catch { self.error = error.localizedDescription }
        persistence.refreshIdentityIssue()
    }
}

private struct IdentityConflictView: View {
    let conflict: IdentityReconciliation.Conflict
    let onResolved: () -> Void
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var fieldChoices: [String: NSManagedObjectID] = [:]
    @State private var kept: NSManagedObjectID?
    @State private var error: String?

    private var copies: [NSManagedObject] { conflict.copies.compactMap { try? context.existingObject(with: $0) } }
    private var visibleFields: [String] {
        let order = ["name", "bookingStatus", "client", "startDay", "endDay", "day", "startTime", "endTime", "callTime", "location", "notes", "note"]
        return conflict.fields.filter { !ConflictText.internalFields.contains($0) }
            .sorted { (order.firstIndex(of: $0) ?? order.count, $0) < (order.firstIndex(of: $1) ?? order.count, $1) }
    }
    private var detailCount: String { visibleFields.count == 1 ? "1 detail" : "\(visibleFields.count) details" }
    /// iCloud's copy and this device's copy when the merge knows them; numbered otherwise.
    private func source(_ index: Int, _ copy: NSManagedObject) -> String {
        guard let base = conflict.base else { return "Copy \(index + 1)" }
        return copy.objectID == base ? "iCloud" : "This device"
    }

    var body: some View {
        Group {
            if conflict.wholeRecord { wholeCopy } else { fieldByField }
        }
        .navigationTitle(ConflictText.kind(conflict.entity)).navigationBarTitleDisplayMode(.inline)
        .saveErrorAlert($error)
        .onAppear {
            kept = kept ?? conflict.copies.first
            for field in conflict.fields where fieldChoices[field] == nil { fieldChoices[field] = conflict.copies.first }
        }
    }

    // MARK: Field by field (events and other editable records)

    private var fieldByField: some View {
        DaybookForm(title: ConflictText.title(copies.first),
                    subtitle: visibleFields.isEmpty
                        ? "These copies differ only in details Cuekeeper keeps for itself. Combine them to continue."
                        : conflict.base != nil
                            ? "This device and iCloud both changed \(detailCount) since the backup was restored. Pick the right one for each. Everything else is already combined."
                            : "Two copies disagree on \(detailCount). Pick the right one for each. Everything else is the same.") {
            ForEach(visibleFields, id: \.self) { field in
                Section {
                    ForEach(Array(copies.enumerated()), id: \.element.objectID) { index, copy in
                        choiceRow(ConflictText.value(copy, field), source: source(index, copy), selected: fieldChoices[field] == copy.objectID) {
                            fieldChoices[field] = copy.objectID
                        }
                    }
                } header: { Text(ConflictText.label(field)) }
            }
            if let kept = ConflictText.keptTogether(copies) {
                Section { Text(kept) } header: { Text("Kept from every copy") }
                    .containerValue(\.daybookUnframed, true)
            }
        }
        .safeAreaInset(edge: .bottom) {
            actions(primary: conflict.entity == "Job" ? "Save event" : "Save \(ConflictText.kind(conflict.entity).lowercased())") {
                .fields(fieldChoices)
            }
        }
    }

    // MARK: Whole copy (payments and other financial history)

    private var wholeCopy: some View {
        DaybookForm(title: conflict.entity == "PaymentRecord" ? "Which payment did you receive?" : "Which version is right?",
                    subtitle: ConflictText.wholeSubtitle(conflict, copies.first)) {
            Section {
                ForEach(Array(copies.enumerated()), id: \.element.objectID) { index, copy in
                    let summary = ConflictText.whole(copy, among: conflict)
                    Button { kept = copy.objectID } label: {
                        HStack(alignment: .top, spacing: 12) {
                            radio(kept == copy.objectID)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(summary.headline).font(.title2.bold()).monospacedDigit()
                                Text(summary.detail).font(.subheadline).foregroundStyle(Color("SecondaryText"))
                                if let after = summary.after {
                                    Divider().padding(.vertical, 4)
                                    HStack {
                                        Text(after.label).foregroundStyle(Color("SecondaryText"))
                                        Spacer()
                                        Text(after.value).fontWeight(.semibold).monospacedDigit()
                                    }.font(.subheadline)
                                }
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("\(source(index, copy)), \(summary.headline)")
                    .accessibilityAddTraits(kept == copy.objectID ? .isSelected : [])
                }
            }
            Section {
                Label("Check your records first. The copy you don’t keep is removed from all your devices and can’t be recovered from Recently Deleted.", systemImage: "exclamationmark.triangle")
                    .font(.subheadline).foregroundStyle(Color("AmberText"))
                    .padding(12)
                    .background(Color.orange.opacity(0.13), in: RoundedRectangle(cornerRadius: 12))
            }
            .containerValue(\.daybookUnframed, true)
        }
        .safeAreaInset(edge: .bottom) {
            let headline = copies.first { $0.objectID == kept }.map { ConflictText.whole($0, among: conflict).headline }
            actions(primary: conflict.entity == "PaymentRecord" ? "Keep \(headline ?? "payment") payment" : "Keep this version") {
                kept.map { .keep($0) }
            }
        }
    }

    // MARK: Parts

    private func radio(_ selected: Bool) -> some View {
        Image(systemName: selected ? "checkmark.circle.fill" : "circle")
            .font(.title3).foregroundStyle(selected ? Color.accentColor : Color("SecondaryText"))
            .accessibilityHidden(true)
    }

    private func choiceRow(_ value: String, source: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                radio(selected)
                Text(value).foregroundStyle(Color.primary).frame(maxWidth: .infinity, alignment: .leading)
                Text(source).font(.caption).foregroundStyle(Color("SecondaryText"))
            }
            .frame(minHeight: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(value), \(source)")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func actions(primary: String, choice: @escaping () -> IdentityReconciliation.Choice?) -> some View {
        VStack(spacing: 6) {
            Button { save(choice()) } label: { Text(primary).frame(maxWidth: .infinity) }
                .buttonStyle(DaybookPrimaryButton())
                .accessibilityIdentifier("resolve-conflict")
            Button("Decide later") { dismiss() }
                .frame(minHeight: 44).foregroundStyle(Color.accentColor)
        }
        .padding(.horizontal, 20).padding(.top, 10).padding(.bottom, 6)
        .frame(maxWidth: 760)
        .frame(maxWidth: .infinity)
        .background(Color("PageBackground"))
    }

    private func save(_ choice: IdentityReconciliation.Choice?) {
        guard let choice else { return }
        do {
            try IdentityReconciliation.resolve(conflict, choice: choice, in: isolatedWriter(context))
            context.refreshAllObjects()
            onResolved()
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
}

/// Reader-facing names and values for reviewed records.
enum ConflictText {
    static var internalFields: Set<String> { IdentityReconciliation.internalFields }

    static func kind(_ entity: String) -> String {
        ["Job": "Event", "Client": "Client", "WorkSession": "Session", "WorkRole": "Role", "WorkProject": "Project",
         "WorkSeries": "Championship", "Invoice": "Invoice", "InvoiceRevision": "Invoice", "FeeRevision": "Fee",
         "PaymentRecord": "Payment", "Expense": "Receipt"][entity] ?? "Record"
    }

    static func label(_ field: String) -> String {
        ["name": "Name", "bookingStatus": "Booking status", "startDay": "Start", "endDay": "End", "day": "Day",
         "location": "Location", "notes": "Notes", "note": "Note", "workArrangement": "Work arrangement",
         "timeZoneID": "Time zone", "trackPlaceID": "Track", "deletedAt": "Deleted", "contact": "Contact",
         "defaultCurrency": "Currency", "invoicingJSON": "Invoicing details", "startTime": "Start time",
         "endTime": "End time", "callTime": "Call time", "scheduleStatus": "Schedule", "coverage": "Coverage",
         "overridesRoles": "Own roles", "overridesSeries": "Own championship", "client": "Client",
         "project": "Project", "series": "Championship", "event": "Event details", "job": "Event",
         "invoice": "Invoice"][field] ?? field
    }

    static func value(_ object: NSManagedObject, _ field: String) -> String {
        if let relationship = object.entity.relationshipsByName[field], !relationship.isToMany {
            guard let target = object.value(forKey: field) as? NSManagedObject else { return "None" }
            return title(target)
        }
        switch object.value(forKey: field) {
        case nil: return field == "deletedAt" ? "Not deleted" : "None"
        case let date as Date where field.hasSuffix("Time"): return date.formatted(date: .abbreviated, time: .shortened)
        case let date as Date: return date.formatted(date: .abbreviated, time: .omitted)
        case let flag as Bool: return flag ? "Yes" : "No"
        case let text as String where text.isEmpty: return "None"
        case let text as String where field == "invoicingJSON": return text.isEmpty ? "None" : "Saved details"
        case let text as String where field.hasSuffix("Day") || field == "day": return Day.display(text)
        case let text as String where ["bookingStatus", "scheduleStatus", "coverage", "workArrangement"].contains(field):
            return text == "notCovering" ? "Not covering" : text.prefix(1).uppercased() + text.dropFirst()
        case let text as String: return text
        case let other?: return "\(other)"
        }
    }

    static func title(_ object: NSManagedObject?) -> String {
        switch object {
        case let job as Job: return job.displayName
        case let session as WorkSession: return session.name.isEmpty ? session.compactSchedule : session.name
        case let payment as PaymentRecord: return Money.format(payment.amount, currency: payment.currency)
        case let expense as Expense: return expense.value.merchant.isEmpty ? "Receipt" : expense.value.merchant
        case let fee as FeeRevision: return fee.value?.amount.map { Money.format($0, currency: fee.value!.currency) } ?? "Fee to come"
        case let revision as InvoiceRevision: return revision.value.map { $0.reference.isEmpty ? "Draft invoice" : $0.reference } ?? "Invoice"
        case let object?: return (object.value(forKey: "name") as? String).flatMap { $0.isEmpty ? nil : $0 } ?? kind(object.entity.name ?? "")
        case nil: return "Record"
        }
    }

    static func summary(_ conflict: IdentityReconciliation.Conflict, in context: NSManagedObjectContext) -> String {
        let copies = conflict.copies.compactMap { try? context.existingObject(with: $0) }
        if conflict.wholeRecord { return "\(kind(conflict.entity)) · " + copies.map { whole($0, among: conflict).headline }.joined(separator: " or ") }
        let fields = conflict.fields.filter { !internalFields.contains($0) }.map { label($0).lowercased() }
        return "\(kind(conflict.entity)) · " + (fields.isEmpty ? "internal details differ" : "differs in " + fields.joined(separator: ", "))
    }

    static func wholeSubtitle(_ conflict: IdentityReconciliation.Conflict, _ copy: NSManagedObject?) -> String {
        if let payment = copy as? PaymentRecord {
            let place = payment.invoice.map { "on \($0.title)" } ?? payment.job.map { "for \($0.displayName)" } ?? ""
            return "A payment \(place) exists in two versions. Its balance is on hold until you choose."
        }
        return "This \(kind(conflict.entity).lowercased()) history exists in two versions. Financial records can’t be mixed, so keep one whole copy."
    }

    struct Whole { var headline: String; var detail: String; var after: (label: String, value: String)? }

    static func whole(_ object: NSManagedObject, among conflict: IdentityReconciliation.Conflict) -> Whole {
        switch object {
        case let payment as PaymentRecord:
            let received = payment.receivedAt.map { "Received \($0.formatted(date: .abbreviated, time: .omitted))" } ?? "Date to come"
            var result = Whole(headline: Money.format(payment.amount, currency: payment.currency),
                               detail: payment.note.isEmpty ? received : "\(received) · \(payment.note)")
            // The balance as it would be with only this copy of the payment.
            if let invoice = payment.invoice, let value = try? invoice.currentValue(), value.status != "void" {
                let others = Array(invoice.payments ?? []).filter { $0.id != payment.id || $0.objectID == payment.objectID }
                if let total = try? value.total(), let paid = try? PaymentLedger.net(others) {
                    result.after = ("Invoice balance after", Money.format(total - paid, currency: value.currency))
                }
            }
            return result
        case let expense as Expense:
            let value = expense.value
            return Whole(headline: ExpenseValue.displayAmount(value.amount, currency: value.currency) ?? (value.amount.isEmpty ? "Amount to add" : value.amount),
                         detail: [value.merchant, Day.display(value.day), value.category, expense.isDraft ? "Draft" : "Finished"].filter { !$0.isEmpty }.joined(separator: " · "))
        case let fee as FeeRevision:
            return Whole(headline: title(fee), detail: (fee.value?.agreement ?? "unknown").capitalized + " fee")
        case let revision as InvoiceRevision:
            let total = (try? revision.value?.total()).flatMap { $0 }.map { Money.format($0, currency: revision.value!.currency) } ?? ""
            return Whole(headline: title(revision), detail: [revision.value?.status.capitalized ?? "", total].filter { !$0.isEmpty }.joined(separator: " · "))
        default:
            return Whole(headline: title(object), detail: kind(conflict.entity))
        }
    }

    /// Related records every copy brings along; they all stay with the kept record.
    static func keptTogether(_ copies: [NSManagedObject]) -> String? {
        guard copies.first is Job else { return nil }
        func count(_ name: String) -> Int {
            Set(copies.flatMap { ($0.value(forKey: name) as? Set<NSManagedObject> ?? []).compactMap { $0.value(forKey: "id") as? UUID } }).count
        }
        let parts = [(count("sessions"), "session", "sessions"), (count("expenses"), "receipt", "receipts"), (count("payments"), "payment", "payments")]
            .filter { $0.0 > 0 }.map { "\($0.0) \($0.0 == 1 ? $0.1 : $0.2)" }
        guard !parts.isEmpty else { return nil }
        let list = parts.count == 1 ? parts[0] : parts.dropLast().joined(separator: ", ") + " and " + parts.last!
        return "\(list) \(parts.count == 1 && parts[0].hasPrefix("1 ") ? "stays" : "stay") with this event."
    }
}
