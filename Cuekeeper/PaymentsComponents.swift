import CoreData
import SwiftUI

extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}

/// Lets a managed object drive `.sheet(item:)` without making the entity itself Identifiable.
struct Presented<Object: NSManagedObject>: Identifiable {
    let object: Object
    init(_ object: Object) { self.object = object }
    var id: NSManagedObjectID { object.objectID }
}

// MARK: - Gate colors

extension GateState {
    var fill: Color {
        switch self {
        case .done: Color.theme.positive
        case .missing: Color.theme.attention
        case .notYet: Color.primary.opacity(0.15)
        }
    }
    var spoken: String {
        switch self {
        case .done: "done"
        case .missing: "missing"
        case .notYet: "not yet"
        }
    }
}

extension MoneyBucket {
    var fill: Color {
        switch self {
        case .paid: Color.theme.positive
        case .invoiced: Color.theme.positive.opacity(0.55)
        case .ready: Color.theme.completed
        case .heldUp: Color.theme.attention
        case .toHappen: Color.primary.opacity(0.12)
        }
    }
}

private func shortDay(_ key: String) -> String {
    guard let date = Day.date(from: key) else { return key }
    return date.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated))
}

// MARK: - Month stepper

struct MonthStepper: View {
    @Binding var month: String
    let eventCount: Int
    var inline = false
    var noun = (one: "event", many: "events")

    static func date(_ month: String) -> Date? { Day.date(from: month + "-01") }
    static func title(_ month: String) -> String { date(month)?.formatted(.dateTime.month(.wide).year()) ?? month }
    private func shift(_ months: Int) {
        guard let date = Self.date(month), let next = Calendar.current.date(byAdding: .month, value: months, to: date) else { return }
        month = String(Day.string(from: next).prefix(7))
    }

    var body: some View {
        HStack(spacing: 4) {
            Button { shift(-1) } label: { Image(systemName: "chevron.left").frame(width: 44, height: 44) }
                .accessibilityLabel("Previous month").accessibilityIdentifier("month-previous")
            if !inline { Spacer(minLength: 0) }
            VStack(alignment: inline ? .leading : .center, spacing: 2) {
                Text(Self.title(month)).font(inline ? .title2.bold() : .title3.bold())
                    .accessibilityIdentifier("payments-month")
                HStack(spacing: 6) {
                    Text(eventCount == 1 ? "1 \(noun.one)" : "\(eventCount) \(noun.many)").foregroundStyle(Color.theme.secondaryText)
                    if month != PaymentsView.currentMonth {
                        Text("·").foregroundStyle(Color.theme.secondaryText)
                        // Tap area grows to 44pt without pushing the stepper taller.
                        Button("This month") { month = PaymentsView.currentMonth }.fontWeight(.semibold)
                            .padding(.vertical, 14).contentShape(Rectangle()).padding(.vertical, -14)
                            .accessibilityIdentifier("month-current")
                    }
                }
                .font(.footnote)
            }
            if !inline { Spacer(minLength: 0) }
            Button { shift(1) } label: { Image(systemName: "chevron.right").frame(width: 44, height: 44) }
                .accessibilityLabel("Next month").accessibilityIdentifier("month-next")
        }
        .font(.body.weight(.semibold))
    }
}

// MARK: - Money by state

struct MonthMoneyPanel: View {
    let currencies: [CurrencyBuckets]
    private var present: [MoneyBucket] { MoneyBucket.allCases.filter { bucket in currencies.contains { ($0.amounts[bucket] ?? 0) > 0 } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(currencies) { currency in
                VStack(alignment: .leading, spacing: 7) {
                    let total = Text(Money.format(currency.total, currency: currency.currency)).monospacedDigit()
                        + Text(currency.unknownFees > 0 ? " + \(currency.unknownFees) \(currency.unknownFees == 1 ? "fee" : "fees") to agree" : "").foregroundStyle(Color.theme.secondaryText)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(currency.currency).fontWeight(.semibold)
                            Spacer(minLength: 8)
                            total
                        }
                        VStack(alignment: .leading, spacing: 2) {
                            Text(currency.currency).fontWeight(.semibold)
                            total
                        }
                    }
                    .font(.subheadline)
                    MoneyBar(buckets: currency)
                }
            }
            if !present.isEmpty {
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
        }
        .padding(.vertical, 2)
    }
}

