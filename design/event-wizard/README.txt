Cuekeeper event wizard — native implementation and revision 6 concept

The native iPhone/iPad wizard is being integrated with main's event grouping,
track weather, grouped billing and session batch UI on
feature/event-creation-wizard. Main's previously uncommitted work was preserved
as 80c437b. The integration builds and is committed as merge eaa0ea8.

The wizard creates a WorkEvent and initial client booking atomically; a season
creates separate grouped events. Event championships aggregate booking series,
and client bookings support explicit add/reuse of multiple championships.
Existing sessions retain a singular championship. Required dates, optional
titles, session copying, independent fees and the full review calendar remain.

Released V7 (trackPlaceID) and V8 (WorkEvent) models are preserved byte-for-byte.
New V9 adds Job.additionalSeries and its WorkSeries.additionalJobs inverse while
retaining the legacy singular relationship. Current integration verification:
39 unit tests and 27 Python tests passed. iPhone passed all 10 CaptureTests,
6 wizard tests and 2 weather tests; iPad passed 2 grouped booking/batch tests,
all 6 wizard tests and 2 weather tests. Live Apple suggestion tests passed on
both devices without skips. Screenshot inspection prompted a championship
entry fix for focused-keyboard overlap; final targeted checks passed on both
iPhone and iPad. Fresh captures are in the ignored local
.impeccable/review/wizard-v9/ directory. Independent review returned ship for the scoped merge integration, accepted
all six reviewed captures and found no material fixes. This is not a release,
physical-device sync or VoiceOver approval. See implementation.txt.

No Production schema deployment or upload is authorized or performed for this
integration. V9 must pass the normal schema initialization/export/deployment
and release gate before upload. Older V8 release records remain historical.
Physical-device sync and multi-device V9 behavior remain unverified here.

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
