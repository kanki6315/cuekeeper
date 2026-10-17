import CoreData
import SwiftUI

/// Payments shows either the month close or every invoice across all months.
enum PaymentsMode: String { case month, invoices }

struct PaymentsModePicker: View {
    @Binding var mode: PaymentsMode
    var body: some View {
        Picker("Payments view", selection: $mode) {
            Text("Month").tag(PaymentsMode.month)
            Text("Invoices").tag(PaymentsMode.invoices)
        }
        .pickerStyle(.segmented).labelsHidden()
        .accessibilityIdentifier("payments-mode")
    }
}

/// Every invoice and direct payment: what is owed, search and filters, then status sections.
/// With `selection`, rows select into a detail column instead of pushing.
struct InvoicesList<Header: View>: View {
    let ledger: InvoiceLedger
    @Binding var filter: LedgerFilter
    var selection: Binding<String?>? = nil
    let invoice: (UUID) -> Invoice?
    let job: (UUID) -> Job?
    let onGoToMonth: () -> Void
    @ViewBuilder var header: Header
    @Environment(\.managedObjectContext) private var context
    @State private var paying: Presented<Invoice>?
    @State private var editing: EditedInvoice?
    @State private var voiding: Invoice?
    @State private var error: String?

    var body: some View {
        let sections = ledger.sections(filter)
        DaybookList {
            // List rows stretch glass buttons and hide their titles; keep the tab header at its natural size.
            Section { header.labelStyle(.titleAndIcon).fixedSize(horizontal: false, vertical: true) }
                .listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
            if ledger.entries.isEmpty {
                Section { noInvoices }
            } else {
                owedSection
                Section { filters }
                    .listRowBackground(Color.clear).listRowInsets(EdgeInsets()).listRowSeparator(.hidden)
                if filter.isScoped { totalsSection }
                ForEach(sections) { section in
                    Section {
                        ForEach(section.entries) { entry in row(entry) }
                    } header: { sectionHeader(section.title, meta: section.meta) }
                }
                if sections.isEmpty { Section { noMatch } }
            }
        }
        .contentMargins(.top, 0, for: .scrollContent)
        .scrollDismissesKeyboard(.interactively)
        .sheet(item: $paying) { PaymentEditorView(invoice: $0.object) }
        .sheet(item: $editing) { InvoiceEditorView(invoice: $0.invoice, draft: $0.draft) }
        .confirmationDialog(voiding.map { "Void \($0.title)?" } ?? "", isPresented: Binding(get: { voiding != nil }, set: { if !$0 { voiding = nil } }), titleVisibility: .visible, presenting: voiding) { invoice in
            Button("Void Invoice", role: .destructive) { void(invoice) }
        } message: { _ in
            Text("It stays in your history, and its events can go on a new invoice.")
        }
        .saveErrorAlert($error)
    }

    // MARK: Sections

