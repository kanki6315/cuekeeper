import CoreData
import SwiftUI

// MARK: - Roster

/// Clients read through the calendar: who you work for next, then everyone.
struct ClientRosterView: View {
    @Environment(\.managedObjectContext) private var context
    @FetchRequest(sortDescriptors: [NSSortDescriptor(keyPath: \Client.name, ascending: true)]) private var clients: FetchedResults<Client>
    @FetchRequest(sortDescriptors: []) private var jobs: FetchedResults<Job>
    @FetchRequest(sortDescriptors: []) private var events: FetchedResults<WorkEvent>
    @FetchRequest(sortDescriptors: []) private var sessions: FetchedResults<WorkSession>
    @FetchRequest(sortDescriptors: []) private var invoiceRevisions: FetchedResults<InvoiceRevision>
    @FetchRequest(sortDescriptors: []) private var payments: FetchedResults<PaymentRecord>
    @State private var adding = false
    @State private var query = ""

    private struct Entry: Identifiable {
        let client: Client
        let summary: ClientSummary
        var id: NSManagedObjectID { client.objectID }
        var next: String { summary.upcoming.first?.facts.startDay ?? "" }
    }

    var body: some View {
        let _ = (jobs.count, events.count, sessions.count, invoiceRevisions.count, payments.count)
        let index = InvoiceIndex(in: context)
        let entries = clients.map { Entry(client: $0, summary: ClientSummary(client: $0, context: context, index: index, detailed: false)) }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let coming = trimmed.isEmpty ? entries.filter { !$0.summary.upcoming.isEmpty }.sorted { lhs, rhs in
            if lhs.next.isEmpty != rhs.next.isEmpty { return rhs.next.isEmpty }
            return (lhs.next, lhs.client.name) < (rhs.next, rhs.client.name)
        } : []
        let comingIDs = Set(coming.map(\.id))
        let all = entries.filter { trimmed.isEmpty || $0.client.name.localizedCaseInsensitiveContains(trimmed) }
        DaybookList {
            if !coming.isEmpty {
                Section("Coming up") {
                    ForEach(coming) { entry in
                        NavigationLink { ClientDetailView(client: entry.client) } label: { ClientComingUpRow(name: entry.client.name, summary: entry.summary) }
                    }
                }
            }
            Section {
                ForEach(all) { entry in
                    NavigationLink { ClientDetailView(client: entry.client) } label: {
                        ClientRosterRow(name: entry.client.name, summary: entry.summary, showsStanding: !comingIDs.contains(entry.id))
                    }
                }
            } header: {
                if !coming.isEmpty { Text("All clients") }
            }
        }
        .overlay {
            if clients.isEmpty {
                ContentUnavailableView("No clients yet", systemImage: "person.2",
                    description: Text("Add one here, or type a new client name while adding an event."))
            } else if all.isEmpty {
                ContentUnavailableView.search(text: trimmed)
            }
        }
        .navigationTitle("Clients").navigationBarTitleDisplayMode(.inline)
        .searchable(text: $query)
        .toolbar { Button("Add Client", systemImage: "plus") { adding = true } }
        .sheet(isPresented: $adding) { ClientEditor(record: nil) }
    }
}

