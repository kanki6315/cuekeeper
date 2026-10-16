# Upcoming concept canvas

Source files for the concept boards behind the Upcoming Now / Plan redesign (`design/upcoming/`).
The live canvas is <https://claude.ai/artifact/QkEB9RqYCDGFraMHXi3CqV>, and it also holds the event
page boards. Those boards' sources are in `design/event-page/concepts/`.

Each `*.dc.html` file is one artboard written in the canvas's Design Component format. They load the
canvas runtime (`support.js`) and won't render on their own in a browser. Open the canvas link to
view them, or read them as layout references. `canvas.json` is the whole canvas layout, so it also
lists the event-page boards kept in `design/event-page/concepts/`. All names, times and amounts are
fictional demonstration data.

| Row | Boards | Direction |
|---|---|---|
| A–C · Event page | see `design/event-page/concepts/` | Run of Show, Open Items, and the built blend |
| D · Upcoming Daybook | `UpDaybook`, `UpDaybookLive` | Session-led agenda |
| E · Upcoming Desk | `UpDesk`, `UpDeskQuiet` | Event-led planning desk |
| F · Blend | `UpBlend` | Daybook agenda with a week strip |
| G · Now / Plan (built) | `UpNow`, `UpNowTwo`, `UpPlanCompact`, `UpPlan`, `UpNowIdle`, `UpIPad` | Two modes for doing and planning |

`UpIPad` shows Now beside the selected event. The shipped app uses a sidebar-adaptable tab view, so
this layout was not built; on iPad, Upcoming pushes the event page just as on iPhone.
