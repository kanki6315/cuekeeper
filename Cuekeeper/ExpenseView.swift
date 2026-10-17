import AVFoundation
import CoreData
import PhotosUI
import SwiftUI
import VisionKit

/// The Expenses tab's two modes: a queue of unfinished work, and the history of finished expenses.
enum ExpensesMode: String, CaseIterable, Hashable {
    case inbox = "Inbox", ledger = "Ledger"
}

/// Expenses as an inbox to empty and a ledger to filter. The inbox has no period, so an old draft is never
/// hidden behind a month; the ledger lists only finished expenses for a period, state, type and client.
struct ExpensesView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.managedObjectContext) private var context
    @Binding var mode: ExpensesMode
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Expense.createdAt, ascending: false)]) private var expenses: FetchedResults<Expense>
    // Observe events, clients and invoices too: renames, deletions and billing change what rows show.
    @FetchRequest(sortDescriptors: []) private var jobs: FetchedResults<Job>
    @FetchRequest(sortDescriptors: []) private var clients: FetchedResults<Client>
    @FetchRequest(sortDescriptors: []) private var invoiceRevisions: FetchedResults<InvoiceRevision>
    @FetchRequest(sortDescriptors: []) private var payments: FetchedResults<PaymentRecord>
    @State private var filter = ExpenseLedgerFilter(period: .current())
    @State private var selecting = false
    @State private var selection: Set<UUID> = []
    @State private var removing = false
    @State private var showAllStale = false
    @State private var assigning: Expense?
    @State private var error: String?
    @State private var sheet: ExpenseSheet?
    @State private var choosingEvent = false
    @State private var pendingCapture: ExpenseSheet?
    @State private var invoicing: ReadyInvoice?
    /// Stale drafts shown before "Show all", so years of Wallet captures never make an endless page.
    private let stalePreview = 5

    var body: some View {
        _ = jobs.count + clients.count + invoiceRevisions.count + payments.count
        let ledger = ExpensesLedger.load(filter: filter, expenses: Array(expenses), context: context)
        return Group {
            // The inbox is a native list so its rows can be swiped; the ledger keeps the ruled panels.
            if mode == .inbox {
                DaybookList {
                    // A header, not rows: list rows squeeze the tab header and merge its buttons' taps.
                    Section {} header: {
                        VStack(alignment: .leading, spacing: 10) {
                            tabHeader
                            modePicker(ledger.inbox.count)
                            if ledger.inbox.count > 0 { inboxSummary(ledger.inbox) }
                        }
                        .textCase(nil).font(.body)
                        .listRowInsets(EdgeInsets())
                    }
                    inboxSections(ledger.inbox)
                }
                // Match the ledger's 20-point page margin.
                .contentMargins(.horizontal, 20, for: .scrollContent)
                .contentMargins(.top, 12, for: .scrollContent)
            } else {
                DaybookForm(topPadding: 12) {
                    Section { tabHeader }.containerValue(\.daybookUnframed, true).containerValue(\.daybookFlushTop, true)
                    Section { modePicker(ledger.inbox.count) }.containerValue(\.daybookUnframed, true)
                    ledgerSections(ledger)
                }
            }
        }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar(sizeClass == .compact ? .hidden : .visible, for: .navigationBar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            if selecting && mode == .inbox { selectionBar }
        }
        .onChange(of: mode) { _, _ in endSelecting() }
        .confirmationDialog(selection.count == 1 ? "Remove this draft?" : "Remove \(selection.count) drafts?",
                            isPresented: $removing, titleVisibility: .visible) {
            Button(selection.count == 1 ? "Remove Draft" : "Remove \(selection.count) Drafts", role: .destructive) { removeSelected() }
            Button(selection.count == 1 ? "Keep Draft" : "Keep Drafts", role: .cancel) {}
        } message: {
            Text(selection.count == 1 ? "It leaves your inbox. A repeated Wallet transaction with the same transaction ID won’t recreate it."
                                      : "They leave your inbox. A repeated Wallet transaction with the same transaction ID won’t recreate them.")
        }
        // A swiped Remove borrows the selection for one draft; cancelling gives it back.
        .onChange(of: removing) { _, open in if !open && !selecting { selection = [] } }
        .sheet(item: $assigning) { expense in
            ExpenseEventSelection { jobID in assign(expense, to: jobID) }
        }
        .saveErrorAlert($error)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .edit(let expense): ExpenseEditorView(expense: expense)
            case .capture(let job): ExpenseEditorView(job: job)
            case .business(let template): ExpenseEditorView(business: template)
            }
        }
        .sheet(item: $invoicing) { InvoiceEditorView(ready: $0) }
        .sheet(isPresented: $choosingEvent, onDismiss: {
            if let pendingCapture { sheet = pendingCapture; self.pendingCapture = nil }
        }) {
            ExpenseEventSelection(select: { id in
                if let job = jobs.first(where: { $0.objectID == id }) { pendingCapture = .capture(job) }
                choosingEvent = false
            }, onBusiness: {
                pendingCapture = .business(ExpenseValue())
                choosingEvent = false
            })
        }
    }

    private var tabHeader: some View {
        DaybookTabHeader {
            Button("Scan Receipt", systemImage: "receipt") { choosingEvent = true }
                .buttonStyle(DaybookPrimaryButton())
                .accessibilityIdentifier("scan-receipt-overview")
        }
    }

    private func modePicker(_ inboxCount: Int) -> some View {
        DaybookSegments(title: "Expenses view", selection: $mode, options: ExpensesMode.allCases,
                        identifier: "expenses-mode", label: \.rawValue,
                        badge: { $0 == .inbox ? inboxCount : 0 })
    }

    // MARK: Inbox

    @ViewBuilder private func inboxSections(_ inbox: ExpenseInbox) -> some View {
        if inbox.count == 0 {
            Section {
                ContentUnavailableView("All caught up", systemImage: "checkmark.circle",
                                       description: Text("Wallet captures and receipts you haven’t finished wait here until they have an event and details."))
                    .accessibilityIdentifier("expenses-inbox-empty")
            }
        } else {
            ForEach(inbox.sections) { section in
                let stale = section.group == .stale
                let items = stale && !showAllStale ? Array(section.items.prefix(stalePreview)) : section.items
                Section {
                    ForEach(items) { inboxRow($0) }
                    if stale && !showAllStale && section.items.count > stalePreview {
                        Button("Show All \(section.items.count)") { withAnimation(.easeOut(duration: 0.2)) { showAllStale = true } }
                            .fontWeight(.semibold).frame(minHeight: 44)
                            .accessibilityIdentifier("expenses-inbox-show-stale")
                    }
                } header: {
                    HStack(spacing: 8) {
                        Text(section.group.title)
                        AmberCount(count: section.items.count)
                    }
                    .font(.headline).foregroundStyle(Color.primary).textCase(nil)
                } footer: {
                    if stale { Text("Probably personal purchases. Swipe left to remove one, or select several.") }
                    else if section.group == .blocking { Text("An event can’t be invoiced while it has a receipt to finish.") }
                    else if section.group == .recent { Text("Swipe right to choose an event, left to remove.") }
                }
            }
        }
        Section {
            NavigationLink { ExpenseAutomationSettingsView() } label: { Label("Wallet automation", systemImage: "creditcard") }
        }
    }

    private func inboxSummary(_ inbox: ExpenseInbox) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(([inbox.count == 1 ? "1 to finish" : "\(inbox.count) to finish"]
                  + inbox.amounts.keys.sorted().map { Money.format(inbox.amounts[$0]!, currency: $0) }).joined(separator: " · "))
                .font(.subheadline).foregroundStyle(Color.theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            if inbox.drafts > 0 {
                Button(selecting ? "Done" : "Select") { selecting ? endSelecting() : (selecting = true) }
                    .fontWeight(.semibold).frame(minWidth: 44, minHeight: 44)
                    .accessibilityIdentifier("expenses-inbox-select")
            }
        }
    }

    /// The whole row opens the draft or the due month. Drafts swipe right to choose an event and left to remove.
    @ViewBuilder private func inboxRow(_ item: FinishItem) -> some View {
        let draft = item.draftID.flatMap { id in expenses.first { $0.id == id } }
        if selecting, let id = item.draftID {
            let selected = selection.contains(id)
            Button {
                if selected { selection.remove(id) } else { selection.insert(id) }
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3).foregroundStyle(selected ? Color.theme.accent : Color.theme.secondaryText)
                        .accessibilityHidden(true)
                    itemText(item)
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(selected ? [.isSelected] : [])
            .accessibilityIdentifier("expenses-inbox-pick")
        } else {
            Button { perform(item) } label: {
                HStack(spacing: 10) {
                    itemText(item)
                    Text(item.actionTitle).font(.subheadline.weight(.semibold)).foregroundStyle(Color.theme.accent)
                        .accessibilityHidden(true)
                }
                .frame(minHeight: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(item.actionTitle == "Add" ? "Adds this month’s cost" : "Opens the draft to finish it")
            .accessibilityIdentifier("expenses-finish-\(item.actionTitle.lowercased())")
            .modifier(InboxRowActions(draft: draft, canAssign: item.group != .blocking,
                                      assign: { assigning = $0 }, remove: { confirmRemove($0) }))
        }
    }

    private func itemText(_ item: FinishItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.title).font(.subheadline.weight(.semibold))
            Text(item.detail).font(.footnote).foregroundStyle(Color.theme.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var selectionBar: some View {
        HStack(spacing: 12) {
            Text(selection.isEmpty ? "Select drafts" : "\(selection.count) selected")
                .font(.subheadline).foregroundStyle(Color.theme.secondaryText)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Remove", systemImage: "trash", role: .destructive) { removing = true }
                .fontWeight(.semibold).frame(minHeight: 44)
                .disabled(selection.isEmpty)
                .accessibilityIdentifier("expenses-inbox-remove")
        }
        .padding(.horizontal, 20).padding(.vertical, 6)
        .background(.bar)
    }

    private func confirmRemove(_ expense: Expense) {
        guard let id = expense.id else { return }
        selection = [id]; removing = true
    }

    private func assign(_ expense: Expense, to jobID: NSManagedObjectID) {
        assigning = nil
        do {
            // Stays a draft: choosing the event is one step, the receipt and details still need review.
            try Expense.save(expense.value, id: expense.objectID, revision: expense.revision, confirmed: false, jobID: jobID, in: context)
        } catch { self.error = error.localizedDescription }
    }

    private func endSelecting() { selecting = false; selection = [] }

    private func removeSelected() {
        var failed = 0
        for expense in expenses where expense.id.map(selection.contains) == true {
            do {
                try Expense.discardDraft(id: expense.objectID, revision: expense.revision, in: context)
                if let id = expense.id { ExpenseNotifications.shared.clear(id: id) }
            } catch { failed += 1 }
        }
        endSelecting()
        if failed > 0 { error = failed == 1 ? "One draft changed on another device and wasn’t removed. Check it and try again." : "\(failed) drafts changed on another device and weren’t removed. Check them and try again." }
    }

    private func perform(_ item: FinishItem) {
        switch item.kind {
        case .draft(let id):
            if let expense = expenses.first(where: { $0.id == id }) { sheet = .edit(expense) }
        case let .repeatDue(template, day, repeatDay):
            guard let expense = expenses.first(where: { $0.id == template }) else { return }
            var value = expense.value
            value.day = day; value.repeatDay = repeatDay; value.capture = nil; value.notes = ""
            sheet = .business(value)
        }
    }

    // MARK: Ledger

    @ViewBuilder private func ledgerSections(_ ledger: ExpensesLedger) -> some View {
        Section { filterBar(ledger) }.containerValue(\.daybookUnframed, true)
        Section { periodStepper(count: ledger.count) }.containerValue(\.daybookUnframed, true)
        if ledger.draftsInPeriod > 0 {
            Section {
                Button { mode = .inbox } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "tray").foregroundStyle(Color.theme.amberText).accessibilityHidden(true)
                        Text(draftsNote(ledger.draftsInPeriod))
                            .font(.subheadline).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.theme.secondaryText).accessibilityHidden(true)
                    }
                    .frame(minHeight: 44).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("expenses-ledger-drafts")
            }
        }
        if !ledger.currencies.isEmpty {
            Section { ExpenseMoneyPanel(currencies: ledger.currencies) }
        }
        if !ledger.rebill.isEmpty {
            Section {
                ForEach(ledger.rebill) { rebillRow($0) }
            } header: { Text("To rebill") }
        }
        if ledger.months.isEmpty {
            Section {
                ContentUnavailableView(filter.isNarrowed ? "No matching expenses" : "No expenses in \(filter.period.title)",
                                       systemImage: "receipt",
                                       description: Text(filter.isNarrowed ? "Clear the filters to see every expense in this period." : "Scan a receipt or add a business cost."))
                if filter.isNarrowed {
                    Button("Clear Filters") { clearFilters() }.fontWeight(.semibold).frame(maxWidth: .infinity, minHeight: 44)
                }
            }
        } else {
            ForEach(ledger.months) { month in
                Section {
                    ForEach(month.days) { dayRow($0) }
                } header: {
                    if filter.period.kind != .month { Text(MonthStepper.title(month.month)) }
                }
            }
        }
        if ledger.earlier.count > 0 {
            Section {
                Button {
                    filter.period.kind = .all; filter.state = .toRebill
                } label: { earlierRow(ledger.earlier) }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("expenses-earlier-rebill")
            }
        }
    }

    private func filterBar(_ ledger: ExpensesLedger) -> some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                // Leading, so it stays in view however far the chips scroll.
                if filter.isNarrowed {
                    Button { withAnimation(.easeOut(duration: 0.2)) { clearFilters() } } label: {
                        Image(systemName: "xmark").font(.footnote.weight(.bold))
                            .frame(width: 34, height: 34)
                            .background(Color.primary.opacity(0.06), in: Circle())
                            .frame(width: 44, height: 44).contentShape(Rectangle())
                    }
                    .foregroundStyle(Color.primary)
                    .accessibilityLabel("Clear filters")
                    .accessibilityIdentifier("ledger-clear")
                }
                chip(filter.period.kind.rawValue, active: filter.period.kind != .month, identifier: "ledger-period") {
                    Picker("Period", selection: $filter.period.kind) {
                        ForEach(LedgerPeriod.Kind.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
                chip(filter.state.rawValue, active: filter.state != .any, identifier: "ledger-state") {
                    Picker("State", selection: $filter.state) {
                        ForEach(LedgerState.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                }
                chip(filter.type == .all ? "All types" : filter.type.rawValue, active: filter.type != .all, identifier: "ledger-type") {
                    Picker("Type", selection: $filter.type) {
                        ForEach(ExpenseFilter.allCases, id: \.self) { Text($0 == .all ? "All types" : $0.rawValue).tag($0) }
                    }
                }
                if !ledger.clients.isEmpty || filter.clientID != nil {
                    chip(ledger.clients.first { $0.id == filter.clientID }?.name ?? "All clients", active: filter.clientID != nil, identifier: "ledger-client") {
                        Picker("Client", selection: $filter.clientID) {
                            Text("All clients").tag(UUID?.none)
                            ForEach(ledger.clients) { Text($0.name).tag(UUID?.some($0.id)) }
                        }
                    }
                }
            }
            // Chips scroll edge to edge but start aligned with the page's 20-point margin.
            .padding(.horizontal, 20)
        }
        .padding(.horizontal, -20)
        .scrollIndicators(.hidden)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Filters")
    }

    private func chip<Options: View>(_ title: String, active: Bool, identifier: String, @ViewBuilder options: () -> Options) -> some View {
        Menu { options() } label: {
            HStack(spacing: 4) {
                Text(title).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2.weight(.bold)).accessibilityHidden(true)
            }
            .font(.subheadline.weight(active ? .semibold : .regular))
            .foregroundStyle(active ? Color.theme.accent : Color.primary)
            .padding(.horizontal, 12).frame(minHeight: 34)
            .background(active ? Color.theme.accent.opacity(0.18) : Color.primary.opacity(0.06), in: Capsule())
            .frame(minHeight: 44).contentShape(Rectangle())
        }
        .accessibilityIdentifier(identifier)
    }

    private func draftsNote(_ count: Int) -> String {
        let drafts = count == 1 ? "1 draft" : "\(count) drafts"
        if filter.period.kind == .all { return "\(drafts) \(count == 1 ? "is" : "are") waiting in your inbox" }
        return "\(drafts) from this \(filter.period.kind.rawValue.lowercased()) \(count == 1 ? "is" : "are") in your inbox"
    }

    private func clearFilters() { filter.state = .any; filter.type = .all; filter.clientID = nil }

    private func periodStepper(count: Int) -> some View {
        let period = filter.period
        let current = LedgerPeriod.current(period.kind)
        return HStack(spacing: 4) {
            if period.kind != .all {
                Button { filter.period = period.shifted(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                    .accessibilityLabel("Previous \(period.kind.rawValue.lowercased())").accessibilityIdentifier("period-previous")
            }
            Spacer(minLength: 0)
            VStack(spacing: 2) {
                Text(period.title).font(.title3.bold()).accessibilityIdentifier("expenses-period")
                HStack(spacing: 6) {
                    Text(count == 1 ? "1 expense" : "\(count) expenses").foregroundStyle(Color.theme.secondaryText)
                    if period.kind != .all && period.months?.first != current.months?.first {
                        Text("·").foregroundStyle(Color.theme.secondaryText)
                        Button("This \(period.kind.rawValue.lowercased())") { filter.period = current }.fontWeight(.semibold)
                            .padding(.vertical, 14).contentShape(Rectangle()).padding(.vertical, -14)
                            .accessibilityIdentifier("period-current")
                    }
                }
                .font(.footnote)
            }
            Spacer(minLength: 0)
            if period.kind != .all {
                Button { filter.period = period.shifted(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                    .accessibilityLabel("Next \(period.kind.rawValue.lowercased())").accessibilityIdentifier("period-next")
            }
        }
        .font(.body.weight(.semibold))
        .frame(minHeight: 44)
    }

    // MARK: To rebill

    private func rebillRow(_ group: RebillGroup) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.headline)
                Text((group.events + [group.receipts.count == 1 ? "1 receipt" : "\(group.receipts.count) receipts", Money.format(group.amount, currency: group.currency)])
                    .joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(Color.theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            if group.canInvoice, let clientID = group.clientID {
                Button("Invoice") {
                    invoicing = ReadyInvoice(clientID: clientID, currency: group.currency,
                                             jobs: jobs.filter { $0.id.map(group.invoiceableJobs.contains) ?? false },
                                             expenses: expenses.filter { $0.id.map(group.receipts.contains) ?? false })
                }
                .buttonStyle(DaybookPrimaryButton()).controlSize(.small)
                .accessibilityIdentifier("expenses-rebill-invoice")
            }
        }
    }

    // MARK: Expenses by day

    private func dayRow(_ day: ExpenseDay) -> some View {
        HStack(alignment: .top, spacing: 12) {
            if !typeSize.isAccessibilitySize { DaybookDateRail(day: day.day) }
            VStack(alignment: .leading, spacing: 0) {
                if typeSize.isAccessibilitySize {
                    Text(Day.display(day.day)).font(.subheadline.weight(.semibold)).foregroundStyle(Color.theme.accent).padding(.bottom, 6)
                }
                ForEach(Array(day.expenses.enumerated()), id: \.element.id) { index, fact in
                    if index > 0 { Divider().padding(.vertical, 10) }
                    expenseRow(fact)
                }
            }
        }
    }

    @ViewBuilder private func expenseRow(_ fact: ExpenseFact) -> some View {
        if fact.eventDeleted {
            expenseLabel(fact)
        } else {
            Button { if let expense = expenses.first(where: { $0.id == fact.id }) { sheet = .edit(expense) } } label: { expenseLabel(fact) }
                .buttonStyle(.plain)
                .accessibilityIdentifier("all-expense-row")
        }
    }

    private func expenseLabel(_ fact: ExpenseFact) -> some View {
        let layout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return VStack(alignment: .leading, spacing: 4) {
            layout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(fact.title).font(.headline)
                    subtitle(fact).font(.subheadline)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 2) {
                    if let amount = fact.displayAmount { Text(amount).font(.subheadline).monospacedDigit() }
                    status(fact).font(.caption.weight(.semibold))
                }
                .fixedSize(horizontal: !typeSize.isAccessibilitySize, vertical: false)
            }
            if fact.eventDeleted {
                Text("Deleted event · Restore it in Settings to open this expense.")
                    .font(.caption).foregroundStyle(Color.theme.secondaryText)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func subtitle(_ fact: ExpenseFact) -> Text {
        if fact.isBusiness { return Text("Business · \(fact.category)").foregroundStyle(Color.theme.secondaryText) }
        guard let event = fact.eventTitle else { return Text("Event to choose").foregroundStyle(Color.theme.amberText) }
        return Text(fact.state == .toFinish && fact.merchant.isEmpty ? event : "\(event) · \(fact.category)").foregroundStyle(Color.theme.secondaryText)
    }

    @ViewBuilder private func status(_ fact: ExpenseFact) -> some View {
        switch fact.state {
        case .toFinish: Text("To finish").foregroundStyle(Color.theme.amberText)
        case .yourCost: Text("Your cost").foregroundStyle(Color.theme.secondaryText)
        case .business:
            if fact.repeats { Label("Monthly", systemImage: "repeat").labelStyle(.titleAndIcon).foregroundStyle(Color.theme.secondaryText) }
        case .toRebill: Text("To rebill").foregroundStyle(Color.theme.completed)
        case .onInvoice(let reference): Text(reference.isEmpty ? "On draft invoice" : "On \(reference)").foregroundStyle(Color.theme.secondaryText)
        case .paidBack: Text("Paid back").foregroundStyle(Color.theme.positive)
        case .review: Text("Billing review").foregroundStyle(Color.theme.amberText)
        }
    }

    private func earlierRow(_ earlier: EarlierRebill) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Still to rebill from earlier")
                Text(([earlier.count == 1 ? "1 receipt" : "\(earlier.count) receipts"]
                      + earlier.amounts.keys.sorted().map { Money.format(earlier.amounts[$0]!, currency: $0) }).joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(Color.theme.secondaryText)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color.theme.secondaryText).accessibilityHidden(true)
        }
        .frame(minHeight: 44).contentShape(Rectangle())
    }
}

/// Swipe, long-press and VoiceOver actions for an inbox draft. Removing never happens on a full swipe.
private struct InboxRowActions: ViewModifier {
    let draft: Expense?
    let canAssign: Bool
    let assign: (Expense) -> Void
    let remove: (Expense) -> Void

    func body(content: Content) -> some View {
        if let draft {
            content
                .swipeActions(edge: .leading, allowsFullSwipe: true) {
                    if canAssign {
                        Button("Choose Event", systemImage: "calendar.badge.plus") { assign(draft) }.tint(Color.theme.accent)
                    }
                }
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    Button("Remove", systemImage: "trash") { remove(draft) }.tint(Color.theme.destructive)
                }
                .contextMenu {
                    if canAssign { Button("Choose Event", systemImage: "calendar.badge.plus") { assign(draft) } }
                    Button("Remove Draft", systemImage: "trash", role: .destructive) { remove(draft) }
                }
                .accessibilityActions {
                    if canAssign { Button("Choose Event") { assign(draft) } }
                    Button("Remove Draft") { remove(draft) }
                }
        } else {
            content
        }
    }
}

/// Editors the Expenses tab presents.
enum ExpenseSheet: Identifiable {
    case edit(Expense), capture(Job), business(ExpenseValue)
    var id: String {
        switch self {
        case .edit(let expense): "edit-\(expense.objectID)"
        case .capture(let job): "capture-\(job.objectID)"
        case .business(let value): "business-\(value.seriesID?.uuidString ?? "new")-\(value.day)"
        }
    }
}

struct AmberCount: View {
    let count: Int
    var body: some View {
        Text(count, format: .number)
            .font(.caption.weight(.bold)).monospacedDigit()
            .foregroundStyle(Color.theme.amberText)
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.theme.attention.opacity(0.18), in: Capsule())
    }
}

