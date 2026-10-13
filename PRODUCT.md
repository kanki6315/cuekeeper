# Cuekeeper

<!-- impeccable:product-schema 1 -->

## Platform
ios

## Users
Broadcast freelancers: commentators, presenters, producers, and crew. iPhone and iPad are both target devices.

## Product Purpose
Track freelance engagements from tentative booking through completed work and payment, with very little upkeep. Capture a job name and placeholder dates now; enrich the record later.

## Capabilities and Constraints
- Jobs, sessions, clients, fees, invoices, payments, and broadcast links.
- Booking confirmation, session schedule confirmation, coverage, invoicing, and payment are independent states.
- Jobs can have no sessions; unknown fees differ from zero fees.
- Calendar placeholders remain alongside eligible confirmed, covering sessions.
- Local offline storage and iCloud sync; recovery and export remain separate from sync.
- USD and EUR balances stay separate. Invoice balances are authoritative for grouped jobs and partial payments.
- Primary navigation: Upcoming, Jobs, Payments, Settings. iPad uses a sidebar.
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

The V2 release predates this milestone. The current V5 Development schema was initialized and exported; its Production deployment and live release gate remain prerequisites to a future distribution. No Production deployment, archive upload or TestFlight push occurred during this work.
