import SwiftUI

// MARK: - Shared panel treatment

/// The same matte ruled panel DaybookSections draws, for views composed outside a DaybookForm.
struct EventPanel: ViewModifier {
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color("SurfaceBackground"), in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(contrast == .increased ? 0.45 : 0.16), lineWidth: 0.5) }
    }
}

struct EventPanelDivider: View {
    @Environment(\.colorSchemeContrast) private var contrast
    var leading: CGFloat = 16
    var body: some View {
        Rectangle().fill(Color.primary.opacity(contrast == .increased ? 0.45 : 0.16)).frame(height: 0.5).padding(.leading, leading)
    }
}

extension View {
    func eventPanel() -> some View { modifier(EventPanel()) }
}

struct EventSectionTitle<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.title3.bold()).accessibilityAddTraits(.isHeader)
            Spacer(minLength: 8)
            trailing
        }
    }
}

extension EventSectionTitle where Trailing == EmptyView {
    init(_ title: String) { self.init(title: title) { EmptyView() } }
}

// MARK: - Time formatting

enum EventTimeText {
    static func time(_ date: Date, in zone: TimeZone) -> String {
        var style = Date.FormatStyle.dateTime.hour().minute()
        style.timeZone = zone
        return date.formatted(style)
    }
    static func abbreviation(_ zone: TimeZone, at date: Date) -> String { zone.abbreviation(for: date) ?? zone.identifier }
    static func duration(from start: Date, to end: Date) -> String? {
        guard end > start else { return nil }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .short; formatter.allowedUnits = [.hour, .minute]; formatter.maximumUnitCount = 2
        return formatter.string(from: end.timeIntervalSince(start))
    }
    /// "5 hours behind the track", for a remote worker's zone relative to the event.
    static func offset(of work: TimeZone, from event: TimeZone, at date: Date) -> String? {
        let seconds = work.secondsFromGMT(for: date) - event.secondsFromGMT(for: date)
        guard seconds != 0 else { return nil }
        let hours = Double(abs(seconds)) / 3600
        let amount = hours == hours.rounded() ? counted(Int(hours), "hour", "hours") : String(format: "%.1f hours", hours)
        return "\(amount) \(seconds < 0 ? "behind" : "ahead of") the track"
    }
}

// MARK: - Header

struct EventHeader: View {
    @ObservedObject var job: Job
    let onStatus: (BookingStatus) -> Void
    let onEditDates: () -> Void
    private var status: BookingStatus { BookingStatus(rawValue: job.bookingStatus) ?? .tentative }
    private var work: String {
        let arrangement = WorkArrangement(rawValue: job.workArrangement)
        return (job.roleNames + (arrangement == nil || arrangement == .unspecified ? [] : [arrangement!.title])).joined(separator: " · ")
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: onEditDates) {
                Text([job.eventDateDescription, job.eventLocation].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(Color("SecondaryText")).multilineTextAlignment(.leading)
            }.buttonStyle(.plain).accessibilityHint("Edits the event dates").accessibilityIdentifier("edit-event-dates")
            Text(job.eventTitle).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { statusMenu; facts }
                VStack(alignment: .leading, spacing: 6) { statusMenu; facts }
            }.padding(.top, 2)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var statusMenu: some View {
        Menu {
            ForEach(BookingStatus.allCases, id: \.self) { option in
                Button { onStatus(option) } label: {
                    if option == status { Label(option.title, systemImage: "checkmark") } else { Text(option.title) }
                }.accessibilityIdentifier("booking-status-\(option.rawValue)")
            }
        } label: { BookingBadge(status: status.rawValue) }
            .accessibilityLabel("Booking status, \(status.title)")
            .accessibilityHint("Changes the booking status")
            .accessibilityIdentifier("booking-status")
    }
    private var facts: some View {
        HStack(spacing: 6) {
            Text(job.client?.name ?? "Client to add").fontWeight(.semibold)
                .foregroundStyle(job.client == nil ? Color("SecondaryText") : Color.accentColor)
            if !work.isEmpty { Text(work).foregroundStyle(Color("SecondaryText")) }
        }.font(.subheadline)
    }
}

