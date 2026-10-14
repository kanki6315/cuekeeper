# Cuekeeper

Native iPhone and iPad daybook for broadcast freelancers. Minimum iOS/iPadOS 27.
The first six implementation steps cover job management, sessions and broadcast
links, EventKit calendar publishing, fees, invoices and payments. The app has
private CloudKit sync and a TestFlight release pipeline.

## Open and run

Requires Xcode 27 and XcodeGen (`brew install xcodegen`).

```sh
xcodegen generate
open Cuekeeper.xcodeproj
```

Select the **Cuekeeper** scheme and your iPhone, iPad or iOS 27 simulator.
`project.yml` is the source of truth for target settings, Info.plist and
entitlements. Regenerate and commit generated files when changing it.

- Bundle: `com.arjunakankipati.cuekeeper`
- Team: `TDBAHN96B3`
- CloudKit container: `iCloud.com.arjunakankipati.cuekeeper`
- Version: `0.1.0`
- Signing: automatic, using the Apple Account in Xcode
- Debug uses CloudKit Development; Release uses Production

The app uses the approved Icon Composer asset in `design/brand/Cuekeeper.icon`.

## What works now

- iPhone tabs and iPad sidebar navigation.
- Shared ivory / warm-charcoal styling across lists, forms, detail screens and
  sheets, with raised surfaces and consistent navigation backgrounds.
- Capture a tentative job using a name and inclusive placeholder dates.
- Edit jobs and set tentative, booked, completed or cancelled status.
- Add and reuse named clients, roles, projects and series inline while editing a job.
- Link jobs under a project independently of the billing client; browse related jobs by year.
- Set a default series per job, with optional session overrides for mixed-series weekends.
- Capture one date by default; enable Multiple days to enter an inclusive date range.
- Manage clients and roles in Settings, including renaming, client contact details,
  notes and default currency; both libraries link back to related jobs.
- Save work arrangement, location, optional timezone and notes.
- Duplicate descriptive details into a tentative job with explicitly confirmed dates;
  notes are excluded and the original stays in history.
- Search job names or clients and combine status, client, role and overlapping-date filters.
  Upcoming excludes past, completed and cancelled jobs.
- Cancel an editor without saving; changed forms require an explicit discard.
- Failed saves show a native alert and keep the editor draft available to correct.
- SQLite persistence through Core Data, with CloudKit private-database mirroring.
- Nonblocking iCloud transfer, waiting, offline and attention feedback above job lists,
  with account checks and detailed errors in Settings. Concurrent transfers remain visible.
- Isolated local test stores that never write test records to iCloud.

- Create incomplete or timed sessions with independent schedule and coverage states,
  timezones, call times, roles, notes and broadcast links.
- Publish all-day job placeholders and eligible confirmed, covering sessions to
  a selected calendar; reconcile changes without removing unrelated events.
- Record unknown or zero fees, agreement status and optional quantity/rate breakdowns.
  The overall fee changes to the breakdown total only with **Use Breakdown Total**.
- Track same-client, same-currency grouped invoices, sent/due dates, overdue balances,
  partial invoice receipts and direct job payments.
- Preserve immutable fee/invoice revisions and receipt/reversal history. Stale
  financial edits are rejected; conflicting revisions remain available for explicit
  resolution. Invoice line amounts are snapshots, independent of later fee edits.
- Keep USD and EUR summaries separate, with exact integer cents and decimal arithmetic.
  Partial receipts reduce the grouped invoice balance, rather than implying which
  individual jobs were paid. Duplicate active billing is rejected locally and flagged
  for review if concurrent invoices later sync together.

Calendar publishing has one designated device, verified online through CloudKit.
Other devices can edit records; calendar updates catch up when the publishing
device opens Cuekeeper in the foreground and receives those changes. To transfer
publishing, disconnect Calendar on the old device, then connect on the new one.
Offline job capture remains available; calendar publishing waits for connectivity.

Step 7 (recovery, export and Recently Deleted) and step 8 (broader physical-device
beta testing, first-run and App Store polish) remain. Invoice tracking does not
create or send invoice documents, connect to banking, calculate tax or convert
currencies. Sync is not a backup.

## CloudKit setup and verification

Run `./cloudkit.sh init --export` to build the signed macOS setup helper,
initialize Development, and export the schema. This Mac must be signed into
iCloud; Xcode handles development signing. No phone is needed. The helper shares
the app's model and uses its own local store. See the workflow below for logs,
authentication, and the optional older iOS setup scheme (`--device`).

