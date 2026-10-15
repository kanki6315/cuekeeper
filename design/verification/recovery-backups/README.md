# Recovery and private iCloud backups — October 14, 2026

Scope: Settings → Recovery & backups, Recently Deleted, explicit private iCloud
snapshots, and conservative restore. Existing Daybook components and native
controls are retained. This is an implementation verification, not a release.

## Checks

- iPhone full unit/model suite: 59 tests, 0 failures, 1 EventKit integration skip
  because Calendar permission was not granted to that test app. Includes V2–V10
  migration into V11, calendar projection, financial and weather regressions.
- Final focused suite: 8 recovery/backup tests pass. Covers empty-store round
  trip, broadcast links, encoded restore over original data, repeat restore,
  newer edits/payments, immutable financial conflicts, malformed relationships,
  recovery deadlines, independent session deletion, permanent recovery removal,
  and explicit backup recovery after removal.
- iPhone and iPad UI workflows pass: restore a deleted event; create a backup;
  confirm restore; confirm deletion and return to empty backup list. UI backup
  tests inject an in-memory CloudBacking transport; no user CloudKit data is
  accessed by simulator tests. Test confirmation waits use state predicates.
- Signed Mac Development helper passes real CloudKit concurrent upload, listing,
  exact asset download and delete checks in a uniquely named disposable zone.
  The helper removes only that test zone. Marker: CLOUD_BACKUPS_VERIFIED.
- Development schema initialized/exported, including V11 optional recovery fields
  and CuekeeperBackup/CuekeeperBackupIndex. Local release-schema gate passes.
- Python tooling suite: 27 tests pass. git diff --check passes.
- Unsigned generic-iOS Release build passes.
- Independent Impeccable finish review: ship, no material fixes, scoped to
  this Settings extension and the four supplied simulator captures.

Visual evidence is in `.impeccable/review/recovery-backups/`: phone-recovery.png,
phone-backups.png, tablet-recovery.png, tablet-backups.png. These are actual iOS
27 simulator captures, light recovery and dark saved-backup states. The iPad
captures are portrait. New large-Dynamic-Type screenshots were not collected;
controls use semantic fonts and ViewThatFits stacking.

Local test bundles: /tmp/cuekeeper-recovery-final.xcresult (full regression),
/tmp/cuekeeper-recovery-diagnostic.xcresult (passing iPhone UI),
/tmp/cuekeeper-recovery-tablet-final.xcresult (final focused tests and iPad UI).
Live CloudKit transcript: /tmp/cuekeeper-backup-live2.log.

## Release boundary

The Production schema has not been deployed, and this task did not upload to
TestFlight. Deploy the reviewed additive Development schema to Production and
run the live Production gate before distributing this build. Cross-device
physical iPhone/iPad recovery and backup restore still need beta validation.
Restores merge and recover records; they do not roll back newer field edits.
Permanent removal ends in-app recovery but retains tombstones for calendar
cleanup/financial references; it is not secure erasure, and old snapshots remain.
