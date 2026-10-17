# Cuekeeper

<!-- impeccable:product-schema 1 -->

## Platform
ios

## Users
Broadcast freelancers: commentators, presenters, producers, and crew. iPhone and iPad are both target devices.

## Product Purpose
Track freelance engagements from tentative booking through completed work and payment, with very little upkeep. Capture event dates and a client now; enrich the record later.

## Capabilities and Constraints
- Single-client events, sessions, clients, fees, invoices, and payments. Each event has at most one client; incomplete events may have none.
- Booking confirmation, session schedule confirmation, coverage, invoicing, and payment are independent states.
- Events can have no sessions; unknown fees differ from zero fees.
- Calendar placeholders remain alongside eligible confirmed, covering sessions.
- Local offline storage and iCloud sync; recovery and export remain separate from sync.
- USD and EUR balances stay separate. Invoice balances are authoritative for grouped jobs and partial payments.
- Primary navigation: Upcoming, Events, Payments, Expenses, Settings. iPad uses a sidebar.
- Invoice tracking only; no document generation, sending, banking, tax calculations, or currency conversion.

## Product Principles
- Capture first, detail later.
- Incomplete records remain useful.
- Reuse information instead of requiring repeated entry.
- Preserve independent statuses and financial history.
- Keep upcoming work legible without persistent low-value warnings.

## Brand Commitments
Product name: Cuekeeper. Approved visual direction: Daybook agenda layout with Call Sheet's warm palette, including warm charcoal, ivory and sage dark mode. User-supplied stacked cue-card/bookmark logo and wordmark now replace the exploratory waveform mark. Brand reference: design/brand/identity-reference.png. Supplied palette: Forest #073E27, Mint #A7DCB4, Ivory #FAF8F2, Charcoal #171E19, Amber #E6A01A. Current branded mockups: design/branded/. SF Pro remains the UI type direction; exact wordmark font is unverified from the raster reference.

Brand identity reference: `design/brand/cuekeeper-brand-identity.png`. Approved logo direction: “Kept cues” — stacked cue cards with a bookmark front, V-shaped lower notch, and rounded horizontal cutout. Exact color tokens are in `design/brand/brand-tokens.json`; editable vector mark sources are in `design/brand/source/`. The iOS app icon source is `design/brand/Cuekeeper.icon`, editable in Apple Icon Composer. Refer to these assets for future design work.

## Evidence on Hand
User supplied Broadcast Work Tracker product specification in Product Specification.txt. Any jobs shown in concepts are fictional demonstration data.

## Current implementation — October 14, 2026

Current source uses Upcoming, Events, Payments, Expenses and Settings with consistent brand
headers, native segmented agenda scopes and a single-client event editor. Saved
client/championship typeaheads and adaptive short-choice controls support capture.
The event owns session timezones; remote/hybrid work can display a second timezone.
Ready-to-invoice rows expand by client while keeping currency totals separate.
Confirmed event deletion removes scheduled work while preserving financial history.
Settings now includes Recently Deleted (30 days) and explicit private iCloud
backups. Backup restore merges missing records and recovers deleted records; it
does not roll back newer edits or financial receipts.
DESIGN.md and .impeccable/design.json describe the current visual implementation.
The configured app version is 0.2.1; this documentation/version change is not a
TestFlight release or new device verification.

First launch now introduces device-local defaults, optional Calendar connection
and explicit backup recovery. Existing installations skip setup; Settings offers
Run setup again and the same editable preferences. Current first-launch behavior
and simulator evidence are recorded below.

The sections below are dated implementation history. Later single-client behavior
supersedes the earlier grouped-client flows; historical verification counts and
release/schema statements describe their own milestones, not the current build.

## Historical implementation scope
The first six implementation steps now cover the native foundation, complete job management, sessions and broadcast links, EventKit calendar integration, fees and breakdowns, and invoices/payments. The UI extends the existing native SwiftUI identity: iPhone tabs and iPad sidebar, native lists, navigation, forms and sheets, SF typography, and forest/mint accents with ivory/charcoal backgrounds. The approved brand assets remain authoritative; branded mockups are direction references, not a claim of a pixel-matched implementation or a new visual world.

Job management includes tentative/booked/completed/cancelled states, clients and roles, arrangement/location/timezone/notes, duplication with date confirmation, and combined search/filters. Libraries support renaming, contact/currency defaults and related records. Sessions permit incomplete schedules, distinguish confirmed time from coverage, and support timezones/call times/role overrides. Changed editors require explicit discard; save errors preserve drafts.

Calendar publishing retains placeholders alongside eligible confirmed, covering sessions. One device owns publishing through an online CloudKit ownership check. Other devices edit records normally; calendar publishing catches up when the owner opens the app in the foreground and receives those changes. Transfer requires disconnecting the old device before connecting the new one. Offline capture does not imply offline calendar publishing.

