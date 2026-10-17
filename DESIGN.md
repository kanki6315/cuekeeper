---
name: Cuekeeper
description: Native Combined Glass navigation and actions over the warm Daybook agenda.
colors:
  AccentColor-light: "#073E27"
  AccentColor-dark: "#A7DCB4"
  PageBackground-light: "#FAF8F2"
  PageBackground-dark: "#171E19"
  SurfaceBackground-light: "#FFFFFF"
  SurfaceBackground-dark: "#2C352F"
  SecondaryText-light: "#626860"
  SecondaryText-dark: "#B7BFB8"
  PrimaryButtonText-light: "#FFFFFF"
  PrimaryButtonText-dark: "#073E27"
  AmberText-light: "#88570C"
  AmberText-dark: "#F0BC59"
  SidebarSelection-light: "#073E27"
typography:
  headline:
    fontFamily: "SF Pro"
    fontWeight: 700
  title:
    fontFamily: "SF Pro"
    fontWeight: 600
  body:
    fontFamily: "SF Pro"
  label:
    fontFamily: "SF Pro"
    fontWeight: 600
rounded:
  panel: "12pt"
  button: "capsule"
  sidebar: "26pt"
  search: "10pt"
spacing:
  row-horizontal: "16pt"
  row-vertical: "12pt"
  page: "20pt"
  section: "24pt"
  section-heading: "9pt"
  sidebar-inset: "10pt"
components:
  button-primary:
    textColor: "{colors.PrimaryButtonText-light}"
    rounded: "{rounded.button}"
  button-primary-dark:
    textColor: "{colors.PrimaryButtonText-dark}"
    rounded: "{rounded.button}"
  button-secondary:
    textColor: "{colors.AccentColor-light}"
    rounded: "{rounded.button}"
  button-secondary-dark:
    textColor: "{colors.AccentColor-dark}"
    rounded: "{rounded.button}"
  sidebar-fallback:
    backgroundColor: "{colors.SurfaceBackground-light}"
    rounded: "{rounded.sidebar}"
  sidebar-fallback-dark:
    backgroundColor: "{colors.SurfaceBackground-dark}"
    rounded: "{rounded.sidebar}"
  panel:
    backgroundColor: "{colors.SurfaceBackground-light}"
    rounded: "{rounded.panel}"
  panel-dark:
    backgroundColor: "{colors.SurfaceBackground-dark}"
    rounded: "{rounded.panel}"
  text-field-prompt:
    textColor: "{colors.SecondaryText-light}"
---

# Design System: Cuekeeper

## Overview

**Creative North Star: "Combined Glass with Daybook warmth"**

Cuekeeper pairs a date-led working agenda with quiet paper surfaces, forest accents and a warm charcoal night palette. The approved Combined Glass direction uses Quiet Glass as its base, an expressive floating iPad sidebar and rounded native glass actions. Its hierarchy supports quick capture, incomplete schedules and independent booking, coverage and payment states. The stacked cue-card mark and native SF typography retain the identity.

This records the implemented SwiftUI system, grounded in `Cuekeeper/DaybookStyle.swift`, the color assets and the existing screen implementations. The approved boards in `design/branded/` supply the composition and hierarchy direction; `design/liquid-glass/implementation-brief.md` records the combined material direction. The multi-device comparison boards are conceptual images. Native system glass optics, SF typography, navigation, tabs, sheets, pickers and menus remain authoritative; this is not a claim of pixel equality with the boards.

**Key Characteristics:**
- Date-led agenda rows with clear booking badges.
- Titled detail pages and compact ruled panels.
- Forest and mint accents on ivory and warm charcoal.
- Native glass actions and a floating iPad navigation surface.
- Native controls and Dynamic Type throughout.

## Colors

The palette combines restrained forest and mint accents with warm paper and green-charcoal neutrals. Asset names and their appearance variants in the frontmatter are the source for exact extracted values.

### Primary

`AccentColor` uses forest in light appearance and mint in dark appearance for primary actions, the brand mark, date rails and positive status text. `PrimaryButtonText` reverses white to forest with the appearance. `SidebarSelection` stays forest as the native sidebar selection tint. Unselected sidebar symbols explicitly use the named `AccentColor` asset to avoid inheriting the selection tint; selected symbols remain white. The primary glass button label explicitly uses `PrimaryButtonText`; secondary glass labels explicitly use `AccentColor`.