// MARK: - To settle

extension OpenItem {
    var actionTitle: String {
        switch action {
        case .markBooked: return "Mark booked"
        case .markCompleted: return "Mark completed"
        case .editSession: return kind == .sessionTime ? "Add time" : kind == .sessionConfirmation ? "Confirm" : "Decide"
        case .editEvent: return "Add client"
        case .openFee: return kind == .feeConflict ? "Review" : "Add fee"
        case .addToInvoice: return "Invoice"
        case .editClientInvoicing: return "Add details"
        case .openInvoice: return kind == .balanceOwed ? "Record payment" : "Open"
        case .reviewBilling, .reviewExpense: return "Review"
        }
    }
    /// The step that moves the event forward gets the prominent button.
    var isPrimary: Bool { kind == .tentativeBooking || kind == .balanceOwed || kind == .readyToInvoice || kind == .eventOver }
    var needsAttention: Bool { [.tentativeBooking, .feeConflict, .clientDetails, .billingReview, .expenseDraft].contains(kind) }
    var symbol: String {
        switch kind {
        case .tentativeBooking: return "calendar.badge.clock"
        case .sessionTime, .sessionConfirmation: return "clock"
        case .sessionCoverage: return "questionmark.circle"
        case .clientMissing: return "person.crop.circle.badge.plus"
        case .clientDetails: return "person.text.rectangle"
        case .feeConflict, .feeUnknown, .readyToInvoice, .balanceOwed: return "banknote"
        case .invoiceDraft, .billingReview: return "doc.text"
        case .expenseDraft: return "receipt"
        case .eventOver: return "checkmark"
        }
    }
}

