// Renders the iCloud sync settings concept boards to PNG.
// Usage: swift design/icloud-sync/render-concepts.swift <output-directory>
// Conceptual images only: macOS SwiftUI approximates the native iOS form.
import AppKit
import SwiftUI

// MARK: Palette (DESIGN.md tokens)

struct Palette {
    let accent, page, surface, secondary, amber, ink, rule: Color
    static let light = Palette(accent: Color(hex: 0x073E27), page: Color(hex: 0xFAF8F2), surface: .white,
                               secondary: Color(hex: 0x626860), amber: Color(hex: 0x88570C), ink: Color(hex: 0x171E19),
                               rule: Color(hex: 0x171E19).opacity(0.16))
    static let dark = Palette(accent: Color(hex: 0xA7DCB4), page: Color(hex: 0x171E19), surface: Color(hex: 0x2C352F),
                              secondary: Color(hex: 0xB7BFB8), amber: Color(hex: 0xF0BC59), ink: Color(hex: 0xFAF8F2),
                              rule: Color(hex: 0xFAF8F2).opacity(0.16))
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

enum SyncState: CaseIterable {
    case synced, sending, receiving, firstDownload, offline, attention, account
    var name: String {
        switch self {
        case .synced: "Synced"
        case .sending: "Sending"
        case .receiving: "Receiving"
        case .firstDownload: "First download"
        case .offline: "Offline"
        case .attention: "Transfer failed"
        case .account: "Account issue"
        }
    }
}

// MARK: Shared form pieces

struct Panel<Content: View>: View {
    let p: Palette
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 0) { content }
            .background(p.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(p.rule, lineWidth: 0.5) }
    }
}

struct Rule: View {
    let p: Palette
    var body: some View { Rectangle().fill(p.rule).frame(height: 0.5).padding(.leading, 16) }
}

struct LinkRow: View {
    let p: Palette
    let symbol: String
    let title: String
    var value: String? = nil
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 16)).frame(width: 24).foregroundStyle(p.accent)
            Text(title).font(.system(size: 17)).foregroundStyle(p.accent)
            Spacer(minLength: 8)
            if let value { Text(value).font(.system(size: 17)).foregroundStyle(p.secondary) }
            Image(systemName: "chevron.right").font(.system(size: 12, weight: .semibold)).foregroundStyle(p.secondary)
        }
        .padding(.horizontal, 16).frame(minHeight: 48)
    }
}

struct SectionTitle: View {
    let p: Palette
    let text: String
    var body: some View {
        Text(text).font(.system(size: 17, weight: .semibold)).foregroundStyle(p.ink).padding(.bottom, 9)
    }
}

// MARK: Concept A — Two places

/// Shows the two copies of the data and the state of the link between them.
struct PathPanel: View {
    let p: Palette
    let state: SyncState

