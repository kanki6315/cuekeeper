import CoreData
import SwiftUI

/// Points Payments at the Expenses inbox while drafts wait there. Finishing happens in the inbox.
struct PendingExpensesPrompt: View {
    @Environment(\.openExpensesInbox) private var openInbox
    @FetchRequest(sortDescriptors: [], predicate: NSPredicate(format: "isDraft == YES AND (job == nil OR job.deletedAt == nil)")) private var expenses: FetchedResults<Expense>
    private var count: Int { expenses.filter(\.needsCompletion).count }
    var body: some View {
        if count > 0 {
            Group {
                if let openInbox {
                    Button(action: openInbox) {
                        HStack(spacing: 10) {
                            promptLabel.foregroundStyle(Color.primary).frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.theme.secondaryText)
                        }.contentShape(Rectangle())
                    }.buttonStyle(.plain)
                } else {
                    promptLabel
                }
            }.accessibilityIdentifier("pending-expenses")
        }
    }
    private var promptLabel: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "tray").foregroundStyle(Color.theme.caution)
            VStack(alignment: .leading, spacing: 4) {
                Text("Expenses to finish").font(.headline)
                Text("\(count) waiting in your Expenses inbox").font(.subheadline).foregroundStyle(Color.theme.secondaryText)
            }
            Spacer()
        }.frame(minHeight: 44)
    }
}

struct ExpenseEventSelection: View {
    @Environment(\.dismiss) private var dismiss
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Job.startDay, ascending: false)], predicate: NSPredicate(format: "deletedAt == nil")) private var jobs: FetchedResults<Job>
    @State private var search = ""
    /// Events in flight, offered first so a receipt from today's work is one tap away.
    var suggested: [Job] = []
    let select: (NSManagedObjectID) -> Void
    /// Offered from the Expenses tab, for costs that belong to no event.
    var onBusiness: (() -> Void)? = nil
    var body: some View {
        NavigationStack {
            List {
                if let onBusiness, search.isEmpty {
                    Section {
                        Button { onBusiness() } label: {
                            Label("Business cost", systemImage: "briefcase").font(.headline).frame(minHeight: 44)
                        }.accessibilityIdentifier("choose-expense-business")
                    }
                }
                if jobs.isEmpty { Text("Create an event from Upcoming, then return here to choose it.") }
                if search.isEmpty && !suggested.isEmpty {
                    Section("In flight") {
                        ForEach(suggested, id: \.objectID) { job in
                            Button { select(job.objectID) } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(job.eventTitle).font(.headline)
                                    Text([job.client?.name, job.eventStartDay].compactMap { $0 }.joined(separator: " · ")).font(.subheadline)
                                }.frame(minHeight: 44)
                            }.accessibilityIdentifier("choose-expense-suggested-row")
                        }
                    }
                }
                ForEach(jobs.filter { search.isEmpty || $0.eventTitle.localizedCaseInsensitiveContains(search) || ($0.client?.name ?? "").localizedCaseInsensitiveContains(search) }, id: \.objectID) { job in
                    Button { select(job.objectID) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(job.eventTitle).font(.headline)
                            Text([job.client?.name, job.eventStartDay].compactMap { $0 }.joined(separator: " · ")).font(.subheadline)
                        }.frame(minHeight: 44)
                    }.accessibilityIdentifier("choose-expense-event-row")
                }
            }.searchable(text: $search, prompt: "Find an event")
                .navigationTitle("Choose Event").navigationBarTitleDisplayMode(.inline)
                .toolbar { Button("Cancel") { dismiss() } }
        }
    }
}

struct ExpenseNotificationView: View {
    @Environment(\.dismiss) private var dismiss
    @FetchRequest private var expenses: FetchedResults<Expense>
    let id: UUID
    init(id: UUID) {
        self.id = id
        _expenses = FetchRequest(sortDescriptors: [], predicate: NSPredicate(format: "id == %@", id as CVarArg))
    }
    var body: some View {
        Group {
            if let expense = expenses.first, expense.needsCompletion { ExpenseEditorView(expense: expense) }
            else {
                NavigationStack {
                    ContentUnavailableView("Expense already handled or unavailable", systemImage: "tray", description: Text("Open the Expenses tab for your remaining drafts."))
                        .toolbar { Button("Done") { dismiss() } }
                }
            }
        }.task { ExpenseNotifications.shared.clear(id: id) }
    }
}
