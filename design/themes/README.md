# Themes

Nine user-selectable themes (Settings → Theme), each with a matching app icon.
Colors are defined in `Shared/Theme.swift`; icon sources are `design/brand/*.icon`.

- `icons.png`: All nine theme icons (Teal, Indigo, Purple, Magenta, Cue Amber, Olive, Espresso, Ink, Graphite), light (top) and dark (bottom), rendered with Icon Composer's `ictool`.
- `picker.png`: Settings → Theme in light and dark, captured by `ThemeCaptureTests.testThemePicker`.
- `screens-light.png`, `screens-dark.png`: Upcoming, event detail, Payments and Settings in every theme, captured by `ThemeCaptureTests` on the iPhone simulator (iOS 27) with design fixtures.

Re-capture with the `Cuekeeper - Design Capture` scheme, `-only-testing:CuekeeperUITests/ThemeCaptureTests`.