extension ExpenseBucket {
    var fill: Color {
        switch self {
        case .paidBack: Color.theme.positive
        case .onInvoice: Color.theme.positive.opacity(0.55)
        case .toRebill: Color.theme.completed
        case .toFinish: Color.theme.attention
        case .yourCost: Color.primary.opacity(0.28)
        }
    }
}

struct ExpenseMoneyPanel: View {
    let currencies: [ExpenseCurrency]
    private var present: [ExpenseBucket] { ExpenseBucket.allCases.filter { bucket in currencies.contains { ($0.amounts[bucket] ?? 0) > 0 } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(currencies) { currency in
                VStack(alignment: .leading, spacing: 7) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(currency.currency).fontWeight(.semibold)
                        Spacer(minLength: 8)
                        Text(Money.format(currency.total, currency: currency.currency)).monospacedDigit()
                    }
                    .font(.subheadline)
                    SegmentedMoneyBar(currency: currency.currency, parts: ExpenseBucket.allCases.compactMap { bucket in
                        (currency.amounts[bucket] ?? 0) > 0 ? .init(label: bucket.label, fill: bucket.fill, amount: currency.amounts[bucket]!) : nil
                    })
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)], alignment: .leading, spacing: 6) {
                ForEach(present, id: \.self) { bucket in
                    HStack(spacing: 6) {
                        RoundedRectangle(cornerRadius: 3).fill(bucket.fill).frame(width: 10, height: 10)
                        Text(bucket.label).font(.footnote)
                    }
                }
            }
            .accessibilityHidden(true)
        }
        .padding(.vertical, 2)
    }
}

