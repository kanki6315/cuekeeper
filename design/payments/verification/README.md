# Payments month close — verification

October 16, 2026. Simulator evidence for the month close described in
`design/payments/implementation-brief.md`. Data is the synthetic `--payments-fixtures` month
(`DesignFixtures.seedPayments`), dated relative to the run day.

## Automated checks

- Unit tests: full `CuekeeperTests` suite, 202 tests, 0 failures (2 skipped by the tests themselves).
  New: `PaymentsReadinessTests` (gates, states, month grouping, currency separation, client
  invoicing, expense-line JSON) and `PaymentsBillingTests` (draft receipts block, rebilling
  eligibility and duplicates, sent-invoice terms, backup without the V15 field, client editor,
  event page rule, fixture seeding). The migration test now covers V2–V14 → V15.
- UI tests: `PaymentsTests` on iPhone 17 Pro (4 tests) and iPad Pro 13" (5 tests), all passing.
  Covers resolving client details from the readiness sheet, starting an invoice from a ready
  group with a rebilled receipt, the ledger, dark mode with accessibility text, and iPad
  portrait/landscape.

## Screenshots

| File | Shows |
|---|---|
| `iphone-month-top.png` | Month stepper, currency bars, step-bar key |
| `iphone-month-clients.png` | Client panels, step bars, gaps named, ready button |
| `iphone-readiness-sheet.png` / `-ready.png` | Gates for a held-up event; after saving client details |
| `iphone-invoice-from-ready-group.png` | Invoice editor with events and a reimbursable receipt |
| `iphone-ledger.png` | All invoices and payments |
| `iphone-dark.png`, `iphone-dark-ax*.png` | Dark mode; accessibility extra large |
| `ipad-portrait.png`, `ipad-wide.png`, `ipad-wide-dark.png` | Ledger table beside money and earlier items |
| `ipad-readiness.png` | Readiness sheet on iPad |
| `ipad-month-*`, `ipad-dark*`, `ipad-ledger.png`, `ipad-invoice-*`, `ipad-readiness-sheet*` | The iPhone flows run on iPad |

## Not covered

- CloudKit: the V15 Development schema has not been initialised or exported; Production
  deployment is a release prerequisite.
- Physical devices, live iCloud sync between a V15 and an older build, and VoiceOver gestures.
- In the iPad table, long state text truncates at two lines in portrait.
