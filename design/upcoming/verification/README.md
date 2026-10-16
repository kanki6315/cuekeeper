# Upcoming Now / Plan verification — October 16, 2026

These screenshots come from `UpcomingTests`. The tests ran as part of the full suite on new
iOS 27.0 simulators, an iPhone 18 Pro and an iPad Pro 13-inch (M5), using unsigned Debug
builds with parallel testing turned off. They use the `--today-fixtures` and
`--upcoming-past-fixture` design fixtures, so all data is synthetic.

| Screenshot | Shows |
|---|---|
| `*-now` / `*-now-lower` | Now with two jobs in flight, next-call countdown, merged run of show and the gap line between jobs |
| `*-plan-collapsed` / `*-plan-expanded` | Plan with To settle collapsed (summary plus the earliest item), then expanded |
| `*-plan-event-over` | An ended booked event asking to be marked completed |
| `*-now-large-text` / `*-plan-large-text` | Both modes at AX3 text size in dark appearance |

## Results

- **Unit tests:** 193 ran on each device with no failures. One EventKit integration test was skipped.
- **iPhone UI tests:** 254 passed and 1 was skipped. One test failed:
  `SyncFeedbackTests.testFloatingSyncFeedbackDoesNotMoveContentAndKeepsWarnings`. The app
  crashed once while creating the iCloud container, and the test passed when rerun on its
  own.
- **iPad UI tests:** 251 passed and 2 were skipped. Three tests failed, none of them in Upcoming:
  - `FeeAndInvoiceTests.testInvoiceAndPartialPaymentWorkflow` and
    `FirstLaunchUITests.testSetupPreferencesFinishAndReplay` look for tab labels laid out for
    the old split view. The app now uses a sidebar-adaptable tab view.
  - `WizardOptionalStepTests.testChosenLocationSetsEventTimezone` timed out waiting for a
    short-lived "timezone pending" state.

  These were left unresolved by decision.

## Not covered

Capture-scheme screenshot tests, physical devices, VoiceOver gestures and live iCloud sync
were not part of this run.