struct EventExpensesSection: View {
    @ObservedObject var job: Job
    @FetchRequest private var expenses: FetchedResults<Expense>
    @State private var adding = false
    @State private var selected: Expense?
    /// When set, the parent presents editors; sheets attached inside lazy or decomposed containers are unreliable.
    var onOpen: ((Expense?) -> Void)? = nil
    init(job: Job, onOpen: ((Expense?) -> Void)? = nil) {
        self.onOpen = onOpen
        self.job = job
        _expenses = FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Expense.createdAt, ascending: false)], predicate: NSPredicate(format: "job == %@", job))
    }
    var body: some View {
        Section("Expenses") {
            ForEach(expenses.filter { !$0.value.discarded }, id: \.objectID) { expense in
                Button { if let onOpen { onOpen(expense) } else { selected = expense } } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(expense.isDraft ? "Review receipt" : expense.value.merchant)
                            Text(expense.isDraft ? (expense.photo == nil ? "Receipt to add · Details to confirm" : "Photo saved · Details to confirm") : Day.display(expense.value.day))
                                .font(.subheadline).foregroundStyle(expense.isDraft ? Color.theme.amberText : Color.theme.secondaryText)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        if !expense.isDraft {
                            Text(ExpenseValue.displayAmount(expense.value.amount, currency: expense.value.currency) ?? "Total to check").monospacedDigit()
                        }
                    }
                    .foregroundStyle(Color.primary)
                    .frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).accessibilityIdentifier("expense-row")
            }
            DaybookActionRow("Scan Receipt", systemImage: "receipt") { if let onOpen { onOpen(nil) } else { adding = true } }
                .accessibilityIdentifier("scan-receipt")
        }
        .sheet(isPresented: $adding) { ExpenseEditorView(job: job) }
        .sheet(item: $selected) { ExpenseEditorView(job: job, expense: $0) }
    }
}

