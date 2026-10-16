# Upcoming redesign — implementation brief (Now / Plan)

Concept boards: <https://claude.ai/artifact/QkEB9RqYCDGFraMHXi3CqV>, row G:

| Board | Shows |
|---|---|
| G1 | Now, one job in flight |
| G2 | Now, two jobs in flight |
| G3 | Plan, To settle collapsed |
| G4 | Plan, To settle expanded |
| G5 | Now, nothing in the next 72 hours |
| G6 | iPad |

The boards are the direction. Native SwiftUI controls, SF typography and the named color
assets are authoritative.

This builds on the event page redesign (branch `claude/event-page-redesign-e1d597`,
brief `design/event-page/implementation-brief.md` on that branch). Upcoming reuses its
`EventDetailSummary` open-item rules, `NextCallPanel`, `RunOfShowRow` and `DaybookSegments`
badges, so **build this after that branch is merged.**

## What changes

`JobsView(upcomingOnly: true)` and `TodayScheduleView` (`Cuekeeper/RootView.swift`,
`Cuekeeper/TodayView.swift`) are replaced by a new `UpcomingView` with two modes:

- **Now**: the work in flight. A next-call panel, the jobs in flight, one merged run of show, then "After this → Plan".
- **Plan**: the desk. To settle (collapsed by default), a two-week strip, then Coming up.

The following are removed from Upcoming:

- The Today / Week / All scopes (`upcoming.scope`).
- Search and filters. The Events tab keeps both.
- The dismissible "Needs attention" box (`upcoming.dismissedAttention`).
- `PendingExpensesPrompt`. Its drafts become To settle items.

`JobsView` remains for the Events tab only.

## Decided rules

| Rule | Decision |
|---|---|
| In flight | Any booked or tentative job with a session or event day between now and **now + 72 hours**, or running now. Completed and cancelled jobs are excluded. |
| Opening mode | Now when anything is in flight, otherwise Plan. A manual choice sticks until the set of in-flight jobs changes. |
| Now with nothing in flight | "Nothing in the next 3 days.", then a link to the next job ("Next work in 11 days"), then "See the next two weeks in Plan". No week strip. |
| Plan badge | The amber count of all open items, shown on the Plan segment in both modes. |
| To settle, collapsed | One header row (title, count, chevron) with a category summary ("2 bookings · 1 schedule · 2 money"). Below it, the item with the earliest ranking date and its action. No label on that item. |
| To settle, expanded | Every item with its event, date and inline action, plus *Show less*. |
| Ranking date | Event over → the event's end day. Session, booking and fee gaps → the event's start day. Balance owed → the invoice due day. Receipt draft → the purchase day. Earliest first. |
| Strip tap | Scrolls Coming up to that day's first job. |
| Clash warnings | None. The only thing shown between sessions is a gap line, and only between sessions of *different* jobs on the same day ("1 hr, 30 min before City derby"). |
| Dismissing items | Not possible. An item clears when its underlying data is fixed. |

## Phase 1 — `UpcomingSummary` (no UI)

New file `Cuekeeper/UpcomingSummary.swift`: a pure value type built from active jobs, standalone
expense drafts and `now`, with unit tests in `CuekeeperTests/UpcomingSummaryTests.swift`.

The summary is built from the same `EventDetailFacts` the event page uses, so open items, next
calls and session facts always match the event page. `Shared/DaySchedule.swift` stays the
widgets' snapshot format and is unchanged.

- `inFlight: [Job]`, using the 72-hour rule, ordered by first commitment.
- `nextCall`: the earliest future call or start among covering sessions of in-flight jobs.
- `days: [MergedDay]`: sessions of in-flight jobs grouped by day. Each row carries its job
  title, plus a gap line where the rule above applies.
  - **Times:** show remote work in your time. If every in-flight job is on site in the same
    zone, use that zone for days and times. Otherwise use the device zone and label on-site
    rows with their track zone abbreviation.
