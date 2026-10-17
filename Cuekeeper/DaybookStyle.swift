import SwiftUI

/// The approved daybook layout: quiet paper, compact ruled panels, and native controls.
struct DaybookForm<Content: View>: View {
    var title: String = ""
    var subtitle: String = ""
    var compact: Bool = false
    var topPadding: CGFloat? = nil
    var onContentHeightChange: ((CGFloat) -> Void)? = nil
    @ViewBuilder var content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !title.isEmpty { DaybookPageHeading(title: title, subtitle: subtitle) }
                DaybookSections(compact: compact) { content }
            }
                .frame(maxWidth: 760)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 20)
                .padding(.top, topPadding ?? (compact ? 8 : 20))
                .padding(.bottom, compact ? 8 : 20)
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.height
                } action: { height in
                    onContentHeightChange?(height)
                }
        }
        .accessibilityIdentifier("daybook-form")
        .scrollDismissesKeyboard(.interactively)
        .daybookSurface()
    }
}

struct DaybookSections<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    var compact: Bool = false
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            ForEach(sections: content) { section in
                VStack(alignment: .leading, spacing: compact ? 4 : 9) {
                    if !section.header.isEmpty {
                        section.header.font(.headline).foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .accessibilityAddTraits(.isHeader)
                    }
                    VStack(spacing: 0) {
                        ForEach(Array(section.content.enumerated()), id: \.element.id) { index, row in
                            if index > 0 && !section.containerValues.daybookUnframed { Rectangle().fill(Color.primary.opacity(contrast == .increased ? 0.45 : 0.16)).frame(height: 0.5).padding(.horizontal, 16) }
                            row.frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, section.containerValues.daybookUnframed ? 0 : 16)
                                .padding(.top, section.containerValues.daybookFlushTop && index == 0 ? 0 : (compact ? 0 : (section.containerValues.daybookUnframed ? 5 : 12)))
                                .padding(.bottom, compact ? 0 : (section.containerValues.daybookUnframed ? 5 : 12))
                                .frame(minHeight: compact ? 44 : nil)
                        }
                    }
                    .background(section.containerValues.daybookUnframed ? Color.clear : Color.theme.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(section.containerValues.daybookUnframed ? 0 : (contrast == .increased ? 0.45 : 0.16)), lineWidth: 0.5) }
                    if !section.footer.isEmpty {
                        section.footer.font(.footnote).foregroundStyle(Color.theme.secondaryText)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .buttonStyle(.borderless)
        .textFieldStyle(.plain)
    }
}

struct DaybookList<Content: View>: View {
    var sectionSpacing: CGFloat = 18
    @ViewBuilder var content: Content
    var body: some View {
        List { content.listRowBackground(Color.theme.surface) }
            .listSectionSpacing(sectionSpacing)
            .daybookSurface()
    }
}

struct DaybookPageHeading: View {
    let title: String
    var subtitle: String = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.largeTitle.bold()).accessibilityAddTraits(.isHeader)
            if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(Color.theme.secondaryText) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BookingBadge: View {
    let status: String
    private var tentative: Bool { status == "tentative" || status == "draft" || status == "estimated" }
    var body: some View {
        Text(status == "notCovering" ? "Not covering" : status.capitalized)
            .font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(tentative ? Color.theme.caution : Color.theme.positive)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(tentative ? Color.theme.attention.opacity(0.13) : Color.theme.positive.opacity(0.1), in: Capsule())
    }
}

/// Compact, text-only segments with a separate 44-point touch area.
struct DaybookSegments<Value: Hashable>: View {
    @ScaledMetric(relativeTo: .caption) private var segmentHeight = 32
    let title: String
    @Binding var selection: Value
    let options: [Value]
    let identifier: String
    let label: (Value) -> String
    var color: (Value) -> Color = { _ in Color.theme.accent }
    /// Open items behind a segment, shown as a small amber count.
    var badge: (Value) -> Int = { _ in 0 }
    @Environment(\.dynamicTypeSize) private var typeSize
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                ScrollView(.horizontal) {
                    row.fixedSize(horizontal: true, vertical: false)
                }.scrollIndicators(.hidden)
            } else {
                row
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(title)
        .accessibilityIdentifier(identifier)
    }

    private var row: some View {
        HStack(spacing: 2) {
            ForEach(options, id: \.self) { option in
                let selected = selection == option
                let tint = color(option)
                let count = badge(option)
                Button {
                    if !selected { selection = option }
                } label: {
                    HStack(spacing: 5) {
                        Text(label(option))
                            .font(.caption.weight(selected ? .semibold : .medium))
                            .lineLimit(1)
                            .minimumScaleFactor(0.85)
                        if count > 0 {
                            Text(count, format: .number)
                                .font(.caption2.weight(.bold)).monospacedDigit()
                                .foregroundStyle(Color.theme.caution)
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.theme.attention.opacity(0.18), in: Capsule())
                        }
                    }
                        .padding(.horizontal, 3)
                        .frame(maxWidth: .infinity)
                        .frame(height: segmentHeight)
                        .foregroundStyle(tint)
                        .background(tint.opacity(selected ? 0.18 : 0.035), in: RoundedRectangle(cornerRadius: 6))
                        .overlay {
                            RoundedRectangle(cornerRadius: 6)
                                .strokeBorder(tint.opacity(selected ? 0.45 : (contrast == .increased ? 0.35 : 0)), lineWidth: 1)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(label(option))
                .accessibilityValue(count > 0 ? "\(count) to settle" : "")
                .accessibilityAddTraits(selected ? [.isSelected] : [])
                .accessibilityIdentifier("\(identifier)-\(String(describing: option))")
            }
        }
        .padding(.horizontal, 2)
        .background {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.primary.opacity(0.045))
                .frame(height: segmentHeight + 4)
        }
    }
}