struct MoneyBar: View {
    let buckets: CurrencyBuckets
    var body: some View {
        SegmentedMoneyBar(currency: buckets.currency, parts: MoneyBucket.allCases.compactMap { bucket in
            (buckets.amounts[bucket] ?? 0) > 0 ? .init(label: bucket.label, fill: bucket.fill, amount: buckets.amounts[bucket]!) : nil
        })
    }
}

/// One currency's money split into proportional colored segments.
struct SegmentedMoneyBar: View {
    struct Part: Identifiable {
        let label: String
        let fill: Color
        let amount: Int64
        var id: String { label }
    }
    let currency: String
    let parts: [Part]
    var body: some View {
        let total = max(1, parts.reduce(0) { $0 + $1.amount })
        GeometryReader { geometry in
            HStack(spacing: 2) {
                if parts.isEmpty { Capsule().fill(Color.primary.opacity(0.08)) }
                ForEach(parts) { part in
                    Rectangle().fill(part.fill)
                        .frame(width: max(3, (geometry.size.width - CGFloat(parts.count - 1) * 2) * CGFloat(part.amount) / CGFloat(total)))
                }
            }
        }
        .frame(height: 12)
        .clipShape(Capsule())
        .accessibilityElement()
        .accessibilityLabel(currency)
        .accessibilityValue(parts.isEmpty ? "Nothing yet" : parts.map { "\(Money.format($0.amount, currency: currency)) \($0.label.lowercased())" }.joined(separator: ", "))
    }
}

// MARK: - Step bar

struct StepBar: View {
    @ScaledMetric(relativeTo: .footnote) private var width = 44
    let gates: [ReadinessGate: GateState]
    var body: some View {
        HStack(spacing: 2) {
            ForEach(ReadinessGate.allCases, id: \.self) { gate in
                RoundedRectangle(cornerRadius: 2).fill((gates[gate] ?? .notYet).fill)
            }
        }
        .frame(width: width, height: 6)
        .accessibilityElement()
        .accessibilityLabel(ReadinessGate.allCases.map { "\($0.label) \((gates[$0] ?? .notYet).spoken)" }.joined(separator: ", "))
    }
}

/// Names each segment of the step bar, aligned with the rows' bars.
struct StepBarKey: View {
    /// Indents the key to line up with the bars in the event rows below it.
    var alignsWithRows = true
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var railWidth = 47
    @ScaledMetric(relativeTo: .caption) private var column = 56
    private let sample: [ReadinessGate: GateState] = [.fee: .done, .client: .missing, .work: .notYet, .receipts: .done]
    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 6) {
                StepBar(gates: sample)
                Text("Left to right: fee, client, work, receipts. Green is done, orange is missing, grey is not yet.")
                    .font(.footnote).foregroundStyle(Color.theme.secondaryText)
            }
        } else { columns }
    }

    private var columns: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(ReadinessGate.allCases, id: \.self) { gate in
                    VStack(spacing: 2) {
                        Text(gate.label).font(.caption.weight(.semibold)).foregroundStyle(Color.theme.secondaryText).lineLimit(1).minimumScaleFactor(0.8)
                        RoundedRectangle(cornerRadius: 2).fill(sample[gate]!.fill).frame(height: 6)
                    }
                    .frame(width: column)
                }
            }
            HStack(spacing: 14) {
                ForEach([GateState.done, .missing, .notYet], id: \.spoken) { state in
                    HStack(spacing: 5) {
                        RoundedRectangle(cornerRadius: 2).fill(state.fill).frame(width: 12, height: 6)
                        Text(state.spoken.capitalizedFirst).font(.caption).foregroundStyle(Color.theme.secondaryText)
                    }
                }
            }
        }
        .padding(.leading, alignsWithRows ? railWidth + 12 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Each event's bar shows fee, client, work and receipts, in that order: done, missing, or not yet.")
    }
}

// MARK: - Rows

