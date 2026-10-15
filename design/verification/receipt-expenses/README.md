# Receipt expenses verification — October 15, 2026

Implemented receipt camera/photo import → Vision OCR → on-device Foundation Models
structured extraction → editable confirmation → event-linked expense and photo.
Scan Receipt is discoverable in App Intents and exported as an App Shortcut for
Action Button assignment. Camera capture and invocation require foreground access.

## Automated evidence

- Xcode 27 simulator build-for-testing passed.
- Full model suite: 76 tests, zero failures. Includes V1–V11 migrations into V12,
  expense validation, incomplete drafts, stale saves, event deletion retention,
  binary photo backup round trip, pre-expense archive compatibility, safe photo
  replacement and actual Vision OCR on a generated receipt image.
- Python tooling suite: 27 tests, zero failures.
- iPhone and iPad: both ExpenseUITests workflows passed. Review/edit/save/reopen
  verifies that the photo and corrected merchant remain attached; shortcut screen
  verifies searchable event selection. Fixtures are synthetic, not model output.
- Shortcut metadata confirms ScanReceiptIntent is discoverable, foreground,
  authenticated, and registered in autoShortcuts with the Scan Receipt tile.
- Development CloudKit initialization/export succeeded. Reviewed diff adds only
  CD_Expense, including binary/asset photo fields. Local schema gate passed.

Final UI evidence is in iphone-fixed/ and ipad-fixed/; their manifests identify
review top, fields, reopened saved expense and shortcut event selection. Dark
accessibility XXXL top-of-form captures are iphone-dark-large.png and
ipad-dark-large.png. Initial iPhone runner failures occurred before/at relaunch;
the final dedicated result bundle build/receipt-iphone-final.xcresult passed both
workflows. A redundant run stalled on a different simulator and was stopped.

## Review

Initial independent native review requested a shorter toolbar action, visible
Currency/Category labels and safe rescan after extraction failure. All three were
implemented in one batch. A subsequent accessibility capture shortened the draft
navigation title to Receipt; that text-only change was rebuilt and is reflected
in the dark/XXXL captures. Simulator system appearance was explicitly set to dark
for those captures because the fixture preference did not propagate into the
iPhone native sheet. No new design tokens or durable visual-system changes;
DESIGN.md and its existing sidecar are preserved. The sidecar was already stale.

## Remaining release checks

Physical-device camera permissions/capture, actual Foundation Models receipt
accuracy and latency, cold/warm Action Button invocation and two-device CloudKit
photo convergence are unverified. This evidence does not claim those results.
The cloud schema must be deployed to Production and the live release gate passed
before distribution. No Production deployment or TestFlight upload was performed.

Final independent finish verdict: **ship**, scoped to the supplied native
simulator evidence and source. All three listed material findings were resolved;
physical-device camera/model/Action Button and VoiceOver gestures remain outside
that verdict. Documenter confirmed no durable visual-system change was needed.
