import Foundation
import XCTest
@testable import Cuekeeper

/// Guards every theme against the fixed status colors, and the code against colors
/// that bypass the theme.
final class ThemeTests: XCTestCase {
    /// Accents closer than this to a status hue read as that status.
    private let minimumHueDistance = 35.0
    /// Below this OKLCH chroma an accent reads as neutral, so its hue cannot be confused with a status.
    private let neutralChroma = 0.06

    func testEveryThemeMeetsTextContrast() {
        for theme in Theme.all {
            for dark in [false, true] {
                let mode = "\(theme.name) \(dark ? "dark" : "light")"
                for (name, foreground) in [("accent", theme.accent), ("secondary text", theme.secondaryText), ("positive", theme.positive), ("caution", theme.caution)] {
                    for (backgroundName, background) in [("page", theme.page), ("surface", theme.surface)] {
                        assertContrast(foreground, on: background, dark: dark, "\(mode): \(name) on \(backgroundName)")
                    }
                }
                assertContrast(theme.onAccent, on: theme.accent, dark: dark, "\(mode): button label on accent")
            }
            // The next-call panel puts accentSoft labels on a solid accent fill in light appearance.
            assertContrast(theme.accentSoft, on: theme.accent, dark: false, "\(theme.name) light: soft label on accent")
        }
    }

    func testAccentsStayClearOfStatusHues() {
        for theme in Theme.all {
            let statuses = ["caution": theme.caution, "attention": theme.attention,
                            "completed": StatusPalette.completed, "cancelled": StatusPalette.cancelled]
            for dark in [false, true] {
                let accent = OKLCH(theme.accent.hex(dark: dark))
                guard accent.chroma >= neutralChroma else { continue }
                var others = statuses
                // A theme may let confirmed work take its accent, but never a near-miss of it.
                if theme.positive != theme.accent { others["positive"] = theme.positive }
                for (name, status) in others {
                    let distance = accent.hueDistance(to: OKLCH(status.hex(dark: dark)))
                    XCTAssertGreaterThanOrEqual(distance, minimumHueDistance,
                        "\(theme.name) \(dark ? "dark" : "light") accent is \(Int(distance))° from \(name)")
                }
            }
        }
    }

    /// A theme that moves caution off amber must not land it on another status.
    func testMovedCautionStaysClearOfOtherStatuses() {
        for theme in Theme.all where theme.caution != StatusPalette.tentative {
            for dark in [false, true] {
                let caution = OKLCH(theme.caution.hex(dark: dark))
                for (name, status) in ["positive": theme.positive, "completed": StatusPalette.completed, "cancelled": StatusPalette.cancelled] {
                    let distance = caution.hueDistance(to: OKLCH(status.hex(dark: dark)))
                    XCTAssertGreaterThanOrEqual(distance, minimumHueDistance,
                        "\(theme.name) \(dark ? "dark" : "light") caution is \(Int(distance))° from \(name)")
                }
            }
        }
    }

    func testThemesAreDistinctAndShipTheirIcons() throws {
        XCTAssertEqual(Set(Theme.all.map(\.id)).count, Theme.all.count)
        XCTAssertEqual(Set(Theme.all.map(\.name)).count, Theme.all.count)
        XCTAssertNil(Theme.standard.iconName, "The default theme uses the primary icon")
        XCTAssertEqual(Theme.named("missing"), Theme.standard)
        let icons = try XCTUnwrap(Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any])
        let alternates = (icons["CFBundleAlternateIcons"] as? [String: Any]).map { Set($0.keys) } ?? []
        for theme in Theme.all {
            if let icon = theme.iconName { XCTAssertTrue(alternates.contains(icon), "\(icon) is missing from the app bundle") }
        }
    }

    /// Colors come from Shared/Theme.swift only, so a new theme or status color reaches every screen.
    func testViewsUseThemeColors() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let allowed: Set<String> = ["Shared/Theme.swift"]
        let rules: [(String, String)] = [
            (#"\bColor\s*\("#, "constructs a Color"),
            (#"\bUIColor\s*\((?!named)"#, "constructs a UIColor"),
            (#"\bUIColor\.(?!white\b|black\b|clear\b)[a-z]\w*"#, "uses a UIKit color"),
            (#"\bColor\.(?!theme\b|primary\b|secondary\b|white\b|black\b|clear\b)[a-z]\w*"#, "uses a system color"),
            (#"(?<![\w.])\.(accentColor|red|orange|yellow|green|mint|teal|cyan|blue|indigo|purple|pink|brown|gray)\b(?!\s*[:=(])"#, "uses a system color"),
        ]
        var failures: [String] = []
        for folder in ["Cuekeeper", "Shared", "CuekeeperWidgets"] {
            let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: root.appending(path: folder), includingPropertiesForKeys: nil))
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relative = String(url.path.dropFirst(root.path.count + 1))
                guard !allowed.contains(relative) else { continue }
                for (index, line) in try String(contentsOf: url, encoding: .utf8).components(separatedBy: .newlines).enumerated() {
                    let code = line.components(separatedBy: "//").first ?? line
                    for (pattern, problem) in rules where code.range(of: pattern, options: .regularExpression) != nil {
                        failures.append("\(relative):\(index + 1) \(problem); use Color.theme instead")
                    }
                }
            }
        }
        XCTAssertTrue(failures.isEmpty, failures.joined(separator: "\n"))
    }

    private func assertContrast(_ foreground: ColorPair, on background: ColorPair, dark: Bool, _ message: String,
                                file: StaticString = #filePath, line: UInt = #line) {
        let ratio = contrast(foreground.hex(dark: dark), background.hex(dark: dark))
        XCTAssertGreaterThanOrEqual(ratio, 4.5, "\(message) is \(String(format: "%.2f", ratio)):1", file: file, line: line)
    }

    private func contrast(_ a: UInt32, _ b: UInt32) -> Double {
        let la = luminance(a), lb = luminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    private func luminance(_ hex: UInt32) -> Double {
        let (r, g, b) = linear(hex)
        return 0.2126 * r + 0.7152 * g + 0.0722 * b
    }
}

private func linear(_ hex: UInt32) -> (Double, Double, Double) {
    func channel(_ shift: UInt32) -> Double {
        let value = Double((hex >> shift) & 0xFF) / 255
        return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
    }
    return (channel(16), channel(8), channel(0))
}

private struct OKLCH {
    let chroma: Double
    let hue: Double
    init(_ hex: UInt32) {
        let (r, g, b) = linear(hex)
        let l = cbrt(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b)
        let m = cbrt(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b)
        let s = cbrt(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b)
        let a = 1.9779984951 * l - 2.4285922050 * m + 0.4505937099 * s
        let bb = 0.0259040371 * l + 0.7827717662 * m - 0.8086757660 * s
        chroma = (a * a + bb * bb).squareRoot()
        let degrees = atan2(bb, a) * 180 / .pi
        hue = degrees < 0 ? degrees + 360 : degrees
    }
    func hueDistance(to other: OKLCH) -> Double {
        let difference = abs(hue - other.hue).truncatingRemainder(dividingBy: 360)
        return min(difference, 360 - difference)
    }
}
