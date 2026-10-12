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
User supplied Broadcast Work Tracker product specification in Pasted text.txt. Any jobs shown in concepts are fictional demonstration data.

## Current Design Scope
The user-authorized first implementation milestone covers Xcode project setup, signing and CloudKit configuration, a Harbor release script, and local Git commits. Its UI is a native SwiftUI foundation: iPhone tabs and an iPad sidebar, Upcoming and Jobs lists, job capture with a name and placeholder dates, basic job details, and storage/iCloud settings. It inherits the approved brand assets and SF Pro direction, with forest/mint accents and ivory/charcoal backgrounds; it does not establish a new visual identity. The branded mockups remain the direction for later product work, not a claim that the full design is implemented. Sessions, fees, invoices, payment tracking, calendar integration, and the remaining specification workflows are future scope.
