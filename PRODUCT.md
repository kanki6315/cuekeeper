# Cuekeeper

<!-- impeccable:product-schema 1 -->

## Platform
ios

## Users
Broadcast freelancers: commentators, presenters, producers, and crew. iPhone and iPad are both target devices.

## Product Purpose
Track freelance engagements from tentative booking through completed work and payment, with very little upkeep. Capture event dates and a client now; enrich the record later.

## Capabilities and Constraints
- Events, client bookings, sessions, clients, fees, invoices, payments, and broadcast links.
- Booking confirmation, session schedule confirmation, coverage, invoicing, and payment are independent states.
- Client bookings can have no sessions; unknown fees differ from zero fees.
- Calendar placeholders remain alongside eligible confirmed, covering sessions.
- Local offline storage and iCloud sync; recovery and export remain separate from sync.
- USD and EUR balances stay separate. Invoice balances are authoritative for grouped jobs and partial payments.
- Primary navigation: Upcoming, Events, Payments, Settings. iPad uses a sidebar.
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

## Current Design Scope
The first six implementation steps now cover the native foundation, complete job management, sessions and broadcast links, EventKit calendar integration, fees and breakdowns, and invoices/payments. The UI extends the existing native SwiftUI identity: iPhone tabs and iPad sidebar, native lists, navigation, forms and sheets, SF typography, and forest/mint accents with ivory/charcoal backgrounds. The approved brand assets remain authoritative; branded mockups are direction references, not a claim of a pixel-matched implementation or a new visual world.

Job management includes tentative/booked/completed/cancelled states, clients and roles, arrangement/location/timezone/notes, duplication with date confirmation, and combined search/filters. Libraries support renaming, contact/currency defaults and related records. Sessions permit incomplete schedules, distinguish confirmed time from coverage, support timezones/call times/role overrides and retain broadcast links. Changed editors require explicit discard; save errors preserve drafts.

Calendar publishing retains placeholders alongside eligible confirmed, covering sessions. One device owns publishing through an online CloudKit ownership check. Other devices edit records normally; calendar publishing catches up when the owner opens the app in the foreground and receives those changes. Transfer requires disconnecting the old device before connecting the new one. Offline capture does not imply offline calendar publishing.

Fees distinguish unknown from zero and preserve the overall fee independently of an optional breakdown until explicit application. Fee/invoice revisions and receipt/reversal history are immutable; conflicting versions remain reviewable and require explicit resolution. Same-client/currency invoice lines snapshot billed amounts, and partial receipts reduce the invoice balance as a whole. Direct payments are also supported. Money uses exact integer cents and decimal arithmetic; USD/EUR summaries stay separate. Duplicate billing is rejected locally and flagged for review when concurrent invoices converge.

Step 7 remains recovery/export and Recently Deleted. Step 8 remains broader physical-device beta validation, first-run and App Store polish. No claim is made that the full product specification is complete.

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
metadata before sessions, broadcast links, fees and billing. Quick capture keeps
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
