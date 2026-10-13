# Existing-screen mockup implementation

October 13, 2026. This pass implements the approved `design/branded` boards across existing Cuekeeper screens. Reminders, export/backup, Recently Deleted and first-run setup remain outside this pass, as requested.

## What matches

- Upcoming and Jobs: cue-card brand lockup, large headings, date rails, status badges, compact schedule/call metadata, filters and attention feedback.
- Job capture and detail: focused name/date entry with optional details; title/status and metadata; sessions and broadcast links before fees and billing; completion and more actions.
- Sessions, fees and clients: explicit schedule/coverage, optional times, readable fee lines and total discrepancies, client metadata and related jobs.
- Payments: separate USD/EUR summaries, invoice and receipt hierarchy, partial balances and payment context. Secondary screens share the same surfaces and navigation treatment.
- Settings and libraries: icon-led destinations, reusable projects/series/clients/roles and clear local/iCloud status.
- iPad: sidebar/list/detail at ordinary landscape sizes, native portrait collapse, and tab/stack navigation at accessibility text sizes.

Native system navigation, sheets, menus and date controls are retained. The generated concept boards contain synthetic system chrome and example data, so verification assesses composition, hierarchy, palette and functioning controls rather than claiming pixel equality.

## Evidence and method

The DEBUG-only design fixture uses synthetic data in a separate UI-test store with CloudKit disabled. XCTest captures actual simulator screens, including presented editor sheets. Saved PNGs have only their EXIF orientation normalized; no UI has been retouched.

The full capture pass covered Upcoming, Jobs, job details and editors, session details and editors, fee details and editors, Payments, invoices and invoice editing, payment entry, clients/projects/series and related libraries, Settings, calendar integration, filters, timezone selection and broadcast-link capture, in light and dark themes on iPhone and iPad. Supplemental captures covered receipts and library editors. Final correction captures cover ordinary and accessibility text sizes plus iPad portrait.

An independent finish review compared individual captures with the approved boards. It requested readable secondary text, scaled metadata icons, accessible iPad navigation, session-local dates, and stacked session date/time rows at large text sizes. The reviewer scored all five fixes resolved and returned **ship** for that correction list. That verdict is scoped to those findings, not an exhaustive accessibility certification.

## Reproducing verification

Build the `Cuekeeper` scheme for an iOS Simulator with `xcodebuild build-for-testing`. Run `CuekeeperTests`, `CuekeeperUITests/CaptureTests`, `CuekeeperUITests/DesignCaptureTests`, and `CuekeeperUITests/DesignSupplementTests` with `test-without-building`. Use `-collect-test-diagnostics never` to avoid simulator diagnostic-collection delays. `DesignCaptureTests` covers both themes; `testReviewCorrections` captures final adaptive corrections using the system preferred content-size category.

## Limits

Simulator checks do not certify VoiceOver, every localization or physical-device behavior. Live cross-device iCloud delivery and Production CloudKit deployment are separate release checks. This pass does not deploy a schema, upload an archive or publish a TestFlight build.

## Representative final screenshots

| Screen | iPhone | iPad |
|---|---|---|
| Upcoming, light | [Capture](screenshots/iphone-root-normal-light.png) | [Capture](screenshots/ipad-root-normal-light.png) |
| Upcoming, dark | [Capture](screenshots/iphone-root-normal-dark.png) | [Capture](screenshots/ipad-root-normal-dark.png) |
| Job detail | [Capture](screenshots/iphone-job-normal-light.png) | — |
| Quick job capture | [Capture](screenshots/iphone-add-job-normal-light.png) | — |
| Accessibility-size session editor | [Capture](screenshots/iphone-edit-session-ax3-dark.png) | [Capture](screenshots/ipad-edit-session-ax3-dark.png) |
| Portrait layout | — | [Capture](screenshots/ipad-root-portrait-light.png) |
| Accessibility-size navigation | — | [Capture](screenshots/ipad-root-ax3-dark.png) |

Full captures and original XCTest attachments remain in the local `build/*.xcresult` bundles and `.impeccable/review/` folders.

## Validation records

- `build/design-reviewed-phone.xcresult`: all 21 unit/model/EventKit tests passed, including session-date and series-override regression assertions.
- `python3 -m unittest discover -s scripts/tests`: 25 tooling tests passed.
- iPhone workflow coverage: all 10 cases passed across `design-regression-phone.xcresult` and focused `design-phone-final.xcresult` reruns. Invoice creation and partial payment also passed with final text-field styling in `design-shipping-phone-invoice.xcresult`.
- Full two-theme capture runs: `design-phone-final.xcresult` and `design-ipad-round2.xcresult`; supplementary library/editor captures are in `design-ipad-final.xcresult` and `design-phone-final.xcresult`.
- Final review correction captures: `design-verdict-phone.xcresult` and `design-verdict-ipad.xcresult` (the capture test passed on both; the latter bundle also records the earlier invoice test selector failure).
- `git diff --check` passed. The app and test targets build successfully.
- iPad workflow coverage: all 10 cases passed across `design-ipad-final.xcresult`, `design-ipad-confirmation.xcresult`, and the final `design-invoice-ipad-complete.xcresult` rerun. The final invoice run verifies the exact invoice reference, creation, partial payment, $125 remaining balance and navigation to the Payments overview. Earlier failures came from pane/keyboard gestures and ambiguous accessibility selectors; those test targets were corrected without removing assertions.
