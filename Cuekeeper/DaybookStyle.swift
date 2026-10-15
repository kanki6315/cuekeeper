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
        VStack(alignment: .leading, spacing: compact ? 8 : 24) {
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
                    .background(section.containerValues.daybookUnframed ? Color.clear : Color("SurfaceBackground"), in: RoundedRectangle(cornerRadius: 12))
                    .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.primary.opacity(section.containerValues.daybookUnframed ? 0 : (contrast == .increased ? 0.45 : 0.16)), lineWidth: 0.5) }
                    if !section.footer.isEmpty {
                        section.footer.font(.footnote).foregroundStyle(Color("SecondaryText"))
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
        List { content.listRowBackground(Color("SurfaceBackground")) }
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
            if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(Color("SecondaryText")) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct BookingBadge: View {
    let status: String
    private var tentative: Bool { status == "tentative" || status == "draft" || status == "estimated" }
    var body: some View {
        Text(status == "notCovering" ? "Not covering" : status.capitalized)
            .font(.caption.weight(.semibold)).fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(tentative ? Color("AmberText") : Color.accentColor)
            .padding(.horizontal, 9).padding(.vertical, 5)
            .background(tentative ? Color.orange.opacity(0.13) : Color.accentColor.opacity(0.1), in: Capsule())
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
    var color: (Value) -> Color = { _ in Color.accentColor }
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
                Button {
                    if !selected { selection = option }
                } label: {
                    Text(label(option))
                        .font(.caption.weight(selected ? .semibold : .medium))
                        .lineLimit(1)
                        .minimumScaleFactor(0.85)
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
    var controlColor: Color { Color("Booking" + title) }
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
        Label { Text(text).foregroundStyle(Color.primary) } icon: { Image(systemName: symbol).foregroundStyle(Color("SecondaryText")).frame(width: iconWidth) }
            .font(.subheadline)
    }
}

/// Let the system own refraction, press behavior and accessibility adaptations.
struct DaybookPrimaryButton: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Button(role: configuration.role, action: configuration.trigger) {
            configuration.label.foregroundStyle(Color("PrimaryButtonText"))
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
            configuration.label.foregroundStyle(Color.accentColor)
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
            content.background(Color("SurfaceBackground"), in: RoundedRectangle(cornerRadius: 26))
        } else {
            content.glassEffect(.regular.tint(Color.accentColor.opacity(0.08)), in: .rect(cornerRadius: 26))
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
            }.foregroundStyle(Color.accentColor).frame(width: railWidth).accessibilityElement(children: .combine)
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
            CuekeeperMark().fill(Color.accentColor, style: FillStyle(eoFill: true)).frame(width: 27, height: 31)
                .accessibilityHidden(true)
            Text("Cuekeeper").font(.title3.weight(.bold)).tracking(-0.5)
        }.foregroundStyle(Color.accentColor).accessibilityElement(children: .combine)
    }
}

/// Exact outlines from design/brand/source/cuekeeper-mark-forest.svg, without its export padding.
struct CuekeeperMark: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x:66,y:351)); p.addCurve(to: CGPoint(x:47,y:320), control1: CGPoint(x:54,y:348), control2: CGPoint(x:49,y:337))
        p.addLine(to: CGPoint(x:0,y:93)); p.addCurve(to: CGPoint(x:32,y:42), control1: CGPoint(x:-6,y:67), control2: CGPoint(x:7,y:49))
        p.addLine(to: CGPoint(x:209,y:1)); p.addCurve(to: CGPoint(x:267,y:37), control1: CGPoint(x:237,y:-6), control2: CGPoint(x:260,y:10))
        p.addLine(to: CGPoint(x:274,y:65)); p.addLine(to: CGPoint(x:137,y:65)); p.addCurve(to: CGPoint(x:66,y:135), control1: CGPoint(x:95,y:65), control2: CGPoint(x:66,y:94)); p.closeSubpath()
        p.move(to: CGPoint(x:137,y:85)); p.addLine(to: CGPoint(x:333,y:85)); p.addCurve(to: CGPoint(x:383,y:135), control1: CGPoint(x:362,y:85), control2: CGPoint(x:383,y:106)); p.addLine(to: CGPoint(x:383,y:419)); p.addCurve(to: CGPoint(x:355,y:437), control1: CGPoint(x:383,y:439), control2: CGPoint(x:370,y:448)); p.addLine(to: CGPoint(x:243,y:355)); p.addQuadCurve(to: CGPoint(x:227,y:355), control: CGPoint(x:235,y:349)); p.addLine(to: CGPoint(x:113,y:437)); p.addCurve(to: CGPoint(x:86,y:421), control1: CGPoint(x:97,y:449), control2: CGPoint(x:86,y:438)); p.addLine(to: CGPoint(x:86,y:136)); p.addCurve(to: CGPoint(x:137,y:85), control1: CGPoint(x:86,y:106), control2: CGPoint(x:107,y:85)); p.closeSubpath()
        p.addRoundedRect(in: CGRect(x:144,y:200,width:183,height:40), cornerSize: CGSize(width:20,height:20))
        return p.applying(CGAffineTransform(scaleX: rect.width / 383, y: rect.height / 448))
    }
}

extension View {
    func daybookSurface() -> some View {
        toolbar(.visible, for: .navigationBar)
            .scrollContentBackground(.hidden)
            .background(Color("PageBackground"))
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
                Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Color("SecondaryText"))
            }.contentShape(Rectangle())
        }
    }
}
extension DaybookLink where Label == Text {
    init(_ title: String, @ViewBuilder destination: () -> Destination) {
        self.destination = destination(); self.label = Text(title)
    }
}

extension ContainerValues {
    @Entry var daybookUnframed = false
    @Entry var daybookFlushTop = false
}

extension WorkSession {
    var compactSchedule: String {
        guard let startTime else { return day.isEmpty ? "Schedule to come" : "Time to come · \(day)" }
        var result = "\(shortDate(startTime)) · \(shortTime(startTime))"
        if let endTime {
            let zone = TimeZone(identifier: eventTimeZoneID) ?? .current
            let overnight = Day.string(from: startTime, timeZone: zone) != Day.string(from: endTime, timeZone: zone)
            result += " – \(overnight ? shortDate(endTime) + " " : "")\(shortTime(endTime))"
        }
        let zone = TimeZone(identifier: eventTimeZoneID) ?? .current
        return result + " " + (zone.abbreviation(for: startTime) ?? eventTimeZoneID)
    }
    func shortDate(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: eventTimeZoneID) ?? .current
        formatter.dateStyle = .medium; formatter.timeStyle = .none
        return formatter.string(from: date)
    }
    func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter(); formatter.timeZone = TimeZone(identifier: eventTimeZoneID) ?? .current
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
        TextField(title, text: $text, prompt: Text(title).foregroundStyle(Color("SecondaryText")), axis: axis)
    }
}
