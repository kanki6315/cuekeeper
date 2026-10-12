# Cuekeeper

Native iPhone and iPad daybook for broadcast freelancers. Minimum iOS/iPadOS 27.
This is the first implementation milestone: signed app foundation, local job
capture, CloudKit configuration, and a TestFlight release pipeline.

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
- Browse, search and view captured jobs; Upcoming excludes past dates.
- SQLite persistence through Core Data, with CloudKit private-database mirroring.
- iCloud account checks and observed transfer/error status in Settings.
- Isolated local test stores that never write test records to iCloud.

Job editing, sessions, EventKit, fees, invoices, payments, conflict-preserving
financial history, backup/restore and Recently Deleted are still future work.
Payments is explicitly marked as unavailable in this foundation build.
Do not use this build as the only copy of important records.

## CloudKit setup and verification

The project enables CloudKit, Push Notifications, and Background Modes → Remote
notifications. Automatic signing configures the app's provisioning. The iCloud
container must be associated with this bundle ID in the developer portal.

1. Run a Debug build on a device signed into iCloud. In Xcode's scheme editor,
   optionally add the launch argument `--initialize-cloudkit-schema` for one run.
   This Debug-only operation initializes all model fields in the Development
   schema; check Settings for success, then remove the argument.
2. Create a disposable job and check the private Development database in
   CloudKit Console. Model schema names are managed by Core Data.
3. Run Debug on a second iOS/iPadOS 27 device with the same iCloud account.
   Verify the job arrives, then add jobs offline on both devices and reconnect.
4. Before using TestFlight, deploy the Development schema to Production in
   CloudKit Console. Deploying schema does not copy Development records.
5. Test again with a Release/TestFlight build; production and development data
   are separate. A completed local archive does not prove live sync.

Keep future model migrations compatible with CloudKit. Do not add uniqueness
constraints. Relationships added later must support CloudKit's optional and
non-atomic relationship delivery. Financial conflict handling is a separate
milestone, not supplied by the current job merge policy.

Settings reports observed operations, not a guarantee that all devices are up to
date. iCloud sync is asynchronous and is not a backup. Local saving remains
available when iCloud is unavailable. Visible load failures never replace the
persistent store with an empty one.

## Tests

```sh
xcodebuild test -project Cuekeeper.xcodeproj -scheme Cuekeeper \
  -destination 'platform=iOS Simulator,name=iPhone 18 Pro,OS=27.0' \
  -derivedDataPath build/tests CODE_SIGNING_ALLOWED=NO
```

Persistence tests cover saving/reopening a real SQLite store, validation without
partial inserts, and civil-date round trips across timezones and DST. UI tests
capture a job, restart the app and verify its booking state. Run the UI suite on
an iPad too by changing the destination. These tests disable CloudKit; live
cross-device convergence must be verified separately on signed-in devices.

## Release to TestFlight

The release tooling is adapted from Harbor. Account settings belong in the
ignored `.release.env`; `.release.env.example` documents the supported values.
Private signing keys remain outside this repository. The validated default is
the Apple Account signed into Xcode. Harbor's API-key authentication failed during
initial setup, so those optional local settings are commented out.

Before the first upload, create the **Cuekeeper app record in App Store Connect**
using the existing bundle ID. Registering a bundle ID alone does not create the
app record. Deploy and verify the CloudKit Production schema as described above.

```sh
./release.sh --no-upload              # tests → archive → local IPA export
./release.sh                          # tests → archive → TestFlight upload → local Git tag
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

`--no-upload` still contacts Apple for signing and may create provisioning
profiles. It does not publish a build. Successful export proves packaging and
signing, not App Store Connect acceptance or live CloudKit sync.
