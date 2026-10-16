import CoreData
import PhotosUI
import SwiftUI
import VisionKit

struct ExpensesView: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.horizontalSizeClass) private var sizeClass
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Expense.createdAt, ascending: false)]) private var expenses: FetchedResults<Expense>
    // Observe event changes too, including deletion/restoration and renamed clients.
    @FetchRequest(sortDescriptors: []) private var jobs: FetchedResults<Job>
    @FetchRequest(sortDescriptors: []) private var clients: FetchedResults<Client>
    @State private var scope = "All"
    @State private var selected: Expense?
    @State private var choosingEvent = false
    @State private var captureJob: Job?

    private var visibleExpenses: [Expense] {
        _ = jobs.count + clients.count
        return expenses.filter { expense in
            let value = expense.value
            let matchesScope = scope == "All" || (scope == "Saved" ? !expense.isDraft : expense.isDraft)
            return value.discarded != true && matchesScope
        }.sorted {
            let lhs = $0.value.day, rhs = $1.value.day
            if lhs != rhs { return lhs > rhs }
            return ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast)
        }
    }

    var body: some View {
        let records = visibleExpenses
        DaybookForm(topPadding: 12) {
            Section {
                DaybookTabHeader {
                    Button("Scan Receipt", systemImage: "doc.viewfinder") { choosingEvent = true }
                        .buttonStyle(DaybookPrimaryButton())
                        .accessibilityIdentifier("scan-receipt-overview")
                }
            }.containerValue(\.daybookUnframed, true)
                .containerValue(\.daybookFlushTop, true)
            Section {
                DaybookSegments(title: "Show expenses", selection: $scope,
                                options: ["All", "Saved", "Needs review"],
                                identifier: "expense-scope", label: { $0 })
            }.containerValue(\.daybookUnframed, true)
            Section { PendingExpensesPrompt() }
            if records.isEmpty {
                Section {
                    ContentUnavailableView("No expenses to show", systemImage: "receipt",
                        description: Text(scope == "All"
                            ? "Scan a receipt to record an expense for an event. Captured payment drafts appear here too."
                            : "Choose a different expense filter."))
                }
            } else {
                Section {
                    ForEach(records, id: \.objectID) { expense in
                        if expense.job?.deletedAt != nil {
                            expenseRow(expense)
                        } else {
                            Button { selected = expense } label: { expenseRow(expense) }
                                .accessibilityIdentifier("all-expense-row")
                        }
                    }
                }
            }
        }
        .navigationTitle("").navigationBarTitleDisplayMode(.inline)
        .toolbar(sizeClass == .compact ? .hidden : .visible, for: .navigationBar)
        .sheet(item: $selected) { ExpenseEditorView(expense: $0) }
        .sheet(isPresented: $choosingEvent, onDismiss: {
            if let job = captureJob { selectedCaptureJob = job; captureJob = nil }
        }) {
            ExpenseEventSelection { id in
                captureJob = jobs.first { $0.objectID == id }
                choosingEvent = false
            }
        }
        .sheet(isPresented: Binding(get: { selectedCaptureJob != nil }, set: { if !$0 { selectedCaptureJob = nil } })) {
            if let job = selectedCaptureJob { ExpenseEditorView(job: job) }
        }
    }

    @State private var selectedCaptureJob: Job?

    private func expenseRow(_ expense: Expense) -> some View {
        let value = expense.value
        let headingLayout = typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4))
            : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        return VStack(alignment: .leading, spacing: 4) {
            headingLayout {
                Text(value.merchant.isEmpty ? "Expense to complete" : value.merchant)
                    .font(.headline)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if let amount = try? Money.parse(value.amount), !value.currency.isEmpty {
                    Text(Money.format(amount, currency: value.currency))
                        .font(.subheadline.weight(.semibold)).monospacedDigit()
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            Text([expense.job?.eventTitle ?? "Event to choose", expense.job?.client?.name]
                .compactMap { $0 }.joined(separator: " · "))
                .font(.subheadline).foregroundStyle(Color("SecondaryText"))
            Text([expense.isDraft ? "Needs review" : "", value.day, value.category,
                  value.reimbursable ? "Reimbursable" : ""]
                .filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.caption)
                .foregroundStyle(Color(expense.isDraft ? "AmberText" : "SecondaryText"))
            if expense.job?.deletedAt != nil {
                Text("Deleted event · Restore the event in Settings to open this expense.")
                    .font(.caption).foregroundStyle(Color("SecondaryText"))
            }
        }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
    }
}

