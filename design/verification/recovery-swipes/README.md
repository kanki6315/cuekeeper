# Recently Deleted layout verification — October 14, 2026

Actual iOS 27 simulator captures, exported from XCTest attachments without image edits.
Devices: iPhone 18 Pro and iPad Pro 11-inch (M5), both portrait.
The isolated DesignFixtureScreen uses sample data and omits Settings navigation/tab chrome.

RecoveryTests/testRecoveryLayoutsAndAccessibleActions passed on both devices.
Each run covers standard Large text in dark appearance and the largest accessibility
size (accessibilityExtraExtraExtraLarge) in both light and dark appearances.
The test checks row/action reachability, swipe-only nonexecution, delete confirmation
cancellation retaining the row, and successful explicit-tap restoration.

Visual review: resting labels wrap without truncation at the largest size on both
devices. Native swipe actions remain visible; translating a row during a swipe
naturally moves some row text outside its visible bounds. Top scroll-content margin removed, intro row padding tightened, and section spacing reduced to 8 points. Updated captures and both device runs pass after this adjustment.
These checks do not cover landscape, Split View, physical-device gestures, or VoiceOver.

Result bundle: /tmp/cuekeeper-recovery-spacing.xcresult
Capture files include resting, delete-revealed, and restore-revealed states.