struct ExpenseEditorView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    let job: Job?
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Job.startDay, ascending: false)], predicate: NSPredicate(format: "deletedAt == nil")) private var events: FetchedResults<Job>
    private let initialJobID: NSManagedObjectID?
    @State private var selectedJobID: NSManagedObjectID?
    @State private var choosingEvent = false
    @State private var proposal: ExpenseValue?
    @State private var conflicts: [ReceiptField] = []
    @State private var recordID: NSManagedObjectID?
    @State private var revision: String
    @State private var draft: ExpenseValue
    @State private var initial: ExpenseValue
    @State private var isDraft: Bool
    @State private var photo: Data?
    /// Bumped whenever `photo` changes, so its preview is decoded once per photo instead of on every edit.
    @State private var photoVersion = 0
    @State private var preview: UIImage?
    @State private var previewFailed = false
    @State private var scanning = false
    @State private var cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var cameraBlocked = false
    @State private var picker: PhotosPickerItem?
    @State private var busy = false
    @State private var savingPhoto = false
    @State private var processingLocation = ReceiptExtractor.ProcessingLocation.device
    @State private var task: Task<Void, Never>?
    @State private var message: String?
    @State private var error: String?
    @State private var failedDraftSave = false
    @State private var discard = false
    @State private var removingDraft = false
    @State private var retry = false
    @State private var replacing = false
    @State private var choosingPhoto = false
    @State private var enlarged = false
    /// A cost that belongs to no event, such as a software subscription.
    @State private var business: Bool
    private let initialBusiness: Bool
    /// Opened with known details (the next month of a repeating cost), so the camera stays closed.
    private let prefilled: Bool

    /// `business` starts a new cost with no event, optionally prefilled.
    init(job: Job? = nil, expense: Expense? = nil, business template: ExpenseValue? = nil) {
        self.job = job
        initialJobID = expense?.job?.objectID ?? job?.objectID
        _selectedJobID = State(initialValue: initialJobID)
        let isBusiness = template != nil || expense?.isBusiness == true
        _business = State(initialValue: isBusiness); initialBusiness = isBusiness
        prefilled = !(template?.merchant.isEmpty ?? true)
        let value = (expense?.value ?? template ?? ExpenseValue()).editingAmounts()
        _draft = State(initialValue: value); _initial = State(initialValue: value)
        _recordID = State(initialValue: expense?.objectID); _revision = State(initialValue: expense?.revision ?? "")
        _photo = State(initialValue: expense?.photo); _isDraft = State(initialValue: expense?.isDraft ?? true)
    }
    var body: some View {
        NavigationStack {
            DaybookForm {
                if job == nil {
                    Section {
                        DaybookSegments(title: "What it's for", selection: $business, options: [false, true],
                                        identifier: "expense-purpose", label: { $0 ? "Business" : "An event" })
                    } header: { Text("What it's for") }
                        .containerValue(\.daybookUnframed, true)
                }
                if !business {
                Section {
                    if let selected = events.first(where: { $0.objectID == selectedJobID }) {
                        Text(selected.eventTitle).font(.headline)
                        if let client = selected.client { Text(client.name).foregroundStyle(Color.theme.secondaryText) }
                    } else { Text("Choose an event to complete this expense.").foregroundStyle(Color.theme.secondaryText) }
                    Button(selectedJobID == nil ? "Choose Event" : "Change Event") { choosingEvent = true }.accessibilityIdentifier("expense-choose-event")
                }.containerValue(\.daybookUnframed, true)
                }
                Section {
                    if photo != nil {
                        if let preview {
                            Button { enlarged = true } label: {
                                Image(uiImage: preview).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 220)
                            }.accessibilityLabel("View full receipt photo")
                        } else if previewFailed {
                            Text("This receipt photo can’t be shown. Replace it or enter the details below.").foregroundStyle(Color.theme.secondaryText)
                        } else {
                            ProgressView().frame(maxWidth: .infinity, minHeight: 120)
                        }
                        if busy {
                            ProgressView(processingLocation.progressMessage)
                            Button("Enter details myself") { task?.cancel(); busy = false; message = "Check the receipt and enter its details below." }.disabled(savingPhoto)
                        } else {
                            if let message { Text(message).font(.subheadline).foregroundStyle(Color.theme.secondaryText) }
                            if isDraft {
                                Button("Read Receipt Again") { retry = true }
                                Button("Replace Receipt Photo") { replacing = true }
                            }
                        }
                    } else {
                        if VNDocumentCameraViewController.isSupported {
                            if cameraUnavailable {
                                Text(cameraUnavailableMessage).foregroundStyle(Color.theme.secondaryText)
                                if cameraAccess == .denied { Button("Open Settings", systemImage: "gear") { openSettings() }.accessibilityIdentifier("receipt-camera-settings") }
                            } else {
                                Button("Open Camera", systemImage: "doc.viewfinder") { Task { await openCamera() } }.accessibilityIdentifier("receipt-camera")
                            }
                        }
                        PhotosPicker(selection: $picker, matching: .images) { Label("Choose Receipt Photo", systemImage: "photo") }
                        Text("Scan one receipt. Its photo stays with this draft while you review the details.").foregroundStyle(Color.theme.secondaryText)
                    }
                } header: {
                    Text("Receipt")
                } footer: {
                    Text("Receipts are read on this device first. If a receipt is too long, its recognized text is sent to Apple Private Cloud Compute. This requires an internet connection.")
                }
                if let captured = draft.capture {
                    Section("Captured payment") {
                        if !captured.merchant.isEmpty { Text(captured.merchant) }
                        if !captured.amount.isEmpty { Text(ExpenseValue.displayAmount(captured.amount, currency: captured.currency) ?? [captured.amount, captured.currency].filter { !$0.isEmpty }.joined(separator: " ")) }
                        if let date = captured.date { Text(date.formatted(date: .abbreviated, time: .shortened)) }
                        Text("Payment details are kept here for comparison. Review the fields below before saving.").font(.subheadline).foregroundStyle(Color.theme.secondaryText)
                    }
                }
                if let proposal, !conflicts.isEmpty {
                    Section("Receipt differences") {
                        Text("Your entered details have been kept. Choose which receipt values to use.").foregroundStyle(Color.theme.secondaryText)
                        ForEach(conflicts) { field in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(field.rawValue).font(.headline)
                                Text("Current: \(field.display(draft[keyPath: field.keyPath]))")
                                Text("Receipt: \(field.display(proposal[keyPath: field.keyPath]))")
                                Button("Use receipt \(field.rawValue.lowercased())") {
                                    draft[keyPath: field.keyPath] = proposal[keyPath: field.keyPath]
                                    conflicts.removeAll { $0 == field }
                                }
                                Button("Keep current \(field.rawValue.lowercased())") { conflicts.removeAll { $0 == field } }
                            }
                        }
                    }
                }
                if photo != nil || recordID != nil || business {
                    Section {
                        field("Merchant", text: $draft.merchant, identifier: "expense-merchant")
                        dateField
                        field("Total paid", text: $draft.amount, identifier: "expense-total", decimal: true)
                        DaybookPicker("Currency", selection: $draft.currency, identifier: "expense-currency") {
                            Text("Choose currency").tag("")
                            ForEach(ExpenseValue.currencies, id: \.self) { Text($0).tag($0) }
                        }.accessibilityIdentifier("expense-currency")
                        field("Tax included (optional)", text: $draft.tax, identifier: "expense-tax", decimal: true)
                        DaybookPicker("Category", selection: $draft.category) { ForEach(ExpenseValue.categories, id: \.self) { Text($0).tag($0) } }
                        if business {
                            Toggle("Repeats monthly", isOn: $draft.repeatsMonthly)
                                .accessibilityIdentifier("expense-repeats")
                        } else {
                            Toggle("Reimbursable", isOn: $draft.reimbursable)
                        }
                        field("Notes (optional)", text: $draft.notes, identifier: "expense-notes")
                    } header: { Text("Review details") } footer: {
                        Text([billingNote, "Check the date, currency and final total against the photo. Empty fields need your input. Tax is already included in the total."].compactMap { $0 }.joined(separator: " "))
                    }
                    .disabled(busy)
                }
                if isDraft && recordID != nil {
                    Section {
                        Button("Remove Draft", role: .destructive) { removingDraft = true }
                            .disabled(savingPhoto)
                            .accessibilityIdentifier("remove-expense-draft")
                    } footer: {
                        Text("For personal purchases and duplicates. A repeated Wallet transaction with the same transaction ID won’t recreate it.")
                    }
                }
            }
            .navigationTitle(business ? "Business cost" : isDraft ? "Receipt" : "Expense").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isDraft && recordID != nil ? "Keep Draft" : "Close") { close() }.disabled(savingPhoto)
                        .confirmationDialog("Discard your changes?", isPresented: $discard, titleVisibility: .visible) {
                            Button("Discard Changes", role: .destructive) { dismiss() }
                            Button("Keep Editing", role: .cancel) {}
                        }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(confirmed: true) }.disabled((photo == nil && !business) || busy || !conflicts.isEmpty).accessibilityIdentifier("save-expense")
                }
            }
            .sheet(isPresented: $choosingEvent) {
                ExpenseEventSelection { id in selectedJobID = id; choosingEvent = false }
            }
            .sheet(isPresented: $scanning) {
                ReceiptScanner { result in
                    scanning = false
                    switch result {
                    case .success(let image): if let image { capture { try ReceiptImage.storedJPEG(from: image) } }
                    case .failure(let error): self.error = error.localizedDescription
                    }
                }.ignoresSafeArea()
            }
            .sheet(isPresented: $enlarged) {
                NavigationStack {
                    ScrollView([.horizontal, .vertical]) {
                        if let photo { ReceiptPhotoViewer(photo: photo) }
                    }.navigationTitle("Receipt").navigationBarTitleDisplayMode(.inline)
                        .toolbar { Button("Done") { enlarged = false } }
                }
            }
            .photosPicker(isPresented: $choosingPhoto, selection: $picker, matching: .images)
            .confirmationDialog("Replace the receipt photo?", isPresented: $replacing, titleVisibility: .visible) {
                if VNDocumentCameraViewController.isSupported { Button("Scan Replacement") { Task { await openCamera() } } }
                Button("Choose Replacement Photo") { choosingPhoto = true }
                Button("Keep Current Photo", role: .cancel) {}
            } message: { Text("Your current photo stays until its replacement is saved. Entered payment details will be kept for comparison.") }
            .onChange(of: picker) { _, item in
                guard let item else { return }
                task = Task {
                    do {
                        // Only the encoded bytes are loaded here; ImageIO decodes them at the stored size.
                        guard let data = try await item.loadTransferable(type: Data.self) else { throw RecordError.invalid(ReceiptImage.unreadableMessage) }
                        try Task.checkCancellation(); capture { try ReceiptImage.storedJPEG(from: data) }
                    } catch is CancellationError {} catch { self.error = error.localizedDescription }
                    picker = nil
                }
            }
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.isUITesting, ProcessInfo.processInfo.arguments.contains("--ui-test-expense-conflict"),
                   let recordID, let expense = try? context.existingObject(with: recordID) as? Expense {
                    expense.revision = UUID().uuidString
                    try? context.save()
                }
                #endif
                // Only open the scanner automatically when the camera can actually be used; otherwise the
                // receipt section explains why and offers Settings instead of presenting a blank scanner.
                if recordID == nil && photo == nil && !prefilled && VNDocumentCameraViewController.isSupported && !cameraUnavailable { await openCamera() }
            }
            .task(id: photoVersion) {
                guard let photo else { preview = nil; previewFailed = false; return }
                let image = await Task.detached(priority: .userInitiated) { ReceiptImage.preview(photo) }.value
                guard !Task.isCancelled else { return }
                preview = image; previewFailed = image == nil
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { cameraAccess = AVCaptureDevice.authorizationStatus(for: .video) }
            }
            .alert("Camera access is off", isPresented: $cameraBlocked) {
                if cameraAccess == .denied { Button("Open Settings") { openSettings() } }
                Button(cameraAccess == .denied ? "Not Now" : "OK", role: .cancel) {}
            } message: { Text(cameraUnavailableMessage) }
            .onDisappear { task?.cancel() }
            .interactiveDismissDisabled(savingPhoto || recordID != nil || photo != nil || draft != initial || selectedJobID != initialJobID || business != initialBusiness)
            .preservesDraftOnTodayLink()
            .alert("Couldn’t save changes", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                if failedDraftSave {
                    Button("Close without saving", role: .destructive) { dismiss() }
                    Button("Keep Editing", role: .cancel) { error = nil }
                } else {
                    Button("OK", role: .cancel) { error = nil }
                }
            } message: { Text(error ?? "Please try again.") }
            .alert("Remove this expense draft?", isPresented: $removingDraft) {
                Button("Remove Draft", role: .destructive) { removeDraft() }
                Button("Keep Draft", role: .cancel) {}
            } message: { Text("It leaves your Expenses inbox and any event it was assigned to.") }
            .confirmationDialog("Read the receipt again?", isPresented: $retry, titleVisibility: .visible) {
                Button("Read Receipt Again") { extract() }
                Button("Keep Editing", role: .cancel) {}
            }
        }.presentationSizing(.page).presentationDetents([.large]).presentationBackground(Color.theme.page)
    }
    /// Explains what stays fixed while the receipt is on an active invoice.
    private var billingNote: String? {
        guard let recordID, let expense = try? context.existingObject(with: recordID) as? Expense, !expense.isDraft, expense.job != nil,
              let invoice = try? expense.activeInvoices(index: InvoiceIndex(in: context)).first, let value = try? invoice.currentValue(),
              let line = value.expenseLines.first(where: { $0.expenseID == expense.id }) else { return nil }
        if value.status == "draft" { return "On a draft invoice. Remove it there before changing its event, currency or reimbursable setting." }
        return "Billed on \(value.reference) as \(Money.format(line.amount, currency: value.currency)). Its event, currency and reimbursable setting stay as billed, and correcting the total does not change the sent invoice."
    }
    /// The receipt date stays empty until it is read or chosen, so a blank never silently becomes today.
    @ViewBuilder private var dateField: some View {
        if draft.day.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Date").font(.subheadline).foregroundStyle(Color.theme.secondaryText)
                Button("Add Date") { draft.day = Day.string(from: Date()) }.accessibilityIdentifier("expense-date")
            }
        } else {
            DatePicker("Date", selection: Binding(get: { Day.date(from: draft.day) ?? Date() }, set: { draft.day = Day.string(from: $0) }),
                       displayedComponents: .date).accessibilityIdentifier("expense-date")
        }
    }
    private func field(_ label: String, text: Binding<String>, identifier: String, decimal: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline).foregroundStyle(Color.theme.secondaryText)
            DaybookTextField(label, text: text).keyboardType(decimal ? .decimalPad : .default).accessibilityIdentifier(identifier)
        }
    }
    private var cameraUnavailable: Bool { cameraAccess == .denied || cameraAccess == .restricted }
    private var cameraUnavailableMessage: String {
        cameraAccess == .restricted
            ? "Camera access is restricted on this device. Choose a receipt photo instead."
            : "Allow camera access in Settings to scan receipts, or choose a receipt photo instead."
    }
    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
    }
    private func openCamera() async {
        // The person just answered the system prompt, so don't follow a refusal with another alert.
        let prompted = cameraAccess == .notDetermined
        if prompted { _ = await AVCaptureDevice.requestAccess(for: .video) }
        cameraAccess = AVCaptureDevice.authorizationStatus(for: .video)
        if cameraAccess == .authorized { scanning = true } else if !prompted { cameraBlocked = true }
    }
    /// `encode` produces the stored JPEG off the main thread; a photo that can't be decoded leaves the current one in place.
    private func capture(_ encode: @escaping @Sendable () throws -> Data) {
        guard !busy else { return }
        busy = true; savingPhoto = true
        task = Task {
            defer { savingPhoto = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) { try encode() }.value
                try Task.checkCancellation()
                let id: NSManagedObjectID
                if let recordID {
                    try await Expense.replacePhotoAsync(data, id: recordID, revision: revision, in: context)
                    id = recordID
                } else {
                    guard selectedJobID != nil || business else { throw RecordError.invalid("Choose an event before scanning a new receipt.") }
                    id = try await Expense.capturePhoto(data, jobID: business ? nil : selectedJobID, in: context)
                }
                let record = try context.existingObject(with: id) as! Expense
                recordID = id; revision = record.revision; photo = data; photoVersion += 1
                if !Task.isCancelled { extract() } else { busy = false }
            } catch { busy = false; self.error = error.localizedDescription }
        }
    }
    private func extract() {
        guard let photo else { return }
        task?.cancel(); busy = true; message = nil; processingLocation = .device
        task = Task {
            do {
                let result = try await ReceiptExtractor.extract(photo) { location in
                    guard !Task.isCancelled else { return }
                    processingLocation = location
                }
                try Task.checkCancellation()
                proposal = result.expense; conflicts = draft.fillBlanks(from: result.expense)
                message = result.location.completionMessage
            } catch is CancellationError { return }
            catch {
                guard !Task.isCancelled else { return }
                message = error.localizedDescription
            }
            busy = false
        }
    }
    private func removeDraft() {
        guard let recordID else { return }
        task?.cancel(); busy = false
        do {
            let id = (try? context.existingObject(with: recordID) as? Expense)?.id
            try Expense.discardDraft(id: recordID, revision: revision, in: context)
            if let id { ExpenseNotifications.shared.clear(id: id) }
            dismiss()
        } catch { self.error = error.localizedDescription }
    }
    private func close() {
        task?.cancel(); busy = false
        if isDraft && recordID != nil { save(confirmed: false) }
        else if draft != initial || selectedJobID != initialJobID || business != initialBusiness { discard = true }
        else { dismiss() }
    }
    private func save(confirmed: Bool) {
        failedDraftSave = false
        guard let recordID else {
            // A business cost can be saved without a receipt photo.
            guard business, confirmed else { return }
            do { _ = try Expense.createBusiness(draft, in: context); dismiss() } catch { self.error = error.localizedDescription }
            return
        }
        do {
            try Expense.save(draft, id: recordID, revision: revision, confirmed: confirmed, jobID: business ? nil : selectedJobID, business: business, in: context)
            if confirmed, let expense = try context.existingObject(with: recordID) as? Expense, let id = expense.id { ExpenseNotifications.shared.clear(id: id) }
            dismiss()
        } catch {
            failedDraftSave = isDraft
            self.error = error.localizedDescription
        }
    }
}