struct EventExpensesSection: View {
    @ObservedObject var job: Job
    @FetchRequest private var expenses: FetchedResults<Expense>
    @State private var adding = false
    @State private var selected: Expense?
    init(job: Job) {
        self.job = job
        _expenses = FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Expense.createdAt, ascending: false)], predicate: NSPredicate(format: "job == %@", job))
    }
    var body: some View {
        Section("Expenses") {
            ForEach(expenses.filter { $0.value.discarded != true }, id: \.objectID) { expense in
                Button { selected = expense } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(expense.isDraft ? "Review receipt" : expense.value.merchant).font(.headline)
                        if expense.isDraft { Text(expense.photo == nil ? "Receipt to add · Details to confirm" : "Photo saved · Details to confirm").font(.subheadline) }
                        else {
                            Text("\(Money.format((try? Money.parse(expense.value.amount)) ?? 0, currency: expense.value.currency)) · \(expense.value.day)").font(.subheadline)
                        }
                    }.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }.accessibilityIdentifier("expense-row")
            }
            Button("Scan Receipt", systemImage: "doc.viewfinder") { adding = true }
                .buttonStyle(DaybookSecondaryButton()).accessibilityIdentifier("scan-receipt")
        }
        .sheet(isPresented: $adding) { ExpenseEditorView(job: job) }
        .sheet(item: $selected) { ExpenseEditorView(job: job, expense: $0) }
    }
}

struct ExpenseEditorView: View {
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
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
    @State private var picker: PhotosPickerItem?
    @State private var busy = false
    @State private var savingPhoto = false
    @State private var processingLocation = ReceiptExtractor.ProcessingLocation.device
    @State private var task: Task<Void, Never>?
    @State private var message: String?
    @State private var error: String?
    @State private var discard = false
    @State private var retry = false
    @State private var replacing = false
    @State private var choosingPhoto = false
    @State private var enlarged = false