enum ReadinessText {
    static func status(_ event: EventReadiness) -> Text {
        let secondary = Color.theme.secondaryText, amber = Color.theme.amberText
        switch event.state {
        case .ready: return Text("Ready to invoice").foregroundStyle(Color.theme.accent).fontWeight(.semibold)
        case .heldUp, .upcoming:
            var text = Text(event.gaps.map(\.text).joined(separator: " · ")).foregroundStyle(amber).fontWeight(.semibold)
            if event.state == .upcoming {
                // The date rail already shows the start; only a multi-day end adds anything.
                let when = event.facts.startDay == event.facts.endDay ? nil : "ends " + shortDay(event.facts.endDay)
                if event.gaps.isEmpty { text = Text(when ?? "Still to happen").foregroundStyle(secondary) }
                else if let when { text = text + Text(" · " + when).foregroundStyle(secondary) }
            }
            return text
        case let .paid(reference): return Text(reference.isEmpty ? "Paid" : "Paid · \(reference)").foregroundStyle(Color.theme.positive).fontWeight(.semibold)
        case let .invoiced(reference, balance, currency, dueDay):
            let owed = "\(reference.isEmpty ? "Invoice" : reference) · \(Money.format(balance, currency: currency)) owed"
            let today = Day.string(from: Date())
            if !dueDay.isEmpty && dueDay < today { return Text(owed + " · overdue").foregroundStyle(Color.theme.cancelled).fontWeight(.semibold) }
            return Text(owed).foregroundStyle(secondary) + Text(dueDay.isEmpty ? "" : " · due " + shortDay(dueDay)).foregroundStyle(secondary)
        case .draft: return Text("On draft invoice · not sent").foregroundStyle(secondary)
        case .directPaid: return Text("Paid directly").foregroundStyle(Color.theme.positive).fontWeight(.semibold)
        case let .directPartial(received, remaining, currency):
            let rest = remaining.map { "\(Money.format($0, currency: currency)) to collect" } ?? "fee to agree"
            return Text("\(Money.format(received, currency: currency)) received directly · \(rest)").foregroundStyle(amber).fontWeight(.semibold)
        case .noFee: return Text("No fee").foregroundStyle(secondary)
        case .review(let message): return Text(message).foregroundStyle(amber).fontWeight(.semibold)
        case .cancelled: return Text("Cancelled").foregroundStyle(secondary)
        }
    }
}

struct EventReadinessRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let event: EventReadiness
    var showsClient = false
    var body: some View {
        let amount = Text(event.amount.flatMap { amount in event.currency.map { Money.format(amount, currency: $0) } } ?? "—")
            .monospacedDigit().foregroundStyle(event.amount == nil ? Color.theme.secondaryText : .primary)
        HStack(alignment: .center, spacing: 12) {
            if !typeSize.isAccessibilitySize { DaybookDateRail(day: event.facts.startDay) }
            VStack(alignment: .leading, spacing: 6) {
                if typeSize.isAccessibilitySize {
                    Text(event.facts.title).foregroundStyle(.primary)
                    Text(shortDay(event.facts.startDay)).font(.subheadline).foregroundStyle(Color.theme.secondaryText)
                    amount
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(event.facts.title).foregroundStyle(.primary)
                        Spacer(minLength: 8)
                        amount
                    }
                }
                if showsClient, let name = event.facts.clientName { Text(name).font(.subheadline).foregroundStyle(Color.theme.secondaryText) }
                if typeSize.isAccessibilitySize {
                    if event.showsGates { StepBar(gates: event.gates) }
                    ReadinessText.status(event).font(.footnote)
                } else {
                    HStack(alignment: .center, spacing: 8) {
                        if event.showsGates { StepBar(gates: event.gates) }
                        ReadinessText.status(event).font(.footnote)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
    }
}

struct ClientGroupHeader: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let group: ClientMonthGroup
    let clientObject: Client?
    let onDetails: (Client) -> Void
    /// Starts an invoice for the ready events in one currency.
    var onInvoice: ((String) -> Void)? = nil
    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        let totals = group.clientID != nil && onInvoice != nil ? group.readyTotals : []
        layout {
            VStack(alignment: .leading, spacing: 3) {
                Text(group.name).font(.headline)
                if group.clientID != nil && group.billable {
                    if group.detailsMissing.isEmpty {
                        let terms = "\(group.termsDays ?? 0)-day terms"
                        Text(group.ready.isEmpty ? "Details complete · \(terms)" : "\(group.ready.count) ready · \(terms)")
                            .font(.subheadline).foregroundStyle(Color.theme.secondaryText)
                    } else {
                        Text(ListFormatter.localizedString(byJoining: group.detailsMissing).capitalizedFirst + " missing")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(Color.theme.amberText)
                    }
                }
            }
            .accessibilityElement(children: .combine)
            if !typeSize.isAccessibilitySize { Spacer(minLength: 8) }
            if let clientObject, group.billable, !group.detailsMissing.isEmpty {
                Button("Add details") { onDetails(clientObject) }.font(.subheadline.weight(.semibold))
                    .frame(minHeight: 44).accessibilityIdentifier("client-details-\(group.name)")
            } else if let onInvoice, !totals.isEmpty {
                VStack(alignment: typeSize.isAccessibilitySize ? .leading : .trailing, spacing: 8) {
                    ForEach(totals, id: \.currency) { total in
                        Button("Invoice \(Money.format(total.amount, currency: total.currency))") { onInvoice(total.currency) }
                            .buttonStyle(DaybookPrimaryButton()).fixedSize()
                            .accessibilityIdentifier("invoice-ready-\(group.name)")
                    }
                }
            }
        }
    }
}

