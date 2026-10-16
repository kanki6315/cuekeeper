# Event page redesign — implementation brief (Concept C)

Concept boards: <https://claude.ai/artifact/QkEB9RqYCDGFraMHXi3CqV> (row C, boards C1–C4).
The boards are the direction. Native SwiftUI controls, SF typography and the named color
assets are authoritative; the boards are not a pixel contract.

## What changes

`JobDetailView` (`Cuekeeper/JobEditorView.swift`) currently shows everything as one long
column of sections in a fixed order. Concept C replaces it with:

1. **Header**: dates · place, the title, then the booking status, client and role.
2. **To settle**: derived open items, each with its own inline action. Hidden when there is nothing to settle.
3. **Body**
   - *Compact width, or the detail column narrower than 820 pt*: three tabs, **Schedule · Money · Details**, pinned while scrolling.
   - *Detail column at least 820 pt, without accessibility text sizes*: two columns, no tabs. Schedule on the left; Money and Details on the right.

Event data, save paths and editors stay as they are. This is a presentation change plus
one derivation layer.

## Phase 1 — derivation layer (no UI)

New file `Cuekeeper/EventDetailSummary.swift`. It is a value type built from a `Job` plus `now`,
recomputed in `body` and never stored.

- `days: [RunOfShowDay]`: sessions grouped by event day (`activeSessions` already sorts by
  `eventDay, startTime`). Each day carries a covering count (`covering n of m`) and its sessions.
- `nextCall: NextCall?`: the earliest session with `coverage == "covering"` whose
  `callTime ?? startTime` is in the future. Only produced when it is within **7 days**; otherwise
  the hero is omitted. It carries the call, on-air start/end and session title, and the session's
  tentative state if any.
- `timeDisplay`: show the *Your time / Track* toggle only when `job.hasWorkTimeZone` and
  `workTimeZoneID != eventTimeZoneID`. Remote work defaults to *Your time*; on-site work
  always uses the track zone. Persist the choice with `@AppStorage("eventTimeDisplay")`.
- `openItems: [OpenItem]`, each with `kind`, `title`, `detail`, `tab` and `action`. Rules, in display order:

| Rule | Copy (example) | Action | Tab |
|---|---|---|---|
| `bookingStatus == tentative` and event not past | Dates are on hold | Mark booked (existing `updateBookingStatus`) | Schedule |
| Session covering/undecided with no `startTime`, or `scheduleStatus == tentative` | Sprint has no time | Open `SessionEditorView` for that session | Schedule |
| Session `coverage == undecided` (time known) | Sprint coverage undecided | Open session editor | Schedule |
| No client | Client to add | Open `JobEditorView` | Details |
| Fee `amount == nil` and status booked/completed | Fee not agreed | Open `FeeDetailView` | Money |
| `currentFee()` throws (conflicting edits) | Fee needs review | Open `FeeDetailView` | Money |
| Completed, has client, fee known, `billingSummary == "Not invoiced"` | Ready to invoice | Add to Invoice (`InvoiceEditorView`) | Money |
| Active invoice is still a draft | Invoice not sent | Open `InvoiceDetailView` | Money |
| Invoice `balance() > 0` | €900 owed · due Nov 19 | Open `InvoiceDetailView` (records receipts) | Money |
| `billingSummary` reports duplicate billing or direct+invoice | Billing needs review | Open the invoice | Money |
| Expense `isDraft` | Receipt to review · €38.40 | Open `ExpenseEditorView(expense:)` | Money |

  Cancelled events show only the billing and expense rules. Show at most 3 rows, then
  *Show all n*. Nothing is persisted, so an item disappears as soon as its data is filled in.
- `defaultTab`: **Money** when the event is completed/cancelled and has a Money open item;
  otherwise **Schedule**.
- `tabCounts`: open-item counts per tab, used for the segment badges.

**Money truth constraint.** Receipts settle an invoice as a whole and are never assigned to
individual bookings. The paid/owed bar is therefore drawn only when the event's active
invoice bills **this event alone**. For a grouped invoice, show
"On INV-0412 with 2 other events · €900 of €3,000 owed on the invoice" with no per-event bar.
Draft invoices show "On draft invoice". Never derive a per-event paid amount.

Unit tests (`CuekeeperTests/EventDetailSummaryTests.swift`) should cover every open-item rule,
the 7-day hero window, an overnight session crossing the event day, remote vs on-site time
display, the default tab, a single vs grouped invoice bar, and unknown vs zero fee.

## Phase 2 — components (`Cuekeeper/EventDetailComponents.swift`)

