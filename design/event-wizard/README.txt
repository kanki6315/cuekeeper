Cuekeeper event wizard — native implementation and revision 6 concept

The approved wizard is now implemented in the native iPhone/iPad app on
feature/event-creation-wizard. New-event creation opens a dynamic wizard for
one event or a season. Required dates, optional titles, multiple championships,
per-event sessions and copying, live Apple location suggestions, independent
fees/breakdowns and the complete review calendar extend Combined Glass /
Daybook. See implementation.txt for source, verification and release limits.

Native verification includes 26 unit tests, four wizard UI tests on each of
iPhone and iPad, ten CaptureTests regressions, and a passing iPhone championship
add/reuse and live Apple suggestion check without a skip. Corrected populated
accessibility, Tokyo session-date and winter work-offset checks passed on both
devices. The combined regression run failed in the new test's old Date locator;
that locator was corrected and the targeted test rerun successfully. Independent
review marked all four requested repairs RESOLVED, with ship limited to those
repairs, not the whole app. Captures are in the ignored local directory
.impeccable/review/event-wizard/.

These results do not establish physical-device sync behavior or readiness for
release. V7 CloudKit initialization/export/deployment must pass the normal
release gate before upload; Production deployment has not been performed.

The standalone HTML remains a discussion prototype. Open index.html directly
without a build or server. Its revision 6 flow places selected championships
under Client, project & series, supports shared/inherited event series and
session copies, and shows every event date at review. Restart keeps edits;
reload restores fictional fixtures. HTML location suggestions are simulated,
monetary arithmetic is illustrative and no app records are written. Browser
rendering remains unverified because administrator policy blocked browser
verification; this restriction does not describe the native simulator tests.

storyboard.png is stale revision 1 Imagegen artwork, not current flow evidence
or a screenshot. Its prompt is in storyboard-prompt.txt and embedded in the
PNG. brief.txt records concept history; later revisions supersede earlier ones.

App source has changed for this authorized implementation. DESIGN.md and
.impeccable/design.json remain preserved; their older creation-flow descriptions
and the known stale sidecar have not been refreshed in this documentation pass.
