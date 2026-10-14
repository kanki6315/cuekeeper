# Events and client bookings verification

Verified October 13, 2026 on the iOS 27 iPhone and iPad simulators.

## Behavior

- Events contain independent client bookings and a combined chronological schedule.
- New event creation requires dates and a client, with an optional title and fees.
- Existing jobs render as individual events; grouping is explicit. V8 adds an
  optional event relationship without replacing booking or financial records.
- Focused event/client/fee editors, consecutive session entry, saved-series reuse,
  session duplication, and selected-session date/series/coverage/client updates.
- One all-day calendar placeholder per event plus eligible session entries.
- Location/weather uses event metadata; existing track lookup remains available.

## Validation

- 35 unit/model/calendar/weather tests pass on iPhone. The final iPad unit run has
  no failures, with one existing EventKit authorization-dependent test skipped
  because simulator permission was unavailable.
- V1–V7 stores migrate to V8. Checks cover record IDs, original names, project and
  series relationships, track locations, session links, immutable fee history,
  invoice snapshots and partial-payment balances.
- Event creation rolls back on invalid fees. Grouping preserves existing receipt
  and fee IDs. Client fees/currencies remain independent. Unrelated concurrent
  event edits survive. Batch date changes preserve local time over a DST boundary
  and retain series/roles/links when changing client booking.
- All ten CaptureTests workflows have passing iPhone and iPad evidence, including
  focused reruns after fixing the booking footer overlap and filter identifier.
  The final saved-series menu and batch workflow passed again on both devices.
- Both weather UI workflows pass on both device sizes: forecast/hourly details
  and track selection/removal.
- 27 Python tooling tests pass against the actual V8 Development export, including
  rejection of an export missing the event record.
- iOS build-for-testing and the unsigned Mac CloudKit schema-helper build pass.
- Visual inspection covered event details, event creation, and the session editor
  in normal/light and accessibility-extra-large/dark presentations. The first
  inspection found a compact-width saved-series picker overlap; the confirmation
  captures show the corrected menu and stacked client/fee rows.

Final captures are in `events/`. All shown records are synthetic test fixtures.
Build logs and xcresult bundles are under `build/events-*` (ignored build output).

## Physical-device installation and schema status

On October 13, 2026, the signed Mac helper successfully initialized V8 in
Development. The actual export and model fingerprints are checked in the working
tree. Compared with live Production, the only additions are `CD_WorkEvent` and
`CD_Job.CD_event`; existing fields and records are retained.

Release 0.1.3 (287.2.7) was built, signature-verified, and installed as an update
on the paired iPhone using `devicectl`. The installed version was confirmed and
the signed CloudKit environment is Production. The app was not launched for
flow testing while the Production schema remains pending.

The user deployed V8 through CloudKit Console. On October 13, 2026, the live
`./cloudkit.sh check` passed: the current model snapshot exactly matches
Production. The TestFlight release gate independently passed the same check.
All agent verification and release actions used CLI tools only.
Cross-device convergence remains to be tested, including grouping and shared
metadata.

TestFlight upload of Release 0.1.3 (287.2.10) succeeded via `release.sh` and
Xcode's signed-in account. The CLI reported `Uploaded Cuekeeper` and
`EXPORT SUCCEEDED`. App Store Connect processing/tester availability is not yet
confirmed. Archive: `build/release/0.1.3-287.2.10/Cuekeeper.xcarchive`;
release log: `build/events-testflight-release.log`. No browser was used.