### Secondary

`AmberText` supplies the darker amber light-mode and lighter amber dark-mode foregrounds for tentative, draft and estimated badges. These badges use native orange at reduced opacity for their fill rather than the supplied brand amber as body text.

### Neutral

`PageBackground` supplies ivory or warm charcoal across the page. Navigation and tab bars use automatic system backgrounds. `SurfaceBackground` supplies white or raised green charcoal for panels. `SecondaryText` is the readable muted foreground used for subtitles, metadata, helper text and text-field prompts. Main text and native separators retain system semantic colors.

**The Appearance Pair Rule.** Use the named color assets so light and dark roles change together.

## Typography

**Display and Body Font:** SF Pro through SwiftUI semantic text styles, as approved for this native application. The brand lockup uses native title3 bold text; the exact raster wordmark font is not asserted.

Page headings use largeTitle bold; primary record titles and amount entry use title2 bold or semibold; agenda day numbers use title semibold with monospaced digits. Section headers and event titles use headline. Body rows retain the native body style. Metadata and summaries use subheadline; badges use caption semibold and footers use footnote. Sizes resolve through Dynamic Type, so there is no fixed pixel type scale in the token layer.

Dates and amounts use monospaced digits where alignment aids scanning. Metadata symbols use SF Symbols and a width scaled relative to subheadline; the date rail width scales relative to body. Text remains able to grow vertically.

**The Native Type Rule.** Preserve semantic text styles and scalable supporting geometry instead of freezing the reference board's text size.

## Layout

The shared form is a custom ScrollView with titled content, vertical section groups and ruled panels; it is more than a recolored native Form. It centers content up to 760 points with page padding and section spacing from the tokens. Section headers sit above panels; rows use shared horizontal and vertical padding, inset dividers and optional footers. Explicitly unframed sections omit their fill, border and horizontal padding. Native lists remain available through DaybookList, with matching row surfaces and 18-point section spacing.

Events leads with the shared brand/action header, search and filters, then date-led records. Upcoming leads with the same header carrying Scan Receipt and Add Event, then the Now / Plan control; it has no search. DaybookTabHeader also heads Payments, Expenses and Settings, with a 48-point minimum height and a stacked fallback for narrow widths or accessibility text. Tab content starts with 12-point top padding. Event details lead with the header and a To settle panel, then Schedule / Money / Details tabs; when the detail column is at least 820 points wide (and text is below accessibility sizes) the schedule sits beside Money and Details in a 1.45 : 1 column split instead. The event editor concentrates initial capture, with optional fields available without manufacturing required data. Payments is a month close: a month stepper, the month's money by state per currency, then events grouped by client with their invoicing gates; amounts and partial balances remain derived from actual records.

The shell is a sidebar-adaptable tab view: a sidebar at regular width and tabs at compact width, each section with its own navigation stack. Events and Upcoming push the event detail onto that stack; the event page itself splits into columns when its width allows. Headers and payment summaries adapt vertically when text or width demands it.

First-launch setup uses full-height navigation with bottom safe-area actions on
iPhone and a compact native form sheet over the daybook at regular iPad widths.
Its scrolling content and actions are capped at 480 points, with existing page
margins. This is the user-approved refinement of the first-launch board; the
earlier empty full-screen iPad composition is superseded. It extends the current
system without changing the normative frontmatter tokens or sidecar.

## Elevation & Depth

The reading layer stays opaque and quiet: surface color, spacing and inset rules establish grouping. Panels and inset dividers use a half-point primary-color stroke at 0.16 opacity, strengthening to 0.45 with Increase Contrast; selected agenda rows use a faint accent fill. Navigation and actions use native Liquid Glass. The inset sidebar uses regular glass with accent tint at 0.08 opacity, falling back to opaque `SurfaceBackground` when Reduce Transparency or Increase Contrast is active. No custom drop-shadow or motion vocabulary is implemented; refraction, pressed feedback and native control accessibility adaptations belong to the system.

**The Quiet Reading Rule.** Keep agenda rows, forms, status badges and financial panels matte; reserve expressive glass for navigation and actions.

## Shapes