    private var owedSection: some View {
        let owed = ledger.owed(client: filter.client)
        return Section {
            if owed.isEmpty {
                Text("Nothing outstanding. Every sent invoice is paid.").foregroundStyle(Color.theme.secondaryText)
            }
            ForEach(owed) { line in
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text(line.currency).fontWeight(.semibold)
                    Spacer(minLength: 0)
                    VStack(alignment: .trailing, spacing: 4) {
                        (Text(Money.format(line.owed, currency: line.currency)).fontWeight(.semibold) + Text(" owed").foregroundStyle(Color.theme.secondaryText))
                            .monospacedDigit()
                        if line.overdue > 0 {
                            Button { filter.status = .overdue } label: {
                                HStack(spacing: 4) {
                                    Text("\(Money.format(line.overdue, currency: line.currency)) overdue").monospacedDigit()
                                    Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                                }
                            }
                            .buttonStyle(.borderless)
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Color.theme.cancelled)
                            .accessibilityHint("Shows overdue invoices")
                            .accessibilityIdentifier("ledger-overdue-\(line.currency)")
                        } else {
                            Text("Nothing overdue").font(.subheadline).foregroundStyle(Color.theme.secondaryText)
                        }
                    }
                }
                .padding(.vertical, 2)
            }
        } header: { sectionHeader(filter.client.isEmpty ? "Owed to you" : "\(filter.client) owes you") }
    }

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(Color.theme.secondaryText).accessibilityHidden(true)
                DaybookTextField("Invoice number, client or amount", text: $filter.query)
                    .textInputAutocapitalization(.never).autocorrectionDisabled().submitLabel(.search)
                    .accessibilityLabel("Search invoices").accessibilityIdentifier("ledger-search")
                if !filter.query.isEmpty {
                    Button { filter.query = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(Color.theme.secondaryText) }
                        .buttonStyle(.borderless).accessibilityLabel("Clear search")
                }
            }
            .padding(.horizontal, 12).frame(minHeight: 40)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(LedgerStatus.allCases) { status in
                        LedgerChip(title: status.title, selected: filter.status == status) { filter.status = status }
                            .accessibilityIdentifier("ledger-filter-\(status.rawValue)")
                    }
                }
            }
            .scrollIndicators(.hidden)
            HStack(spacing: 8) {
                LedgerMenu(title: "Client", all: "All clients", options: ledger.clients, selection: $filter.client)
                    .accessibilityIdentifier("ledger-client")
                LedgerMenu(title: "Year", all: "All years", options: ledger.years, selection: $filter.year)
                    .accessibilityIdentifier("ledger-year")
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 4)
    }

    private var totalsSection: some View {
        let totals = ledger.totals(filter)
        return Section {
            if totals.isEmpty { Text("Nothing billed").foregroundStyle(Color.theme.secondaryText) }
            ForEach(totals) { line in
                VStack(alignment: .leading, spacing: 8) {
                    Text(line.currency).fontWeight(.semibold)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 12) { totalColumns(line) }
                        VStack(alignment: .leading, spacing: 8) { totalColumns(line) }
                    }
                }
                .padding(.vertical, 2)
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                sectionHeader([filter.client, filter.year].filter { !$0.isEmpty }.joined(separator: " · "))
                Button("Clear") { filter.client = ""; filter.year = "" }
                    .buttonStyle(.borderless).font(.subheadline.weight(.semibold)).textCase(nil)
                    .accessibilityLabel("Clear client and year")
            }
        }
    }

    @ViewBuilder private func totalColumns(_ line: LedgerTotals) -> some View {
        totalColumn("Billed", Money.format(line.billed, currency: line.currency), color: .primary)
        totalColumn("Received", Money.format(line.received, currency: line.currency), color: Color.theme.positive)
        totalColumn("Owed", Money.format(line.owed, currency: line.currency), color: .primary)
    }

    private func totalColumn(_ label: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.footnote).foregroundStyle(Color.theme.secondaryText)
            Text(value).fontWeight(.semibold).monospacedDigit().foregroundStyle(color)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var noInvoices: some View {
        VStack(alignment: .leading, spacing: 12) {
            Image(systemName: "doc.text").font(.title).foregroundStyle(Color.theme.accent).accessibilityHidden(true)
            Text("No invoices yet").font(.title3.bold()).accessibilityAddTraits(.isHeader)
            Text("Invoices and event payments land here, with what’s still owed.")
                .foregroundStyle(Color.theme.secondaryText)
            Button("Go to Month", action: onGoToMonth).buttonStyle(DaybookSecondaryButton())
                .accessibilityIdentifier("ledger-go-to-month")
        }
        .padding(.vertical, 8)
        .accessibilityIdentifier("ledger-empty")
    }

    private var noMatch: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(ledger.emptyMessage(filter)).font(.headline)
            Text("Try another client or year, or clear the filters to see everything.").font(.subheadline).foregroundStyle(Color.theme.secondaryText)
            Button("Clear Filters") { filter = LedgerFilter() }.buttonStyle(DaybookSecondaryButton())
                .accessibilityIdentifier("ledger-clear-filters")
        }
        .padding(.vertical, 8)
    }

    private func sectionHeader(_ title: String, meta: String = "") -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.headline).foregroundStyle(Color.primary).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 0)
            if !meta.isEmpty { Text(meta).font(.subheadline).foregroundStyle(Color.theme.secondaryText).monospacedDigit().multilineTextAlignment(.trailing) }
        }
        .textCase(nil)
    }

    // MARK: Rows

    @ViewBuilder private func row(_ entry: LedgerEntry) -> some View {
        Group {
            if let selection {
                Button { selection.wrappedValue = entry.id } label: {
                    HStack(spacing: 10) {
                        LedgerRow(entry: entry, today: ledger.today).frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.theme.secondaryText)
                    }.contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .listRowBackground(selection.wrappedValue == entry.id ? Color.theme.accent.opacity(0.12) : Color.theme.surface)
                .accessibilityAddTraits(selection.wrappedValue == entry.id ? .isSelected : [])
            } else {
                NavigationLink { LedgerDestination(entry: entry, invoice: invoice, job: job) } label: { LedgerRow(entry: entry, today: ledger.today) }
            }
        }
        .accessibilityIdentifier("ledger-\(entry.title)")
        .modifier(LedgerActions(entry: entry, invoice: entry.kind == .invoice ? invoice(entry.recordID) : nil,
                                pay: { paying = Presented($0) }, markSent: markSent, void: { voiding = $0 }))
    }

    private func markSent(_ invoice: Invoice) {
        do {
            var draft = try InvoiceDraft(invoice: invoice)
            draft.value.status = "sent"
            if draft.value.sentDay.isEmpty { draft.value.sentDay = Day.string(from: Date()) }
            if draft.value.dueDay.isEmpty, let due = invoice.client?.invoicing.dueDay(sent: draft.value.sentDay) { draft.value.dueDay = due }
            editing = EditedInvoice(invoice: invoice, draft: draft)
        } catch { self.error = error.localizedDescription }
    }

    private func void(_ invoice: Invoice) {
        do {
            var draft = try InvoiceDraft(invoice: invoice)
            draft.value.status = "void"
            try draft.save(in: context, editing: invoice.objectID)
        } catch { self.error = error.localizedDescription }
        voiding = nil
    }
}

