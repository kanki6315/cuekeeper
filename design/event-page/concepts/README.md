# Event page concepts

Source for the event page concept boards, copied from the design canvas
<https://claude.ai/artifact/QkEB9RqYCDGFraMHXi3CqV> on October 16, 2026. Concept C was chosen and
implemented; see `../implementation-brief.md` and `../verification/`.

Each board is a self-contained `.dc.html` design component at a fixed artboard size. The markup is
static; the canvas runtime (`support.js`) is not in the repo, so open them on the canvas for the
intended view. All event data is fictional.

| File | Board | Size |
|---|---|---|
| `Current.dc.html` | Today's event page before the redesign (points at `design/verification/single-client-events/events-iphone-event-light.png`) | 390 × 848 |
| `Main.dc.html` | A1 · Run of Show, day before | 390 × 1840 |
| `RunOfShowLive.dc.html` | A2 · Run of Show, on the day | 390 × 844 |
| `OpenItemsBefore.dc.html` | B1 · Open Items, two weeks out | 390 × 1700 |
| `OpenItemsAfter.dc.html` | B2 · Open Items, after the weekend | 390 × 1500 |
| `BlendSchedule.dc.html` | C1 · Schedule tab, day before, all settled | 390 × 1280 |
| `BlendMoney.dc.html` | C2 · Money tab, after the weekend | 390 × 1300 |
| `BlendDetails.dc.html` | C3 · Details tab | 390 × 1060 |
| `BlendIPad.dc.html` | C4 · iPad, two columns, no tabs | 1366 × 1200 |

Feed links were removed from the boards after they were removed from the app. The `Up*` boards on
the same canvas belong to separate Upcoming-tab work and are not included here.