- `afterThis`: the first job that starts after the in-flight window.
- `idle`: the next job and the number of days until it, used when `inFlight` is empty.
- `openItems`:
  - **Sources:** the union of `EventDetailSummary.openItems` for tentative and booked events,
    plus money items for completed events.
  - **Two new kinds:**
    - `eventOver`: a booked or tentative event whose end day has passed. Action: Mark completed.
    - `expenseDraft` with no event: action Finish.
  - **Cancelled events** contribute billing items only.
  - **Each item** carries `rankDate` and a category: booking, schedule or money.
- `fortnight: [StripDay]`: Monday of the current week plus 13 days. Each day shows one mark per
  session:
  - covering: solid
  - not covering: outline
  - no time: dashed amber

  A tentative event with no sessions gets one dashed mark per event day.
- `comingUp`: jobs starting within 30 days, at most 8, each with its open-item count. Ends with an *All events* link.

**Test:**
- the 72-hour boundary at both edges
- an overnight session
- two jobs on one day, including the gap line
- the opening-mode choice
- the idle state
- every ranking-date rule
- the category counts
- a receipt with no event
- the fortnight marks, including a tentative event with no sessions

## Phase 2 — Now

`UpcomingNowView` reuses the event branch components:

- `NextCallPanel`, with the job title on its meta line.
- An **In flight** list. Each row opens the job and, when the job has notes, a Notes icon button (44 pt, labelled per job) that opens a read-only notes sheet with Edit Event. With one job, the row becomes a heading with a Notes capsule, as on board G1.
- The merged **Run of show**, using `DaybookDateRail` and `RunOfShowRow`. A TBC session row keeps *Add time* inline.
- **After this**, which switches the mode to Plan.
- The idle state (G5).
- A 90-minute countdown in the panel, matching the event page.

## Phase 3 — Plan

`UpcomingPlanView`:

- `SettlePanel`: collapsed or expanded. Store the expanded state in `@SceneStorage`, collapsed by default. Each row runs the same open-item actions as the event page; `eventOver` reuses the existing booking-status save path.
- `FortnightStrip`: a 7-column grid. Each day is a button whose accessibility label describes its sessions. At accessibility text sizes it becomes a horizontally scrolling single row.
- `ComingUpList`: `DaybookDateRail` with a date range, title, client · arrangement · coverage summary and the open-item count. Rows navigate to the event, or select it on iPad.

## Phase 4 — shell and iPad

- `DaybookTabHeader` holds a circular **Scan receipt** button (44 pt, `scan-receipt-header`) beside Add Event, in both modes and in the iPad agenda column. It replaces the per-job scan buttons. It opens the existing capture flow with the event picker preselected to the first in-flight job, if there is one; otherwise the user picks the event as today. The Now / Plan control is `DaybookSegments` with a badge, identifier `upcoming-mode`.
- iPad uses the app's sidebar-adaptable tab view (main replaced the split view), so Upcoming pushes the event detail onto its own navigation stack, exactly as on iPhone. Board G6's side-by-side layout is not built.
- Delete `TodayScheduleView`. Keep `DaySchedule`, because widgets and `SchedulePublisher` use it.

## Phase 5 — tests and verification

- **Update UI tests** that use `upcoming-scope`, `today-schedule`, `search-jobs`, `filter-jobs`,
  `pending-expenses` or the attention box: `TodayTests`, `CaptureTests`, `EventVisualTests`,
  `DesignSupplementTests`, `FirstLaunchTests` and `BackgroundExpenseTests`.
- **Add workflows:**
  - the opening mode with and without in-flight work
  - expanding To settle and resolving each kind of item until the badge clears
  - a strip tap scrolling to the job
- **Capture simulator evidence** for iPhone and iPad, in light and dark, at default and AX3 text sizes, in
  `design/upcoming/verification/`.
- **Update DESIGN.md**: the Upcoming description, the removal of the Today/Week/All scopes,
  and the new components.

## Out of scope

Data model changes, widgets, calendar publishing, the Events and Payments tabs, and clash detection.