Panels and search use gently rounded rectangles. Primary and secondary actions use native capsules; icon-only filter and more-action controls use circles. The floating sidebar uses the larger radius and inset from the token layer. Booking badges are capsules with horizontal padding of 9 points and vertical padding of 5. The date rail is typographic rather than a decorative calendar tile. The stacked cue-card mark follows the supplied vector outlines, including its notch and rounded cutout.

## Components

### Primary and secondary actions

DaybookPrimaryButton wraps a native button with `.glassProminent`, a capsule border shape, large control size and semibold subheadline. Its label explicitly uses the appearance-aware `PrimaryButtonText` asset. DaybookSecondaryButton uses `.glass` with the same shape, control size and typography, and an explicit accent label. Native controls determine sizing, material, press and disabled behavior; there is no custom opacity animation or fixed button padding token. Add Event uses the primary style; Add Session uses the secondary style.

Event details change booking status from the header badge menu; the next step for a tentative booking, an owed balance or a ready-to-invoice event appears as the prominent To settle action. Edit Event and a More menu (Duplicate, Delete) are toolbar actions; Duplicate and confirmed Delete also close the Details tab. Upcoming uses DaybookSegments for Now / Plan, with Plan carrying the amber To settle count. Events uses the same control for All / Active / Completed / Cancelled. These compact, text-only controls keep all choices in one row. The visible track is 36 points high at default text size (32-point segments), with a separate 44-point touch area. Selection uses a slightly stronger tinted fill, a fine outline and semibold text; inactive options keep a faint tint without individual outlines. No icons or grid fallback. At accessibility text sizes the same row scrolls horizontally rather than compressing enlarged labels.

### Panels and sections

DaybookForm and DaybookSections create a clear page heading followed by titled, ruled groups. DaybookList provides the corresponding native list treatment. Do not wrap every informational line in another card.

### Fields and navigation rows

DaybookTextField uses a plain native TextField with its prompt explicitly colored SecondaryText; entered text retains native primary styling. Pickers keep an explicit visible label. DaybookLink combines a leading label with a subdued chevron and a rectangular content hit area. Native focus, keyboard, date selection, search/filter controls and sheet dismissal behaviors remain functional. At accessibility text sizes, the session editor stacks date/time labels above native controls, gives the clear action an independent row with a 44-point minimum height, and stacks the timezone label and value.

### Booking badges and metadata

BookingBadge displays the status as text as well as color, wrapping when required. DaybookMetadata pairs an SF Symbol with readable text. Compact session schedules include the date and time in the session timezone, show an end date when crossing midnight and retain a timezone abbreviation. Unknown dates or times retain honest pending copy.

### Events list

Events groups rows under month headings, with a footnote of what that month's finished events still owe per currency. All and Completed show events that ended within the last two weeks; a Show earlier events control above the list reveals the rest, and searching or a date filter lifts the window. Active and Cancelled are not windowed. A forest Today rule marks where past events end.

Each row starts with the date rail beside the title and client. Multi-day events extend the rail: a fine line runs beside the day lines and the end day sits level with the last day, so a multi-day row always carries three day lines and a single-day row one, ending in the month as on Upcoming. Each day line shows the weekday, that day's sessions and its first start time. Events longer than three days fold later days into the third line; days without dated sessions read Schedule to come. Before the work the badge shows the booking status; afterwards it shows the money state (Ready to invoice, Invoiced, Overdue, To settle, Paid). Finished rows quiet the rail and title to the secondary color.

### Date rail and brand lockup

DaybookDateRail stacks abbreviated weekday, day number and month in accent color. BrandLockup combines the actual cue-card path with Cuekeeper text; the redundant shape is hidden from accessibility and the lockup is combined as one element.

### Native shell

Upcoming, Events, Payments, Expenses and Settings form the tab/sidebar destinations. The sidebar groups the brand, native sidebar list and sync feedback into one floating glass surface with an opaque accessibility fallback. Native navigation and tab bar backgrounds use automatic material behavior. Sync feedback leads to Settings and describes observed activity without claiming that every device is current.

### Expenses overview