struct OpenItemsPanel: View {
    @ScaledMetric(relativeTo: .subheadline) private var iconSize = 28
    let items: [OpenItem]
    let perform: (OpenItem) -> Void
    var limit = 3
    @State private var expanded = false
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        if !items.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("To settle · \(items.count)").font(.footnote.weight(.semibold)).foregroundStyle(Color("SecondaryText"))
                    .padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 4)
                    .accessibilityAddTraits(.isHeader)
                let shown = expanded ? items : Array(items.prefix(limit))
                ForEach(Array(shown.enumerated()), id: \.element.id) { index, item in
                    if index > 0 { EventPanelDivider(leading: 16 + iconSize + 10) }
                    row(item)
                }
                if items.count > limit {
                    EventPanelDivider()
                    Button(expanded ? "Show fewer" : "Show all \(items.count)") { expanded.toggle() }
                        .font(.subheadline).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 16)
                        .accessibilityIdentifier("open-items-more")
                }
            }
            .padding(.bottom, 4)
            .eventPanel()
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("open-items")
        }
    }
    @ViewBuilder private func row(_ item: OpenItem) -> some View {
        let tint = item.needsAttention ? Color("AmberText") : Color.accentColor
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 8)) : AnyLayout(HStackLayout(spacing: 10))
        layout {
            HStack(spacing: 10) {
                Image(systemName: item.symbol).font(.footnote.weight(.semibold)).foregroundStyle(tint)
                    .frame(width: iconSize, height: iconSize)
                    .background((item.needsAttention ? Color.orange.opacity(0.18) : Color.accentColor.opacity(0.1)), in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(.subheadline.weight(.semibold))
                    if let detail = item.detail { Text(detail).font(.footnote).foregroundStyle(Color("SecondaryText")) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.accessibilityElement(children: .combine)
            if item.isPrimary {
                Button(item.actionTitle) { perform(item) }.buttonStyle(DaybookPrimaryButton()).controlSize(.small)
                    .accessibilityIdentifier("open-item-\(item.kind.rawValue)")
            } else {
                Button(item.actionTitle) { perform(item) }.font(.subheadline.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44).accessibilityIdentifier("open-item-\(item.kind.rawValue)")
            }
        }
        .padding(.leading, 16).padding(.trailing, 10).padding(.vertical, 4)
    }
}

// MARK: - Next call

struct NextCallPanel: View {
    let next: NextCall
    let zone: TimeZone
    /// The other clock, shown beneath the main time when the user works remotely.
    let otherZone: TimeZone?
    let showsYourTime: Bool
    var series: [String] = []
    var weather: String? = nil
    /// Names the event when the panel sits outside the event's own page.
    var subtitle: String? = nil
    @Environment(\.colorScheme) private var scheme
    private static let mint = Color(red: 167 / 255, green: 220 / 255, blue: 180 / 255)
    private var fill: Color { scheme == .dark ? Color("SurfaceBackground") : Color.accentColor }
    private var label: Color { scheme == .dark ? Color.accentColor : Self.mint }
    private var primary: Color { scheme == .dark ? Color.primary : Color("PageBackground") }
    private var secondary: Color { scheme == .dark ? Color("SecondaryText") : Color.white.opacity(0.82) }

    var body: some View {
        TimelineView(.everyMinute) { context in
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(lead(now: context.date)).font(.subheadline.weight(.semibold)).foregroundStyle(label)
                    Spacer(minLength: 8)
                    if let weather { Text(weather).font(.subheadline).foregroundStyle(secondary) }
                }
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(secondary).padding(.top, -8) }
                if let countdown = countdown(now: context.date) {
                    Text(countdown).font(.largeTitle.weight(.semibold)).monospacedDigit().foregroundStyle(primary)
                    Text(callAndAir).font(.subheadline).foregroundStyle(secondary)
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .lastTextBaseline, spacing: 14) { bigTime; zones }
                        VStack(alignment: .leading, spacing: 4) { bigTime; zones }
                    }
                    if let air = onAir { Text(([air] + series).joined(separator: " · ")).font(.subheadline).foregroundStyle(secondary) }
                }
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(fill, in: RoundedRectangle(cornerRadius: 12))
            .overlay { if scheme == .dark { RoundedRectangle(cornerRadius: 12).strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 0.5) } }
            .accessibilityElement(children: .combine)
            .accessibilityIdentifier("next-call")
        }
    }
    private var bigTime: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(next.isCallTime ? (showsYourTime ? "Your call" : "Call") : "Starts").font(.footnote.weight(.semibold)).foregroundStyle(label)
            Text(EventTimeText.time(next.at, in: zone)).font(.system(.largeTitle, design: .default).weight(.semibold)).monospacedDigit()
                .foregroundStyle(primary)
        }
    }
    @ViewBuilder private var zones: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(EventTimeText.abbreviation(zone, at: next.at) + (showsYourTime ? " · your time" : " · track time"))
            if let otherZone {
                Text("\(EventTimeText.time(next.at, in: otherZone)) \(showsYourTime ? "at the track" : "your time") (\(EventTimeText.abbreviation(otherZone, at: next.at)))")
            }
        }.font(.footnote).foregroundStyle(secondary)
    }
    private var onAir: String? {
        guard let start = next.session.start else { return nil }
        return "On air " + EventTimeText.time(start, in: zone) + (next.session.end.map { " – " + EventTimeText.time($0, in: zone) } ?? "")
    }
    private var callAndAir: String {
        ([next.session.call.map { "Call " + EventTimeText.time($0, in: zone) }, onAir].compactMap { $0 } + series).joined(separator: " · ")
    }
    private func lead(now: Date) -> String {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let day: String
        if calendar.isDate(next.at, inSameDayAs: now) { day = "Today" }
        else if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now), calendar.isDate(next.at, inSameDayAs: tomorrow) { day = "Tomorrow" }
        else { var style = Date.FormatStyle.dateTime.weekday(.wide); style.timeZone = zone; day = next.at.formatted(style) }
        return ([day, next.session.title] + (next.session.confirmed ? [] : ["Tentative"])).joined(separator: " · ")
    }
    /// Within 90 minutes the lead becomes a countdown.
    private func countdown(now: Date) -> String? {
        let minutes = Int(next.at.timeIntervalSince(now) / 60)
        guard minutes >= 0, minutes <= 90 else { return nil }
        let noun = next.isCallTime ? "Call" : "On air"
        return minutes < 1 ? "\(noun) now" : "\(noun) in \(minutes) min"
    }
}