Fees distinguish unknown from zero and preserve the overall fee independently of an optional breakdown until explicit application. Fee/invoice revisions and receipt/reversal history are immutable; conflicting versions remain reviewable and require explicit resolution. Same-client/currency invoice lines snapshot billed amounts, and partial receipts reduce the invoice balance as a whole. Direct payments are also supported. Money uses exact integer cents and decimal arithmetic; USD/EUR summaries stay separate. Duplicate billing is rejected locally and flagged for review when concurrent invoices converge.

At that milestone, Step 7 remained recovery/export and Recently Deleted. Recently Deleted and private iCloud snapshots were subsequently implemented; readable file export remains outstanding. Step 8 remains broader physical-device beta validation, first-run and App Store polish. No claim is made that the full product specification is complete.

## Implementation Evidence

The user verified the original production sync and offline/reconnect flow. New financial workflows and conflicts across two physical devices still need beta validation. Nineteen unit/model/EventKit tests, including migrations from V1–V4 into V5, and 24 tooling tests passed. All eight UI workflows have passing iPhone and iPad evidence after the editor presentation fixes: the full iPhone suite, six iPad workflows plus successful focused reruns of breakdown and invoice entry after test keyboard corrections. A real Development CloudKit check verified concurrent calendar-owner claims, rejection and transfer. A signed Release build passed.

The V2 release predates this milestone. At that milestone, the V5 Development schema was initialized and exported; its Production deployment and live release gate remain prerequisites to a future distribution. No Production deployment, archive upload or TestFlight push occurred during this work.

## Project and series refinement — October 13, 2026

Projects optionally group jobs independently of clients and payment. Each job
retains its own booking, fee and invoices. A reusable job series supplies the
session default; a session can inherit it or explicitly override it, including
choosing no series. Libraries support creation, renaming and related jobs;
projects include a year filter. Search and job filters include project and series.
Duplication carries both associations. Existing jobs migrate into V6 without
invented groupings.

New jobs default to one Date. Multiple days reveals Start and End; stored dates
remain inclusive, and existing multiday jobs open with the toggle enabled.
Upcoming and Jobs show nonblocking iCloud activity, waiting, offline and attention
feedback with a link to Settings. Overlapping imports/exports remain tracked
independently. Empty-device copy explains that jobs may still arrive, while local
capture remains available. Completed operations do not claim all devices are current.

The V6 Development schema is initialized and exported. Production deployment and
physical-device validation of the new relationships remain release prerequisites.

Validation for this refinement includes 21 passing unit/model/EventKit tests,
25 passing tooling tests, new project/date and sync-feedback UI workflows on
both iPhone and iPad, and passing iPad edit/duplicate/session regression checks
in dark mode with larger text. Sync UI states are simulated; physical-device
validation of delivery remains outstanding.

## Shared app surfaces — October 13, 2026

The existing app screens now implement the approved Daybook composition with
Call Sheet warmth. Upcoming and Jobs use a date-led agenda, booking badges,
search/filters and a focused add action. Job details put status and icon-led
metadata before sessions, fees and billing. Quick capture keeps
optional detail available; Payments separates USD/EUR summaries, review items,
invoices and balances. Settings and libraries use titled, icon-led groups.

DaybookForm is a custom scrolling composition with page headings and ruled
section panels; DaybookList supplies the corresponding native list treatment.
Shared surfaces cover fees, invoices, receipts, payment entry, libraries,
calendar settings and general Settings. Native navigation, tabs, sheets, date
pickers, menus and other controls remain intact. Regular-width Upcoming and
Jobs use sidebar, agenda and selected detail columns with native collapse;
compact width and accessibility text sizes use tabs and navigation stacks.
Session editors stack date/time and timezone fields at accessibility sizes, with
separate clear-action rows.

The shipped system is recorded in DESIGN.md and .impeccable/design.json.
Appearance-aware secondary text also colors field prompts; metadata icons and
date rails scale with Dynamic Type. Compact session schedules show dates and
times in the session timezone, including the end date for overnight sessions.
The implementation follows the approved boards' hierarchy and composition;
it does not claim pixel equality with their conceptual operating-system chrome.

This pass covers existing functionality. Reminders, recovery/export, Recently
Deleted and onboarding remain outside this design implementation. Earlier
milestone evidence above remains historical; current visual and workflow
verification is recorded separately in the review artifacts.

## 0.1.1 upload — October 13, 2026

Build 286.15.2 was signed and uploaded to App Store Connect for iPhone and iPad.
The user deployed the V6 schema to Production, and the live schema gate passed
before upload. This supersedes the earlier milestone notes about pending
Production deployment. Release evidence is in
`design/verification/release-0.1.1.md`; physical-device testing remains the next
validation step.

