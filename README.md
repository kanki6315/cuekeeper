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
- Version: `0.2.1`
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
- Save work arrangement, location, event timezone and notes. Remote and hybrid work can also store your timezone.
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
  the event timezone, call times, roles and notes.
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
Writable shared calendars are supported as publishing destinations; read-only
calendars are excluded. The publisher claim is per iCloud account, not per shared
calendar. Sync, disconnect, and calendar switching only modify entries whose keys
match this account's locally available Cuekeeper records. Unknown Cuekeeper entries
are preserved, including colleagues' entries and records still downloading on a
replacement device; disconnect may therefore leave entries until those records arrive.

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
  -parallel-testing-worker-count 4 \
  -collect-test-diagnostics never \
  -derivedDataPath build/tests CODE_SIGNING_ALLOWED=NO
python3 -m unittest discover -s scripts/tests
./cloudkit.sh check --local-only
```

UI test classes run in parallel on clones of that simulator, so grant Calendar
access before the first run (clones copy it). Screenshot-only classes
(`DesignCaptureTests`, `DesignSupplementTests`, `EventCaptureTests`,
`TodayCaptureTests`) are skipped here; run the `Cuekeeper - Design Capture`
scheme the same way when reviewing design changes. `BackupFilePickerTests`
drives the out-of-process Files picker, which drops taps on parallel clones; run
the `Cuekeeper - System Pickers` scheme (one test, serial) when backup files change.
The parallel suite covers the same export, import and restore through
`--ui-test-backup-files`. For a quick loop, add
`-only-testing:CuekeeperTests` to run just the unit tests.

Run benchmarks only when other worktrees are not running simulator tests. Use an
explicit simulator UDID and a separate derived-data directory per worktree.
`-collect-test-diagnostics never` avoids the observed ten-minute diagnostic
collection stall; ordinary test results and coverage are still produced.

Regression UI tests reset orientation before each test, use a minimal seeded event
for downstream workflows, and use synthetic location suggestions for the location
selection test. Wizard creation remains covered by its own tests. Routine success
screenshots are disabled; to enable them for investigation, set
`CUEKEEPER_TEST_SCREENSHOTS=1` in the test runner's environment (in the Xcode scheme's
Test action, or with `TEST_RUNNER_CUEKEEPER_TEST_SCREENSHOTS=1` when invoking
`xcodebuild`). Dedicated Design Capture tests always take screenshots.
The five-minute target applies to the default regression suite; measure build time
and test execution separately, with Design Capture and System Pickers reported
separately. This is a target, not a verified runtime guarantee.

Without the Calendar grant, the real EventKit integration test skips; a green
suite alone does not prove that check ran. Repeat the UI suite on an iPad by
changing the destination. UI tests use isolated local stores, disable CloudKit
and calendar publishing, and contain synthetic records. The EventKit test uses
its own temporary calendar and a test publisher; real CloudKit publisher ownership
is checked separately in Development.

### Suite benchmark — 16 October 2026

Measured on an Apple M4 Pro (14 cores, 48 GB memory), using an isolated iPhone 18
Pro simulator on iOS 27.0, with coverage enabled and no retry flags. Times are
`test-without-building` wall time, including worker startup and result collection;
the base simulator was booted, installed and granted Calendar access. Build time
and the separate Python suites are excluded from this table.

| Change | Workers | Wall time | Passed | Failed | Skipped |
| --- | --- | --- | --- | --- | --- |
| Initial consolidations and navigation fixes | 2 | 10m 52s | 252 | 0 | 1 |
| Initial consolidations and navigation fixes | 4 | 8m 12s | 252 | 0 | 1 |
| Split long UI classes | 4 | 7m 48s | 252 | 0 | 1 |
| Class splits and nonblocking notification cleanup | 4 | 7m 33s | 253 | 0 | 1 |

The final measured suite had 194 unit/integration tests and the same 60 UI tests. All
previous test methods remain; the additional regression checks that an
unresponsive notification service cannot block the UI thread during cleanup.
These measurements precede the subsequent Payments redesign merged from main,
which replaces the old Payments test with five new workflows and adds unit tests.
See the merged-suite worker benchmark below for current counts and timings.
The only skip in the measured suite requires physical-device Data Protection support; Calendar
integration ran. The earlier 32 tooling tests and five website tests passed in
2.7 seconds combined. The final incremental test-bundle rebuild took 7.9 seconds;
this is not a cold-build estimate.

Twenty-four methods from CaptureTests, TodayTests, EventEditorTests,
WizardOptionalStepTests and FeeAndInvoiceTests now occupy 17 independently
schedulable classes instead of five. Their complete method bodies are unchanged.
The gap between the first and last UI worker finishing fell from 84 seconds in
the initial four-worker run to 31 seconds in the final run. Scheduling and startup
vary, so these single complete runs do not establish a stable performance bound.

The receipt edit/save/reopen test took 133.6 seconds initially, 48.6 seconds after
splitting classes, and 16.6 seconds after the notification fix. Activity logs
localized the delay to the idle wait after Save. A diagnostic repeat reproduced
a related expense-route failure: a one-second process sample showed
`ExpenseNotifications.clear` blocked in synchronous notification-service IPC
from `removePendingNotificationRequests`. That repeat was stopped after capturing
the failure and is not included as a completed benchmark. System notification
removal now runs on a serial utility queue; database saving, assertions and UI
wait limits are unchanged. The formerly failing expense-route test passed in
28.0 seconds in the final clean run, which used no process sampling.

The final run is about 8% faster than the previous four-worker baseline, but still
2m 33s over the five-minute target before building. Summed UI test time was 1,368
seconds: even perfect four-worker distribution would take about 5m 42s before
startup and result collection. Further gains require shortening the workflows
themselves, especially repeated session entry, library setup, weather and layout
checks, as well as reducing simulator startup overhead. Keep their unique
assertions when replacing repeated setup with fixtures; further class splitting
alone cannot reach five minutes at these observed durations.

The initial two-worker run found two navigation assumptions, both fixed and
validated in the passing runs: library/filter setup must leave Events at its list,
and delete-event checks must use Events rather than date-filtered Upcoming.
Design Capture and System Pickers remain separate, as described above.

The separate `./cloudkit.sh check --local-only` gate still fails because the
reviewed manifest's `CloudBackupStore.swift` hash is stale. The mismatch also
exists in HEAD before these test changes. No schema export or manifest update was
performed; the release schema gate remains outstanding.

### Merged-suite benchmark with prepared workers — 16 October 2026

After merging Payments, the enabled Xcode suite contains 217 unit/integration
methods and 64 UI methods (281 total). No methods were removed in this pass.
Seven seeded workflows now open their prerequisite in the normal Events
navigation stack; separate navigation tests still exercise list entry. Weather
checks retain visibility assertions but only perform extra screenshot framing
when success screenshots are enabled.

| Four explicit simulator workers | Test wall time | Passed | Failed | Skipped |
| --- | --- | --- | --- | --- |
| First pass on newly prepared devices | 7m 10s | 278 | 1 | 2 |
| Warm devices, updated Payments assertion | 6m 07s | 279 | 0 | 2 |
| Warm devices, balanced from warm timings, wizard wait fixed | **5m 27s** | **279** | **0** | **2** |

The final run is 27 seconds above the five-minute target. Times include runner
startup and result collection, with coverage enabled and no failure retries.
They exclude build, test enumeration and simulator preparation. Creating four
fresh simulators, booting them concurrently, installing the app and granting
Calendar access took another **59.7 seconds**, measured separately. These are
local observations, not a five-minute cold-start guarantee. The earlier 7m 33s
clone-based result covered a smaller 254-test suite and is not a controlled
before/after comparison.

Xcode's automatic clone scheduler previously dispatched its fourth UI worker
73 seconds after the first. Explicit prepared devices reduced that spread to
17 seconds on their first test run. On warmed devices three UI workers started
together, while the fourth first ran the unit suite. Balancing whole classes
using warm durations reduced the first-to-last worker completion gap from 88 to
16 seconds. Final summed UI time was 1,237 seconds, an ideal four-worker floor
of about 5m 9s before overhead: scheduling alone cannot guarantee five minutes.

The first merged run found an obsolete `Invoiced` heading assertion. It now
checks the redesigned Payments row for the actual invoice reference and $125
remaining balance. A further balancing run finished in 5m 31s but failed an
immediate wizard selection assertion; it is excluded from successful results.
That assertion now waits up to five seconds for the same selected label. Three
consecutive focused runs and the final full suite passed after the correction.
The two skips are physical-device Data Protection and the iPad-only Payments
layout test on iPhone. All 36 Python tooling tests and five website tests passed.
The schema-test success mock now includes V15's client invoicing field and a
negative test rejects its absence; the reviewed CloudKit snapshot is unchanged.

### Consolidated UI setup — 16 October 2026

The enabled suite now has 217 unit/integration methods and 63 UI methods (280
total). `testForeignSessionDate` was absorbed into
`testInlineNativeSessionTimesAndIndependentClear`: the Tokyo date, independent
start/end clearing and absent work-timezone assertions remain. The combined test
also waits for the Role & location page before checking the absent field.

Standard-size session timezone assertions now share the session-choice launch.
The two original accessibility sizes remain independently covered: session
choices at accessibility XL and timezone visibility at accessibility XXXL.
Payments' standard-size dark heading check now shares the ledger workflow;
its extra screenshot launch remains opt-in with `CUEKEEPER_TEST_SCREENSHOTS=1`.
Together these changes remove three default app launches without removing the
behavioral assertions. No additional tests are excluded and no retries are used.

| Four explicit simulator workers | Test wall time | Passed | Failed | Skipped |
| --- | --- | --- | --- | --- |
| Freshly prepared devices, initial consolidation | 6m 13s | 277 | 1 | 2 |
| Warm devices, corrected wizard page synchronization | 5m 27s | 278 | 0 | 2 |
| Warm devices, balanced using current warm timings | **5m 16s** | **278** | **0** | **2** |

The initial failure was an incorrect new wait for Review; this fixture advances
from Session times to Role & location. Waiting for its arrangement control fixed
that check, and both subsequent full runs passed. The final exact time was
315.50 seconds, versus the previous 327.33 seconds: about 12 seconds faster and
16 seconds above the five-minute target. Worker completion times ranged from
303.46 to 315.50 seconds. All 280 enabled methods ran exactly once, with the same
physical-device and iPad-only skips as before.

These are warmed, test-only timings with coverage enabled. Build, discovery and
simulator preparation are excluded; preparing the four fresh devices took 67.21
seconds separately. Results are local observations, not a cold-start guarantee.
Artifacts for this pass are under `build/benchmarks/consolidated-{first,warm,balanced}-4/`.

Run the complete build, simulator preparation and two-pass benchmark with:

```sh
./benchmark.sh
```

This creates four dedicated iPhone 18 Pro / iOS 27 simulators, builds in an
isolated directory, enumerates the current tests, and runs the full suite twice.
The second run uses the first run's timings to balance warmed workers. Logs,
results, device UUIDs and build products are retained under the printed
`build/balanced.*` directory; read `warm/summary.json` for the final timing.
Only simulators created by this invocation are removed on exit, including after
failure. A failed first run stops before the second run. The iOS 27 runtime and
Xcode command-line tools must already be installed. Run while other worktrees
are not testing; this script does not archive or upload a release.

For manual control of already prepared simulators:

`scripts/benchmark_tests.py` partitions whole UI classes across explicitly supplied
simulators, keeps unit tests together, and rejects missing, duplicate or unexpected
result methods. It creates one result bundle per worker, `plan.json`, `summary.json`
and combined `tests.json` for subsequent timing input. It does not create, erase
or delete devices. Supply four distinct, dedicated, booted iPhone simulators with
the app installed and Calendar permission granted; never use a simulator involved
in another worktree's test run.

Enumerate the current compiled bundle after changing its test inventory. Do not
reuse enumeration from an older suite: result verification cannot discover a new
class absent from both an old inventory and its selected classes.

```sh
xcodebuild test-without-building -xctestrun "$TEST_RUN" \
  -destination "platform=iOS Simulator,id=$SIM_A" \
  -enumerate-tests -test-enumeration-style flat -test-enumeration-format json \
  -test-enumeration-output-path build/enabled-tests.json