    var body: some View {
        Panel(p: p) {
            HStack(alignment: .top, spacing: 0) {
                node(symbol: "iphone", title: "This iPhone", caption: "Saved", tone: p.secondary)
                connector.frame(height: 44)
                node(symbol: cloudSymbol, title: "iCloud", caption: cloudCaption, tone: cloudTone)
            }
            .padding(.horizontal, 12).padding(.top, 18).padding(.bottom, 14)
            if let action {
                Rule(p: p)
                HStack {
                    Text(action.note).font(.system(size: 15)).foregroundStyle(p.ink)
                    Spacer()
                    Text(action.button).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.accent)
                        .padding(.horizontal, 14).padding(.vertical, 7)
                        .background(p.accent.opacity(0.1), in: Capsule())
                }
                .padding(.horizontal, 16).frame(minHeight: 52)
            }
            Rule(p: p)
            LinkRow(p: p, symbol: "info.circle", title: "iCloud details")
        }
    }

    private var action: (note: String, button: String)? {
        switch state {
        case .attention: ("iCloud will retry on its own.", "Check now")
        case .account: ("Sign in to iCloud in Settings.", "Check again")
        default: nil
        }
    }

    private var cloudSymbol: String {
        switch state {
        case .offline: "icloud.slash"
        case .attention, .account: "exclamationmark.icloud"
        default: "icloud"
        }
    }

    private var cloudCaption: String {
        switch state {
        case .synced: "Synced 2:41 PM"
        case .sending: "Sending…"
        case .receiving: "Receiving…"
        case .firstDownload: "Downloading…"
        case .offline: "When online"
        case .attention: "Not reached"
        case .account: "Signed out"
        }
    }

    private var cloudTone: Color {
        switch state {
        case .attention, .account: p.amber
        default: p.secondary
        }
    }

    private func node(symbol: String, title: String, caption: String, tone: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: symbol).font(.system(size: 26, weight: .regular))
                .foregroundStyle(tone == p.amber ? p.amber : p.accent)
                .frame(width: 52, height: 44)
            Text(title).font(.system(size: 15, weight: .semibold)).foregroundStyle(p.ink)
            Text(caption).font(.system(size: 13)).foregroundStyle(tone).monospacedDigit()
        }
        .frame(width: 104)
    }

    @ViewBuilder private var connector: some View {
        GeometryReader { geo in
            let y = geo.size.height / 2
            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: 4, y: y)); path.addLine(to: CGPoint(x: geo.size.width - 4, y: y))
                }
                .stroke(lineColor, style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: dashed ? [3, 5] : []))
                badge.position(x: geo.size.width / 2, y: y)
            }
        }
    }

    private var dashed: Bool { [.offline, .attention, .account, .firstDownload].contains(state) }
    private var lineColor: Color {
        switch state {
        case .attention, .account: p.amber.opacity(0.7)
        case .offline: p.secondary.opacity(0.6)
        default: p.accent.opacity(0.75)
        }
    }

    @ViewBuilder private var badge: some View {
        let symbol: String? = switch state {
        case .synced: "checkmark"
        case .sending: "chevron.right.2"
        case .receiving, .firstDownload: "chevron.left.2"
        case .offline: "wifi.slash"
        case .attention, .account: "exclamationmark"
        }
        if let symbol {
            Image(systemName: symbol).font(.system(size: 11, weight: .bold))
                .foregroundStyle(state == .offline ? p.secondary : (state == .attention || state == .account ? p.amber : p.accent))
                .frame(width: 26, height: 26)
                .background(p.surface, in: Circle())
                .overlay { Circle().strokeBorder(lineColor, lineWidth: 1.5) }
        }
    }
}

// MARK: Concept B — Status ledger

/// One headline answers "is my work safe?"; three short rows say where it lives.
struct LedgerPanel: View {
    let p: Palette
    let state: SyncState
    var showsRows = true

    var body: some View {
        Panel(p: p) {
            HStack(spacing: 14) {
                Image(systemName: headlineSymbol).font(.system(size: 20, weight: .medium))
                    .foregroundStyle(warning ? p.amber : p.accent)
                    .frame(width: 44, height: 44)
                    .background((warning ? p.amber : p.accent).opacity(0.12), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline).font(.system(size: 20, weight: .semibold)).foregroundStyle(p.ink)
                    Text(subhead).font(.system(size: 15)).foregroundStyle(warning ? p.amber : p.secondary).monospacedDigit()
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16).padding(.vertical, 14)
            if showsRows {
                Rule(p: p)
                ledgerRow("This iPhone", value: "Saved", ok: true)
                Rule(p: p)
                ledgerRow("iCloud account", value: state == .account ? "Signed out" : "Available", ok: state != .account)
            }
        }
    }

    private var warning: Bool { state == .attention || state == .account }

    private var headlineSymbol: String {
        switch state {
        case .synced: "checkmark"
        case .sending: "arrow.up"
        case .receiving, .firstDownload: "arrow.down"
        case .offline: "icloud.slash"
        case .attention, .account: "exclamationmark"
        }
    }