## Combined Glass refinement — October 13, 2026

The approved native direction combines a Quiet Glass base with an expressive
floating iPad sidebar and rounded glass actions. Agenda rows, form panels,
status badges and financial content retain the Daybook reading surfaces.
Primary and secondary capsules use native glass styles and explicit
appearance-aware labels; navigation materials remain automatic. The sidebar
uses an opaque fallback for Reduce Transparency or Increase Contrast. Job
completion actions use the native bottom safe-area bar, and Upcoming scope
uses a menu picker. Existing app functions, independent workflow states and
stored data remain intact.

DESIGN.md and .impeccable/design.json record the implemented system. The
comparison boards are conceptual multi-device images; native system glass
and SF typography are authoritative. Earlier verification and upload evidence
remains historical. Simulator verification of this refinement passed on iPhone and iPad, including workflow, light/dark, large-text and portrait checks. The independent visual review ended with `ship` after correcting sidebar icon contrast. Evidence and physical-device validation limits are recorded in `design/liquid-glass/verification/README.md`.


## 0.1.2 TestFlight release — October 13, 2026

Combined Glass shipped to internal TestFlight as version 0.1.2, build 286.16.21. Apple processing is VALID and internal status is IN_BETA_TESTING. The existing Test group has automatic distribution. The live Production schema gate passed without schema changes. Release evidence: `design/verification/release-0.1.2.md`.

## Event and client-booking structure — October 13, 2026

Events/weekends are the agenda container, with shared dates, location, timezone,
and notes. Each event has one or more client bookings, each retaining independent
status, fees, invoices and payments. Sessions belong to a client booking and carry
a series; new records need no job or project name. Event titles derive from
location/dates unless customized. Existing names and grouping metadata remain
available without being required during normal capture.

Focused event, client-booking and fee editors replace the combined job form.
The event shows all client bookings and a chronological schedule. Sessions support
consecutive capture with shared defaults, duplication, and explicit selected-field
batch editing. Session moves retain links and inherited series/roles and do not
move fees. Event date edits do not silently reschedule sessions.

V8 uses an additive optional event relationship. Old jobs stay intact as single
virtual events until edited or explicitly grouped. Shared grouping never replaces
financial records or invoice labels. V8 cloud schema initialization, export and
Production deployment remain release prerequisites; physical-device sync still
requires validation.

## Event wizard integration — October 14, 2026

The optional-step creation wizard now creates grouped events with an initial
client booking, individually or as a season. Dates are required; client details
can be added later for a planning shell. Multiple championships can be selected
before sessions exist, on the client/context page. Championships remain scoped
to each booking, with their union shown on the event. Sessions retain one series.
V9 adds the optional additional-series relationship over the unchanged released
V7/V8 models. Existing grouped billing, track weather and batch-session editing
remain part of the same flow.


## Event editing refinement — October 14, 2026

Event details and client bookings share one editor and one Save. Adding bookings
from the overview opens that editor with a pending new booking; new and edited
bookings commit with event changes in one isolated writer transaction. Schedule
and payment states remain independent. The wizard’s guided sequence is unchanged.

## Single-client events — October 14, 2026

This supersedes the grouped-client workflow above. Each event represents at most
one client, with its own status, series, roles, sessions, fee and payment history.
Incomplete events may still have no client yet. There is no event linking or
add-client-to-event workflow. The wizard retains optional steps and season capture;
each created event gets one independent client record.

Historical grouped records display as separate client events immediately, using
their existing Job identities. Shared historical metadata remains readable until
that client's event is edited, when it is copied to an owned WorkEvent record.
This works even when only one member of an old group has downloaded. Session IDs,
financial revisions, invoice snapshots and receipts remain unchanged. New-event
metadata uses its Job UUID; older group metadata is retained for calendar cleanup.
No schema migration is required. Older builds still understand the historical
group records, so all devices should use the new behaviour for consistent editing.


## Recovery and explicit iCloud backups — October 14, 2026

Settings → Recovery & backups provides Recently Deleted and iCloud Backups.
Events and individually deleted sessions can be restored for 30 days. Restoring
an event retains independently deleted sessions in recovery. Ending recovery
keeps tombstones for calendar cleanup and financial history; it is not a secure
erasure operation. Existing backups are not changed by deletion.

Back Up Now saves a dated snapshot to the user's private CloudKit database in a
separate CuekeeperBackups zone. The list shows date, event count and byte size,
with explicit restore and delete confirmations. Backups use the user's iCloud
quota, with up to 50 manually retained copies and a 100 MB per-backup limit.
No automatic retention deletes older backups. Snapshots contain local records,
including financial revisions, relationships and deleted records, but exclude
calendar ownership and device preferences. Pending remote sync is not assumed
complete. Restores validate format, identities and relationships before an atomic
save, add missing UUIDs, recover deleted records that were active in the backup,
and preserve current fields and receipts. Repeated restores are idempotent.