struct OpenInvoiceRow: View {
    let reference: String
    let clientName: String
    let balance: Int64
    let currency: String
    let dueDay: String
    let draft: Bool
    let paid: Int64
    let total: Int64
    var body: some View {
        let today = Day.string(from: Date())
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                (Text(reference).fontWeight(.semibold) + Text(" · " + clientName)).foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(Money.format(draft ? total : balance, currency: currency)).fontWeight(.semibold).monospacedDigit()
            }
            Group {
                if draft { Text("Draft · not sent").foregroundStyle(Color.theme.secondaryText) }
                else if !dueDay.isEmpty && dueDay < today {
                    let days = Day.days(from: dueDay, to: today) ?? 0
                    Text(days == 1 ? "1 day late" : "\(days) days late").fontWeight(.semibold).foregroundStyle(Color.theme.cancelled)
                } else if dueDay == today { Text("Due today").fontWeight(.semibold).foregroundStyle(Color.theme.amberText) }
                else if !dueDay.isEmpty { Text("Due \(shortDay(dueDay))").foregroundStyle(Color.theme.secondaryText) }
                else { Text("No due date").foregroundStyle(Color.theme.secondaryText) }
            }.font(.subheadline)
            if paid > 0 && !draft {
                Text("\(Money.format(paid, currency: currency)) of \(Money.format(total, currency: currency)) received").font(.footnote).foregroundStyle(Color.theme.secondaryText).monospacedDigit()
            }
        }
        .frame(minHeight: 44)
    }
}

// MARK: - Wide ledger

struct WidePanel<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    var padded = true
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .padding(padded ? 16 : 0)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.theme.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(contrast == .increased ? 0.45 : 0.16), lineWidth: 0.5) }
    }
}

struct MonthLedgerTable: View {
    let groups: [ClientMonthGroup]
    let job: (UUID) -> Job?
    let client: (UUID?) -> Client?
    let onReadiness: (Job) -> Void
    let onDetails: (Client) -> Void
    let onInvoice: (ClientMonthGroup, String) -> Void

    var body: some View {
        WidePanel(padded: false) {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 0) {
                GridRow {
                    Text("Event")
                    ForEach(ReadinessGate.allCases, id: \.self) { Text($0.label).gridColumnAlignment(.center) }
                    Text("Amount").gridColumnAlignment(.trailing)
                    Text("State")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(Color.theme.secondaryText)
                .padding(.vertical, 10)
                ForEach(groups) { group in
                    Divider()
                    GridRow {
                        ClientGroupHeader(group: group, clientObject: client(group.clientID), onDetails: onDetails) { onInvoice(group, $0) }
                            .gridCellColumns(7)
                    }
                    .padding(.vertical, 8)
                    .background(Color.theme.accent.opacity(0.04))
                    ForEach(group.events) { event in
                        Divider()
                        row(event)
                    }
                }
            }
            .padding(.horizontal, 16)
        }
    }

