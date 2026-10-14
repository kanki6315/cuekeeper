# Adaptive session choices — October 14, 2026

Native XCTest simulator captures from the current working tree, using synthetic
fixtures on iOS 27. PNGs are unaltered screenshots, not generated concepts.

Schedule and Coverage use labelled native segments in the session editor and
wizard; bulk editing shares the Coverage control. At text sizes above xLarge or
when the scaled 300-point minimum width cannot fit, controls use native menus.
Booking status and arrangement retain menus (four choices each).

Verification passed:
- Build and test targets.
- Selection interaction at normal and accessibility Extra Large text sizes on
  iPhone and iPad, including explicit segment/menu assertions.
- Wizard session copying between season events.
- Existing session capture, links and confirmation validation. Its navigation
  helper was updated to match the previous event overview's renamed payment link;
  the initial stale-selector failure passed on rerun.
- Screenshots inspected for labels, segment fit and readable menu fallback.

Result bundles: /tmp/cuekeeper-choices-phone.xcresult (visual and wizard tests pass;
contains the initial stale-selector failure), /tmp/cuekeeper-choices-ipad.xcresult,
and /tmp/cuekeeper-choices-validation.xcresult (corrected workflow passes).

No persistence changes or release upload. Physical-device testing not performed.