    private var headline: String {
        switch state {
        case .synced: "Synced"
        case .sending: "Sending changes"
        case .receiving: "Receiving changes"
        case .firstDownload: "Downloading your work"
        case .offline: "Offline"
        case .attention: "Sync paused"
        case .account: "iCloud signed out"
        }
    }

    private var subhead: String {
        switch state {
        case .synced: "Last exchange 2:41 PM"
        case .sending, .receiving: "Last exchange 2:41 PM"
        case .firstDownload: "Events may still arrive"
        case .offline: "Syncs when you reconnect"
        case .attention: "Retrying automatically"
        case .account: "Saved on this iPhone only"
        }
    }

    private func ledgerRow(_ title: String, value: String, ok: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 15)).foregroundStyle(ok ? p.accent : p.amber).frame(width: 18)
            Text(title).font(.system(size: 17)).foregroundStyle(p.ink)
            Spacer()
            Text(value).font(.system(size: 17)).foregroundStyle(ok ? p.secondary : p.amber)
        }
        .padding(.horizontal, 16).frame(minHeight: 48)
    }
}

// MARK: Phone screen

enum Concept { case path, ledger }

struct SettingsScreen: View {
    let p: Palette
    let concept: Concept
    let state: SyncState

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("9:41").font(.system(size: 16, weight: .semibold))
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: "cellularbars"); Image(systemName: "wifi"); Image(systemName: "battery.100")
                }.font(.system(size: 14, weight: .semibold))
            }
            .foregroundStyle(p.ink).padding(.horizontal, 30).frame(height: 50)

            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 5).fill(p.accent).frame(width: 22, height: 26)
                        .overlay { Image(systemName: "bookmark.fill").font(.system(size: 11)).foregroundStyle(p.page) }
                    Text("Cuekeeper").font(.system(size: 22, weight: .bold)).foregroundStyle(p.accent)
                }
                .padding(.top, 6)

                VStack(alignment: .leading, spacing: 0) {
                    SectionTitle(p: p, text: "Integrations")
                    Panel(p: p) {
                        LinkRow(p: p, symbol: "calendar", title: "Calendar")
                        Rule(p: p)
                        LinkRow(p: p, symbol: "creditcard", title: "Wallet Automation")
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    SectionTitle(p: p, text: concept == .path ? "iCloud sync" : "Your data")
                    switch concept {
                    case .path: PathPanel(p: p, state: state)
                    case .ledger: LedgerPanel(p: p, state: state)
                    }
                }

                VStack(alignment: .leading, spacing: 0) {
                    SectionTitle(p: p, text: "Recovery & backups")
                    Panel(p: p) {
                        LinkRow(p: p, symbol: "icloud.and.arrow.up", title: "Backups", value: "Oct 12")
                        Rule(p: p)
                        LinkRow(p: p, symbol: "trash", title: "Recently Deleted")
                    }
                }
            }
            .padding(.horizontal, 20)
            Spacer(minLength: 0)

            HStack {
                ForEach(Array(["calendar.day.timeline.left", "list.bullet.rectangle", "banknote", "receipt", "gearshape.fill"].enumerated()), id: \.offset) { i, symbol in
                    VStack(spacing: 3) {
                        Image(systemName: symbol).font(.system(size: 19))
                        Text(["Upcoming", "Events", "Payments", "Expenses", "Settings"][i]).font(.system(size: 10, weight: .medium))
                    }
                    .foregroundStyle(i == 4 ? p.accent : p.secondary)
                    .frame(maxWidth: .infinity)
                }
            }
            .padding(.vertical, 8).padding(.horizontal, 8)
            .background(p.surface.opacity(0.92), in: Capsule())
            .overlay { Capsule().strokeBorder(p.rule, lineWidth: 0.5) }
            .padding(.horizontal, 18).padding(.bottom, 26)
        }
        .frame(width: 390, height: 844)
        .background(p.page)
        .clipShape(RoundedRectangle(cornerRadius: 52))
        .overlay { RoundedRectangle(cornerRadius: 52).strokeBorder(Color.black.opacity(0.85), lineWidth: 7) }
        .shadow(color: .black.opacity(0.12), radius: 20, y: 10)
    }
}

