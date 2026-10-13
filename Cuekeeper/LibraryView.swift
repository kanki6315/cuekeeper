import CoreData
import SwiftUI

enum LibraryKind {
    case client, role, project, series
    var entity: String {
        switch self { case .client: "Client"; case .role: "WorkRole"; case .project: "WorkProject"; case .series: "WorkSeries" }
    }
    var title: String {
        switch self { case .client: "Clients"; case .role: "Roles"; case .project: "Projects"; case .series: "Series" }
    }
    var singular: String {
        switch self { case .client: "Client"; case .role: "Role"; case .project: "Project"; case .series: "Series" }
    }
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
        DaybookList {
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
        .navigationTitle(kind.title).navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query)
        .toolbar { Button("Add \(kind.singular)", systemImage: "plus") { adding = true } }
        .sheet(isPresented: $adding) { LibraryEditor(kind: kind) }
    }
}

struct LibraryDetailView: View {
    @ObservedObject var record: NSManagedObject
    let kind: LibraryKind
    @State private var editing = false
    @State private var year = ""
    private var jobs: [Job] {
        var related = (record.value(forKey: "jobs") as? Set<Job>) ?? []
        if let role = record as? WorkRole {
            related.formUnion((role.sessions ?? []).filter { $0.deletedAt == nil }.compactMap(\.job))
        }
        if let series = record as? WorkSeries {
            related.formUnion((series.sessions ?? []).filter { $0.deletedAt == nil && $0.overridesSeries }.compactMap(\.job))
        }
        return related.sorted { $0.startDay > $1.startDay }
    }
    var body: some View {
        DaybookForm(title: record.value(forKey: "name") as? String ?? kind.singular) {
            if let client = record as? Client {
                Section("Client") {
                    if !client.contact.isEmpty { DaybookMetadata(symbol: "envelope", text: client.contact).textSelection(.enabled) }
                    DaybookMetadata(symbol: "dollarsign.circle", text: "Default currency · \(client.defaultCurrency)")
                    if !client.notes.isEmpty { Text(client.notes).textSelection(.enabled) }
                }
            }
            if let client = record as? Client {
                Section("Related invoices") {
                    if (client.invoices ?? []).isEmpty { Text("No invoices yet").foregroundStyle(Color("SecondaryText")) }
                    ForEach((client.invoices ?? []).sorted { ($0.createdAt ?? .distantPast) > ($1.createdAt ?? .distantPast) }, id: \.objectID) { invoice in
                        DaybookLink { InvoiceDetailView(invoice: invoice) } label: { InvoiceRow(invoice: invoice) }
                    }
                }
            }
            if kind == .project {
                Section {
                    DaybookPicker("Year", selection: $year) {
                        Text("All years").tag("")
                        ForEach(Array(Set(jobs.map { String($0.startDay.prefix(4)) })).sorted().reversed(), id: \.self) { Text($0).tag($0) }
                    }
                }
            }
            Section("Related jobs") {
                if jobs.isEmpty { Text("No jobs yet").foregroundStyle(Color("SecondaryText")) }
                ForEach(jobs.filter { year.isEmpty || $0.startDay.hasPrefix(year) }, id: \.objectID) { job in
                    DaybookLink { JobDetailView(job: job) } label: {
                        VStack(alignment: .leading) {
                            HStack { Text(job.name).font(.headline); Spacer(); BookingBadge(status: job.bookingStatus) }
                            Text(dateRange(job)).font(.subheadline).foregroundStyle(Color("SecondaryText"))
                        }
                    }
                }
            }
        }
        .navigationTitle(kind.singular).navigationBarTitleDisplayMode(.inline)
        .toolbar { Button("Edit") { editing = true } }
        .sheet(isPresented: $editing) { LibraryEditor(kind: kind, record: record) }
    }
}

struct LibraryEditor: View {
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
            DaybookForm {
                Section {
                    DaybookTextField("Name", text: $draft.name).focused($nameFocused)
                        .submitLabel(.done).onSubmit { nameFocused = false }
                    if kind == .client {
                        DaybookTextField("Contact details", text: $draft.contact, axis: .vertical).lineLimit(2...6)
                        DaybookPicker("Default currency", selection: $draft.currency) {
                            Text("USD").tag("USD")
                            Text("EUR").tag("EUR")
                        }
                        DaybookTextField("Notes", text: $draft.notes, axis: .vertical).lineLimit(3...10)
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
        .presentationBackground(Color("PageBackground"))
    }
}

/// Reuse and creation share one binding, matching the client editor.
struct NamedLibraryField: View {
    let kind: LibraryKind
    @Binding var name: String
    @FocusState private var focused: Bool
    @FetchRequest private var records: FetchedResults<NSManagedObject>
    init(kind: LibraryKind, name: Binding<String>) {
        self.kind = kind; _name = name
        let request = NSFetchRequest<NSManagedObject>(entityName: kind.entity)
        request.sortDescriptors = [NSSortDescriptor(key: "name", ascending: true)]
        _records = FetchRequest(fetchRequest: request)
    }
    private var names: [String] { Array(Set(records.compactMap { $0.value(forKey: "name") as? String }).union(name.isEmpty ? [] : [name])).sorted() }
    var body: some View {
        if !records.isEmpty {
            DaybookPicker("Reuse \(kind.singular.lowercased())", selection: $name, identifier: "reuse-\(kind.entity)") {
                Text("None").tag("")
                ForEach(names, id: \.self) { Text($0).tag($0) }
            }
        }
        VStack(alignment: .leading, spacing: 6) {
            Text(kind.singular).font(.subheadline).foregroundStyle(Color("SecondaryText"))
            DaybookTextField("Name (optional)", text: $name)
                .focused($focused).submitLabel(.done).onSubmit { focused = false }
                .accessibilityLabel("\(kind.singular) name")
                .accessibilityIdentifier("library-\(kind.entity)-name")
        }
        .padding(.vertical, 4)
    }
}