// MARK: - Run of show

struct RunOfShowDayView<Row: View>: View {
    let day: RunOfShowDay
    var weather: String? = nil
    @ViewBuilder let row: (EventSessionFact) -> Row
    @ScaledMetric(relativeTo: .body) private var railWidth = 47
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if day.key.isEmpty {
                Image(systemName: "calendar.badge.questionmark").font(.title3).foregroundStyle(Color.accentColor)
                    .frame(width: railWidth).padding(.top, 4).accessibilityLabel("Date to come")
            } else {
                DaybookDateRail(day: day.key)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(coverage)
                    Spacer(minLength: 8)
                    if let weather { Text(weather) }
                }.font(.footnote).foregroundStyle(Color("SecondaryText")).padding(.top, 4)
                VStack(spacing: 0) {
                    ForEach(Array(day.sessions.enumerated()), id: \.element.id) { index, session in
                        if index > 0 { EventPanelDivider() }
                        row(session)
                    }
                }.eventPanel()
            }
        }
    }
    private var coverage: String {
        if day.key.isEmpty { return "Date to come" }
        let covering = day.coveringCount
        return covering == day.sessions.count ? "Covering \(covering)" : "Covering \(covering) of \(day.sessions.count)"
    }
}

struct RunOfShowRow: View {
    let session: EventSessionFact
    let zone: TimeZone
    /// Shown trailing at regular width so remote workers see both clocks at once.
    var trackZone: TimeZone? = nil
    /// Series every session shares; a session's own series shows only when it differs.
    var eventSeries: [String] = []
    var onAddTime: (() -> Void)? = nil
    /// Leads the subtitle when rows from several events share one run of show.
    var context: String? = nil
    @ScaledMetric(relativeTo: .body) private var timeWidth = 90
    @Environment(\.dynamicTypeSize) private var typeSize
    private var skipped: Bool { session.coverage == "notCovering" }

    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6)) : AnyLayout(HStackLayout(spacing: 12))
        layout {
            time
            VStack(alignment: .leading, spacing: 2) {
                Text(session.title).font(.body.weight(skipped ? .regular : .semibold))
                if !session.series.isEmpty && session.series != eventSeries {
                    ForEach(session.series, id: \.self) { Text($0).font(.subheadline) }
                }
                if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(subtitleColor) }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if session.start == nil, !skipped, let onAddTime {
                Button("Add time", action: onAddTime).font(.subheadline.weight(.semibold)).frame(minHeight: 44)
            } else if let trackZone, let start = session.start, !typeSize.isAccessibilitySize {
                Text("\(EventTimeText.time(start, in: trackZone)) track").font(.subheadline).monospacedDigit().foregroundStyle(Color("SecondaryText"))
            }
        }
        .foregroundStyle(skipped ? Color("SecondaryText") : Color.primary)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    @ViewBuilder private var time: some View {
        if let start = session.start {
            Text(EventTimeText.time(start, in: zone)).font(.headline.weight(skipped ? .regular : .semibold)).monospacedDigit()
                .lineLimit(1).minimumScaleFactor(typeSize.isAccessibilitySize ? 1 : 0.8)
                .frame(width: typeSize.isAccessibilitySize ? nil : timeWidth, alignment: .leading)
        } else {
            Text("TBC").font(.footnote.weight(.semibold)).foregroundStyle(Color("AmberText"))
                .frame(width: timeWidth, height: 40)
                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(Color("AmberText").opacity(0.55), style: StrokeStyle(lineWidth: 1.5, dash: [4, 3])) }
                .accessibilityLabel("Time to come")
        }
    }
    private var subtitle: String? {
        if skipped { return [context, "Not covering"].compactMap { $0 }.joined(separator: " · ") }
        var parts: [String] = context.map { [$0] } ?? []
        if session.start == nil || !session.confirmed { parts.append("Tentative") }
        if session.coverage == "undecided" { parts.append("coverage undecided") }
        if let call = session.call { parts.append("Call " + EventTimeText.time(call, in: zone)) }
        if let start = session.start, let end = session.end, let length = EventTimeText.duration(from: start, to: end) { parts.append(length) }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
    private var subtitleColor: Color {
        !skipped && (session.start == nil || !session.confirmed || session.coverage == "undecided") ? Color("AmberText") : Color("SecondaryText")
    }
}

