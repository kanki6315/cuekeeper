# Cuekeeper

Native iPhone and iPad daybook for broadcast freelancers. Minimum iOS/iPadOS 27.
The signed app foundation now includes complete nonfinancial job management,
CloudKit configuration, and a TestFlight release pipeline.

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
- Capture a tentative job using a name and inclusive placeholder dates.
- Edit jobs and set tentative, booked, completed or cancelled status.
- Add and reuse named clients and roles inline while editing a job.
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
- iCloud account checks and observed transfer/error status in Settings.
- Isolated local test stores that never write test records to iCloud.

Sessions, EventKit, fees, invoices, payments, conflict-preserving
financial history, backup/restore and Recently Deleted are still future work.
Payments is explicitly marked as unavailable in this foundation build.
Do not use this build as the only copy of important records.

## CloudKit setup and verification

To initialize from the terminal, use `./cloudkit.sh init --device '<UDID or name>'`
with an unlocked, paired, iCloud-signed-in device. This installs the dedicated
setup build and waits for confirmed completion. See the CloudKit workflow below
for side effects, logs and the equivalent Xcode steps.

Select the **Cuekeeper - Initialize CloudKit** scheme in Xcode and run it on a
device signed into iCloud. This uses a dedicated Development-only build and a
separate local store. Settings shows a persistent initialization result. Return
to the ordinary **Cuekeeper** scheme afterward; no launch arguments are needed.

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

```sh
xcodebuild test -project Cuekeeper.xcodeproj -scheme Cuekeeper \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' \
  -derivedDataPath build/tests CODE_SIGNING_ALLOWED=NO
```

Persistence tests cover saving/reopening SQLite, V1-to-V2 migration, validation
without partial changes, duplication and library reuse, client renaming,
combined filters, preservation of unchanged editor fields, and civil-date round
trips across timezones and DST. UI tests cover capture/relaunch, editing booking
status, confirming duplicate dates, discarding edits, client creation/filter
navigation, and visible failed-save alerts that preserve the draft. Run the UI suite on
an iPad too by changing the destination. These tests disable CloudKit; live
cross-device convergence must be verified separately on signed-in devices.

## Release to TestFlight

The release tooling is adapted from Harbor. Account settings belong in the
ignored `.release.env`; `.release.env.example` documents the supported values.
Private signing keys remain outside this repository. The validated default is
the Apple Account signed into Xcode. Harbor's API-key authentication failed during
initial setup, so those optional local settings are commented out.

The Cuekeeper app record already exists in App Store Connect. Deploy and verify
the CloudKit Production schema as described above before the first upload.

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

## Job management validation and next release

The V2 Core Data model adds clients, roles and job details. The V1 model remains
bundled for lightweight migration; tests open a V1 SQLite store and verify that
its jobs survive the upgrade. Each editor saves through an isolated context.
Unchanged form fields do not overwrite updates saved while the editor was open.
This does not establish conflict resolution for simultaneous edits to the same field.

On October 12, 2026, the user verified cross-device sync in the first TestFlight
build, including capture offline and sync after reconnecting. Cross-device
conflicts were not tested. The new V2 fields and relationships need their own
cross-device check after release.

Before distributing this model change, run the dedicated initialization scheme
on an iCloud-signed-in device, export and commit the real Development schema,
and deploy its additions in CloudKit Console. The existing committed CloudKit
snapshot represents the first released model; the release gate intentionally
blocks V2 uploads until the new export and Production deployment are complete.
Client/role renames update related jobs through their shared records. Library
names are checked case-insensitively on this device; independently created
records on offline devices are not yet automatically deduplicated.