private struct EditedInvoice: Identifiable {
    let id = UUID()
    let invoice: Invoice
    let draft: InvoiceDraft
}

/// Swipe, long-press and VoiceOver actions for an open invoice or draft.
private struct LedgerActions: ViewModifier {
    let entry: LedgerEntry
    let invoice: Invoice?
    let pay: (Invoice) -> Void
    let markSent: (Invoice) -> Void
    let void: (Invoice) -> Void

    private var canPay: Bool { entry.state == .overdue || entry.state == .unpaid }
    private var canSend: Bool { entry.state == .draft }
    private var canVoid: Bool { (canPay || canSend) && entry.received == 0 }

    func body(content: Content) -> some View {
        if let invoice, canPay || canSend {
            content
                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                    if canVoid { Button("Void", systemImage: "xmark.circle") { void(invoice) }.tint(Color.theme.secondaryText) }
                    if canPay { Button("Record Payment", systemImage: "banknote") { pay(invoice) }.tint(Color.theme.accent) }
                    if canSend { Button("Mark Sent", systemImage: "paperplane") { markSent(invoice) }.tint(Color.theme.accent) }
                }
                .contextMenu {
                    if canPay { Button("Record Payment", systemImage: "banknote") { pay(invoice) } }
                    if canSend { Button("Mark Sent", systemImage: "paperplane") { markSent(invoice) } }
                    if canVoid { Button("Void Invoice", systemImage: "xmark.circle", role: .destructive) { void(invoice) } }
                }
                .accessibilityActions {
                    if canPay { Button("Record Payment") { pay(invoice) } }
                    if canSend { Button("Mark Sent") { markSent(invoice) } }
                    if canVoid { Button("Void Invoice") { void(invoice) } }
                }
        } else {
            content
        }
    }
}