Authenticate Apple's schema CLI once using a management token from CloudKit
Console (separate from your App Store Connect key):

```sh
xcrun cktool save-token --type management # secure prompt; token stays in keychain
./cloudkit.sh export                     # export Development schema + model fingerprint
```

Review and commit `cloudkit/schema.ckdb` and `cloudkit/schema.json`, deploy the
reviewed Development schema to Production in CloudKit Console, then run:

```sh
./cloudkit.sh check
```

Every normal release runs this check against live Production before building.
It rejects missing/stale snapshots, authentication failures and schema drift.
See [the CloudKit workflow](cloudkit/README.md) for initialization, deployment,
comparison rules, CI authentication, and model-change instructions.

Verify actual record sync separately using two signed-in devices. Debug and
Release/TestFlight use separate CloudKit environments; deploy copies schema,
not Development records. Settings reports observed operations, not a guarantee
that every device is up to date. Sync remains separate from backup.

## Tests

Boot the intended simulator, build/install the app, and grant full Calendar access
before the suite. Use the same simulator UDID throughout:

```sh
SIMULATOR_ID='<booted simulator UDID>'
xcodebuild build-for-testing -project Cuekeeper.xcodeproj -scheme Cuekeeper \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath build/tests CODE_SIGNING_ALLOWED=NO
xcrun simctl install "$SIMULATOR_ID" build/tests/Build/Products/Debug-iphonesimulator/Cuekeeper.app
xcrun simctl privacy "$SIMULATOR_ID" grant calendar com.arjunakankipati.cuekeeper
xcodebuild test-without-building -project Cuekeeper.xcodeproj -scheme Cuekeeper \
  -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
  -derivedDataPath build/tests CODE_SIGNING_ALLOWED=NO
python3 -m unittest discover -s scripts/tests
./cloudkit.sh check --local-only
```

Without the Calendar grant, the real EventKit integration test skips; a green
suite alone does not prove that check ran. Repeat the UI suite on an iPad by
changing the destination. UI tests use isolated local stores, disable CloudKit
and calendar publishing, and contain synthetic records. The EventKit test uses
its own temporary calendar and a test publisher; real CloudKit publisher ownership
is checked separately in Development.

Earlier V5 validation included 19 passing unit/model/EventKit tests (no skipped
EventKit integration), 24 passing tooling tests and a passing local schema gate.
Coverage includes V1–V4 migration into V5, session/DST validation, field-preserving
edits, immutable financial conflict branches, invoice snapshots, grouped partial
payments, duplicate billing detection and receipt reversals. All eight UI workflows
have passing iPhone and iPad evidence after the editor presentation fixes. The full iPhone suite passed; the iPad run passed six
workflows, followed by passing focused reruns of breakdown and invoice entry
after correcting keyboard submission in those tests. A signed Release build passed;
this does not claim a new archive, distribution or upload.

## Release to TestFlight

The release tooling is adapted from Harbor. Account settings belong in the
ignored `.release.env`; `.release.env.example` documents the supported values.
Private signing keys remain outside this repository. The validated default is
the Apple Account signed into Xcode. Harbor's API-key authentication failed during
initial setup, so those optional local settings are commented out.

The V6 Development schema was deployed to Production on October 13, 2026.
The live Production check passed for the 0.1.1 release, including project and
series relationships. Keep this gate enabled for every future upload.

```sh
./release.sh --no-upload              # schema check → tests → archive → local IPA export
./release.sh                          # schema check → tests → archive → upload → local Git tag
./release.sh --skip-tests             # only when the current code already passed tests
./release.sh --build 286.10.1          # explicit monotonically increasing build number
./release.sh --no-upload --allow-dirty # local verification of uncommitted changes
```

Default build numbers use days since 2026-01-01 (one-based), UTC hour and minute,
for example `285.23.10`. To release twice in a minute, supply a greater valid
`--build` value. The script requires a clean Git working tree unless
`--allow-dirty` is explicit, and never tags dirty builds. Upload tags are local;
no remote push is performed. Archives, dSYMs, logs and exported IPAs live under
`build/release/`. Keep release archives for crash symbolication.

Set `TEST_DESTINATION` in `.release.env` for a different iOS 27 simulator.
`RELEASE_ENV_FILE=/dev/null ./release.sh ...` bypasses local account overrides.
API-key mode additionally requires an Apple Distribution certificate/private key
in the keychain. Its profile helper verifies the team, bundle, CloudKit container,
production CloudKit environment and production push entitlement, and preserves
existing profiles when creating a replacement.

