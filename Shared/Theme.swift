import Observation
import SwiftUI
import UIKit

/// A light and dark value for one color role. Every color in the app and widget starts here.
struct ColorPair: Equatable, Sendable {
    let light: UInt32
    let dark: UInt32
    init(_ light: UInt32, _ dark: UInt32) { self.light = light; self.dark = dark }

    /// Follows the view's appearance.
    var color: Color { Color(uiColor: uiColor) }
    var uiColor: UIColor {
        let light = Self.uiColor(light), dark = Self.uiColor(dark)
        return UIColor { $0.userInterfaceStyle == .dark ? dark : light }
    }
    /// A fixed value, for surfaces such as widgets that resolve their own appearance.
    func color(for scheme: ColorScheme) -> Color { Color(uiColor: Self.uiColor(scheme == .dark ? dark : light)) }
    func hex(dark: Bool) -> UInt32 { dark ? self.dark : light }

    private static func uiColor(_ hex: UInt32) -> UIColor {
        UIColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

/// The user-selectable part of the palette. Each theme must supply every role, so a new
/// role cannot ship without a value for every theme.
struct Theme: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    /// The alternate app icon; nil is the primary icon.
    let iconName: String?
    /// Interaction and brand only: buttons, links, selection, the mark and date rails.
    /// Never use it to mean booked, paid or done; that is `positive`.
    let accent: ColorPair
    /// Text and symbols on a solid accent fill.
    let onAccent: ColorPair
    /// A pale accent for labels on an accent fill, and the light app icon's mark.
    let accentSoft: ColorPair
    let page: ColorPair
    let surface: ColorPair
    let secondaryText: ColorPair
    /// Booked, paid and done. A fixed green, except where the accent is itself green.
    let positive: ColorPair
    /// Tentative, draft and needs-attention text. Amber, except where the accent is itself amber.
    var caution: ColorPair = StatusPalette.tentative
    /// Fills behind caution states, at reduced opacity. The system orange, except beside an amber accent.
    var attention: ColorPair = StatusPalette.attention
}

extension Theme {
    static let green = ColorPair(0x05773B, 0x6DE18B)

    static let teal = Theme(id: "teal", name: "Teal", iconName: nil,
        accent: ColorPair(0x17745D, 0x6FE4BF), onAccent: ColorPair(0xFFFFFF, 0x151817), accentSoft: ColorPair(0xC6F4E4, 0x6FE4BF),
        page: ColorPair(0xF5F8F7, 0x151817), surface: ColorPair(0xFFFFFF, 0x222625), secondaryText: ColorPair(0x5E6663, 0xA5ADAA),
        // Teal sits too close to green for a separate booked color, so confirmed work takes the accent.
        positive: ColorPair(0x17745D, 0x6FE4BF))
    static let indigo = Theme(id: "indigo", name: "Indigo", iconName: "CuekeeperIndigo",
        accent: ColorPair(0x5A4EBF, 0xADAEFC), onAccent: ColorPair(0xFFFFFF, 0x151618), accentSoft: ColorPair(0xDCDDFE, 0xADAEFC),
        page: ColorPair(0xF6F7F9, 0x151618), surface: ColorPair(0xFFFFFF, 0x232427), secondaryText: ColorPair(0x62646B, 0xAAABB1),
        positive: green)
    static let purple = Theme(id: "purple", name: "Purple", iconName: "CuekeeperPurple",
        accent: ColorPair(0x703BA1, 0xD0AAFC), onAccent: ColorPair(0xFFFFFF, 0x171518), accentSoft: ColorPair(0xEBDDFE, 0xD0AAFC),
        page: ColorPair(0xF8F6F9, 0x171518), surface: ColorPair(0xFFFFFF, 0x262428), secondaryText: ColorPair(0x656269, 0xACA9B1),
        positive: green)
    static let magenta = Theme(id: "magenta", name: "Magenta", iconName: "CuekeeperMagenta",
        accent: ColorPair(0xA32384, 0xF59CD8), onAccent: ColorPair(0xFFFFFF, 0x181517), accentSoft: ColorPair(0xFFE1F4, 0xF59CD8),
        page: ColorPair(0xF9F6F8, 0x181517), surface: ColorPair(0xFFFFFF, 0x282426), secondaryText: ColorPair(0x686165, 0xB0A8AD),
        positive: green)
    static let ink = Theme(id: "ink", name: "Ink", iconName: "CuekeeperInk",
        accent: ColorPair(0x2B2A44, 0xDCDCEE), onAccent: ColorPair(0xFFFFFF, 0x161619), accentSoft: ColorPair(0xE9E9FC, 0xDCDCEE),
        page: ColorPair(0xF7F7FA, 0x161619), surface: ColorPair(0xFFFFFF, 0x252529), secondaryText: ColorPair(0x62626A, 0xAAAAB2),
        positive: green)