// MARK: - Money

struct MoneySummaryPanel: View {
    let fee: EventFeeFact
    let progress: InvoiceProgress
    /// Shown when the panel opens the fee screen.
    var chevron = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(amount).font(.title2.bold()).monospacedDigit()
                Spacer(minLength: 8)
                Text(agreement).font(.subheadline).foregroundStyle(Color("SecondaryText"))
                if chevron {
                    Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color("SecondaryText")).accessibilityHidden(true)
                }
            }
            switch progress {
            case let .single(total, paid, currency):
                bar(fraction: total > 0 ? Double(min(max(paid, 0), total)) / Double(total) : 0)
                    .accessibilityLabel("\(Money.format(paid, currency: currency)) paid of \(Money.format(total, currency: currency)) invoiced")
                HStack(spacing: 16) {
                    legend("Paid \(Money.format(paid, currency: currency))", fill: Color.accentColor)
                    legend("Owed \(Money.format(total - paid, currency: currency))", fill: Color.accentColor.opacity(0.3))
                }
            case let .shared(reference, others, total, balance, currency):
                Text("On \(reference.isEmpty ? "an invoice" : reference) with \(counted(others, "other event", "other events")) · \(Money.format(balance, currency: currency)) of \(Money.format(total, currency: currency)) owed on the invoice")
                    .font(.subheadline).foregroundStyle(Color("SecondaryText"))
            case .draft:
                Text("On draft invoice").font(.subheadline).foregroundStyle(Color("SecondaryText"))
            case .none:
                Text("Not invoiced yet").font(.subheadline).foregroundStyle(Color("SecondaryText"))
            }
            if case .value(let value) = fee, !value.lines.isEmpty {
                VStack(spacing: 0) {
                    ForEach(value.lines) { line in
                        EventPanelDivider(leading: 0)
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(line.description.isEmpty ? "Item" : line.description)
                                if let rate = try? Money.parse(line.rate, currency: value.currency, allowNegative: true) {
                                    Text("\(line.quantity) × \(Money.format(rate, currency: value.currency))").font(.footnote).foregroundStyle(Color("SecondaryText"))
                                }
                            }
                            Spacer(minLength: 8)
                            Text((try? line.total(currency: value.currency)).map { Money.format($0, currency: value.currency) } ?? "Needs review").monospacedDigit()
                        }.font(.subheadline).padding(.vertical, 10)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    private var amount: String {
        switch fee {
        case .conflict: return "Needs review"
        case .value(let value): return value.amount.map { Money.format($0, currency: value.currency) } ?? "Fee unknown"
        }
    }
    private var agreement: String {
        guard case .value(let value) = fee else { return "Conflicting edits" }
        return value.agreement == "unknown" ? "Not agreed" : value.agreement.capitalized + " fee"
    }
    private func bar(fraction: Double) -> some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.accentColor.opacity(0.3))
                Capsule().fill(Color.accentColor).frame(width: proxy.size.width * fraction)
            }
        }.frame(height: 10).accessibilityElement()
    }
    private func legend(_ text: String, fill: Color) -> some View {
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: 3).fill(fill).frame(width: 10, height: 10).accessibilityHidden(true)
            Text(text).monospacedDigit()
        }.font(.footnote)
    }
}

// MARK: - Facts

