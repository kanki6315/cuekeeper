# Event page and Upcoming concept canvas

Source files for the concept boards behind the event page redesign (`design/event-page/`) and
the Upcoming Now / Plan redesign (`design/upcoming/`). The live canvas is
<https://claude.ai/artifact/QkEB9RqYCDGFraMHXi3CqV>.

Each `*.dc.html` file is one artboard written in the canvas's Design Component format. They
load the canvas runtime (`support.js`) and won't render on their own in a browser. Open the
canvas link to view them, or read them as layout references. `canvas.json` records each
board's position and title. `Current.dc.html` shows a screenshot that is stored with the canvas,
not in this folder. All names, times and amounts are fictional demonstration data.

| Row | Boards | Direction |
|---|---|---|
| — | `Current` | The event page before the redesign |
| A · Run of Show | `Main`, `RunOfShowLive` | Time-led event page |
| B · Open Items | `OpenItemsBefore`, `OpenItemsAfter` | Lifecycle-led event page |
| C · Blend (built) | `BlendSchedule`, `BlendMoney`, `BlendDetails`, `BlendIPad` | To settle plus Schedule / Money / Details tabs |
| D · Upcoming Daybook | `UpDaybook`, `UpDaybookLive` | Session-led agenda |
| E · Upcoming Desk | `UpDesk`, `UpDeskQuiet` | Event-led planning desk |
| F · Blend | `UpBlend` | Daybook agenda with a week strip |
| G · Now / Plan (built) | `UpNow`, `UpNowTwo`, `UpPlanCompact`, `UpPlan`, `UpNowIdle`, `UpIPad` | Two modes for doing and planning |

`BlendIPad` and `UpIPad` show side-by-side layouts. The shipped app uses a sidebar-adaptable
tab view instead: the event page splits into columns when it is wide enough, and `UpIPad` was
not built.