V11 adds optional recoveryDiscardedAt fields to Job and WorkSession. Development
schema initialization and a live disposable-zone backup test passed, including
concurrent uploads, exact downloads and deletion. Production deployment remains
a release prerequisite; no TestFlight release was made in this task.

## First launch — October 14, 2026

New installations show a brief welcome, preferences, then optional Calendar setup
using the existing permission and ownership flow. Completion is saved locally;
unfinished setup remains available on relaunch. Existing-store detection skips
setup on upgrade. Records arriving during setup change the welcome to a returning
user state while iCloud continues independently.

Currency and role defaults prefill new entries, retaining existing client currency
precedence. Home timezone seeds only the secondary local-time display for new
remote/hybrid work; it does not change event/session timezones or existing records.
Preferences remain device-local and editable in Settings; appearance applies
immediately. Settings also offers Run setup again.

Recover from a backup opens selection and explicit confirmation for the existing
merge restore, preserving current edits and payments. Setup does not create or
delete backups. Local emptiness never asserts an empty iCloud account. The empty
daybook hides search, filters and routine sync feedback, retaining offline/error
feedback and the iPad sidebar.

The approved `design/first-launch/concept-board-v3.png` was refined to bottom
actions on iPhone, compact native form-sheet setup on iPad and branded subpage
navigation after the user rejected the initial empty full-screen iPad composition.
The contract is `design/first-launch/implementation-brief.md`; current evidence is
`design/first-launch/verification/README.md` and its 24 native simulator screenshots.
The model suite passed 64 tests with one existing EventKit skip. Four onboarding
workflows passed on each device, alongside sync-feedback and event/work-timezone
regressions. The fresh native finish review returned `ship` for the supplied evidence.
This establishes simulator behavior, not live cross-device iCloud delivery,
VoiceOver gestures or physical-device ergonomics. No schema deployment, release
archive or TestFlight upload occurred; broader product validation remains open.

## Receipt expenses — October 15, 2026

Events now include receipt expenses. Scan or import one receipt page, extract
proposed fields with Vision and the on-device Foundation Models model (falling back
to Apple Private Cloud Compute for receipt text too long for the on-device model),
review and edit, then save the expense with its photo. A persisted draft protects the photo
before extraction; Keep Draft saves incomplete details. Manual entry remains
available when automatic extraction fails or Apple Intelligence is unavailable.
Draft photos can be replaced with confirmation; saved expenses reopen for editing.
Expenses remain independent of fees, invoices and payments. The first version
supports USD, EUR, GBP, CAD, AUD, NZD and CHF with exact two-decimal minor units.

The Scan Receipt intent and App Shortcut support Action Button assignment and
open event selection followed by capture. V12 adds event-linked expenses and
binary receipt attachments; backups include photos and accept older archives.
Development schema initialization/export and local validation passed. Production
deployment and physical-device capture/model/shortcut/sync checks remain release
prerequisites. Evidence: design/verification/receipt-expenses/README.md.


## Background expense drafts — October 15, 2026

Capture Expense saves optional Wallet transaction details in the background without
requiring an event or photo. Upcoming prompts for incomplete expenses; Payments
provides the completion list. Users attach a receipt, select an event, and confirm
fields; captured payment details remain available when OCR/model results differ.
Settings → Integrations → Wallet Automation provides the personal automation setup
steps and optional local notification controls. Notifications open a persisted
draft by UUID; drafts remain accessible without notification permission.

An explicit source transaction ID prevents repeated local delivery from creating
another draft. Without an ID, captures remain separate to avoid dropping legitimate
purchases. Removing a draft is confirmed and preserves its identity. V12 is reused;
version is 0.1.10. This work does not deploy Production or upload TestFlight.

## Payments month close — October 16, 2026

Payments is now a month close. Each event shows four invoicing gates (work, fee,
reimbursable receipts, client invoicing details) as a step bar with the gap named,
grouped by client, with the month's money split by state per currency and money still
open from earlier months. Ready groups start an invoice with their events and can rebill
finished reimbursable receipts as separate invoice lines; each receipt can be on one
active invoice. Any draft receipt holds up invoicing until it is finished. A Month / Invoices switch
opens every invoice and direct payment across months, with what is owed, search, filters and
swipe actions. Expenses remain their own tab.

V15 adds optional client invoicing details (billing name, email, address, terms, tax ID).
Older builds ignore them and show a lower total for invoices with receipt lines until
updated. Backups without the field still restore. The V15 Development schema still needs
initialising and exporting, and Production deployment remains a release prerequisite.
Brief: `design/payments/implementation-brief.md`; evidence: `design/payments/verification/`.
