# Combined Glass implementation

Mode: Operate. Scope: existing iPhone and iPad app surfaces, preserving stored data, actions, native navigation, independent workflow states and accessibility adaptation.

## Direction contract

THESIS: Quiet reading surfaces with expressive glass reserved for navigation and action. The existing date-led working agenda remains the organizing structure.

OWN-WORLD: Cuekeeper cue-card mark, SF semantic typography, forest/mint accents, ivory and warm charcoal. Matte badges and financial panels; rounded native glass buttons and a floating glass iPad sidebar.

STORY: A freelancer scans upcoming dates, opens a job, captures incomplete details and tracks invoices and receipts independently.

FIRST VIEWPORT: iPhone shows the brand and Add Job above the title, search/filter and date-led list, with quiet native tabs below. iPad keeps sidebar, agenda and selected detail columns; sidebar carries the pronounced material. Details keep sessions and links ahead of billing.

FORM: User-pinned combination of boards 04 and 05. Existing native structure retained. No randomized direction selection: user explicitly selected the visual treatment. System glass is implemented with native APIs, never baked raster material. The boards are conceptual references with the previously recorded illustrative deviations, not device screenshots.

FINISH: unreviewed and undocumented is unfinished; this build ends with the finish review, the verdict, DESIGN.md, and every shipping raster carrying its provenance

## Verification requirements

- Build the native app and test targets.
- Inspect iPhone/iPad light and dark captures; inspect large-text and iPad portrait adaptation.
- Verify creation, editing/discard, sessions/links, fees, invoices/partial receipts, libraries/filters and nonblocking sync feedback using the existing UI workflows.
- Retain separate USD/EUR balances and semantic status text.
- Review the actual simulator screenshots against the combined concepts, with native system behavior authoritative for glass optics and navigation.
- No schema deployment or distribution is part of this UI task.