extension BookingStatus {
    var controlColor: Color {
        switch self {
        case .tentative: Color.theme.caution
        case .booked: Color.theme.positive
        case .completed: Color.theme.completed
        case .cancelled: Color.theme.cancelled
        }
    }
}

struct BookingStatusSegments: View {
    @Binding var selection: BookingStatus
    let identifier: String
    var body: some View {
        DaybookSegments(title: "Booking status", selection: $selection,
                        options: BookingStatus.allCases, identifier: identifier,
                        label: { $0.title }, color: { $0.controlColor })
    }
}

struct DaybookMetadata: View {
    @ScaledMetric(relativeTo: .subheadline) private var iconWidth = 21
    let symbol: String
    let text: String
    var body: some View {
        Label { Text(text).foregroundStyle(Color.primary) } icon: { Image(systemName: symbol).foregroundStyle(Color.theme.secondaryText).frame(width: iconWidth) }
            .font(.subheadline)
    }
}

/// Let the system own refraction, press behavior and accessibility adaptations.
struct DaybookPrimaryButton: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.foregroundStyle(Color.theme.onAccent)
        }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.glassProminent)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
    }
}

struct DaybookSecondaryButton: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.foregroundStyle(Color.theme.accent)
        }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.large)
    }
}

/// One glass navigation layer; the agenda and financial content stay opaque.
struct DaybookSidebarSurface: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    func body(content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(Color.theme.surface, in: RoundedRectangle(cornerRadius: 26))
        } else {
            content.glassEffect(.regular.tint(Color.theme.accent.opacity(0.08)), in: .rect(cornerRadius: 26))
        }
    }
}

struct DaybookDateRail: View {
    @ScaledMetric(relativeTo: .body) private var railWidth = 47
    let day: String
    var body: some View {
        if let date = Day.date(from: day) {
            VStack(spacing: 2) {
                Text(date.formatted(.dateTime.weekday(.abbreviated))).font(.caption)
                Text(date.formatted(.dateTime.day())).font(.title.weight(.semibold)).monospacedDigit()
                Text(date.formatted(.dateTime.month(.abbreviated))).font(.caption)
            }.foregroundStyle(Color.theme.accent).frame(width: railWidth).accessibilityElement(children: .combine)
        }
    }
}

/// A consistent first row for tab pages, with room for larger accessibility text.
struct DaybookTabHeader<Action: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ViewBuilder var action: Action

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                stacked
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) {
                        BrandLockup().fixedSize(horizontal: true, vertical: false)
                        Spacer(minLength: 0)
                        action.fixedSize(horizontal: true, vertical: false)
                    }
                    stacked
                }
            }
        }
        .frame(minHeight: 48, alignment: .leading)
    }

    private var stacked: some View {
        VStack(alignment: .leading, spacing: 12) {
            BrandLockup()
            action
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BrandLockup: View {
    var body: some View {
        HStack(spacing: 8) {
            CuekeeperMark().fill(Color.theme.accent, style: FillStyle(eoFill: true)).frame(width: 27, height: 31)
                .accessibilityHidden(true)
            Text("Cuekeeper").font(.title3.weight(.bold)).tracking(-0.5)
        }.foregroundStyle(Color.theme.accent).accessibilityElement(children: .combine)
    }
}


extension View {
    func daybookSurface() -> some View {
        toolbar(.visible, for: .navigationBar)
            .scrollContentBackground(.hidden)
            .background(Color.theme.page)
            .toolbarBackground(.automatic, for: .navigationBar, .tabBar)
    }
}

/// Explicit field labels remain visible outside the system Form container.
struct DaybookPicker<Selection: Hashable, Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    let title: String
    @Binding var selection: Selection
    var identifier: String = ""
    @ViewBuilder var content: Content
    init(_ title: String, selection: Binding<Selection>, identifier: String = "", @ViewBuilder content: () -> Content) {
        self.title = title; _selection = selection; self.identifier = identifier; self.content = content()
    }
    var body: some View {
        if typeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                Picker(title, selection: $selection) { content }.labelsHidden()
                    .fixedSize(horizontal: false, vertical: true).accessibilityIdentifier(identifier)
            }
        } else {
            LabeledContent {
                Picker(title, selection: $selection) { content }.labelsHidden().accessibilityIdentifier(identifier)
            } label: { Text(title) }
        }
    }
}