/// A client with work ahead, on the agenda's date rail.
private struct ClientComingUpRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let name: String
    let summary: ClientSummary
    private var next: EventsListRow? { summary.upcoming.first }
    private var detail: String {
        guard let next else { return "" }
        let more = summary.upcoming.count - 1
        return more > 0 ? "\(next.facts.title) · then \(more) more" : next.facts.title
    }
    var body: some View {
        HStack(spacing: 14) {
            ClientRail(day: next?.facts.startDay ?? "", quiet: false)
            VStack(alignment: .leading, spacing: 4) {
                Text(name).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(Color.theme.secondaryText).lineLimit(2)
                if let standing = summary.standing { EventsStatusBadge(badge: standing).padding(.top, 2) }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
    }
}

private struct ClientRosterRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let name: String
    let summary: ClientSummary
    let showsStanding: Bool
    private var detail: String {
        let count = summary.eventCount
        var parts = [count == 0 ? "No events yet" : counted(count, "event", "events")]
        if summary.upcoming.isEmpty, let last = summary.lastDay.flatMap({ Day.date(from: $0) }) {
            parts.append("last " + last.formatted(.dateTime.month(.abbreviated).year()))
        }
        parts.append(summary.currency)
        return parts.joined(separator: " · ")
    }
    var body: some View {
        HStack(spacing: 12) {
            ClientMonogram(name: name)
            VStack(alignment: .leading, spacing: 3) {
                Text(name).font(.body.weight(.semibold))
                Text(detail).font(.subheadline).foregroundStyle(Color.theme.secondaryText)
                if showsStanding, let standing = summary.standing { EventsStatusBadge(badge: standing).padding(.top, 2) }
            }
            .multilineTextAlignment(.leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

struct ClientMonogram: View {
    @ScaledMetric(relativeTo: .body) private var size = 36
    let name: String
    var body: some View {
        Text(name.initials)
            .font(.subheadline.weight(.semibold)).minimumScaleFactor(0.7).lineLimit(1)
            .foregroundStyle(Color.theme.accent)
            .frame(width: size, height: size)
            .background(Color.theme.accent.opacity(0.1), in: Circle())
            .accessibilityHidden(true)
    }
}

/// The agenda's weekday / day / month rail, quiet once the work is over, honest when undated.
private struct ClientRail: View {
    @ScaledMetric(relativeTo: .body) private var width = 47
    let day: String
    let quiet: Bool
    var body: some View {
        Group {
            if let date = Day.date(from: day) {
                VStack(spacing: 2) {
                    Text(date.formatted(.dateTime.weekday(.abbreviated))).font(.caption)
                    Text(date.formatted(.dateTime.day())).font(.title2.weight(.semibold)).monospacedDigit()
                    Text(date.formatted(.dateTime.month(.abbreviated))).font(.caption)
                }
            } else {
                Text("Dates to come").font(.caption).multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(quiet ? Color.theme.secondaryText : Color.theme.accent)
        .frame(width: width)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Client view

enum ClientTab: String, CaseIterable, Hashable {
    case events, money, details
    var title: String { rawValue.capitalized }
}

struct ClientDetailView: View {
    @ObservedObject var client: Client
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dynamicTypeSize) private var typeSize
    @FetchRequest(sortDescriptors: []) private var jobs: FetchedResults<Job>
    @FetchRequest(sortDescriptors: []) private var events: FetchedResults<WorkEvent>
    @FetchRequest(sortDescriptors: []) private var sessions: FetchedResults<WorkSession>
    @FetchRequest(sortDescriptors: []) private var invoiceRevisions: FetchedResults<InvoiceRevision>
    @FetchRequest(sortDescriptors: []) private var feeRevisions: FetchedResults<FeeRevision>
    @FetchRequest(sortDescriptors: []) private var payments: FetchedResults<PaymentRecord>
    @FetchRequest(sortDescriptors: []) private var expenses: FetchedResults<Expense>
    @SceneStorage private var storedTab: String
    @State private var editing = false
    @State private var year: String?
    @State private var expandedYears: Set<String> = []
    @State private var invoicing: ReadyInvoice?

    init(client: Client) {
        self.client = client
        _storedTab = SceneStorage(wrappedValue: "", "clientTab-\(client.id?.uuidString ?? client.objectID.uriRepresentation().absoluteString)")
    }

    var body: some View {
        let _ = (jobs.count, events.count, sessions.count, invoiceRevisions.count, feeRevisions.count, payments.count, expenses.count)
        let summary = ClientSummary(client: client, context: context, index: InvoiceIndex(in: context), detailed: true)
        let tab = ClientTab(rawValue: storedTab) ?? .events
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0, pinnedViews: typeSize.isAccessibilitySize ? [] : [.sectionHeaders]) {
                Section { header(summary).padding(.bottom, 16) }
                Section {
                    Group {
                        switch tab {
                        case .events: eventsTab(summary)
                        case .money: moneyTab(summary)
                        case .details: detailsTab(summary)
                        }
                    }.padding(.top, 16)
                } header: {
                    DaybookSegments(title: "Client sections", selection: Binding(get: { tab }, set: { storedTab = $0.rawValue }),
                                    options: ClientTab.allCases, identifier: "client-tab", label: { $0.title },
                                    badge: { $0 == .details ? (summary.detailsNeeded.isEmpty ? 0 : summary.detailsNeeded.count) : 0 })
                        .padding(.vertical, 4)
                        .background(Color.theme.page)
                }
            }
            .frame(maxWidth: 760)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 24)
        }
        .accessibilityIdentifier("daybook-form")
        .daybookSurface()
        .navigationTitle("Client").navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let email = emailURL {
                ToolbarItem(placement: .primaryAction) {
                    Link(destination: email) { Label("Email \(client.name)", systemImage: "envelope") }
                }
            }
            ToolbarItem(placement: .primaryAction) { Button("Edit") { editing = true }.accessibilityIdentifier("edit-client") }
        }
        .sheet(isPresented: $editing) { ClientEditor(record: client) }
        .sheet(item: $invoicing) { InvoiceEditorView(ready: $0, startsOnRecord: true) }
    }

    /// The first address in the contact details, else the billing email.
    private var emailURL: URL? {
        let candidates = client.contact.split(whereSeparator: \.isWhitespace).map(String.init) + [client.invoicing.email]
        guard let address = candidates.map({ $0.trimmingCharacters(in: CharacterSet(charactersIn: "<>(),;")) })
            .first(where: { $0.contains("@") && $0.contains(".") }) else { return nil }
        return URL(string: "mailto:\(address)")
    }

    // MARK: Header

    private func header(_ summary: ClientSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(client.name).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            Text(sinceText(summary)).font(.subheadline).foregroundStyle(Color.theme.secondaryText)
            ChipFlow(spacing: 6) {
                EventFactChip(symbol: "calendar", text: summary.eventCount == 0 ? "No events yet" : counted(summary.eventCount, "event", "events"))
                EventFactChip(symbol: CurrencyPreferences.symbol(summary.currency), text: summary.currency)
                if let terms = summary.invoicing.termsDays { EventFactChip(symbol: "clock", text: "\(terms) days to pay") }
                if !summary.overdue.isEmpty {
                    EventChip(tint: Color.theme.amberText) { Text(ClientSummary.amounts(summary.overdue) + " overdue").fontWeight(.semibold) }
                } else if !summary.owed.isEmpty {
                    EventChip { Text(ClientSummary.amounts(summary.owed) + " owed") }
                }
            }.padding(.top, 4)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sinceText(_ summary: ClientSummary) -> String {
        guard let since = summary.sinceDay.flatMap({ Day.date(from: $0) }) else { return "No events yet" }
        return "Client since " + since.formatted(.dateTime.month(.abbreviated).year())
    }

    // MARK: Events

    @ViewBuilder private func eventsTab(_ summary: ClientSummary) -> some View {
        if summary.upcoming.isEmpty && summary.past.isEmpty {
            Text("No events yet. Choose \(client.name) as the client when you add an event.")
                .foregroundStyle(Color.theme.secondaryText).frame(maxWidth: .infinity, alignment: .leading)
        } else {
            DaybookSections {
                if !summary.upcoming.isEmpty {
                    Section("Next up") {
                        ForEach(summary.upcoming) { row in eventLink(row) }
                    }
                }
                ForEach(Array(summary.past.enumerated()), id: \.element.id) { offset, year in
                    let open = offset == 0 || expandedYears.contains(year.year)
                    Section {
                        if open {
                            ForEach(year.rows) { row in eventLink(row) }
                        } else {
                            Button { expandedYears.insert(year.year) } label: {
                                HStack {
                                    Text("Show \(counted(year.rows.count, "event", "events"))")
                                    Spacer()
                                    Image(systemName: "chevron.down").font(.caption.weight(.semibold))
                                }.frame(minHeight: 32).contentShape(Rectangle())
                            }.foregroundStyle(Color.theme.accent).accessibilityIdentifier("client-year-\(year.year)")
                        }
                    } header: {
                        Text(year.year.isEmpty ? "Dates to come" : year.year)
                    }
                }
            }
        }
    }

    @ViewBuilder private func eventLink(_ row: EventsListRow) -> some View {
        if let id = row.facts.objectID, let job = try? context.existingObject(with: id) as? Job {
            DaybookLink { JobDetailView(job: job) } label: { ClientEventRow(row: row) }
        } else {
            ClientEventRow(row: row)
        }
    }

    // MARK: Money

    @ViewBuilder private func moneyTab(_ summary: ClientSummary) -> some View {
        let shown = year ?? summary.defaultYear
        let money = summary.money(in: shown)
        VStack(alignment: .leading, spacing: 20) {
            ForEach(summary.readyToInvoice, id: \.currency) { group in
                Button(invoiceTitle(group.events)) { invoicing = readyInvoice(currency: group.currency, events: group.events) }
                    .buttonStyle(DaybookPrimaryButton())
                    .frame(maxWidth: .infinity)
                    .accessibilityIdentifier("client-invoice-\(group.currency)")
            }
            DaybookSections {
                Section {
                    if money.isEmpty {
                        Text("No fees recorded for \(shown).").foregroundStyle(Color.theme.secondaryText)
                    } else {
                        MonthMoneyPanel(currencies: money)
                    }
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Money in \(shown)")
                        Spacer()
                        if summary.years.count > 1 {
                            Menu {
                                Picker("Year", selection: Binding(get: { shown }, set: { year = $0 })) {
                                    ForEach(summary.years, id: \.self) { Text($0).tag($0) }
                                }
                            } label: {
                                HStack(spacing: 3) { Text("Year"); Image(systemName: "chevron.up.chevron.down").font(.caption2) }
                                    .font(.subheadline.weight(.regular)).frame(minHeight: 44)
                            }.accessibilityIdentifier("client-money-year")
                        }
                    }
                }
                Section("Invoices") {
                    if summary.invoices.isEmpty {
                        Text("No invoices yet").foregroundStyle(Color.theme.secondaryText)
                    }
                    ForEach(summary.invoices) { invoice in
                        if let id = invoice.objectID, let record = try? context.existingObject(with: id) as? Invoice {
                            DaybookLink { InvoiceDetailView(invoice: record) } label: { ClientInvoiceRow(invoice: invoice, today: summary.today) }
                        }
                    }
                }
            }
        }
    }

    private func invoiceTitle(_ events: [EventReadiness]) -> String {
        events.count == 1 ? "Invoice \(events[0].facts.title)" : "Invoice \(events.count) ready events"
    }

    private func readyInvoice(currency: String, events: [EventReadiness]) -> ReadyInvoice? {
        guard let clientID = client.id else { return nil }
        let ids = Set(events.map(\.id))
        let rebill = Set(events.flatMap { $0.facts.rebillable.filter { $0.currency == currency }.map(\.id) })
        return ReadyInvoice(clientID: clientID, currency: currency,
                            jobs: jobs.filter { $0.id.map(ids.contains) ?? false }.sorted { $0.eventStartDay < $1.eventStartDay },
                            expenses: expenses.filter { $0.id.map(rebill.contains) ?? false })
    }

    // MARK: Details

    private func detailsTab(_ summary: ClientSummary) -> some View {
        let invoicing = summary.invoicing
        let required = 4 - invoicing.missing.count
        return DaybookSections {
            Section("Contact") {
                if client.contact.isEmpty {
                    Text("No contact details").foregroundStyle(Color.theme.secondaryText)
                } else {
                    Text(client.contact).textSelection(.enabled)
                }
            }
            Section {
                ClientValueRow(label: "Bill to", value: invoicing.billingName, missing: true)
                ClientValueRow(label: "Email", value: invoicing.email, missing: true)
                ClientValueRow(label: "Address", value: invoicing.address, missing: true)
                ClientValueRow(label: "Terms", value: invoicing.termsDays.map { "\($0) days" } ?? "", missing: true)
                ClientValueRow(label: "Tax ID", value: invoicing.taxID, missing: false)
            } header: {
                HStack(alignment: .firstTextBaseline) {
                    Text("Invoicing")
                    Spacer()
                    Text(invoicing.isComplete ? "Complete" : "\(required) of 4")
                        .font(.subheadline.weight(.regular))
                        .foregroundStyle(invoicing.isComplete ? Color.theme.positive : Color.theme.amberText)
                }
            }
            if !client.notes.isEmpty {
                Section("Notes") { Text(client.notes).textSelection(.enabled) }
            }
        }
    }
}

/// One of the client's events: rail, title, dates and its booking or money badge.
/// The Roles page adds the roles held on it, as tags or as the other roles beside the selected one.
struct ClientEventRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let row: EventsListRow
    var tags: [String] = []
    var also: [String] = []
    var showsClient = false
    private var detail: String {
        var parts: [String] = []
        if showsClient { parts.append(row.facts.client ?? "Client to add") }
        if row.multiDay, let start = Day.date(from: row.facts.startDay), let end = Day.date(from: row.facts.endDay) {
            parts.append(start.formatted(.dateTime.weekday(.abbreviated)) + "–" + end.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)))
        }
        let count = row.facts.sessions.count
        parts.append(count == 0 ? "Schedule to come" : counted(count, "session", "sessions"))
        if !also.isEmpty { parts.append("also " + also.joined(separator: ", ")) }
        return parts.joined(separator: " · ")
    }
    private var title: some View {
        Text(row.facts.title).font(.headline).foregroundStyle(row.finished ? Color.theme.secondaryText : Color.primary)
    }
    var body: some View {
        HStack(spacing: 14) {
            ClientRail(day: row.facts.startDay, quiet: row.finished || row.facts.bookingStatus == "cancelled")
            VStack(alignment: .leading, spacing: 3) {
                if typeSize.isAccessibilitySize {
                    title.lineLimit(3)
                    EventsStatusBadge(badge: row.badge)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        title.lineLimit(1)
                        Spacer(minLength: 4)
                        EventsStatusBadge(badge: row.badge)
                    }
                }
                Text(detail).font(.subheadline).foregroundStyle(Color.theme.secondaryText)
                if !tags.isEmpty {
                    ChipFlow(spacing: 4) { ForEach(tags, id: \.self) { RoleTag(name: $0) } }.padding(.top, 2)
                }
            }
            .multilineTextAlignment(.leading)
        }
        .accessibilityElement(children: .combine)
    }
}

