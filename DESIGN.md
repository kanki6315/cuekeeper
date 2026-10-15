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

Upcoming and Events lead with a shared brand/action header, search and filters, then date-led records. DaybookTabHeader also heads Payments and Settings, with a 48-point minimum height and a stacked fallback for narrow widths or accessibility text. Tab content starts with 12-point top padding. Split-view agenda columns retain their section title beside Add Event; the sidebar carries the brand. Event details keep schedule and work context ahead of broadcast links and fee/billing content. The event editor concentrates initial capture, with optional fields available without manufacturing required data. Payments use a compact separated USD/EUR summary before review items and invoice/job sections; amounts and partial balances remain derived from actual records.

Regular-width layouts at non-accessibility text sizes use a sidebar; Upcoming and Events use sidebar, agenda and selected detail columns. The sidebar ranges from 210 to 280 points (ideal 230); the agenda from 320 to 520 (ideal 420). Native split-view behavior handles width and portrait collapse. Compact widths and all accessibility text sizes use tabs and navigation stacks. Headers and payment summaries adapt vertically when text or width demands it.

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

DaybookPrimaryButton wraps a native button with `.glassProminent`, a capsule border shape, large control size and semibold subheadline. Its label explicitly uses the appearance-aware `PrimaryButtonText` asset. DaybookSecondaryButton uses `.glass` with the same shape, control size and typography, and an explicit accent label. Native controls determine sizing, material, press and disabled behavior; there is no custom opacity animation or fixed button padding token. Add Event uses the primary style; Add Session and Add Broadcast Link use the secondary style.

Event details expose the next booking-state action inline: Mark as booked for tentative events and Mark completed for booked events. Edit Event is a toolbar action; Duplicate Event and confirmed Delete Event appear in separate sections. Upcoming uses a native segmented picker for All upcoming / This week. Events uses All / Active / Completed / Cancelled. Both segmented scopes sit on a capsule with AccentColor at 0.08 opacity.

### Panels and sections

DaybookForm and DaybookSections create a clear page heading followed by titled, ruled groups. DaybookList provides the corresponding native list treatment. Do not wrap every informational line in another card.

### Fields and navigation rows

DaybookTextField uses a plain native TextField with its prompt explicitly colored SecondaryText; entered text retains native primary styling. Pickers keep an explicit visible label. DaybookLink combines a leading label with a subdued chevron and a rectangular content hit area. Native focus, keyboard, date selection, search/filter controls and sheet dismissal behaviors remain functional. At accessibility text sizes, the session editor stacks date/time labels above native controls, gives the clear action an independent row with a 44-point minimum height, and stacks the timezone label and value.

### Booking badges and metadata

BookingBadge displays the status as text as well as color, wrapping when required. DaybookMetadata pairs an SF Symbol with readable text. Compact session schedules include the date and time in the session timezone, show an end date when crossing midnight and retain a timezone abbreviation. Unknown dates or times retain honest pending copy.

### Date rail and brand lockup

DaybookDateRail stacks abbreviated weekday, day number and month in accent color. BrandLockup combines the actual cue-card path with Cuekeeper text; the redundant shape is hidden from accessibility and the lockup is combined as one element.

### Native shell

Upcoming, Events, Payments and Settings form the tab/sidebar destinations. The regular-width selected-record layout keeps agenda and details visible together. The sidebar groups the brand, native sidebar list and sync feedback into one floating glass surface with an opaque accessibility fallback. Native navigation and tab bar backgrounds use automatic material behavior. Sync feedback leads to Settings and describes observed activity without claiming that every device is current.

### Event capture and editing

Each event has at most one client, with client/status, schedule, broadcast links,
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
scaled 300-point minimum width cannot fit. Existing-event status and arrangement
retain menus for their four choices.

The event owns every session's timezone. Event setup and the wizard session list
expose it once; session editing displays it read-only. Remote/hybrid Work fields
include Your timezone for secondary local-time readouts, including call time.
On-site work inherits the event zone. Event-zone changes preserve scheduled instants.

### Payment disclosures and deletion

Ready to invoice groups events into initially collapsed client disclosures, with
event counts and separate currency totals. Expanded rows show event names, dates
and fees and open the event detail. Accessibility text stacks the row content.
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
- **Do** preserve the date-led hierarchy and sessions-before-billing detail order.
- **Do** use named appearance-aware color assets and semantic text styles.
- **Do** keep USD and EUR separate and show real partial balances and pending schedules.
- **Do** retain native controls, navigation and accessibility adaptation.
- **Do** keep reading surfaces matte and let native glass define action and navigation depth.

### Don't:
- **Don't** flatten the implementation into a palette-only treatment of generic forms.
- **Don't** substitute sample board data for financial or calendar truth.
- **Don't** force three columns at accessibility text sizes.
- **Don't** treat conceptual system chrome as a pixel-exact native requirement.