Expenses reuses DaybookForm and DaybookTabHeader with a primary Scan Receipt action,
followed directly by All / Saved / Needs review segments, without a repeated title or search field. Rows lead with merchant
and amount, then subdued event/client, date/category and reimbursement metadata;
drafts carry an amber Needs review label. Records sort by expense date, newest
first. Rows open the existing expense editor; expenses linked to deleted events
remain visible with restoration guidance and cannot be opened. Scan Receipt asks
for an event before capture. The empty state offers capture guidance or suggests
changing the filter. This extension was source-reviewed and passed
build-for-testing plus all 22 ExpenseTests and BackgroundExpenseTests. iPhone and
iPad simulator captures verified the compact rows; those captures predate removal
of the heading and search field. The final heading removal also passed a build.

### Event capture and editing

Each event has at most one client, with client/status, schedule,
fee and payment history, notes, project and championships on one detail surface.
Edit Event shows Client / Work / Fee fields directly, without booking accordions
or add-client controls. Historical booking notes remain labelled and editable;
new notes belong to the event. Former grouped bookings appear independently with
their client names. Bulk session editing stays within the selected event.

The new-event wizard retains optional steps, with Back leading and Cancel trailing.
Client entry is a labelled typeahead of saved clients; new text stays in the draft
until Save. Championship entry uses inline search, explicit Add for a new name,
and removable selected rows. Searches show up to five saved matches while focused;
championship matches also remain visible for an uncommitted query after keyboard
dismissal. New events offer Tentative / Booked; existing events also allow Completed
and Cancelled.

Schedule (Tentative / Confirmed), Coverage (Undecided / Covering / Not covering),
and new-event status use DaybookChoicePicker. The label stays above the native
segments. A labelled menu replaces them above xLarge Dynamic Type or when the
scaled 300-point minimum width cannot fit. Existing-event booking status uses BookingStatusSegments in both detail and editing, with dedicated light/dark BookingTentative (amber), BookingBooked (forest/mint), BookingCompleted (blue), and BookingCancelled (muted red) tokens. Detail selections save immediately through the existing conflict-aware save path; editor selections remain draft changes until Save. Arrangement retains its menu.

The event owns every session's timezone. Event setup and the wizard session list
expose it once; session editing displays it read-only. Remote/hybrid Work fields
include Your timezone for secondary local-time readouts, including call time.
On-site work inherits the event zone. Event-zone changes preserve scheduled instants.

### Upcoming: Now and Plan

The landing tab is built from `UpcomingSummary`, derived on each render from the same `EventDetailFacts` the event page
uses, plus receipt drafts that have no event; nothing it shows is stored. A Now / Plan control sits under the header.
It opens on Now when any booked or tentative job has work in the next 72 hours, otherwise on Plan; a manual choice
holds until the set of jobs in flight changes, and the Today widget link always opens Now.

**Now** shows the next-call panel (with the event name under the lead line), then the jobs in flight. One job reads as
a heading with a Notes capsule when it has notes; several jobs list as rows with a Notes button each, followed by one
merged run of show. Sessions from several jobs carry their job name, rows on site in another zone carry its
abbreviation, and a quiet gap line ("2 hr before Studio highlights") sits between covered sessions of different jobs on
the same day. No clash warnings are drawn. "After this" hands off to Plan. With nothing in flight, Now shows "Nothing in
the next 3 days", a link to the next job with its first call, and a link to Plan.

**Plan** opens with To settle collapsed: title, amber count and a category summary ("2 bookings · 1 schedule · 2 money"),
then the item with the earliest day and its action, unlabelled. Expanded, every item lists its event, detail and action,
with Show less. Items rank by the day they are tied to: an ended event by its last day, invoices by due day, receipts by
purchase day, everything else by the event's start. Booking and schedule gaps surface only for events within 30 days;
money items always surface. A booked or tentative event that has ended asks to be marked completed. Items cannot be
dismissed; they clear when the data is fixed. Below sit a two-week strip from this Monday (one mark per session: solid
covering, outlined not covering, dashed amber time to come; past unscheduled days stay blank) whose days scroll Coming
up to the matching job, and Coming up: jobs within 30 days with their coverage summary and open-item count, then All events.

Sources: `Cuekeeper/UpcomingView.swift`, `Cuekeeper/UpcomingSummary.swift`. Brief and evidence: `design/upcoming/`.

### Event detail page

The page is built from `EventDetailSummary`, a value derived on each render from the event's sessions, fee, invoices,
receipts and expense drafts; nothing it shows is stored. Order: header (dates · place as one line that opens the editor,
large-title event name, status badge menu, client, role · arrangement), To settle, then the body.

