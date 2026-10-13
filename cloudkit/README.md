# CloudKit schema workflow

The Core Data model is the source of truth. Apple generates its CloudKit schema;
we do not maintain a hand-written approximation of Core Data's internal records.
All commands here operate on `iCloud.com.arjunakankipati.cuekeeper`, team
`TDBAHN96B3`. `cloudkit.sh` derives that identity from the project configuration.

## Initialize Development

From the terminal:

```sh
xcrun devicectl list devices
./cloudkit.sh init --device '<device UDID or name>'
./cloudkit.sh export
```

Keep the selected paired device unlocked, with Developer Mode enabled and signed
into iCloud. The script builds the setup scheme, installs it, and waits up to
180 seconds for an explicit completion marker. Use `--timeout 300` if needed.
Logs are saved under `build/cloudkit-initialize/`. A successful app launch alone
is not treated as successful initialization. This installs the setup build over
Cuekeeper on that device; its separate setup store leaves the normal local store
untouched. Return to the ordinary app build or reinstall TestFlight afterward.
The script does not export or deploy automatically.

This device runner is a convenience for the existing iOS setup scheme, not an
Apple requirement to initialize inside the shipping app. Core Data initialization
can also run in an appropriately configured integration-test or helper target.
`cktool` can import an existing schema but does not generate Core Data's mapping
from the managed object model.

Alternatively, use Xcode:

1. Run `xcodegen generate` and open `Cuekeeper.xcodeproj`.
2. Select **Cuekeeper - Initialize CloudKit** and an iCloud-signed-in device.
3. Run. In Settings, wait for **Development schema initialized**. The result
   remains visible independently of subsequent sync notifications; Xcode's
   console also receives the result.
4. Return to the ordinary **Cuekeeper** scheme for app development.

The setup scheme uses the `CloudKitSetup` build configuration. Schema generation
is compiled only into that configuration, requires a Development environment,
and uses a separate local `CloudKitSchemaSetup/Schema.sqlite` store. Neither
ordinary Debug nor Release contains the initialization code. The setup scheme's
build action is enabled for Run only, not Archive or Test. No launch arguments
need to be edited. The initializer creates and removes representative CloudKit
records as part of Apple's schema-generation process.

## Authenticate cktool once

Generate a **management token** in CloudKit Console and save it using the secure
interactive prompt:

```sh
xcrun cktool save-token --type management
```

This stores the token in your macOS keychain. It is separate from an App Store
Connect API key and doesn't grant access to people's private records. Never put
it in source control or a command argument. For CI, cktool also supports the
`CLOUDKIT_MANAGEMENT_TOKEN` environment variable; use your CI secret store.

## Export and review

After initialization, from the repository root:

```sh
./cloudkit.sh export
git diff -- cloudkit/schema.ckdb cloudkit/schema.json
```

Commit both files. `schema.ckdb` is the actual Development export, including
Core Data's supporting record types, fields, indexes and permissions.
`schema.json` records team/container identity, a checksum of that export, and
checksums of the Core Data model versions and current-version selector.

Export rejects an empty/uninitialized schema or missing model attributes before
replacing the previous snapshot. The fingerprint catches subsequent local model
changes; it does not independently prove that Core Data completed initialization
for every possible model migration. Always run the initialization scheme first
when the model changes. Do not edit the exported schema by hand.

## Deploy, then check

Review and deploy the Development schema to Production in CloudKit Console.
Deployment is explicit: the scripts never import, deploy, reset, or delete a
schema. Production retains existing types/fields, so plan model migrations before
publishing incompatible changes.

```sh
./cloudkit.sh check              # current snapshot + live Production comparison
./cloudkit.sh check --local-only # offline fingerprint check; not release approval
```

The live check exports Production to a temporary directory and compares its
schema to the reviewed snapshot. Whitespace, comments, declaration order and
field/grant order are ignored. Field types, indexes, grants, roles, extra/missing
records and other token differences block release. The comparison is deliberately
conservative: an unexpected difference needs review rather than an automatic
schema mutation. A passing check proves schema agreement, not record sync or
cross-device conflict resolution.

## Release integration

`release.sh` performs the live check before tests/archive/upload. `--skip-tests`
and `--allow-dirty` do not bypass it. Missing authentication, missing snapshots,
a changed model or production drift all stop the release.

For an explicitly local, offline packaging check only:

```sh
./release.sh --no-upload --skip-cloudkit-check
```

The bypass is rejected if upload is enabled. It does not establish TestFlight
readiness. Normal uploads must use the ordinary `Cuekeeper` Release scheme.

References: [Core Data schema initialization](https://developer.apple.com/documentation/coredata/creating-a-core-data-model-for-cloudkit),
[CloudKit schema deployment](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema),
and [Apple's cktool guide](https://developer.apple.com/icloud/ck-tool/).