For local packaging before schema deployment, use
`./release.sh --no-upload --skip-cloudkit-check`. This bypass is rejected for
uploads. `--skip-tests` does not skip the schema check.

Run the CLI and release-gate tests with
`python3 -m unittest discover -s scripts/tests`; they also run in the release
script unless tests are explicitly skipped.

`--no-upload` still contacts Apple for signing and may create provisioning
profiles. It does not publish a build. Successful export proves packaging and
signing, not App Store Connect acceptance or live CloudKit sync.

## Data and beta validation

The current V6 Core Data model retains V1–V5 for migration. Tests open stores from
each older version and verify data preservation. Editors save through isolated
contexts; unchanged fields do not overwrite updates made while a form was open.
This is not a general resolution policy for simultaneous edits to the same
nonfinancial field. Financial history uses explicit immutable revisions instead.

The user verified original production cross-device sync, including offline
capture and reconnect, on October 12, 2026. Full new financial workflows and
conflict handling across two physical devices remain beta validation. Simulator
coverage and the successful real Development calendar ownership/concurrent-claim/
transfer check do not establish that broader physical-device result.

Client/role renames update related jobs through shared records. Library names are
checked case-insensitively on this device; independently created records on offline
devices are not automatically deduplicated. Settings reports observed iCloud
operations rather than guaranteeing that every device has received every record.

## Project and series update (October 13, 2026)

Projects group jobs without changing their clients, fees or invoices. Series are
shared named records: a job supplies the default, while a session can override it
(including choosing no series). Duplicate Job carries both associations. Projects
and Series are managed in Settings → Libraries; job search and filters include
both. Existing jobs migrate with no project or series assigned.

The V6 Development CloudKit schema was initialized and exported. Production
schema deployment and physical-device cross-device validation remain required
before distributing these additions. No TestFlight upload is part of this change.

Validation for this update: all 21 unit/model/EventKit tests and 25 tooling tests
passed, including migrations from V1–V5 into V6. The new project/date and sync
feedback UI workflows passed on iPhone and iPad; edit/duplicate/discard and session
capture regression workflows also passed on iPad with dark mode and larger text.
Sync presentation tests use simulated activity and do not prove live-device delivery.

## License

Cuekeeper is licensed under the [MIT License](LICENSE), except for
`release.sh` and `asc_profile.py`, which retain their
[Mozilla Public License 2.0](LICENSE-MPL-2.0) terms. See [NOTICE](NOTICE).

## Track location and event weather

Jobs can save an Apple Maps Place ID through **Edit Job → Where you’ll work →
Choose track location**. Native MapKit search needs no Google billing account or
location permission. Search results update after a 350 ms typing pause, with
loading, no-results and retry feedback; selecting a result opens its confirmation
map. Existing free-text locations remain available as location
notes. Only the selected Place ID is persisted and synced; venue details and
coordinates are resolved through MapKit and kept temporarily in memory.

Weather appears on job details only for **booked, on-site** jobs overlapping today
through the next nine days in the venue’s timezone. It shows available event-day
conditions, high/low temperature, precipitation probability and wind. Expand a
session to see hourly conditions from call time (or session start) through its end.
Forecast dates and hours use the venue timezone; units follow device preferences.

Each device makes at most one WeatherKit attempt per Place ID per rolling 24 hours,
including failed requests. Loads are on demand; there is no background polling.
Concurrent requests share one task. Request timestamps and forecasts persist
locally outside iCloud and backups. Forecasts show their fetch time and are marked
outdated after Apple’s expiry. They stop displaying after 24 hours, and expired
payloads are purged when the app runs. If refresh fails, weather is unavailable
until the next permitted attempt. The 24-hour stale-display policy is an explicit
initial product assumption, not a claim that Apple has approved this retention
window. No forecasts are synced or retained as event history.

### Setup before a device release

- Enable WeatherKit for `com.arjunakankipati.cuekeeper` in the Apple Developer
  portal (capability and App Services), and regenerate provisioning profiles.
  `project.yml` and the generated app entitlements already include WeatherKit.
- The V7 Core Data model adds `trackPlaceID`; V1–V6 migration is covered by tests.
  Development schema initialization/export is complete. Review the schema diff,
  deploy it to Production and run `./cloudkit.sh check` before distribution.
- Verify real Apple Maps search and WeatherKit responses on a signed device.
  Automated weather UI tests use synthetic data and do not consume weather quota.

