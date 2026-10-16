# Expenses overview screenshots

Simulator captures use synthetic records from the debug-only `expenses-overview`
fixture. `iphone.png` and `ipad.png` show the initial layout; `*-compact.png` show
the compact rows. All four predate the subsequent removal of the Expenses heading
and search field and are retained as iteration evidence, not final-screen captures.

Validation: app and test targets built; 22 existing expense regression tests
passed before the layout refinements. The compact layout and final heading/search
removal each passed a simulator build.