**To settle** lists derived open items in a fixed order: dates on hold, session gaps (no time, unconfirmed time,
undecided coverage; one item per session), client to add, fee conflict or unknown fee, ready to invoice, unsent draft
invoice, owed balance, billing review, receipts to review. Each row has a tinted symbol, a one-line title, optional
detail and its own action; dates on hold, owed balance and ready to invoice use the prominent button. Three rows show
before "Show all". The panel disappears when nothing is open, and cancelled events keep only money items.

**Tabs** use DaybookSegments with an amber per-tab count of open items and stay pinned while scrolling, except at
accessibility sizes where a pinned bar would cover the screen. The selection is remembered per event; completed or
cancelled events with money items open on Money.

**Schedule** shows a next-call panel for covered work within seven days: forest fill in light mode, raised surface with
a mint hairline in dark mode, the call time large in the chosen clock, the other clock beneath, then on-air range and
series. Within 90 minutes it becomes a countdown. Remote work offers *Your time / Track* segments, defaulting to your
time; on-site work always reads track time. The run of show groups sessions under the date rail with a covering count
and, inside the forecast window, that day's track weather. Rows are quiet when confirmed and covering; not-covering rows
use secondary text, missing times show a dashed amber TBC tile with Add time, and a session's own series shows only when
it differs from the event's. Wide layouts add the track time trailing each row. Forecast status and the Apple Weather
attribution sit under the run of show; hourly forecasts belong to each session's page.

**Money** opens with the fee, its agreement and, only when the active invoice bills this event alone, a paid/owed bar.
Grouped invoices state the invoice balance instead, because receipts settle the whole invoice. Fee breakdown lines,
invoices and payments, and expenses follow.

**Details** holds client, role, working arrangement with its zone offset in words, event timezone, location, track,
project and series links, notes, then Duplicate and Delete.

Sources: `Cuekeeper/JobDetailView.swift`, `Cuekeeper/EventDetailSummary.swift`, `Cuekeeper/EventDetailComponents.swift`,
`Cuekeeper/EventWeatherView.swift`. Brief and evidence: `design/event-page/`.

### Payments month close

Built from `PaymentsMonth` (`Cuekeeper/PaymentsReadiness.swift`), derived on each render from
events, fees, invoices, receipts and client invoicing details; nothing is stored. Each event has
four gates in a fixed order — **Work · Fee · Receipts · Client** — each done, missing or not yet:

- Work: completed is done; ended but not completed is missing (*Mark completed*); otherwise not yet.
- Fee: a known amount is done; unknown or conflicting is missing. A zero fee reads *No fee* and is not counted.
- Receipts: any draft receipt on the event blocks, prompting the bookkeeping. Finished receipts never block.
- Client: needs a client with billing name, billing email, address and payment terms (tax ID optional).

Billing state wins over gates: review, paid, invoiced (with balance and due), draft, paid directly.
Otherwise all four done is *Ready to invoice*, work done with a gap is *Held up*, and work still to
come is upcoming. Receipts settle invoices as a whole; no per-event paid amount is derived.

Compact layout: tab header with Add Invoice; the Wallet expenses prompt when drafts are pending;
month stepper (chevrons, *This month* when away); a panel with one bar per currency split into
Paid, Invoiced, Ready to invoice, Held up and Still to happen (accent at full, 62% and 32%,
orange, faint ink), with totals, unknown-fee counts and a legend; *By client* with the step-bar
key (gate labels with arrows into a sample bar, then Done / Missing / Not yet). Client panels show
the name, details state (*Add details* when incomplete), then rows: date rail, title, a 4-segment
step bar with the gap named in text, and the amount. Groups with ready work end in *Invoice n
ready · total* per currency. *Still open from earlier* lists unpaid and draft invoices for earlier
work and earlier finished work not yet invoiced. *All invoices and payments* opens the full ledger.

Rows with gaps open the readiness sheet: four gate rows with their actions (Mark completed, Add
fee, Finish for each blocking receipt, Add client), the client invoicing form inline when details
are the gap, and *Create invoice* once ready. Other rows open the event.

At 900 pt and wider (non-accessibility) the clients become a ledger table with gate columns
beside a 340 pt column holding the money panel and *Still open from earlier*.

