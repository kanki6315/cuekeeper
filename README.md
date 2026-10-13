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