| Component | Notes |
|---|---|
| `EventHeader` | Meta line (subheadline, SecondaryText), title (largeTitle bold), then a status/client/role row. The status badge is a `Menu` of statuses that reuses the existing save path and keeps identifier `booking-status`. The date line keeps `edit-event-dates`. |
| `OpenItemsPanel` | Ruled Daybook panel titled "To settle · n". Each row has a leading symbol in a tinted circle (amber for warnings, accent otherwise), a one-line title and a trailing text button. The first row may use `DaybookPrimaryButton` when it is the event's main next step (Mark booked, record payment). Each row is a single accessibility element with a custom action. |
| `NextCallPanel` | Forest fill (`AccentColor` light / a dark-mode pairing, to be decided in Phase 6). Shows the call time large in the selected zone, with the other zone beneath it. Then on-air range and series. Use `TimelineView(.everyMinute)` for "Tomorrow" / "in 19 min" copy. Within 90 minutes of the call, the lead text becomes a "Call in 19 min" countdown (board A2). Matte, with no glass, per the Quiet Reading Rule. |
| `RunOfShowDayView` | Reuses `DaybookDateRail` on the left. The day header shows the covering count and, when a forecast exists, the day's weather. Then a ruled panel of `RunOfShowRow`s. |
| `RunOfShowRow` | Time column (`@ScaledMetric` width, monospaced digits), title, then "Call 5:30 · 1 hr". At regular width it also shows the track time trailing. Not-covering rows use SecondaryText with no badge. A missing time shows a dashed "TBC" tile in amber with an *Add time* button. Confirmed + covering rows show no badge (quiet by default). Rows navigate to `SessionDetailView`. At accessibility sizes the time stacks above the title. |
| `MoneySummaryPanel` | Fee amount (title2 bold, monospaced) plus the agreement state, the paid/owed bar (subject to the constraint above), legend, then `FeeLine` breakdown rows when `lines` is non-empty. Keeps `job-fee`, which opens `FeeDetailView`. |
| `EventExpensesSection` | Existing. Restyled to rows: merchant, amount, and an amber *Needs review* for drafts. Keeps `scan-receipt` and `expense-row`. |
| `EventFactsList` | `<dl>`-style labelled rows: Client (link), Role, Working (remote place + zone offset in words: "EDT, 5 hours behind the track"), Track, Series, Project, Notes, Previous booking notes. |

`DaybookSegments` gains an optional `badge: (Value) -> Int` and renders a small amber count
capsule after the label. Its accessibility value becomes "1 to settle". The text-only,
single-row and accessibility-scroll behaviour stays unchanged.

## Phase 3 — compact layout

Replace the body of `JobDetailView` with `ScrollView { LazyVStack(pinnedViews: [.sectionHeaders]) }`.
`DaybookForm` cannot pin headers, so this screen gets its own scroll container on the same
`daybookSurface()`, 760 pt max width and page padding.

- Section 1, unpinned: `EventHeader`, then `OpenItemsPanel`.
- Section 2: its pinned header is the `DaybookSegments` tab bar on `PageBackground`; its content is the selected tab.
  - **Schedule**: `NextCallPanel` (if any), then *Run of show* with the zone toggle, the days, and the *Session* / *Edit several* buttons (`add-session`, `batch-sessions`).
  - **Money**: `MoneySummaryPanel`, then Invoice & payments (existing `JobBillingSection` content as rows: `add-job-invoice`, `record-direct-payment`), then Expenses.
  - **Details**: `EventFactsList`, Notes, then Duplicate (`duplicate-job`) and Delete (`delete-job`) as quiet rows.
- Store the selected tab in `@SceneStorage("eventTab-\(job.id)")`, seeded from `defaultTab`.
- The toolbar keeps **Edit** (`edit-event`) and adds a `…` menu with Duplicate and Delete. The `advance-booking-status` button is replaced by the "Dates are on hold → Mark booked" open item; the status menu covers *Mark completed*. Keep that identifier on the menu item.
- `EventWeatherSection`'s stand-alone panel is removed (see Phase 5).

## Phase 4 — wide layout

Decide the layout by the detail column's measured width (`onGeometryChange`), not by
`horizontalSizeClass`. An iPad with the sidebar *and* agenda visible leaves the detail column
around 530 pt, which needs tabs. Collapsing the agenda leaves about 1,100 pt, which gets columns.

- At 820 pt or more, without an accessibility type size: `Grid`/`HStack` with columns weighted 1.45 : 1 and 32 pt spacing, top-aligned.
  - Left column: the Schedule tab content.
  - Right column: Money, then Details (no Duplicate/Delete rows; those stay in the toolbar menu).
- Header and To settle span the full width above both columns.
- When the width crosses the threshold, keep the user's tab selection for the next time it collapses.

## Phase 5 — weather in the day headers

`EventWeatherSection` owns loading, quota and the eligibility window. Extract that into an
`@Observable EventWeatherLoader` keyed by `job.weatherRequest`, held in `JobDetailView`'s state.
Day headers read `snapshot.days` for their date ("14° showers"); the hero reads the same day.
The quota, purge timer, scene-phase refresh and `--weather-fixtures` behaviour must be
unchanged. Outside the forecast window nothing renders: weather is never shown as missing.
The hourly breakdown (`ForecastContent`) moves into `SessionDetailView` for that session's hours.
This phase is independent of 3 and 4 and can ship after them.

## Phase 6 — verification and documentation

- Update UI tests that reach moved elements: tap the Money or Details tab first in
  `EventVisualTests`, `CaptureTests`, `DesignSupplementTests` and `EventWizardTests` (`job-fee`,
  `duplicate-job`, `delete-job`, `scan-receipt`, `record-direct-payment`, `job-project-link`).
  Add an identifier per tab (`event-tab-schedule|money|details`).
- New UI workflow: an event with open items → resolve each one → the panel disappears and the badges clear.
- Simulator evidence (iPhone + iPad, light/dark, default and AX3 text, iPad agenda shown and
  hidden) in `design/event-page/verification/`, following the earlier verification READMEs.
- Dark mode for `NextCallPanel`: a forest fill would disappear on the charcoal page. Use
  `SurfaceBackground`-dark with a mint call time, or add a named `HeroBackground` pair, and record it in DESIGN.md.
- Update DESIGN.md: the event detail section, the Do's ("sessions-before-billing" becomes
  "schedule tab first; money promoted after completion"), and the new components.
  `.impeccable/design.json` is updated to match.

## Decisions to confirm

- Hero window: 7 days (the boards show "Tomorrow").
- Whether pre-booking gaps (no client, tentative) belong in To settle, or only items that block
  getting paid. The brief includes them, because capture-first events otherwise give no
  guidance. They never block saving.

## Out of scope

Data model or schema changes, sync, calendar publishing, editors, and the Payments and
Upcoming tabs.
