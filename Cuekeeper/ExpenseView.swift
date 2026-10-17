import AVFoundation
import CoreData
import PhotosUI
import SwiftUI
import VisionKit

/// Expenses as a month: money by state per currency, what to finish and rebill, then every expense by day.
struct ExpensesView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Expense.createdAt, ascending: false)]) private var expenses: FetchedResults<Expense>
    // Observe events, clients and invoices too: renames, deletions and billing change what rows show.
    @FetchRequest(sortDescriptors: []) private var jobs: FetchedResults<Job>
    @FetchRequest(sortDescriptors: []) private var clients: FetchedResults<Client>
    @FetchRequest(sortDescriptors: []) private var invoiceRevisions: FetchedResults<InvoiceRevision>
    @FetchRequest(sortDescriptors: []) private var payments: FetchedResults<PaymentRecord>
    @State private var month = PaymentsView.currentMonth
    @State private var filter = ExpenseFilter.all
    @SceneStorage("expenses.finishExpanded") private var finishExpanded = false
    @State private var sheet: ExpenseSheet?
    @State private var choosingEvent = false
    @State private var pendingCapture: ExpenseSheet?
    @State private var invoicing: ReadyInvoice?

    var body: some View {
        _ = jobs.count + clients.count + invoiceRevisions.count + payments.count
        let summary = ExpensesMonth.load(month: month, expenses: Array(expenses), context: context)
        let days = summary.days(filter)
        return DaybookForm(topPadding: 12) {
            Section {
                DaybookTabHeader {
                    Button("Scan Receipt", systemImage: "doc.viewfinder") { choosingEvent = true }
                        .buttonStyle(DaybookPrimaryButton())
                        .accessibilityIdentifier("scan-receipt-overview")
                }
            }.containerValue(\.daybookUnframed, true).containerValue(\.daybookFlushTop, true)
            Section {
                MonthStepper(month: $month, eventCount: summary.count, noun: (one: "expense", many: "expenses"))
            }.containerValue(\.daybookUnframed, true)
            if !summary.currencies.isEmpty {
                Section { ExpenseMoneyPanel(currencies: summary.currencies) }
            }
            if !summary.finish.isEmpty {
                Section {
                    finishHeader(summary.finish.count)
                    ForEach(Array((finishExpanded ? summary.finish : Array(summary.finish.prefix(1))).enumerated()), id: \.element.id) { index, item in
                        finishRow(item, primary: index == 0)
                    }
                }
            }
            if !summary.rebill.isEmpty {
                Section {
                    ForEach(summary.rebill) { rebillRow($0) }
                } header: { Text("To rebill") }
            }
            Section {
                DaybookSegments(title: "Show expenses", selection: $filter, options: ExpenseFilter.allCases,
                                identifier: "expense-filter", label: \.rawValue)
            } header: { Text("Expenses") }
                .containerValue(\.daybookUnframed, true)
            if days.isEmpty {
                Section {
                    ContentUnavailableView(filter == .all ? "No expenses in \(MonthStepper.title(month))" : "No \(filter.rawValue.lowercased()) expenses",
                                           systemImage: "receipt",
                                           description: Text(filter == .all ? "Scan a receipt or add a business cost." : "Choose All to see every expense."))
                }
            } else {
                Section {
                    ForEach(days) { dayRow($0) }
                }
            }
            if summary.earlier.count > 0 {
                Section {
                    Button { month = summary.earlier.latestMonth } label: { earlierRow(summary.earlier) }
                        .buttonStyle(.plain)
                        .accessibilityIdentifier("expenses-earlier-rebill")
                }
            }
        }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar(sizeClass == .compact ? .hidden : .visible, for: .navigationBar)
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

    // MARK: To finish

    private func finishHeader(_ count: Int) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) { finishExpanded.toggle() }
        } label: {
            HStack(spacing: 8) {
                Text("To finish").font(.headline)
                AmberCount(count: count)
                Spacer(minLength: 8)
                Image(systemName: finishExpanded ? "chevron.up" : "chevron.down")
                    .font(.footnote.weight(.semibold)).foregroundStyle(Color("SecondaryText"))
                    .accessibilityHidden(true)
            }
            .frame(minHeight: 32).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("To finish, \(count)")
        .accessibilityValue(finishExpanded ? "Expanded" : "Collapsed")
        .accessibilityIdentifier("expenses-finish-toggle")
    }

    private func finishRow(_ item: FinishItem, primary: Bool) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title).font(.subheadline.weight(.semibold))
                Text(item.detail).font(.footnote).foregroundStyle(Color("SecondaryText"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Group {
                if primary {
                    Button(item.actionTitle) { perform(item) }.buttonStyle(DaybookPrimaryButton()).controlSize(.small)
                } else {
                    Button(item.actionTitle) { perform(item) }.font(.subheadline.weight(.semibold)).frame(minWidth: 44, minHeight: 44)
                }
            }
            .accessibilityIdentifier("expenses-finish-\(item.actionTitle.lowercased())")
        }
    }

    private func perform(_ item: FinishItem) {
        switch item.kind {
        case .draft(let id):
            if let expense = expenses.first(where: { $0.id == id }) { sheet = .edit(expense) }
        case let .repeatDue(template, day):
            guard let expense = expenses.first(where: { $0.id == template }) else { return }
            var value = expense.value
            value.day = day; value.capture = nil; value.notes = ""
            sheet = .business(value)
        }
    }

    // MARK: To rebill

    private func rebillRow(_ group: RebillGroup) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        return layout {
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).font(.headline)
                Text((group.events + [group.receipts.count == 1 ? "1 receipt" : "\(group.receipts.count) receipts", Money.format(group.amount, currency: group.currency)])
                    .joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(Color("SecondaryText"))
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
                    Text(Day.display(day.day)).font(.subheadline.weight(.semibold)).foregroundStyle(Color.accentColor).padding(.bottom, 6)
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
                    .font(.caption).foregroundStyle(Color("SecondaryText"))
            }
        }
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }

    private func subtitle(_ fact: ExpenseFact) -> Text {
        if fact.isBusiness { return Text("Business · \(fact.category)").foregroundStyle(Color("SecondaryText")) }
        guard let event = fact.eventTitle else { return Text("Event to choose").foregroundStyle(Color("AmberText")) }
        return Text(fact.state == .toFinish && fact.merchant.isEmpty ? event : "\(event) · \(fact.category)").foregroundStyle(Color("SecondaryText"))
    }

    @ViewBuilder private func status(_ fact: ExpenseFact) -> some View {
        switch fact.state {
        case .toFinish: Text("To finish").foregroundStyle(Color("AmberText"))
        case .yourCost: Text("Your cost").foregroundStyle(Color("SecondaryText"))
        case .business:
            if fact.repeats { Label("Monthly", systemImage: "repeat").labelStyle(.titleAndIcon).foregroundStyle(Color("SecondaryText")) }
        case .toRebill: Text("To rebill").foregroundStyle(Color("BookingCompleted"))
        case .onInvoice(let reference): Text(reference.isEmpty ? "On draft invoice" : "On \(reference)").foregroundStyle(Color("SecondaryText"))
        case .paidBack: Text("Paid back").foregroundStyle(Color.accentColor)
        case .review: Text("Billing review").foregroundStyle(Color("AmberText"))
        }
    }

    private func earlierRow(_ earlier: EarlierRebill) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Still to rebill from earlier")
                Text(([earlier.count == 1 ? "1 receipt" : "\(earlier.count) receipts"]
                      + earlier.amounts.keys.sorted().map { Money.format(earlier.amounts[$0]!, currency: $0) }).joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(Color("SecondaryText"))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(Color("SecondaryText")).accessibilityHidden(true)
        }
        .frame(minHeight: 44).contentShape(Rectangle())
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
            .foregroundStyle(Color("AmberText"))
            .padding(.horizontal, 7).padding(.vertical, 2)
            .background(Color.orange.opacity(0.18), in: Capsule())
    }
}