    init(job: Job? = nil, expense: Expense? = nil) {
        self.job = job
        initialJobID = expense?.job?.objectID ?? job?.objectID
        _selectedJobID = State(initialValue: initialJobID)
        let value = expense?.value ?? ExpenseValue()
        _draft = State(initialValue: value); _initial = State(initialValue: value)
        _recordID = State(initialValue: expense?.objectID); _revision = State(initialValue: expense?.revision ?? "")
        _photo = State(initialValue: expense?.photo); _isDraft = State(initialValue: expense?.isDraft ?? true)
    }
    var body: some View {
        NavigationStack {
            DaybookForm {
                Section {
                    if let selected = events.first(where: { $0.objectID == selectedJobID }) {
                        Text(selected.eventTitle).font(.headline)
                        if let client = selected.client { Text(client.name).foregroundStyle(Color("SecondaryText")) }
                    } else { Text("Choose an event to complete this expense.").foregroundStyle(Color("SecondaryText")) }
                    Button(selectedJobID == nil ? "Choose Event" : "Change Event") { choosingEvent = true }.accessibilityIdentifier("expense-choose-event")
                }.containerValue(\.daybookUnframed, true)
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
                            Button("Open Camera", systemImage: "doc.viewfinder") { scanning = true }.accessibilityIdentifier("receipt-camera")
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
                        if !captured.amount.isEmpty { Text([captured.amount, captured.currency].filter { !$0.isEmpty }.joined(separator: " ")) }
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
                                Text("Current: \(draft[keyPath: field.keyPath])")
                                Text("Receipt: \(proposal[keyPath: field.keyPath])")
                                Button("Use receipt \(field.rawValue.lowercased())") {
                                    draft[keyPath: field.keyPath] = proposal[keyPath: field.keyPath]
                                    conflicts.removeAll { $0 == field }
                                }
                                Button("Keep current \(field.rawValue.lowercased())") { conflicts.removeAll { $0 == field } }
                            }
                        }
                    }
                }
                if photo != nil || recordID != nil {
                    Section {
                        field("Merchant", text: $draft.merchant, identifier: "expense-merchant")
                        field("Date (YYYY-MM-DD)", text: $draft.day, identifier: "expense-date")
                        field("Total paid", text: $draft.amount, identifier: "expense-total", decimal: true)
                        DaybookPicker("Currency", selection: $draft.currency, identifier: "expense-currency") {
                            Text("Choose currency").tag("")
                            ForEach(ExpenseValue.currencies, id: \.self) { Text($0).tag($0) }
                        }.accessibilityIdentifier("expense-currency")
                        field("Tax included (optional)", text: $draft.tax, identifier: "expense-tax", decimal: true)
                        DaybookPicker("Category", selection: $draft.category) { ForEach(ExpenseValue.categories, id: \.self) { Text($0).tag($0) } }
                        Toggle("Reimbursable", isOn: $draft.reimbursable)
                        field("Notes (optional)", text: $draft.notes, identifier: "expense-notes")
                    } header: { Text("Review details") } footer: { Text("Check the date, currency and final total against the photo. Empty fields need your input. Tax is already included in the total.") }
                    .disabled(busy)
                }
            }
            .navigationTitle(isDraft ? "Receipt" : "Expense").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(isDraft && recordID != nil ? "Keep Draft" : "Close") { close() }.disabled(savingPhoto)
                        .confirmationDialog("Discard your changes?", isPresented: $discard, titleVisibility: .visible) {
                            Button("Discard Changes", role: .destructive) { dismiss() }
                            Button("Keep Editing", role: .cancel) {}
                        }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(confirmed: true) }.disabled(photo == nil || busy || !conflicts.isEmpty).accessibilityIdentifier("save-expense")
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
                if VNDocumentCameraViewController.isSupported { Button("Scan Replacement") { scanning = true } }
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
            .task { if recordID == nil && photo == nil && VNDocumentCameraViewController.isSupported { scanning = true } }
            .onDisappear { task?.cancel() }
            .interactiveDismissDisabled(savingPhoto || recordID != nil || photo != nil || draft != initial || selectedJobID != initialJobID)
            .saveErrorAlert($error)
            .confirmationDialog("Read the receipt again?", isPresented: $retry, titleVisibility: .visible) {
                Button("Read Receipt Again") { extract() }
                Button("Keep Editing", role: .cancel) {}
            }
        }.presentationSizing(.page).presentationDetents([.large]).presentationBackground(Color("PageBackground"))
    }
    private func field(_ label: String, text: Binding<String>, identifier: String, decimal: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).font(.subheadline).foregroundStyle(Color("SecondaryText"))
            DaybookTextField(label, text: text).keyboardType(decimal ? .decimalPad : .default).accessibilityIdentifier(identifier)
        }
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
                    guard let selectedJobID else { throw RecordError.invalid("Choose an event before scanning a new receipt.") }
                    id = try await Expense.capturePhoto(data, jobID: selectedJobID, in: context)
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
        else if draft != initial || selectedJobID != initialJobID { discard = true }
        else { dismiss() }
    }
    private func save(confirmed: Bool) {
        guard let recordID else { return }
        do {
            try Expense.save(draft, id: recordID, revision: revision, confirmed: confirmed, jobID: selectedJobID, in: context)
            if confirmed, let expense = try context.existingObject(with: recordID) as? Expense, let id = expense.id { ExpenseNotifications.shared.clear(id: id) }
            dismiss()
        } catch { self.error = error.localizedDescription }
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