struct EventFactRow<Value: View>: View {
    @ScaledMetric(relativeTo: .subheadline) private var labelWidth = 84
    @Environment(\.dynamicTypeSize) private var typeSize
    let label: String
    @ViewBuilder var value: Value
    var body: some View {
        let layout = typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 4)) : AnyLayout(HStackLayout(alignment: .firstTextBaseline, spacing: 12))
        layout {
            Text(label).foregroundStyle(Color("SecondaryText")).frame(width: typeSize.isAccessibilitySize ? nil : labelWidth, alignment: .leading)
            value.frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.subheadline)
        .padding(.horizontal, 16).padding(.vertical, 12)
        .accessibilityElement(children: .combine)
    }
}

extension EventFactRow where Value == Text {
    init(_ label: String, _ value: String) { self.init(label: label) { Text(value) } }
}

// MARK: - Previews

#if DEBUG
private enum EventDetailPreview {
    static let london = TimeZone(identifier: "Europe/London")!
    static let newYork = TimeZone(identifier: "America/New_York")!
    static func at(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    static let practice = EventSessionFact(id: UUID(), title: "Practice 1", day: "2026-10-16", start: at("2026-10-16T10:30:00Z"), end: at("2026-10-16T11:30:00Z"), call: at("2026-10-16T09:30:00Z"), confirmed: true, coverage: "covering")
    static let practice2 = EventSessionFact(id: UUID(), title: "Practice 2", day: "2026-10-16", start: at("2026-10-16T14:00:00Z"), end: at("2026-10-16T15:00:00Z"), call: nil, confirmed: true, coverage: "notCovering")
    static let sprint = EventSessionFact(id: UUID(), title: "Sprint", day: "2026-10-17", start: nil, end: nil, call: nil, confirmed: false, coverage: "undecided")
    static let facts = EventDetailFacts(bookingStatus: "booked", hasClient: true, startDay: "2026-10-16", endDay: "2026-10-18", eventZone: london, workZone: newYork,
                                        sessions: [practice, practice2, sprint], fee: .value(FeeValue(amount: 180_000, currency: "EUR", agreement: "agreed",
                                        lines: [FeeLine(description: "Practice & qualifying days", quantity: "2", rate: "500"), FeeLine(description: "Race day", quantity: "1", rate: "800")])),
                                        billing: .sent(invoiceID: UUID(), reference: "INV-0412", currency: "EUR", total: 180_000, balance: 90_000, dueDay: "2026-11-19", otherEvents: 0),
                                        expenseDrafts: [EventExpenseFact(id: UUID(), merchant: "Fuel, Towcester", amount: 3_840, currency: "EUR")])
    static let summary = EventDetailSummary(facts: facts, now: at("2026-10-15T12:00:00Z"))
}

#Preview("Event detail components") {
    let summary = EventDetailPreview.summary
    ScrollView {
        VStack(alignment: .leading, spacing: 24) {
            OpenItemsPanel(items: summary.openItems, perform: { _ in })
            if let next = summary.nextCall {
                NextCallPanel(next: next, zone: EventDetailPreview.newYork, otherZone: EventDetailPreview.london, showsYourTime: true,
                              series: ["National League"], weather: "14° showers")
            }
            EventSectionTitle("Run of show")
            ForEach(summary.days) { day in
                RunOfShowDayView(day: day, weather: "12° cloudy") { session in
                    RunOfShowRow(session: session, zone: EventDetailPreview.newYork, onAddTime: {})
                }
            }
            EventSectionTitle("Money")
            MoneySummaryPanel(fee: EventDetailPreview.facts.fee, progress: summary.invoiceProgress).eventPanel()
            VStack(spacing: 0) {
                EventFactRow("Working", "Remote · EDT, " + (EventTimeText.offset(of: EventDetailPreview.newYork, from: EventDetailPreview.london, at: EventDetailPreview.at("2026-10-16T12:00:00Z")) ?? ""))
                EventPanelDivider()
                EventFactRow("Series", "National League")
            }.eventPanel()
        }.padding(20)
    }.background(Color("PageBackground"))
}
#endif