private struct ClientInvoiceRow: View {
    let invoice: ClientInvoiceFact
    let today: String
    private var state: ClientInvoiceFact.State { invoice.state(today: today) }
    private var detail: String {
        var parts = [invoice.events.joined(separator: ", ")]
        switch state {
        case .open:
            if let due = Day.date(from: invoice.dueDay) { parts.append("due " + due.formatted(.dateTime.day().month(.abbreviated))) }
        default:
            if let sent = Day.date(from: invoice.sentDay) { parts.append("sent " + sent.formatted(.dateTime.day().month(.abbreviated).year())) }
        }
        return parts.filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private var label: String {
        switch state {
        case .review: "Needs review"
        case .draft: "Draft"
        case .void: "Voided"
        case .credit: "Credit"
        case .paid: "Paid"
        case .open(overdue: true):
            Day.date(from: invoice.dueDay).map { "Overdue since " + $0.formatted(.dateTime.day().month(.abbreviated)) } ?? "Overdue"
        case .open: "Owed"
        }
    }
    private var amount: Int64 {
        switch state {
        case .open, .credit: abs(invoice.balance)
        default: invoice.total
        }
    }
    private var amber: Bool { state == .open(overdue: true) || state == .review }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(invoice.reference).font(.headline).multilineTextAlignment(.leading)
                if !detail.isEmpty { Text(detail).font(.subheadline).foregroundStyle(Color.theme.secondaryText).multilineTextAlignment(.leading) }
            }
            Spacer(minLength: 6)
            VStack(alignment: .trailing, spacing: 3) {
                if state != .review { Text(Money.format(amount, currency: invoice.currency)).font(.body.weight(.semibold)).monospacedDigit() }
                Text(label).font(.footnote.weight(amber ? .semibold : .regular))
                    .foregroundStyle(amber ? Color.theme.amberText : Color.theme.secondaryText)
            }.multilineTextAlignment(.trailing)
        }
        .opacity(state == .void ? 0.6 : 1)
        .accessibilityElement(children: .combine)
    }
}

