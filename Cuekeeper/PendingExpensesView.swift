import CoreData
import SwiftUI

struct PendingExpensesPrompt: View {
    @Environment(\.todayNavigation) private var todayNavigation
    var alwaysVisible = false
    @FetchRequest(sortDescriptors: [], predicate: NSPredicate(format: "isDraft == YES AND (job == nil OR job.deletedAt == nil)")) private var expenses: FetchedResults<Expense>
    private var count: Int { expenses.filter(\.needsCompletion).count }
    var body: some View {
        if count > 0 || alwaysVisible {
            Group {
                if todayNavigation != nil {
                    NavigationLink(value: ScheduleDestination.pendingExpenses) {
                        HStack(spacing: 10) {
                            promptLabel.foregroundStyle(Color.primary).frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color("SecondaryText"))
                        }.contentShape(Rectangle())
                    }
                } else {
                    DaybookLink { PendingExpensesView() } label: { promptLabel }
                }
            }.accessibilityIdentifier("pending-expenses")
        }
    }
    private var promptLabel: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: "tray")
            VStack(alignment: .leading, spacing: 4) {
                Text("Expenses to complete").font(.headline)
                Text(count == 0 ? "All caught up" : "\(count) \(count == 1 ? "expense needs" : "expenses need") your review").font(.subheadline).foregroundStyle(Color("SecondaryText"))
            }
            Spacer()
        }.frame(minHeight: 44)
    }
}

struct PendingExpensesView: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Expense.createdAt, ascending: false)], predicate: NSPredicate(format: "isDraft == YES AND (job == nil OR job.deletedAt == nil)")) private var records: FetchedResults<Expense>
    @State private var selected: Expense?
    @State private var removing: Expense?
    @State private var error: String?
    var body: some View {
        DaybookForm {
            if records.filter(\.needsCompletion).isEmpty {
                Section { ContentUnavailableView("All caught up", systemImage: "checkmark.circle", description: Text("Expenses captured from Shortcuts appear here until you add a receipt and choose an event.")) }
            } else {
                Section {
                    Text("Add a receipt, choose an event and review each expense. Remove personal purchases or duplicates you don’t want to keep.").foregroundStyle(Color("SecondaryText"))
                }.containerValue(\.daybookUnframed, true)
                Section("Needs review") {
                    ForEach(records.filter(\.needsCompletion), id: \.objectID) { expense in
                        Button { selected = expense } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                Text(expense.value.merchant.isEmpty ? "Expense to complete" : expense.value.merchant).font(.headline)
                                if let amount = ExpenseValue.displayAmount(expense.value.amount, currency: expense.value.currency) {
                                    Text(amount).monospacedDigit()
                                }
                                Text(expense.job?.eventTitle ?? "Event to choose").font(.subheadline).foregroundStyle(Color("SecondaryText"))
                                Text(expense.photo == nil ? "Receipt to add" : "Receipt attached").font(.caption).foregroundStyle(Color("SecondaryText"))
                            }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        }.accessibilityIdentifier("pending-expense-row")
                        Button("Remove Draft", role: .destructive) { removing = expense }.accessibilityIdentifier("remove-expense-draft")
                    }
                }
            }
            ExpenseRemindersSection(header: "Reminders")
            Section { DaybookLink("Wallet automation setup") { ExpenseAutomationSettingsView() } }
        }
        .navigationTitle("Expenses to complete").navigationBarTitleDisplayMode(.inline)
        .sheet(item: $selected) { ExpenseEditorView(expense: $0) }
        .alert("Remove this expense draft?", isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button("Remove Draft", role: .destructive) {
                guard let removing else { return }
                do {
                    let id = removing.id
                    try Expense.discardDraft(id: removing.objectID, revision: removing.revision, in: context)
                    if let id { ExpenseNotifications.shared.clear(id: id) }
                    self.removing = nil
                } catch { self.error = error.localizedDescription }
            }
            Button("Keep Draft", role: .cancel) { removing = nil }
        } message: { Text("It will leave the completion list. A repeated transaction with the same transaction ID won’t recreate it.") }
        .saveErrorAlert($error)
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