    private func row(_ event: EventReadiness) -> some View {
        GridRow {
            Group {
                if let job = job(event.id) {
                    if event.showsGates && event.state != .ready {
                        Button { onReadiness(job) } label: { eventLabel(event) }.buttonStyle(.plain)
                    } else {
                        NavigationLink { JobDetailView(job: job) } label: { eventLabel(event) }.buttonStyle(.plain)
                    }
                } else { eventLabel(event) }
            }
            .accessibilityIdentifier("readiness-\(event.facts.title)")
            ForEach(ReadinessGate.allCases, id: \.self) { gate in
                Group {
                    if event.showsGates { GateGlyph(state: event.gates[gate] ?? .notYet) }
                    else { Text("—").foregroundStyle(Color.theme.secondaryText) }
                }
                .frame(minWidth: 48)
                .accessibilityLabel("\(gate.label) \(event.showsGates ? (event.gates[gate] ?? .notYet).spoken : "not applicable")")
            }
            Text(event.amount.flatMap { amount in event.currency.map { Money.format(amount, currency: $0) } } ?? "—").monospacedDigit()
            ReadinessText.status(event).font(.subheadline).lineLimit(2)
        }
        .padding(.vertical, 10)
    }

    private func eventLabel(_ event: EventReadiness) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(event.facts.title).foregroundStyle(.primary).fixedSize(horizontal: false, vertical: true)
            Text(shortDay(event.facts.startDay)).font(.subheadline).foregroundStyle(Color.theme.secondaryText)
        }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
    }
}

struct GateGlyph: View {
    let state: GateState
    var body: some View {
        Group {
            switch state {
            case .done: Circle().fill(Color.theme.positive).frame(width: 11, height: 11)
            case .missing: Circle().fill(Color.theme.attention).frame(width: 11, height: 11)
            case .notYet: Circle().strokeBorder(Color.theme.secondaryText, lineWidth: 1.5).frame(width: 10, height: 10)
            }
        }
    }
}

// MARK: - Client invoicing details

struct InvoicingFieldRow: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var labelWidth = 96
    let label: String
    let prompt: String
    @Binding var text: String
    var missing = false
    var axis: Axis = .horizontal
    /// Visible lines for a vertical field.
    var lines: ClosedRange<Int> = 2...5
    var keyboard: UIKeyboardType = .default
    var identifier: String
    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: text.isEmpty && axis == .vertical ? .center : .firstTextBaseline, spacing: 12))
        layout {
            Text(label).foregroundStyle(missing ? Color.theme.amberText : Color.theme.secondaryText).fontWeight(missing ? .semibold : .regular)
                .frame(width: typeSize.isAccessibilitySize ? nil : labelWidth, alignment: .leading)
            TextField(label, text: $text, prompt: Text(prompt).foregroundStyle(Color.theme.secondaryText), axis: axis)
                .keyboardType(keyboard)
                .textInputAutocapitalization(keyboard == .emailAddress ? .never : .sentences)
                .autocorrectionDisabled(keyboard == .emailAddress)
                .lineLimit(axis == .vertical ? lines : 1...1)
                .accessibilityIdentifier(identifier)
        }
        .frame(minHeight: 32)
    }
}

/// The client invoicing rows, for use inside a Daybook section.
@ViewBuilder func clientInvoicingRows(_ draft: Binding<InvoicingDraft>, highlight: Bool = false) -> some View {
    let value = (try? draft.wrappedValue.value()) ?? ClientInvoicing()
    let missing = Set(highlight ? value.missing : [])
    InvoicingFieldRow(label: "Bill to", prompt: "Company or person", text: draft.billingName, missing: missing.contains("billing name"), identifier: "invoicing-name")
    InvoicingFieldRow(label: "Email", prompt: "accounts@…", text: draft.email, missing: missing.contains("billing email"), keyboard: .emailAddress, identifier: "invoicing-email")
    InvoicingFieldRow(label: "Address", prompt: "Street, city, postcode, country", text: draft.address, missing: missing.contains("address"), axis: .vertical, identifier: "invoicing-address")
    InvoicingFieldRow(label: "Terms", prompt: "Days, e.g. 30", text: draft.terms, missing: missing.contains("payment terms"), keyboard: .numberPad, identifier: "invoicing-terms")
    InvoicingFieldRow(label: "Tax ID", prompt: "Optional", text: draft.taxID, identifier: "invoicing-tax")
}

struct ClientInvoicingFields: View {
    @Binding var draft: InvoicingDraft
    var body: some View { clientInvoicingRows($draft) }
}

