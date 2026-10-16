# Event page redesign — verification

Concept C (Run of Show + To settle, in tabs) as implemented across phases 1–6 on
`claude/event-page-redesign-e1d597`. Brief: `../implementation-brief.md`.

## Screens

| File | What it shows |
|---|---|
| `ipad-wide-light.png` | iPad Pro 13" landscape, detail column ≥ 820 pt: schedule beside Money and Details, no tabs. To settle spans both columns. |
| `ipad-wide-dark.png` | Same in dark mode; the next-call panel uses the raised surface with a mint hairline. |
| `ipad-ax-light.png` | iPad at Accessibility XL: falls back to tabs, rows stack time above title, tab bar not pinned. |

iPhone tab captures come from `DesignSupplementTests.testEventPageTabsAndOpenItems` in the
`Cuekeeper - Design Capture` scheme (Schedule, Money and Details in light, dark and Accessibility XL);
that scheme was not run for this record.

Fixture data is the app's design fixture set (fictional events and amounts).

## Tests

Final run on October 16, 2026: `Cuekeeper` scheme, iOS 27 iPhone simulator, four parallel workers,
after merging local `main` (parallel UI tests).

- Unit tests: 178 passed, 1 skipped (EventKit integration without a Calendar grant in a clone), 0 failed.
  Includes 19 `EventDetailSummary`/`EventDetailFacts` tests.
- UI tests: 57 passed, 1 failed: `RecoveryTests.testBackupFilePickersAndLayouts`. It drives the
  system Files picker, passes alone and on a two-worker clone run (125 s, waiting on the picker), and
  fails only under the full four-worker load. Its waits were lengthened; the remaining failure is
  load timing in the system picker, not the event page.
- Fixed during verification: the event page now presents expense editors itself (sheets inside tab
  content did not open), the dates test waits for the place timezone lookup before saving, and the
  outdated-forecast label is one accessibility element.

## Not verified

- iPad split view with the agenda column visible (detail column below 820 pt, expected to show tabs) was not captured.
- VoiceOver gestures and physical devices were not exercised; accessibility checks are limited to UI-test queries.
- Live WeatherKit data: weather evidence uses the `--weather-fixtures` snapshot.
