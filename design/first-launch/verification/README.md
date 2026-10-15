# First launch verification — October 14, 2026

Implemented against `../concept-board-v3.png`, then refined after the user found
the initial full-screen composition too empty. The user selected bottom actions
on iPhone and compact native setup on iPad. Current captures reflect that revision.

## Automated evidence

- Debug Simulator app and test-target build succeeded.
- Model suite: 64 passed; one existing EventKit test skipped.
- Four first-launch UI workflows passed on iPhone 18 Pro and iPad Pro 13-inch (M5),
  iOS/iPadOS 27: backup empty/back navigation; largest accessibility text setup;
  returning user and backup merge recovery; preference persistence, completion,
  relaunch and Settings replay.
- Existing sync-feedback regression passed with a populated daybook. Empty-daybook
  routine feedback is deliberately hidden; offline/error feedback remains.
- Existing event/work timezone and session-inheritance UI regression passed.

Current screenshot source bundles:

- `/private/tmp/cuekeeper-first-launch-refined-phone.xcresult`
- `/private/tmp/cuekeeper-first-launch-compact-ipad-v2.xcresult`

Model results: `/private/tmp/cuekeeper-first-launch-phone-fixed.xcresult`.
Sync-feedback results: `/private/tmp/cuekeeper-first-launch-regressions.xcresult`
(that earlier bundle also includes a failed timezone selector test, superseded by
the passing refined-phone run). Earlier failing layout/test-selector runs are not
the current verification result.

Preference captures were refreshed after normalizing currency, role and timezone
row heights and value/indicator alignment. Preference persistence/replay and largest
accessibility text workflows passed again on both devices (four tests, no failures):
`/private/tmp/cuekeeper-spacing-phone.xcresult` and
`/private/tmp/cuekeeper-spacing-ipad.xcresult`.

All PNGs here are native screenshots exported from these bundles through
`xcrun xcresulttool export attachments`. No browser or computer-control tools were
used. Screenshot filenames identify device class, surface and appearance/text-size
variant. Backup records and iCloud activity in UI tests are simulated in an isolated
test store; no production records or accounts were used.

## Corrections caught by validation

- Moved the home-timezone default into new-event creation, preserving legacy event
  timezone inheritance and required-timezone validation.
- Matched UIKit accessibility labels in role, sidebar and session-timezone tests;
  scoped session checks to the active editor rather than content behind its sheet.
- Hid routine sync feedback in both empty tab and sidebar presentations.
- Replaced full-screen iPad setup with the user-approved native form sheet.

## Limits

The tests and captures establish simulator behavior, not live cross-device iCloud
delivery, VoiceOver gesture behavior or physical-device ergonomics. Calendar setup
reuses the existing permission/ownership screen. No schema deployment, release
archive or TestFlight upload was performed.