Invoices started from a ready group preselect those events and offer that client's finished,
reimbursable, unbilled receipts in the invoice currency as *Reimbursable receipts* lines. Marking
an invoice sent fills the due date from the client's terms when none is set. The client editor has
an *Invoicing details* section; the event page adds *Invoicing details to add* before *Ready to
invoice* when only details are missing.

Sources: `Cuekeeper/PaymentsView.swift`, `Cuekeeper/PaymentsComponents.swift`,
`Cuekeeper/PaymentsReadiness.swift`. Brief: `design/payments/implementation-brief.md`.

### Event deletion

Delete Event requires a destructive confirmation explaining that the event and
sessions leave the schedule and synced calendar while invoices and payments remain.
Save failures are surfaced without dismissing the detail.

Existing native verification artifacts are in `design/verification/single-client-events/`,
`design/verification/session-choices/`, and `design/verification/event-typeahead/`.
This documentation refresh was checked against source; it adds no new visual validation.

### Recently Deleted

Use a native grouped DaybookList with a single inline navigation title and the
intro “Restore deleted items for 30 days.” Remove the default top scroll-content margin
and use 8-point section spacing on this screen. Keep restoration and financial-retention
details behind the About recovery toolbar button. Rows show title, client/event,
and a compact “Restore by” date. Leading swipe reveals Restore; trailing swipe
reveals Delete. Both disable full-swipe execution. Delete opens the existing
permanent-removal confirmation; it never removes a row on the initial swipe/tap.
Context menus and named accessibility actions provide alternatives to swiping.

### Backups

Status first, with an inline navigation title and no page heading. A panel leads
with the last backup's relative date and its event count and size, followed by
Back Up Now, progress and notices. An amber line appears only while sync changes
may still be arriving. Saved iCloud backups follow under "In iCloud" with an
"n of 50" count. Each row has a capsule Restore action and a "…" menu holding
Delete Backup; a context menu offers both. Pull to refresh reloads the list. At
regular width and non-accessibility text sizes, the status and a Files panel
(Export to Files, Import a Backup, "ZIP files aren't encrypted.") sit in a
360-point column beside the list, with content capped at 1080 points. Otherwise
the panels stack and Files moves to a toolbar folder menu. All other fine print
(what's included, restore semantics, encryption, iCloud limit) lives behind the
About backups info button: a popover on iPad and a medium sheet on iPhone.

### First-launch setup

The welcome centers the existing cue-card mark and semantic large-title text,
followed by observed iCloud status and a primary setup action. Backup recovery
stays secondary. Preferences, Calendar and backup selection retain the native
navigation stack and reuse BrandLockup in the principal toolbar. Setup actions
wrap the existing primary/secondary glass styles; preference and backup rows reuse
DaybookSections. Reading surfaces retain PageBackground and SurfaceBackground.

Preferences and Settings share the same labelled fields. Appearance uses native
segments at standard text sizes and a labelled menu at accessibility sizes;
scrolling keeps content reachable above the action area. Backup selection shows
date, event count and a selected-state symbol, then a native restore confirmation.
Loading, empty and error states remain distinct. No decorative assets or new
system tokens were introduced.

Sources: `Cuekeeper/FirstLaunchView.swift`, `Cuekeeper/PreferenceFields.swift`,
`Cuekeeper/FirstLaunchBackupView.swift` and `Cuekeeper/RootView.swift`.
The approved board and subsequent layout decision are recorded in
`design/first-launch/implementation-brief.md`. Current simulator evidence and
limits are in `design/first-launch/verification/README.md`; this pass preserves
the incumbent visual system rather than claiming a new full-product audit.

## Do's and Don'ts

### Do:
- **Do** preserve the date-led hierarchy; event details open on Schedule and promote Money once the event is completed with money still to settle.
- **Do** keep Upcoming's To settle collapsed by default and derived from records, never dismissible.
- **Do** use named appearance-aware color assets and semantic text styles.
- **Do** keep USD and EUR separate and show real partial balances and pending schedules.
- **Do** retain native controls, navigation and accessibility adaptation.
- **Do** keep reading surfaces matte and let native glass define action and navigation depth.

### Don't:
- **Don't** flatten the implementation into a palette-only treatment of generic forms.
- **Don't** substitute sample board data for financial or calendar truth.
- **Don't** force three columns at accessibility text sizes.
- **Don't** treat conceptual system chrome as a pixel-exact native requirement.
