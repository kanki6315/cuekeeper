# Capture Expense verification — 0.1.10

The native Daybook UI now supports background payment drafts, a completion inbox,
optional local reminders, receipt/payment comparison, and Wallet automation setup
under Settings → Integrations → Wallet Automation.

## Automated checks

- Final simulator app build succeeded (`build/background-final`).
- Full model suite: 87 tests passed, including six background-expense tests for
  partial capture, explicit-ID deduplication, required event/photo completion,
  immutable source evidence, discard/backup, extraction conflicts and notification
  opt-in/denial/failure/routing/cleanup.
- Tooling suite: 27 tests passed.
- Four background UI workflows passed on iPhone and iPad: choose event and complete,
  route to the exact photo-less draft and keep it, cancel/confirm draft removal,
  and navigate the Upcoming prompt and setup guide.
- Both existing receipt UI workflows passed on both devices in the initial run.
- The first removal UI check exposed a native confirmation popover without an
  explicit cancel button. The final native alert exposes both choices; the rerun
  passed on both device classes.
- Local CloudKit schema gate passed. No new model version beyond V12 was needed.
  Production schema was not checked or deployed.
- `git diff --check` passed. App Intent metadata confirms background execution,
  no app opening, and optional inputs for Capture Expense.

## Evidence

`iphone/` and `ipad/` contain named XCT screenshots and their original export
manifests. These use synthetic test stores, never personal expense data.
`iphone/pending-dark-large.png` and `automation-dark-large.png` are final-build
simctl captures at accessibility-large Dynamic Type in dark appearance. The
remaining captures use standard text size in light appearance.

The final build also corrects the event-list draft subtitle when a chosen event
has a saved draft without a photo. That one-line text correction followed the UI
run; the list/editor/settings captures remain representative. Independent finish review then identified a duplicate disclosure arrow in the Upcoming prompt. It was removed, rebuilt successfully, and recaptured on both devices as `pending-upcoming-prompt-final.png`; those files supersede the earlier prompt captures and the prompt visible behind iPad navigation.

## Physical-device validation still required

Actual Wallet transaction variables/delivery, background execution while locked,
OS notification delivery and tap launch, camera capture, Foundation Models receipt
quality, and Action Button invocation require a compatible iPhone. Simulator
routing invokes the same draft route but does not prove system notification or
Apple Pay delivery. Inputs remain optional because Wallet availability varies.

The user creates the personal automation in Shortcuts. Cuekeeper cannot install
it automatically. Deduplication uses only an explicitly supplied stable transaction
ID; absent IDs produce separate drafts. This is local serialized deduplication,
not a global uniqueness guarantee across offline devices. Notifications are opt-in
and never determine whether a draft is saved.

## Independent finish review

The fresh native finish reviewer inspected all 18 initial captures and the relevant
UI source. Its sole material finding was the duplicate prompt chevron. After the
correction, both final prompt captures were scored resolved with disposition **ship**.
No broader physical-device validation is implied by that visual verdict.
