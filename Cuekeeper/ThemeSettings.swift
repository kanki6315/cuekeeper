import SwiftUI
import UIKit
import WidgetKit

extension ThemeStore {
    /// Saves the theme, then brings the widget, UIKit windows and app icon along with it.
    @MainActor func choose(_ theme: Theme) {
        guard theme != self.theme else { return }
        select(theme)
        applyWindowTint()
        WidgetCenter.shared.reloadTimelines(ofKind: ScheduleStore.widgetKind)
        let application = UIApplication.shared
        guard application.supportsAlternateIcons, application.alternateIconName != theme.iconName else { return }
        application.setAlternateIconName(theme.iconName) { error in
            if let error { NSLog("Could not change the app icon: %@", error.localizedDescription) }
        }
    }

    /// Alerts and other UIKit-presented controls read the window tint, not SwiftUI's.
    @MainActor func applyWindowTint() {
        let tint = theme.accent.uiColor
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            for window in scene.windows { window.tintColor = tint }
        }
    }
}

/// Theme and app icon change together, so one choice covers both.
struct ThemePicker: View {
    private var store: ThemeStore { ThemeStore.shared }

    var body: some View {
        DaybookList {
            Section {
                ForEach(Theme.all) { theme in
                    Button { store.choose(theme) } label: {
                        HStack(spacing: 14) {
                            ThemeIconPreview(theme: theme).frame(width: 44, height: 44)
                            Text(theme.name).foregroundStyle(Color.primary)
                            Spacer()
                            if store.theme == theme {
                                Image(systemName: "checkmark").font(.body.weight(.semibold)).foregroundStyle(Color.theme.accent)
                            }
                        }
                        .frame(minHeight: 52)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(theme.name)
                    .accessibilityAddTraits(store.theme == theme ? .isSelected : [])
                    .accessibilityIdentifier("theme-\(theme.id)")
                }
            }
        }
        .contentMargins(.top, 12, for: .scrollContent)
        .navigationTitle("Theme").navigationBarTitleDisplayMode(.inline)
    }
}

/// Matches the app icon: a pale mark on the accent in light appearance, the accent mark on a dark tile in dark.
struct ThemeIconPreview: View {
    let theme: Theme
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let dark = scheme == .dark
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(dark ? theme.page.color(for: .dark) : theme.accent.color(for: .light))
            .overlay {
                CuekeeperMark()
                    .fill(dark ? theme.accent.color(for: .dark) : theme.accentSoft.color(for: .light), style: FillStyle(eoFill: true))
                    .aspectRatio(383 / 448, contentMode: .fit)
                    .padding(9)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(dark ? 0.16 : 0), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
    }
}
