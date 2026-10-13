import CoreData
import SwiftUI

enum LibraryKind {
    case client, role
    var entity: String { self == .client ? "Client" : "WorkRole" }
    var title: String { self == .client ? "Clients" : "Roles" }
    var singular: String { self == .client ? "Client" : "Role" }
}

struct LibraryView: View {
    let kind: LibraryKind
    @FetchRequest private var records: FetchedResults<NSManagedObject>
    @State private var adding = false
    @State private var query = ""
    init(kind: LibraryKind) {
        self.kind = kind
        let request = NSFetchRequest<NSManagedObject>(entityName: kind.entity)
        request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        _records = FetchRequest(fetchRequest: request)
    }
    var body: some View {
        List {
            ForEach(records.filter { query.isEmpty || ($0.value(forKey: "name") as? String ?? "").localizedCaseInsensitiveContains(query) }, id: \.objectID) { record in
                NavigationLink {
                    LibraryDetailView(record: record, kind: kind)
                } label: { Text(record.value(forKey: "name") as? String ?? "") }
            }
        }
        .overlay {
            if records.isEmpty {
                ContentUnavailableView("No \(kind.title.lowercased()) yet", systemImage: kind == .client ? "person.2" : "person.text.rectangle",
                    description: Text("Add one here or while editing a job."))
            }
        }
        .navigationTitle(kind.title)
        .searchable(text: $query)
        .toolbar { Button("Add \(kind.singular)", systemImage: "plus") { adding = true } }
        .sheet(isPresented: $adding) { LibraryEditor(kind: kind) }
    }
}

struct LibraryDetailView: View {
    @ObservedObject var record: NSManagedObject
    let kind: LibraryKind
    @State private var editing = false
    private var jobs: [Job] {
        var related = (record.value(forKey: "jobs") as? Set<Job>) ?? []
        if let role = record as? WorkRole {
            related.formUnion((role.sessions ?? []).filter { $0.deletedAt == nil }.compactMap(\.job))
        }
        return related.sorted { $0.startDay > $1.startDay }
    }
    var body: some View {
        Form {
            if let client = record as? Client {
                Section("Client") {
                    if !client.contact.isEmpty { LabeledContent("Contact", value: client.contact).textSelection(.enabled) }
                    LabeledContent("Default currency", value: client.defaultCurrency)
                    if !client.notes.isEmpty { Text(client.notes).textSelection(.enabled) }
                }
            }
            if let client = record as? Client {
                Section("Related invoices") {
                    if (client.invoices ?? []).isEmpty { Text("No invoices yet").foregroundStyle(.secondary) }
                    ForEach((client.invoices ?? []).sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }, id: \.objectID) { invoice in
                        NavigationLink { InvoiceDetailView(invoice: invoice) } label: { InvoiceRow(invoice: invoice) }
                    }
                }
            }
            Section("Related jobs") {
                if jobs.isEmpty { Text("No jobs yet").foregroundStyle(.secondary) }
                ForEach(jobs, id: \.objectID) { job in
                    NavigationLink { JobDetailView(job: job) } label: {
                        VStack(alignment: .leading) {
                            Text(job.name)
                            Text(dateRange(job)).font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .navigationTitle(record.value(forKey: "name") as? String ?? kind.singular)
        .toolbar { Button("Edit") { editing = true } }
        .sheet(isPresented: $editing) { LibraryEditor(kind: kind, record: record) }
    }
}

private struct LibraryEditor: View {
    let kind: LibraryKind
    let record: NSManagedObject?
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var draft: LibraryDraft
    @State private var initial: LibraryDraft
    @State private var error: String?
    @State private var discard = false
    @FocusState private var nameFocused: Bool
    init(kind: LibraryKind, record: NSManagedObject? = nil) {
        self.kind = kind
        self.record = record
        let value = LibraryDraft(record: record)
        _draft = State(initialValue: value)
        _initial = State(initialValue: value)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $draft.name).focused($nameFocused)
                        .submitLabel(.done).onSubmit { nameFocused = false }
                    if kind == .client {
                        TextField("Contact details", text: $draft.contact, axis: .vertical).lineLimit(2...6)
                        Picker("Default currency", selection: $draft.currency) {
                            Text("USD").tag("USD")
                            Text("EUR").tag("EUR")
                        }
                        TextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(3...10)
                    }
                } footer: { Text("Renaming updates the name shown on related jobs.") }
            }
            .navigationTitle("\(record == nil ? "Add" : "Edit") \(kind.singular)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { if draft != initial { discard = true } else { dismiss() } } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try draft.save(entity: kind.entity, editing: record?.objectID, baseline: initial, in: context); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .saveErrorAlert($error)
            .interactiveDismissDisabled(draft != initial)
            .confirmationDialog("Discard changes?", isPresented: $discard, titleVisibility: .visible) {
                Button("Discard Changes", role: .destructive) { dismiss() }
                Button("Keep Editing", role: .cancel) {}
            }
        }
        .presentationSizing(.page)
        .presentationDetents([.large])
    }
}
