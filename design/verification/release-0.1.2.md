# Cuekeeper 0.1.2

- Build: **286.16.21**; uploaded to App Store Connect October 13, 2026.
- Apple confirmed `Upload succeeded` at 12:23 PM America/New_York.
- Archive: `build/release/0.1.2-286.16.21/Cuekeeper.xcarchive` (includes dSYMs).
- Upload log: `build/release-0.1.2.log`.
- Archive metadata confirms version 0.1.2, build 286.16.21 and iPhone/iPad support.
- The current V6 model snapshot matched the live Production CloudKit schema. No schema changes were needed for Combined Glass.
- All 25 release-tooling tests passed. The existing final simulator and workflow evidence is recorded in [Combined Glass verification](../liquid-glass/verification/README.md); redundant simulator tests were skipped by the release script.
- Release includes the Combined Glass refinement: quiet reading surfaces, expressive iPad sidebar, native glass capsule actions and corrected appearance-aware contrast.
- Built from the current working tree with `--allow-dirty`; no Git tag was created and no unrelated changes were discarded.

Apple processing completed successfully (`VALID`). App Store Connect confirmed marketing version `0.1.2`, build `286.16.21`, and internal status `IN_BETA_TESTING`, with automatic notifications enabled. The existing internal group `Test` has automatic access to all builds. The build is ready for internal TestFlight installation.

App Store Connect build ID: `2680fbae-d0c1-48bb-8615-b0673d064727`.
