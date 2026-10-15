# Today and widgets verification

October 15, 2026. Independent review returned **ship at simulator/app-fixture
scope**. This extends the existing Daybook / Combined Glass system; the root
design specification and sidecar were preserved.

## Captures

All 16 PNGs in this directory are native simulator captures with fictional
fixture data. They cover iPhone and iPad Today in light/dark appearance, iPhone
lower schedule rows, accessibility XXXL text, and widget/accessory galleries.

| Filename pattern | Count | Coverage |
| --- | ---: | --- |
| `today-{iphone,ipad}-root-{light,dark}.png` | 4 | Today and native navigation |
| `today-iphone-lower-{light,dark}.png` | 2 | Later sessions and second-event context |
| `today-{iphone,ipad}-large-text.png` | 2 | Accessibility XXXL, portrait, dark appearance |
| `today-{iphone,ipad}-widgets-{light,dark}.png` | 4 | Small one-event/across-event and medium specimens |
| `today-{iphone,ipad}-accessories-{light,dark}.png` | 4 | Rectangular, circular and inline specimens |

Widget galleries render the actual `ScheduleWidgetView` inside the app, using
explicit family overrides and declared specimen sizes: small 170×170, medium
360×170, rectangular 170×80, circular 80×80 and inline 320×36 points. They are
**not WidgetKit-hosted Home Screen or Lock Screen captures**. Fixture framing,
padding and backgrounds do not establish actual host margins or system tint.

## Validation

- The initial full unit/model run passed 73 tests, including four DaySchedule
  tests for DST/overnight boundaries, commitment eligibility/order, remaining
  sessions, incomplete schedules, cancellation and snapshot encoding.
- The added ScheduleCaptureTests case passed on both simulator sizes. It checks
  privacy exclusions, client renaming and deletion propagation into the capture.
  This was a focused follow-up, not a rerun of the full suite with a new total.
- All four Today UI workflows passed on iPhone and iPad: light/dark layouts,
  warm links from All and from a session detail, accessibility XXXL, and all three
  accessory families in light/dark appearance. Layout tests also exercise session
  navigation and the later iPhone schedule rows.
- All 27 tooling tests passed.
- An unsigned Release build for generic iOS device succeeded for the main app
  and embedded widget extension (`/private/tmp/cuekeeper-today-release.log`).
  This validates compilation/embedding, not device provisioning or installation.

Documentation was checked against `TodayView.swift`, `RootView.swift`,
`SchedulePublisher.swift`, `Shared/DaySchedule.swift`, widget and fixture source,
the model/UI tests, the 16-file capture inventory and available test/build logs.
Visual approval is the independent review verdict above; this documentation pass
adds no separate visual audit. Temporary execution evidence includes
`/private/tmp/cuekeeper-today-tests.log`, `cuekeeper-today-final.log`,
`cuekeeper-today-tooling.log` and the Today `.xcresult` bundles in `/private/tmp`.
These temporary logs are not durable repository artifacts.

## Remaining device and release checks

The signed Release device build subsequently passed after the user registered the
widget Bundle ID, assigned both targets to the shared App Group, signed into Xcode
and refreshed provisioning profiles. Both embedded signatures verified successfully;
both signed binaries and provisioning profiles include
`group.com.arjunakankipati.cuekeeper`. This supersedes the earlier “No Accounts”
and missing-entitlement failures. Retry log: `/private/tmp/cuekeeper-today-signed-retry.log`.
The extension uses `com.arjunakankipati.cuekeeper.widgets`; no separate App Store
Connect listing is required. This was a build only, not a device installation.

Actual WidgetKit installation, Home/Lock Screen rendering, system tint/redaction,
reload timing, locked-device access and widget-host tap behavior remain unverified.
The in-app URL workflow does not establish a successful tap from a real widget.
Physical-device sync delivery and timezone changes also remain device checks.
No archive upload, TestFlight distribution or release occurred.

## Main-branch integration

Integrated the newer compact `DaybookSegments` controls from main while preserving
Today / Week / All. The earlier layout captures show the prior native segmented
picker; schedule and widget content are unchanged. UI test selectors were updated
to the new string scope identifiers. The combined signed Release build passed.
The post-integration Events filter UI check passed. The widget-link rerun did not
complete successfully: one run failed its return-to-Today assertion amid runner
restarts, and an isolated run on a second simulator restarted before completion.
Those stalled runs were stopped. Earlier pre-integration widget-link checks passed
on both devices; post-integration widget-link verification remains inconclusive.