The simulator build and local schema checks do not prove WeatherKit account
activation or live-device delivery. No Production schema deployment or app upload
is part of this feature change.

### Events and client bookings (V8, local implementation)

The main agenda now lists events/weekends. Create an event with dates and a client;
its title defaults to location and dates. Each event contains independent client
bookings with their own status, overall fee, optional fee items, invoices and
payments. Sessions belong to a client booking and select their series directly.
The event screen collects those sessions into one schedule and opens focused
editors for event details, client details and fees. Session entry offers Save &
Add Another, duplication, and selected-session changes to date, series, coverage
or client booking. Moving a session does not move financial records.

V8 adds only `WorkEvent` and an optional `Job.event` relationship. `Job` remains
the persisted client booking entity; all existing job/session IDs, original names,
project/series associations, fee revisions, invoice snapshots and receipts remain
in place. Older jobs appear as individual events without an eager data backfill.
Editing shared event details or adding another client creates their event record
transactionally. “Include Existing Booking” explicitly groups an older standalone
booking; there is no automatic merging by date or client. Original booking metadata
is retained, while shared dates/location come from the event. Session schedules
are unchanged when event dates change. Calendar publishing uses one all-day event
placeholder plus eligible session entries, retiring the old per-job placeholders.

The checked-in CloudKit export still describes V7. **V8 must be initialized in
Development, exported/reviewed, and deployed to Production before distribution.**
The existing release gate intentionally rejects this model until that is done.
No schema deployment or release upload is performed by this implementation.
Physical-device iCloud convergence between upgraded devices remains a release
check; older app versions do not understand event grouping.

### Integrated event wizard (V9)

New-event creation now uses the optional-step wizard for one event or a season.
Each outline saves a real `WorkEvent` with an initial client booking; the client
can be filled in later when planning a season. Add further clients from the event
screen. Fees, receipts, and sessions remain attached to their own booking.
Championships are selected explicitly on the client page and can be edited on a
booking; an event shows the union of its bookings’ championships. A session still
has one championship and inherits automatically only from a booking with one.
Track selection and weather, grouped calendar publishing, and existing event and
batch-session editors remain available.

V7 (track locations) and V8 (event grouping) are preserved unchanged. V9 adds only
optional additional booking-series relationships. The checked-in CloudKit export
was refreshed after successful V9 Development initialization on October 14, 2026.
The exported schema is unchanged from V8 and the live Production comparison
passes; no Production promotion is needed for this model. The normal release
gate still runs before upload. No TestFlight upload was performed in this step.

## Siri event creation

The iOS 27 integration uses Apple's `.calendar.createEvent` schema. Siri resolves
standard calendar parameters, then opens Cuekeeper's existing event wizard with
an unsaved draft. Add client, championships, roles, fees, or other details and
review before tapping **Create event**. The intent returns a saved event only
after that action succeeds. Discarding the wizard or cancelling the intent creates
no records. A second Siri draft is rejected while one is already open.

No App Shortcut trigger phrases are advertised. Existing custom shortcuts using
the older Create Event action remain compatible, but now open the same review
wizard instead of saving in the background. The legacy action is hidden from
new action discovery.

All-day calendar end dates are exclusive; the adapter converts them to the
wizard's inclusive end day using calendar arithmetic. Timed requests populate a
session with the original start/end instants and device timezone, leaving its
schedule tentative and coverage undecided. Missing end times stay unknown.
Location and notes are carried into the draft. Recurrence and invitees are not
imported; a six-second, accessibility-announced notice explains that only one
event will be created and no invitations will be sent. Invalid date ranges
still fail validation. No Siri audio or full conversation transcript is received.

The intent uses the app's shared persistence controller and `EventCreationDraft`
transaction. Nothing is written to EventKit directly; the existing designated
calendar publisher and foreground reconciliation rules remain in effect.

Validation includes schema metadata export (calendar domain, no App Shortcuts),
persistence tests for unsaved handoff, explicit save, discard, task cancellation,
concurrent requests and daylight-saving date conversion, plus simulator wizard
save/discard and disappearing-notice flows. These do not establish Siri speech
recognition, schema routing, or foreground continuation on a physical device.
Test the installed build on an iOS 27 device with supported Siri AI: request an
all-day event, a timed event, and recurrence/invitees; verify the populated draft,
notice, discard, save, and cold launch. Opening the wizard requires foreground
interaction and may require unlocking the device.