python3 scripts/benchmark_tests.py --xctestrun "$TEST_RUN" \
  --enumeration build/enabled-tests.json \
  --timings build/previous-benchmark/tests.json \
  --device "$SIM_A" --device "$SIM_B" --device "$SIM_C" --device "$SIM_D" \
  --output build/new-benchmark
```

`TEST_RUN` is the built `.xctestrun` path; each `SIM_*` is a prepared device UUID.
Use a new output directory each time. Omit `--timings` on the first run; the
fallback estimates are less accurate. Keep provisioning and enumeration time
separate in reports, and include them when budgeting a fresh-machine CI job.

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

The release script reuses or creates its named simulator (default: iPhone 18 Pro),
boots it and waits for startup, then passes its UUID to Xcode. It selects the
newest installed compatible iOS runtime, respecting the deployment target and
an explicit `OS=` version. The simulator is retained for subsequent runs; Xcode
manages parallel worker clones. Missing runtimes produce an actionable error;
the script does not download runtimes automatically.

Unit and UI tests run as separate labelled stages. Each stage streams Xcode output,
prints elapsed time every 15 seconds while running, and ends with an explicit
pass/fail result. Parallel workers can delay individual test results until they
finish; an elapsed-time update confirms the command is still running, not that a
test has passed. `TEST_WORKERS` sets the worker count (default: 4).
Unfiltered output is saved as `CuekeeperTests.log` and `CuekeeperUITests.log` in
that release's output directory. The terminal replaces repeated Xcode
debugger-version metadata notices with one explanation; the raw logs retain them.
Either stage failing stops the release before archiving.

Set `TEST_DESTINATION` in `.release.env` for another named simulator or an explicit
UUID. Named devices are prepared automatically; explicit UUIDs and other
platform destinations are passed through unchanged. `--skip-tests` skips device
preparation too.
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

Each device makes at most one WeatherKit attempt per Place ID per hour, with a
shared cap of 24 attempts across all venues per rolling 24 hours, including failed
requests. Loads are on demand, with hourly refreshes while an eligible job is
visible; there is no background polling. Both limits persist across app restarts.
Concurrent requests share one task. Request timestamps and forecasts persist
locally outside iCloud and backups. Forecasts show their fetch time and are marked
outdated after Apple’s expiry. They stop displaying after 24 hours, and expired
payloads are purged when the app runs. If refresh fails, an existing displayable forecast remains visible; otherwise
weather is unavailable until the next permitted attempt. The 24-hour stale-display policy is an explicit
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
standard calendar parameters and saves a basic event through the wizard's existing
`EventCreationDraft` transaction. The intent returns that saved event and opens
Cuekeeper to its detail screen. It does not wait for the user to finish editing.
Add clients, championships, roles, fees, sessions, or other details through the
existing editors, anchored to the saved record's permanent ID. These edits update
the same event. Closing the screen or cancelling an edit keeps the basic event.
A second Siri creation is rejected while the first event screen remains open.

No App Shortcut trigger phrases are advertised. Existing custom shortcuts using
the older Create Event action remain compatible and use the same save-then-edit
flow. The legacy action is hidden from new action discovery.

All-day calendar end dates are exclusive; the adapter converts them to the
wizard's inclusive end day using calendar arithmetic. Timed requests populate a
session with the original start/end instants and device timezone, leaving its
schedule tentative and coverage undecided. Missing end times stay unknown.
Location and notes are saved with the event. Recurrence and invitees are not
imported; a six-second, accessibility-announced notice explains that only one
event was created and no invitations will be sent. Invalid date ranges
still fail validation. No Siri audio or full conversation transcript is received.

The intent uses the app's shared persistence controller. Nothing is written to
EventKit directly; the existing designated calendar publisher and foreground
reconciliation rules remain in effect.

Validation includes schema metadata export (calendar domain, no App Shortcuts),
persistence tests for creating once, editing the same record, closing without
removing it, failed saves, concurrent requests, and daylight-saving date conversion.
Simulator tests cover editing in place, cancelling edits, and the disappearing
notice. These do not establish Siri speech recognition, schema routing, or
foreground handoff on a physical device. Test the installed build on an iOS 27
device with supported Siri AI: request an all-day event, a timed event, and
recurrence/invitees; verify the saved event, notice, edits, close, and cold launch.
Opening the event requires foreground interaction and may require unlocking the
device.

### Single-client events

The app now treats every client record as its own event. Adding clients to an event
and grouping/linking events are no longer available. Client, project, championships,
work, fees and notes are edited directly within the event. Sessions and payments
are accessible on the same event detail screen.

Old grouped records remain compatible: each client appears separately using the
existing record ID. The first event save copies historical shared metadata into
that client's own record without changing sessions, fee revisions, invoice lines
or receipts. There is no eager CloudKit backfill or schema change. Use the updated
app on all devices; older versions retain their previous grouping behaviour.
Calendar reconciliation retires known grouped placeholders and publishes one
placeholder per active client event, retaining eligible session entries.

### Event and work timezones

Every session uses its event’s timezone; there is no session timezone override.
Remote and hybrid work can set “Your timezone” for an additional local-time display.
On-site work inherits the event timezone. Changing a timezone preserves the saved
start, end and call instants. Copying sessions between events preserves local clock
times in the destination event timezone and rejects nonexistent daylight-saving times.
Existing session timezone fields remain for storage compatibility; an older event
without a timezone can recover a common zone from its sessions. Conflicting legacy
zones require choosing an event timezone.

## Receipt expenses (V12)

Event → Expenses → Scan Receipt opens the native document camera, with photo
import available after cancelling the camera or on devices without a scanner.
Scan one page per expense. Vision reads the image on-device and the on-device
Foundation Models model proposes merchant, civil date, total, currency, included
tax and category. If the on-device context limit is exceeded, the complete OCR
text (not the photo) is retried once using Apple Private Cloud Compute (PCC).
Progress and completion messages identify where processing happens. PCC requires
internet access and available usage quota; failures leave the saved photo available
for manual entry or a later retry. If PCC also exceeds its context limit, the
friendly “too long” message is shown. No third-party model is used. Apple Intelligence must
be available for automatic field extraction; manual review remains available
when it is disabled, unsupported, downloading or fails.

PCC requires Apple to assign the Private Cloud Compute entitlement to the developer
account and enable it for the app identifier. Regenerate distribution profiles with
`com.apple.developer.private-cloud-compute`; the release profile check requires it.
See https://developer.apple.com/private-cloud-compute/ for eligibility and access.
Verify live PCC with an entitled TestFlight or ad hoc build on a compatible device.
Extraction runs while the receipt editor is open; it has no background queue or
automatic retry after relaunch. Closing the editor cancels the request.

The review form requires confirmation before an expense is counted as saved.
The normalized receipt JPEG is persisted as an event-linked draft before model
processing. Keep Draft preserves incomplete fields; reopen Review receipt in the
event to continue. A process interruption preserves the photo, but form edits
since the last save may be lost. Saved expenses can be reopened and edited, with
stale edits rejected locally. Expenses do not change fees, invoices or payments.
This version supports positive totals in USD, EUR, GBP, CAD, AUD, NZD and CHF;
it does not split receipts or perform currency conversion or tax calculation.

The discoverable Scan Receipt App Intent and App Shortcut open event selection
and then receipt capture. Assign it through Settings → Action Button → Shortcut
→ Cuekeeper → Scan Receipt (or create a shortcut containing that action).
It requires foreground interaction and authentication. Repeated invocations
reuse the pending selection rather than creating events or expenses.

V12 adds the optional Expense entity and Job.expenses inverse, with externally
stored binary receipt data. Photos and draft fields are included in explicit
backups; pre-expense archives remain restorable. Event deletion retains its
expenses with the event tombstone. Backups use the ZIP format and limits described below.
Production schema deployment and real-device camera/model, Action Button,
and cross-device image-sync checks are required before release.
### Today and widgets

Upcoming now offers Today, Week and All. Today shows the complete day's sessions
in device-local time, with each session's event, client and call time. Sessions
crossing midnight remain visible on both affected days. Event-local times appear
when the event timezone differs. Events awaiting a schedule remain useful in a
separate section. Cancelled/deleted work is excluded. Tentative times and undecided
coverage are labeled; only booked, confirmed, covering sessions supply Next call.
Tap a session to open it, then its Event link to open the parent event.

The widget extension supports small and medium Home Screen widgets plus inline,
circular and rectangular Lock Screen accessories. Small widgets list two remaining
sessions, sharing an event heading when appropriate or labeling each event separately.
Medium widgets show up to four sessions. Widgets open Upcoming → Today. Completed
sessions drop out of widgets while remaining in the in-app day schedule.

The app writes an atomic, schedule-only JSON snapshot to App Group
`group.com.arjunakankipati.cuekeeper`. Both the main app and
`com.arjunakankipati.cuekeeper.widgets` extension must have that group enabled in
Apple Developer and their signing profiles. No Core Data migration or CloudKit
schema change is needed. Snapshots exclude notes, links and financial data and are
protected until the first device unlock. Widget content is marked privacy-sensitive.
The app refreshes the snapshot after local/merged changes and foreground activation;
WidgetKit schedules time transitions and controls reload delivery. Widgets do not
independently sync CloudKit, so they reflect the last app snapshot, not a guarantee
of current data on every device. UI-test stores never publish widget snapshots.

Design references and verification notes live in `design/today-widgets/`.

## Background expense capture (0.1.10)

Capture Expense is a separate, background-only App Intent with optional Merchant,
Amount, Currency, Transaction date and Transaction ID inputs. It saves an expense
draft without a receipt or event and returns its UUID. It does not open the app or
ask for missing fields. Scan Receipt remains the foreground Action Button action.
It runs without unlocking so Wallet automations work after a locked-phone payment.
For that reason it is not an App Shortcut and has no Siri phrase; add it to a
personal automation or custom shortcut from the Shortcuts action list.
The new behavior reuses V12; optional captured-payment metadata is stored with the
expense value, so no further Core Data/CloudKit schema version is required.

Set up the Wallet personal automation on the iPhone using Settings → Integrations
→ Wallet Automation. The guide explains mapping available Shortcut Input fields,
Run Immediately, optional completion reminders, and the separate Scan Receipt
Action Button use case. Cuekeeper cannot install the personal automation itself.
Unknown or unparseable transaction values remain available in Captured payment;
review fields stay blank rather than assuming a currency, date or total.

Upcoming shows a completion prompt when drafts exist; Payments always links to
Expenses to complete. Choose a draft, attach a receipt and assign an active event.
Keep Draft saves incomplete work. Confirming still requires a receipt, event and
valid expense details. Receipt extraction fills blanks and shows explicit choices
for conflicts instead of overwriting payment values. Original payment evidence
remains unchanged after editing. Personal/duplicate drafts can be removed with
confirmation; their capture identity remains retained to prevent re-import.

Deduplication uses only an explicit stable source Transaction ID (stored as a hash).
Re-delivery of that ID does not modify a completed, edited or removed record. If
no source ID is supplied, captures are kept separately; equal merchant/amount/date
values are not sufficient evidence to discard a genuine second purchase. Local
intent saves are serialized on the main actor; independently captured duplicates
on offline devices are not globally deduplicated by CloudKit.

Reminders are opt-in and local to the capturing device. Notification denial or
scheduling failure never undoes a saved draft. Generic notification text avoids
putting merchant/amount details on the lock screen. Tapping routes by persisted
expense UUID after store loading. Completion/removal clears its reminder, and
foreground reconciliation removes stale delivered/pending reminders. Drafts stay
accessible when reminders are disabled or silenced by Focus. Locked-device access,
actual Wallet payloads and cold-start notification delivery still need hardware
validation. No server, PCC or remote notification service is used for this flow.


### Receipt-heavy backups

Backups use a version-2 ZIP: `manifest.json`, `records.json`, and `receipts/*.jpg`.
The metadata references receipt paths, lengths and SHA-256 checksums; photo bytes
are never base64-encoded into JSON. ZIPFoundation 0.9.20 is pinned through SwiftPM.
No legacy JSON import is supported (there are no deployed backups to migrate).

Settings → Recovery & backups → Backups supports private iCloud copies and
Files export/import. First-launch recovery also supports Files import. Archive
preparation, validation and restore run on private Core Data contexts. Restore
validates before writing, preserves the existing merge rules, and commits once
with an error merge policy so concurrent conflicts abort rather than overwrite.

Limits: 512 MiB per archive/expanded contents, 32 MiB metadata, 200,000 records,
12 MiB per receipt, 50 iCloud copies. Cloud storage splits the archive into
16 MiB CKAssets; parts and the backup index commit atomically in the existing
custom zone. File export is an unencrypted ZIP and needs no iCloud account.
Temporary files are owned by the operation, protected on iOS, and removed on
normal completion/cancellation. Keep the app open for backup and restore.

Progress names the local preparation, checking, packing and restoring stages;
iCloud operations remain indeterminate. Preparation/read cancellation leaves
the daybook unchanged. Restore and cloud commit do not offer cancellation.
The tests exercise corrupt/missing/unexpected files, limits, cancellation,
merge behavior and a 128 MiB receipt round trip beyond the old limit.

### All expenses

Expenses is a dedicated iPhone tab and iPad sidebar destination. It shows saved
expenses and drafts across events, newest receipt date first, with All, Saved and
Needs review filters.
Each row keeps its original currency and opens the existing receipt editor.
Scan Receipt starts with event selection; Expenses to complete retains draft
completion and removal. Removed drafts stay hidden. Expenses retained with deleted
events remain listed with a restore instruction and cannot be edited until the
event is restored in Settings. This navigation change adds no storage schema.
