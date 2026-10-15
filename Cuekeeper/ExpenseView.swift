import CoreData
import PhotosUI
import SwiftUI
import VisionKit

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
            ForEach(expenses, id: \.objectID) { expense in
                Button { selected = expense } label: {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(expense.isDraft ? "Review receipt" : expense.value.merchant).font(.headline)
                        if expense.isDraft { Text("Photo saved · Details to confirm").font(.subheadline) }
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
    let job: Job
    @State private var recordID: NSManagedObjectID?
    @State private var revision: String
    @State private var draft: ExpenseValue
    @State private var initial: ExpenseValue
    @State private var isDraft: Bool
    @State private var photo: Data?
    @State private var scanning = false
    @State private var picker: PhotosPickerItem?
    @State private var busy = false
    @State private var task: Task<Void, Never>?
    @State private var message: String?
    @State private var error: String?
    @State private var discard = false
    @State private var retry = false
    @State private var replacing = false
    @State private var choosingPhoto = false
    @State private var enlarged = false

    init(job: Job, expense: Expense? = nil) {
        self.job = job
        let value = expense?.value ?? ExpenseValue()
        _draft = State(initialValue: value); _initial = State(initialValue: value)
        _recordID = State(initialValue: expense?.objectID); _revision = State(initialValue: expense?.revision ?? "")
        _photo = State(initialValue: expense?.photo); _isDraft = State(initialValue: expense?.isDraft ?? true)
    }
    var body: some View {
        NavigationStack {
            DaybookForm {
                Section {
                    Text(job.eventTitle).font(.headline)
                    if let client = job.client { Text(client.name).foregroundStyle(Color("SecondaryText")) }
                }.containerValue(\.daybookUnframed, true)
                Section("Receipt") {
                    if let photo, let image = UIImage(data: photo) {
                        Button { enlarged = true } label: {
                            Image(uiImage: image).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 220)
                        }.accessibilityLabel("View full receipt photo")
                        if busy {
                            ProgressView("Reading receipt on this device…")
                            Button("Enter details myself") { task?.cancel(); busy = false; message = "Check the receipt and enter its details below." }
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
                        Text("Scan one receipt. Its photo stays attached to this event while you review the details.").foregroundStyle(Color("SecondaryText"))
                    }
                }
                if photo != nil {
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
                ToolbarItem(placement: .cancellationAction) { Button(isDraft && photo != nil ? "Keep Draft" : "Close") { close() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save(confirmed: true) }.disabled(photo == nil || busy).accessibilityIdentifier("save-expense")
                }
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
            .confirmationDialog("Replace the photo and reread its details?", isPresented: $replacing, titleVisibility: .visible) {
                if VNDocumentCameraViewController.isSupported { Button("Scan Replacement") { scanning = true } }
                Button("Choose Replacement Photo") { choosingPhoto = true }
                Button("Keep Current Photo", role: .cancel) {}
            } message: { Text("Your current photo and form stay unchanged until a replacement photo is saved.") }
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
            .task { if photo == nil && VNDocumentCameraViewController.isSupported { scanning = true } }
            .onDisappear { task?.cancel() }
            .interactiveDismissDisabled(photo != nil || draft != initial)
            .saveErrorAlert($error)
            .confirmationDialog("Discard your changes?", isPresented: $discard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
            .confirmationDialog("Replace the form with a new reading?", isPresented: $retry, titleVisibility: .visible) {
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
        do {
            let scale = min(1, 2400 / max(image.size.width, image.size.height))
            let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
            let format = UIGraphicsImageRendererFormat(); format.scale = 1; format.opaque = true
            let normalized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
            guard let data = normalized.jpegData(compressionQuality: 0.88) else { throw RecordError.invalid("The receipt photo could not be saved. Please try again.") }
            let id: NSManagedObjectID
            if let recordID {
                try Expense.replacePhoto(data, id: recordID, revision: revision, in: context)
                id = recordID
            } else { id = try Expense.capture(data, jobID: job.objectID, in: context) }
            let record = try context.existingObject(with: id) as! Expense
            recordID = id; revision = record.revision; photo = data; draft = ExpenseValue()
            extract()
        } catch { self.error = error.localizedDescription }
    }
    private func extract() {
        guard let photo else { return }
        task?.cancel(); busy = true; message = nil
        task = Task {
            do {
                let value = try await ReceiptExtractor.extract(photo)
                try Task.checkCancellation()
                draft = value
                message = "Details filled on this device. Review them before saving."
            } catch is CancellationError { return }
            catch { message = error.localizedDescription }
            busy = false
        }
    }
    private func close() {
        task?.cancel(); busy = false
        if isDraft && photo != nil { save(confirmed: false) }
        else if draft != initial { discard = true }
        else { dismiss() }
    }
    private func save(confirmed: Bool) {
        guard let recordID else { return }
        do {
            try Expense.save(draft, id: recordID, revision: revision, confirmed: confirmed, in: context)
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
