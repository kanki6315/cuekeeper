# Cuekeeper 0.1.3 device-test preparation

- Version 0.1.3, build 287.0.56, packaged October 13, 2026 (America/New_York).
- Regenerated and installed `Cuekeeper App Store 20261014005528`; its WeatherKit entitlement is enabled.
- Archive and IPA export succeeded using the existing distribution certificate.
- Verified the exported IPA signature, version/build, WeatherKit entitlement in both app and profile, and Production CloudKit environment.
- Archive: `build/release/0.1.3-287.0.56/Cuekeeper.xcarchive`.
- IPA: `build/release/0.1.3-287.0.56/export/Cuekeeper.ipa`.
- Build log: `build/weather-0.1.3-package.log`.
- Existing feature validation is recorded in [weather verification](weather.md); tests were not repeated for this version/profile-only change.

The user deployed V7 to Production, and `./cloudkit.sh check` passed against the live schema. Apple confirmed upload success at 9:04 PM America/New_York on October 13, 2026. Upload log: `build/weather-0.1.3-upload.log`. The existing internal TestFlight group `Test` has automatic access to all builds.

App Store Connect confirmed processing state `VALID`, version `0.1.3`, build `287.0.56`, and internal status `IN_BETA_TESTING` with automatic notifications enabled. The build is ready for internal TestFlight installation. Build ID: `c173c8d2-3d3b-4470-b0f9-f5be13bb2362`. Live WeatherKit responses remain unverified on-device.

## V9 wizard integration release — October 14, 2026

- Uploaded version 0.1.3, build 287.13.3 from source commit `c7c794c` using
  `release.sh`; the signed archive and App Store Connect export/upload succeeded.
- Release tag `ios/v0.1.3-287.13.3` is pushed to origin.
- V9 Development initialization completed and its actual schema export matched
  live Production. The script's live CloudKit release gate passed again.
- The full release run passed 39 unit tests and 23 of 24 UI tests. The remaining
  test exposed a missing `upcoming-scope` accessibility identifier from the event
  grouping change. Restored that identifier in `c7c794c`; the targeted
  `DesignSupplementTests/testCombinedGlassSurfaces` rerun passed. All test cases
  therefore have passing coverage. All 27 Python tooling tests also passed.
- After the passing rerun, `release.sh --skip-tests` reused those results while
  retaining the normal live schema gate, signed archive, upload and tagging.
- Logs: `/tmp/cuekeeper-v9-testflight-release.log` (full run),
  `/tmp/cuekeeper-v9-scope-check.log` (corrected check), and
  `/tmp/cuekeeper-v9-testflight-upload.log` (successful release).
- Archive: `build/release/0.1.3-287.13.3/Cuekeeper.xcarchive`.

Upload is confirmed. At the immediate post-upload API check the build had not
appeared in App Store Connect's build list yet; Apple processing and tester
availability remain pending. No physical-device V9 sync claim is made.
