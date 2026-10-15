# Receipt-heavy backup verification — October 15, 2026

Implemented a version-2 ZIP containing manifest.json, records.json and separate
receipt files. The app uses URLs for production backup IO and private Core Data
contexts for preparation, validation and restore. Legacy JSON is deliberately
unsupported; no existing backups require migration.

## Checks completed

- Final model suite: 92 tests, zero failures. Includes byte-for-byte receipt
  round trips, missing/unexpected/corrupt attachments, oversized files,
  pre-cancelled work, cancellation immediately before save with complete rollback,
  repeated restores, tombstone recovery and immutable-financial conflict rollback.
- Receipt volume: 128 × 1 MiB synthetic photo payloads, producing a 134,352,646-byte
  ZIP (about 128 MiB), restored successfully. The archive avoids base64 expansion.
  The full test-process peak RSS was about 893 MiB, including fixture creation,
  both stores and the full model suite; this is not a measured app-only memory
  budget. The isolated backup test run peaked around 709 MiB. Physical-device
  memory and near-limit stress validation remain necessary before release.
- iPhone: actual native Files export → import → confirm restore passed; standard
  light and largest-text dark captures taken. Existing backup save/restore/delete
  UI regression passed against the fixture cloud adapter.
- iPad: actual Files round trip, first-launch empty state/back navigation, and
  first-launch cloud-fixture restore passed (three UI tests, zero failures).
  Earlier picker cancellation and largest-text checks also passed.
- Live Development CloudKit: signed macOS helper saved concurrent backups in a
  disposable zone, including a payload larger than the 16 MiB part size; loaded
  and compared bytes, deleted all backups and removed the test zone. Markers:
  CLOUD_BACKUPS_VERIFIED and CUEKEEPER_SCHEMA_INIT_OK.
- Release iOS build passed without signing. App and ZIPFoundation privacy
  manifests and third-party license notice are bundled.
- Website: build and all 5 tests passed. Tooling: all 27 tests passed.
- Native UI finish review: SHIP, no required fixes. Documentation review recorded
  alongside this file. Existing design-system files were preserved.

Initial iPhone picker tests incorrectly expected Cancel to be a Button; the
system exposed an Other element. They were replaced by the stronger real file
save/import test. Failed xcodebuild runs also stalled while collecting failure
diagnostics; final passing runs completed normally.

## Limits and remaining device checks

The implementation enforces 512 MiB archive/expanded-content, 32 MiB metadata,
200,000-record and 12 MiB individual-image limits. These are guardrails, not a
claim that the maximum size has been validated on every device. Test substantial
real JPEG collections, low-storage conditions, app interruption, VoiceOver,
third-party Files providers and signed Production CloudKit on release devices.
Cloud UI shows indeterminate transfer progress; local stages show counts or
fractions. Restore uses one save to preserve all-or-nothing behavior, so its
memory requirements still grow with the records being restored.

Exported ZIP files are unencrypted. No changes were pushed or deployed by this
implementation task. Website source and App Store draft copy were updated locally.