extension ExpenseBucket {
    var fill: Color {
        switch self {
        case .paidBack: Color.accentColor
        case .onInvoice: Color.accentColor.opacity(0.55)
        case .toRebill: Color("BookingCompleted")
        case .toFinish: Color.orange
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
                    VStack(alignment: .leading, spacing: 5) {
                        Text(expense.isDraft ? "Review receipt" : expense.value.merchant).font(.headline)
                        if expense.isDraft { Text(expense.photo == nil ? "Receipt to add · Details to confirm" : "Photo saved · Details to confirm").font(.subheadline) }
                        else {
                            Text("\(ExpenseValue.displayAmount(expense.value.amount, currency: expense.value.currency) ?? "Total to check") · \(Day.display(expense.value.day))").font(.subheadline)
                        }
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.accessibilityIdentifier("expense-row")
            }
            Button("Scan Receipt", systemImage: "doc.viewfinder") { if let onOpen { onOpen(nil) } else { adding = true } }
                .buttonStyle(DaybookSecondaryButton()).accessibilityIdentifier("scan-receipt")
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
                        if let client = selected.client { Text(client.name).foregroundStyle(Color("SecondaryText")) }
                    } else { Text("Choose an event to complete this expense.").foregroundStyle(Color("SecondaryText")) }
                    Button(selectedJobID == nil ? "Choose Event" : "Change Event") { choosingEvent = true }.accessibilityIdentifier("expense-choose-event")
                }.containerValue(\.daybookUnframed, true)
                }
                Section {
                    if let photo, let image = UIImage(data: photo) {
                        Button { enlarged = true } label: {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 220)
                        }.accessibilityLabel("View full receipt photo")
                        if busy {
                            ProgressView(processingLocation.progressMessage)
                            Button("Enter details myself") { task?.cancel(); busy = false; message = "Check the receipt and enter its details below." }.disabled(savingPhoto)
                        } else {
                            if let message { Text(message).font(.subheadline).foregroundStyle(Color("SecondaryText")) }
                            if isDraft {
                                Button("Read Receipt Again") { retry = true }
                                Button("Replace Receipt Photo") { replacing = true }
                            }
                        }
                    } else {
                        if VNDocumentCameraViewController.isSupported {
                            if cameraUnavailable {
                                Text(cameraUnavailableMessage).foregroundStyle(Color("SecondaryText"))
                                if cameraAccess == .denied { Button("Open Settings", systemImage: "gear") { openSettings() }.accessibilityIdentifier("receipt-camera-settings") }
                            } else {
                                Button("Open Camera", systemImage: "doc.viewfinder") { Task { await openCamera() } }.accessibilityIdentifier("receipt-camera")
                            }
                        }
                        PhotosPicker(selection: $picker, matching: .images) { Label("Choose Receipt Photo", systemImage: "photo") }
                        Text("Scan one receipt. Its photo stays with this draft while you review the details.").foregroundStyle(Color("SecondaryText"))
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
                        Text("Payment details are kept here for comparison. Review the fields below before saving.").font(.subheadline).foregroundStyle(Color("SecondaryText"))
                    }
                }
                if let proposal, !conflicts.isEmpty {
                    Section("Receipt differences") {
                        Text("Your entered details have been kept. Choose which receipt values to use.").foregroundStyle(Color("SecondaryText"))
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
                    case .success(let image): if let image { capture(image) }
                    case .failure(let error): self.error = error.localizedDescription
                    }
                }.ignoresSafeArea()
            }
            .sheet(isPresented: $enlarged) {
                NavigationStack {
                    ScrollView([.horizontal, .vertical]) {
                        if let photo, let image = UIImage(data: photo) { Image(uiImage: image).accessibilityLabel("Receipt photo") }
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
                        guard let data = try await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else { throw RecordError.invalid("This photo could not be opened. Choose another image.") }
                        try Task.checkCancellation(); capture(image)
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
            .confirmationDialog("Read the receipt again?", isPresented: $retry, titleVisibility: .visible) {
                Button("Read Receipt Again") { extract() }
                Button("Keep Editing", role: .cancel) {}
            }
        }.presentationSizing(.page).presentationDetents([.large]).presentationBackground(Color("PageBackground"))
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
                Text("Date").font(.subheadline).foregroundStyle(Color("SecondaryText"))
                Button("Add Date") { draft.day = Day.string(from: Date()) }.accessibilityIdentifier("expense-date")
            }
        } else {
            DatePicker("Date", selection: Binding(get: { Day.date(from: draft.day) ?? Date() }, set: { draft.day = Day.string(from: $0) }),
                       displayedComponents: .date).accessibilityIdentifier("expense-date")
        }
    }
    private func field(_ label: String, text: Binding<String>, identifier: String, decimal: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline).foregroundStyle(Color("SecondaryText"))
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
    private func capture(_ image: UIImage) {
        guard !busy else { return }
        busy = true; savingPhoto = true
        task = Task {
            defer { savingPhoto = false }
            do {
                let data = try await Task.detached(priority: .userInitiated) {
                    let scale = min(1, 2400 / max(image.size.width, image.size.height))
                    let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
                    let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
                    guard let data = normalized.jpegData(compressionQuality: 0.88) else { throw RecordError.invalid("The receipt photo could not be saved. Please try again.") }
                    return data
                }.value
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
                recordID = id; revision = record.revision; photo = data
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