/// The full stored photo, decoded off the main thread only while the viewer is open.
private struct ReceiptPhotoViewer: View {
    let photo: Data
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { Image(uiImage: image).accessibilityLabel("Receipt photo") }
            else if failed { Text("This receipt photo can’t be shown.").foregroundStyle(Color.theme.secondaryText).padding() }
            else { ProgressView().padding() }
        }
        .task {
            let photo = photo
            let decoded = await Task.detached(priority: .userInitiated) { ReceiptImage.preview(photo, maxPixels: ReceiptImage.storedPixels) }.value
            image = decoded; failed = decoded == nil
        }
    }
}

private struct ReceiptScanner: UIViewControllerRepresentable {
    let completion: (Result<UIImage?, Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController {
        let controller = VNDocumentCameraViewController(); controller.delegate = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: VNDocumentCameraViewController, context: Context) {}
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let completion: (Result<UIImage?, Error>) -> Void
        init(completion: @escaping (Result<UIImage?, Error>) -> Void) { self.completion = completion }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { completion(.success(nil)) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { completion(.failure(error)) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard scan.pageCount == 1 else { completion(.failure(RecordError.invalid("Scan one receipt page at a time. Please scan this receipt again as a single page."))); return }
            completion(.success(scan.imageOfPage(at: 0)))
        }
    }
}