struct ClientInvoicingEditor: View {
    @ObservedObject var client: Client
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @State private var draft: InvoicingDraft
    @State private var initial: InvoicingDraft
    @State private var error: String?
    @State private var discard = false
    init(client: Client) {
        self.client = client
        let value = InvoicingDraft(client.invoicing)
        _draft = State(initialValue: value); _initial = State(initialValue: value)
    }
    var body: some View {
        NavigationStack {
            DaybookForm(title: client.name, subtitle: "Invoicing details") {
                Section { clientInvoicingRows($draft, highlight: true) }
            }
            .navigationTitle("Invoicing details").navigationBarTitleDisplayMode(.inline)
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
                        do { try Client.saveInvoicing(try draft.value(), client: client.objectID, in: context); dismiss() }
                        catch { self.error = error.localizedDescription }
                    }.accessibilityIdentifier("save-invoicing")
                }
            }
            .saveErrorAlert($error)
            .interactiveDismissDisabled(draft != initial)
        }
        .presentationDetents([.large])
        .presentationBackground(Color.theme.page)
    }
}

// MARK: - Readiness sheet

struct ReadinessSheet: View {
    @ObservedObject var job: Job
    @Environment(\.managedObjectContext) private var context
    @Environment(\.dismiss) private var dismiss
    @FetchRequest(sortDescriptors: []) private var invoiceRevisions: FetchedResults<InvoiceRevision>
    @FetchRequest(sortDescriptors: []) private var expenses: FetchedResults<Expense>
    @FetchRequest(sortDescriptors: []) private var clients: FetchedResults<Client>
    @State private var draft: InvoicingDraft
    @State private var initial: InvoicingDraft
    @State private var error: String?
    @State private var showingFee = false
    @State private var editingEvent = false
    @State private var reviewing: Expense?
    @State private var invoicing: ReadyInvoice?

    init(job: Job) {
        self.job = job
        let value = InvoicingDraft(job.client?.invoicing ?? ClientInvoicing())
        _draft = State(initialValue: value); _initial = State(initialValue: value)
    }

