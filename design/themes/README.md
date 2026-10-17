# Themes

Five user-selectable themes (Settings → Theme), each with a matching app icon.
Colors are defined in `Shared/Theme.swift`; icon sources are `design/brand/*.icon`.

- `icons.png`: Teal, Indigo, Purple, Magenta and Ink icons, light (top) and dark (bottom), rendered with Icon Composer's `ictool`.
- `picker.png`: Settings → Theme in light and dark, captured by `ThemeCaptureTests.testThemePicker`.
- `screens-light.png`, `screens-dark.png`: Upcoming, event detail, Payments and Settings in every theme, captured by `ThemeCaptureTests` on the iPhone simulator (iOS 27) with design fixtures.

These captures predate a later contrast fix: the light next-call panel's secondary text now uses 90% `onAccent` instead of 82% white.

Re-capture with the `Cuekeeper - Design Capture` scheme, `-only-testing:CuekeeperUITests/ThemeCaptureTests`.