/// Short, mutually exclusive choices stay visible when they fit comfortably.
/// Keep the same selection binding and label when Dynamic Type needs a menu.
struct DaybookChoicePicker<Selection: Hashable, Content: View>: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @ScaledMetric(relativeTo: .body) private var minimumSegmentWidth = 300
    let title: String
    @Binding var selection: Selection
    var identifier: String
    @ViewBuilder var content: Content

    init(_ title: String, selection: Binding<Selection>, identifier: String, @ViewBuilder content: () -> Content) {
        self.title = title
        _selection = selection
        self.identifier = identifier
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).foregroundStyle(Color.primary)
            if typeSize > .xLarge {
                menu
            } else {
                ViewThatFits(in: .horizontal) {
                    Picker(title, selection: $selection) { content }
                        .pickerStyle(.segmented).labelsHidden()
                        .frame(minWidth: minimumSegmentWidth, minHeight: 44)
                        .accessibilityIdentifier(identifier)
                    menu
                }
            }
        }
    }

    private var menu: some View {
        Picker(title, selection: $selection) { content }
            .pickerStyle(.menu).labelsHidden()
            .frame(minHeight: 44, alignment: .leading)
            .accessibilityIdentifier(identifier)
    }
}

struct DaybookLink<Destination: View, Label: View>: View {
    @ViewBuilder var destination: Destination
    @ViewBuilder var label: Label
    var body: some View {
        NavigationLink { destination } label: {
            HStack(spacing: 10) {
                label.foregroundStyle(Color.primary).frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color.theme.secondaryText)
            }.contentShape(Rectangle())
        }
    }
}
extension DaybookLink where Label == Text {
    init(_ title: String, @ViewBuilder destination: () -> Destination) {
        self.destination = destination(); self.label = Text(title)
    }
}

/// An icon-led action that sits as a row inside a ruled panel, so actions belong to their group instead of floating beside it.
struct DaybookActionRow: View {
    @ScaledMetric(relativeTo: .body) private var iconSize = 30
    let title: String
    let symbol: String
    let action: () -> Void
    init(_ title: String, systemImage symbol: String, action: @escaping () -> Void) {
        self.title = title; self.symbol = symbol; self.action = action
    }
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.subheadline.weight(.semibold))
                    .frame(width: iconSize, height: iconSize)
                    .background(Color.theme.accent.opacity(0.13), in: Circle())
                    .accessibilityHidden(true)
                Text(title).frame(maxWidth: .infinity, alignment: .leading)
            }
            .foregroundStyle(Color.theme.accent)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

extension ContainerValues {
    @Entry var daybookUnframed = false
    @Entry var daybookFlushTop = false
}

extension WorkSession {
    var compactSchedule: String {
        guard let startTime else { return day.isEmpty ? "Schedule to come" : "Time to come · \(Day.display(day))" }
        var result = "\(shortDate(startTime)) · \(shortTime(startTime))"
        if let endTime {
            let zone = TimeZone.effective(eventTimeZoneID)
            let overnight = Day.string(from: startTime, timeZone: zone) != Day.string(from: endTime, timeZone: zone)
            result += " – \(overnight ? shortDate(endTime) + " " : "")\(shortTime(endTime))"
        }
        let zone = TimeZone.effective(eventTimeZoneID)
        return result + " " + (zone.abbreviation(for: startTime) ?? eventTimeZoneID)
    }
    func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone.effective(eventTimeZoneID)
        formatter.dateStyle = .medium; formatter.timeStyle = .none
        return formatter.string(from: date)
    }
    func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone.effective(eventTimeZoneID)
        formatter.dateStyle = .none; formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

/// Keeps placeholder copy readable on both approved page surfaces.
struct DaybookTextField: View {
    let title: String
    @Binding var text: String
    var axis: Axis
    init(_ title: String, text: Binding<String>, axis: Axis = .horizontal) {
        self.title = title; self._text = text; self.axis = axis
    }
    var body: some View {
        TextField(title, text: $text, prompt: Text(title).foregroundStyle(Color.theme.secondaryText), axis: axis)
    }
}
