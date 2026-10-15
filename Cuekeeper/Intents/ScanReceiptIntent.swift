import AppIntents
import SwiftUI
import CoreData

struct ScanReceiptIntent: AppIntent {
    static var title: LocalizedStringResource = "Scan Receipt"
    static var description = IntentDescription("Open Cuekeeper to choose an event, scan a receipt and review its expense details. Suitable for the Action Button.")
    static var authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication
    static let supportedModes: IntentModes = .foreground
    @Dependency private var handoff: EventEditorHandoff
    @MainActor func perform() async throws -> some IntentResult {
        try handoff.requestReceiptScan()
        return .result()
    }
}

struct CuekeeperShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: ScanReceiptIntent(), phrases: ["Scan a receipt with \(.applicationName)"], shortTitle: "Scan Receipt", systemImageName: "doc.viewfinder")
    }
}

struct ReceiptEventPicker: View {
    @Environment(\.dismiss) private var dismiss
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Job.startDay, ascending: false)], predicate: NSPredicate(format: "deletedAt == nil")) private var jobs: FetchedResults<Job>
    @State private var search = ""
    @State private var selected: Job?
    var body: some View {
        NavigationStack {
            List {
                if jobs.isEmpty {
                    ContentUnavailableView("Add an event first", systemImage: "calendar.badge.plus", description: Text("Close this screen and create an event, then scan its receipt."))
                }
                ForEach(jobs.filter { search.isEmpty || $0.eventTitle.localizedCaseInsensitiveContains(search) || ($0.client?.name ?? "").localizedCaseInsensitiveContains(search) }, id: \.objectID) { job in
                    Button { selected = job } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(job.eventTitle).font(.headline)
                            Text([job.client?.name, job.eventStartDay].compactMap { $0 }.joined(separator: " · ")).font(.subheadline)
                        }.frame(minHeight: 44)
                    }
                }
            }.searchable(text: $search, prompt: "Find an event")
                .navigationTitle("Receipt for which event?").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } } }
                .sheet(isPresented: Binding(get: { selected != nil }, set: { if !$0 { selected = nil } }), onDismiss: { dismiss() }) {
                    if let selected { ExpenseEditorView(job: selected) }
                }
        }
    }
}