// MARK: Board

struct Board: View {
    let concept: Concept
    let title: String
    let summary: String
    let states: [SyncState]
    let notes: [String]
    private let ink = Color(hex: 0x171E19)
    private let muted = Color(hex: 0x4E554F)

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.system(size: 34, weight: .bold)).foregroundStyle(ink)
                Text(summary).font(.system(size: 18)).foregroundStyle(muted)
            }
            HStack(alignment: .top, spacing: 40) {
                VStack(spacing: 14) {
                    SettingsScreen(p: .light, concept: concept, state: .synced)
                    caption("Synced · light")
                }
                VStack(spacing: 14) {
                    SettingsScreen(p: .dark, concept: concept, state: .attention)
                    caption("Transfer failed · dark")
                }
                VStack(alignment: .leading, spacing: 18) {
                    Text("States").font(.system(size: 20, weight: .semibold)).foregroundStyle(ink)
                    LazyVGrid(columns: [GridItem(.fixed(350), spacing: 22, alignment: .top), GridItem(.fixed(350), alignment: .top)], alignment: .leading, spacing: 20) {
                        ForEach(states, id: \.self) { state in
                            VStack(alignment: .leading, spacing: 8) {
                                caption(state.name)
                                Group {
                                    switch concept {
                                    case .path: PathPanel(p: .light, state: state)
                                    case .ledger: LedgerPanel(p: .light, state: state, showsRows: state == .account)
                                    }
                                }
                                .padding(14)
                                .background(Palette.light.page, in: RoundedRectangle(cornerRadius: 18))
                            }
                        }
                    }
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(notes, id: \.self) { note in
                            HStack(alignment: .firstTextBaseline, spacing: 8) {
                                Circle().fill(Palette.light.accent).frame(width: 5, height: 5).offset(y: -3)
                                Text(note).font(.system(size: 15)).foregroundStyle(muted).fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .frame(width: 722, alignment: .leading)
                    .padding(.top, 6)
                }
            }
        }
        .padding(56)
        .background(Color(hex: 0xE7E9E5))
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.system(size: 14, weight: .semibold)).foregroundStyle(muted)
    }
}

// MARK: Render

@MainActor func render(_ view: some View, to url: URL) {
    let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light))
    renderer.scale = 2
    guard let image = renderer.cgImage,
          let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
        fatalError("Render failed for \(url.lastPathComponent)")
    }
    try! data.write(to: url)
    print("Wrote \(url.path) (\(image.width)×\(image.height))")
}

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? ".")
MainActor.assumeIsolated {
    render(Board(concept: .path,
                 title: "Concept A · Two places",
                 summary: "A picture of where your work lives. The line between this iPhone and iCloud carries the state.",
                 states: [.sending, .receiving, .firstDownload, .offline, .attention, .account],
                 notes: [
                    "Replaces the account row, message, error text, transfer status, footnote and footer with two labelled nodes.",
                    "This iPhone always reads Saved; only the iCloud side and the line change. Account, last transfer and Check iCloud move into iCloud details.",
                    "Motion: chevrons drift along the line while transferring; a 200 ms crossfade between states; static under Reduce Motion.",
                 ]),
           to: output.appendingPathComponent("concept-a-two-places.png"))
    render(Board(concept: .ledger,
                 title: "Concept B · Status ledger",
                 summary: "One headline answers “is my work syncing?” Two short rows say where it is kept.",
                 states: [.sending, .receiving, .firstDownload, .offline, .attention, .account],
                 notes: [
                    "Your data describes live sync only; the headline is the only line that changes for routine activity.",
                    "The latest manual backup date sits on the Backups row, so it isn’t read as part of sync.",
                    "Checks turn amber on the failing row, so an account issue points at the account, not at sync in general.",
                    "“Last exchange” describes this device only. No state claims every device is current.",
                 ]),
           to: output.appendingPathComponent("concept-b-status-ledger.png"))
}