/// A read-only label and value on the invoicing label column; required gaps read in amber.
private struct ClientValueRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var labelWidth = 96
    let label: String
    let value: String
    /// Whether an empty value is a gap that blocks invoicing.
    let missing: Bool
    var body: some View {
        let empty = value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        layout {
            Text(label).foregroundStyle(empty && missing ? Color.theme.amberText : Color.theme.secondaryText)
                .fontWeight(empty && missing ? .semibold : .regular)
                .frame(width: typeSize.isAccessibilitySize ? nil : labelWidth, alignment: .leading)
            Text(empty ? (missing ? "Missing" : "None") : value)
                .foregroundStyle(empty ? Color.theme.secondaryText : Color.primary)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 32)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Editor

struct ClientEditor: View {
    let record: NSManagedObject?
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var labelWidth = 96
    @State private var draft: LibraryDraft
    @State private var initial: LibraryDraft
    @State private var error: String?
    @State private var discard = false
    init(record: NSManagedObject?) {
        self.record = record
        let value = LibraryDraft(record: record)
        _draft = State(initialValue: value)
        _initial = State(initialValue: value)
    }
    private var invoicing: ClientInvoicing {
        (try? draft.invoicing.value()) ?? ClientInvoicing(billingName: draft.invoicing.billingName, email: draft.invoicing.email, address: draft.invoicing.address)
    }
    var body: some View {
        let missing = invoicing.missing
        NavigationStack {
            DaybookForm(title: draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? (record == nil ? "New client" : "Client") : draft.name,
                        subtitle: record == nil ? "Only the name is needed now. Add billing details whenever you have them." : "Renaming updates every event for this client.") {
                Section("Client") {
                    InvoicingFieldRow(label: "Name", prompt: "Client name", text: $draft.name, identifier: "client-name")
                    InvoicingFieldRow(label: "Contact", prompt: "Person, email or phone", text: $draft.contact, axis: .vertical, lines: 1...6, identifier: "client-contact")
                    labeled("Currency") {
                        Menu {
                            Picker("Currency", selection: $draft.currency) {
                                ForEach(CurrencyPreferences.supported, id: \.self) { Text($0).tag($0) }
                            }
                        } label: {
                            HStack(spacing: 4) { Text(draft.currency); Image(systemName: "chevron.up.chevron.down").font(.caption) }
                                .frame(minHeight: 44)
                        }
                        .accessibilityLabel("Currency").accessibilityValue(draft.currency).accessibilityIdentifier("client-currency")
                    }
                }
                Section {
                    InvoicingMeter(filled: 4 - missing.count)
                    clientInvoicingRows($draft.invoicing, highlight: record != nil)
                } header: {
                    HStack(alignment: .firstTextBaseline) {
                        Text("Invoicing")
                        Spacer()
                        Text(missing.isEmpty ? "Complete" : "\(4 - missing.count) of 4")
                            .font(.subheadline.weight(.regular))
                            .foregroundStyle(missing.isEmpty ? Color.theme.positive : Color.theme.secondaryText)
                    }
                }
                Section("Notes") {
                    DaybookTextField("Anything to remember about working with them", text: $draft.notes, axis: .vertical).lineLimit(3...10)
                        .accessibilityIdentifier("client-notes")
                }
            }
            .navigationTitle(record == nil ? "Add Client" : "Edit Client")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { if draft != initial { discard = true } else { dismiss() } }
                        .confirmationDialog("Discard changes?", isPresented: $discard, titleVisibility: .visible) {
                            Button("Discard Changes", role: .destructive) { dismiss() }
                            Button("Keep Editing", role: .cancel) {}
                        }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        do { try draft.save(entity: "Client", editing: record?.objectID, baseline: initial, in: context); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.disabled(draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .saveErrorAlert($error)
            .interactiveDismissDisabled(draft != initial)
            .preservesDraftOnTodayLink()
        }
        .presentationSizing(.page)
        .presentationDetents([.large])
        .presentationBackground(Color.theme.page)
    }

    @ViewBuilder private func labeled<Content: View>(_ label: String, @ViewBuilder content: () -> Content) -> some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            Text(label).foregroundStyle(Color.theme.secondaryText)
                .frame(width: typeSize.isAccessibilitySize ? nil : labelWidth, alignment: .leading)
            content().frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 32)
    }
}

/// Four short segments, one per required invoicing detail.
private struct InvoicingMeter: View {
    let filled: Int
    var body: some View {
        HStack(spacing: 3) {
            ForEach(0..<4, id: \.self) { index in
                Capsule().fill(index < filled ? Color.theme.accent : Color.primary.opacity(0.12))
            }
        }
        .frame(height: 4)
        .accessibilityElement()
        .accessibilityLabel("Invoicing details")
        .accessibilityValue("\(filled) of 4 required details")
    }
}