struct LedgerRow: View {
    let entry: LedgerEntry
    let today: String

    private var tone: Color {
        switch entry.state {
        case .overdue: Color.theme.cancelled
        case .review: Color.theme.caution
        case .paid, .direct: Color.theme.positive
        default: Color.theme.secondaryText
        }
    }
    private var emphasised: Bool {
        switch entry.state {
        case .overdue, .review, .paid, .direct: true
        default: false
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(entry.title).fontWeight(.semibold)
                Spacer(minLength: 8)
                if !entry.currency.isEmpty {
                    Text(Money.format(entry.shownAmount, currency: entry.currency)).fontWeight(.semibold).monospacedDigit()
                        .strikethrough(entry.state == .void)
                        .foregroundStyle(entry.state == .void ? Color.theme.secondaryText : Color.primary)
                }
            }
            Text([entry.clientName, entry.detail].filter { !$0.isEmpty }.joined(separator: " · "))
                .font(.subheadline).lineLimit(1)
            Text(entry.status(today: today))
                .font(.subheadline.weight(emphasised ? .semibold : .regular)).monospacedDigit()
                .foregroundStyle(tone)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// Where a ledger row leads: the invoice, the event paid directly, or the fee to review.
struct LedgerDestination: View {
    let entry: LedgerEntry
    let invoice: (UUID) -> Invoice?
    let job: (UUID) -> Job?

    var body: some View {
        switch entry.kind {
        case .invoice:
            if let invoice = invoice(entry.recordID) { InvoiceDetailView(invoice: invoice) } else { syncing }
        case .directPayment:
            if let job = job(entry.recordID) {
                if job.deletedAt == nil { JobDetailView(job: job) }
                else {
                    DaybookForm(title: job.displayName, subtitle: "Deleted event") {
                        Section("Payments") { ReceiptLinks(records: Array(job.payments ?? [])) }
                    }
                }
            } else { syncing }
        case .feeReview:
            if let job = job(entry.recordID) { FeeDetailView(job: job) } else { syncing }
        }
    }

    private var syncing: some View {
        ContentUnavailableView("Still syncing", systemImage: "icloud", description: Text("This record hasn’t finished arriving on this device."))
    }
}

private struct LedgerChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Button(action: action) {
            Text(title).font(.subheadline.weight(.semibold))
                .padding(.horizontal, 14).frame(minHeight: 34)
                .foregroundStyle(selected ? Color.theme.onAccent : Color.primary)
                .background(selected ? Color.theme.accent : Color.clear, in: Capsule())
                .overlay { Capsule().strokeBorder(selected ? Color.theme.accent : Color.primary.opacity(contrast == .increased ? 0.45 : 0.16), lineWidth: 1) }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct LedgerMenu: View {
    let title: String
    let all: String
    let options: [String]
    @Binding var selection: String
    @Environment(\.colorSchemeContrast) private var contrast
    var body: some View {
        Menu {
            Picker(title, selection: $selection) {
                Text(all).tag("")
                ForEach(options, id: \.self) { Text($0).tag($0) }
            }
        } label: {
            HStack(spacing: 6) {
                Text(selection.isEmpty ? all : selection).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption.weight(.semibold))
            }
            .font(.subheadline.weight(.semibold)).foregroundStyle(Color.primary)
            .padding(.horizontal, 14).frame(minHeight: 34)
            .overlay { Capsule().strokeBorder(selection.isEmpty ? Color.primary.opacity(contrast == .increased ? 0.45 : 0.16) : Color.theme.accent, lineWidth: 1) }
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(title)
        .accessibilityValue(selection.isEmpty ? all : selection)
    }
}