    var body: some View {
        _ = invoiceRevisions.count + expenses.count + clients.count
        let index = InvoiceIndex(in: context)
        let event = EventReadiness(ReadinessFacts(job: job, context: context, index: index), today: Day.string(from: Date()))
        let doneCount = ReadinessGate.allCases.filter { event.gates[$0] == .done }.count
        return NavigationStack {
            DaybookForm(topPadding: 8) {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text([job.eventDateDescription, job.client?.name].compactMap { $0 }.joined(separator: " · ")).font(.subheadline).foregroundStyle(Color.theme.secondaryText)
                        Text(job.displayName).font(.title2.bold())
                        HStack(spacing: 10) {
                            StepBar(gates: event.gates)
                            Text("\(doneCount) of 4 ready").font(.subheadline).foregroundStyle(Color.theme.secondaryText)
                        }
                    }
                }.containerValue(\.daybookUnframed, true)
                Section {
                    ForEach(ReadinessGate.allCases, id: \.self) { gate in gateRow(gate, event: event) }
                } header: { Text("Before you can invoice") }
                if let client = job.client, !client.invoicing.isComplete {
                    Section {
                        clientInvoicingRows($draft, highlight: true)
                        Button("Save details") { saveDetails() }
                            .buttonStyle(DaybookPrimaryButton()).disabled(draft == initial)
                            .accessibilityIdentifier("save-invoicing")
                    } header: { Text("\(client.name) invoicing details") }
                }
                if event.state == .ready, let clientID = job.client?.id, let currency = event.currency {
                    Section {
                        Button("Create invoice") {
                            let rebill = Set(event.facts.rebillable.filter { $0.currency == currency }.map(\.id))
                            invoicing = ReadyInvoice(clientID: clientID, currency: currency, jobs: [job], expenses: expenses.filter { $0.id.map(rebill.contains) ?? false })
                        }
                        .buttonStyle(DaybookPrimaryButton()).accessibilityIdentifier("readiness-create-invoice")
                    }.containerValue(\.daybookUnframed, true)
                }
            }
            .navigationTitle("Readiness").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    NavigationLink("Open event") { JobDetailView(job: job) }.accessibilityIdentifier("readiness-open-event")
                }
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .navigationDestination(isPresented: $showingFee) { FeeDetailView(job: job) }
            .sheet(item: $reviewing) { ExpenseEditorView(job: job, expense: $0) }
            .sheet(isPresented: $editingEvent) { JobEditorView(job: job) }
            .sheet(item: $invoicing) { InvoiceEditorView(ready: $0) }
            .saveErrorAlert($error)
            .onChange(of: job.client?.invoicingJSON) { _, _ in
                let value = InvoicingDraft(job.client?.invoicing ?? ClientInvoicing())
                if draft == initial { draft = value }
                initial = value
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Color.theme.page)
    }

    @ViewBuilder private func gateRow(_ gate: ReadinessGate, event: EventReadiness) -> some View {
        let state = event.gates[gate] ?? .notYet
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: state == .done ? "checkmark.circle.fill" : state == .missing ? "exclamationmark.circle.fill" : "circle.dashed")
                .font(.title3).foregroundStyle(state == .done ? Color.theme.positive : state == .missing ? Color.theme.attention : Color.theme.secondaryText)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title(gate)).fontWeight(state == .missing ? .semibold : .regular)
                Text(detail(gate, state: state, event: event)).font(.subheadline)
                    .foregroundStyle(state == .missing ? Color.theme.amberText : Color.theme.secondaryText)
            }
            Spacer(minLength: 8)
            if state == .missing { action(gate, event: event) }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("gate-\(gate.rawValue)")
        if gate == .receipts && state == .missing {
            ForEach(expenses.filter { $0.job == job && $0.isDraft && !$0.value.discarded }, id: \.objectID) { expense in
                Button { reviewing = expense } label: {
                    HStack {
                        Text(expense.value.merchant.isEmpty ? "Receipt" : expense.value.merchant)
                        Spacer()
                        Text(ExpenseValue.displayAmount(expense.value.amount, currency: expense.value.currency) ?? "Amount to confirm").monospacedDigit()
                        Text("Finish").fontWeight(.semibold).foregroundStyle(Color.theme.accent)
                    }.frame(minHeight: 44).contentShape(Rectangle())
                }.buttonStyle(.plain).padding(.leading, 36)
            }
        }
    }

    private func title(_ gate: ReadinessGate) -> String {
        switch gate {
        case .work: "Work finished"
        case .fee: "Fee agreed"
        case .receipts: "Receipts filed"
        case .client: "Client invoicing details"
        }
    }

    private func detail(_ gate: ReadinessGate, state: GateState, event: EventReadiness) -> String {
        let gap = event.gaps.first { $0.gate == gate }?.text
        switch gate {
        case .work:
            if state == .done { return "Marked completed" }
            return state == .missing ? "Ended \(shortDay(job.eventEndDay)), not marked completed" : (job.eventStartDay == job.eventEndDay ? shortDay(job.eventStartDay) : "Ends \(shortDay(job.eventEndDay))")
        case .fee:
            if state == .done, case .value(let fee) = event.facts.fee, let amount = fee.amount { return Money.format(amount, currency: fee.currency) }
            return gap ?? ""
        case .receipts:
            if state == .missing { return gap ?? "" }
            let rebill = event.facts.rebillable.count
            return rebill == 0 ? "Nothing to finish" : "\(rebill) to rebill"
        case .client:
            if state == .done, let terms = job.client?.invoicing.termsDays { return "Complete · \(terms)-day terms" }
            if let missing = job.client?.invoicing.missing, !missing.isEmpty { return ListFormatter.localizedString(byJoining: missing).capitalizedFirst + " missing" }
            return gap ?? ""
        }
    }

    @ViewBuilder private func action(_ gate: ReadinessGate, event: EventReadiness) -> some View {
        switch gate {
        case .work:
            Button("Mark completed") { markCompleted() }.fontWeight(.semibold).accessibilityIdentifier("gate-mark-completed")
        case .fee:
            Button(event.facts.fee == .conflict ? "Review" : "Add fee") { showingFee = true }.fontWeight(.semibold)
        case .receipts:
            EmptyView()
        case .client:
            if job.client == nil { Button("Add client") { editingEvent = true }.fontWeight(.semibold) }
        }
    }

    private func markCompleted() {
        let baseline = JobDraft(job: job)
        var draft = baseline
        draft.bookingStatus = .completed
        do { try draft.save(in: context, editing: job.objectID, baseline: baseline) }
        catch { self.error = error.localizedDescription }
    }

    private func saveDetails() {
        guard let client = job.client else { return }
        do {
            let value = try draft.value()
            try Client.saveInvoicing(value, client: client.objectID, in: context)
            initial = draft
        } catch { self.error = error.localizedDescription }
    }
}