    static let violet = ColorPair(0x703BA1, 0xD0AAFC)

    // Amber already means tentative and needs-attention, so this theme moves those states to violet.
    static let amber = Theme(id: "amber", name: "Cue Amber", iconName: "CuekeeperAmber",
        accent: ColorPair(0xA0600B, 0xFCB442), onAccent: ColorPair(0xFFFFFF, 0x1A1918), accentSoft: ColorPair(0xFFF3DE, 0xFCB442),
        page: ColorPair(0xFAF8F2, 0x1A1918), surface: ColorPair(0xFFFFFF, 0x282623), secondaryText: ColorPair(0x66625A, 0xAFABA3),
        positive: green, caution: violet, attention: violet)
    // Olive sits midway between tentative amber and booked green, as far from each as it can.
    static let olive = Theme(id: "olive", name: "Olive", iconName: "CuekeeperOlive",
        accent: ColorPair(0x646904, 0xCBD95B), onAccent: ColorPair(0xFFFFFF, 0x161614), accentSoft: ColorPair(0xE8EFD2, 0xCBD95B),
        page: ColorPair(0xF7F7F4, 0x161614), surface: ColorPair(0xFFFFFF, 0x252622), secondaryText: ColorPair(0x62645D, 0xAAACA4),
        positive: green)
    static let espresso = Theme(id: "espresso", name: "Espresso", iconName: "CuekeeperEspresso",
        accent: ColorPair(0x443124, 0xEFD9CC), onAccent: ColorPair(0xFFFFFF, 0x181513), accentSoft: ColorPair(0xFFE6D6, 0xEFD9CC),
        page: ColorPair(0xF9F6F5, 0x181513), surface: ColorPair(0xFFFFFF, 0x282422), secondaryText: ColorPair(0x69625D, 0xB1A9A4),
        positive: green)
    static let graphite = Theme(id: "graphite", name: "Graphite", iconName: "CuekeeperGraphite",
        accent: ColorPair(0x2A2E34, 0xE1E5EA), onAccent: ColorPair(0xFFFFFF, 0x151618), accentSoft: ColorPair(0xE1E5EA, 0xE1E5EA),
        page: ColorPair(0xF6F7F9, 0x151618), surface: ColorPair(0xFFFFFF, 0x232427), secondaryText: ColorPair(0x62646B, 0xAAABB1),
        positive: green)

    static let all = [teal, indigo, purple, magenta, amber, olive, espresso, ink, graphite]
    static let standard = teal
    static func named(_ id: String?) -> Theme { all.first { $0.id == id } ?? standard }
}

/// Status colors keep one meaning in every theme; themes are checked against them.
/// Only a theme whose accent shares a status hue may move that status, through its own role.
enum StatusPalette {
    static let tentative = ColorPair(0x88570C, 0xFCBF4D)
    static let completed = ColorPair(0x255E7F, 0x93CCF2)
    static let cancelled = ColorPair(0x8A4343, 0xF5A5A2)
    /// Needs attention: missing details, overdue money, held-up work. The system orange.
    static let attention = ColorPair(0xFF9500, 0xFF9F0A)
    /// Destructive actions. The system red.
    static let destructive = ColorPair(0xFF3B30, 0xFF453A)
}

/// The colors views use, read as `Color.theme.accent`. Reading them inside a view's body
/// registers the view with `ThemeStore`, so a theme change redraws it in place.
struct ThemeColors {
    let theme: Theme
    var accent: Color { theme.accent.color }
    var onAccent: Color { theme.onAccent.color }
    var accentSoft: Color { theme.accentSoft.color }
    var page: Color { theme.page.color }
    var surface: Color { theme.surface.color }
    var secondaryText: Color { theme.secondaryText.color }
    var positive: Color { theme.positive.color }
    /// Tentative, draft and needs-attention text.
    var caution: Color { theme.caution.color }
    var completed: Color { StatusPalette.completed.color }
    var cancelled: Color { StatusPalette.cancelled.color }
    var attention: Color { theme.attention.color }
    var destructive: Color { StatusPalette.destructive.color }
}

extension Color {
    static var theme: ThemeColors { ThemeColors(theme: ThemeStore.shared.theme) }
}

/// The chosen theme is a device preference, shared with the widget through the app group.
@Observable
final class ThemeStore {
    static let shared = ThemeStore()
    static let key = "theme"
    static var defaults: UserDefaults { UserDefaults(suiteName: ScheduleStore.group) ?? .standard }

    private(set) var theme: Theme

    init() { theme = Self.saved() }

    static func saved() -> Theme { Theme.named(defaults.string(forKey: key)) }

    func select(_ theme: Theme) {
        Self.defaults.set(theme.id, forKey: Self.key)
        self.theme = theme
    }

    /// Shows a theme without saving it, for design captures.
    func preview(_ theme: Theme) { self.theme = theme }
}
