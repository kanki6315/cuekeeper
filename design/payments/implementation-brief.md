# Payments redesign — implementation brief (Concept B, month close)

Concept canvas: <https://claude.ai/artifact/J3QR7jVP943kLavP4FryS2> — boards B1b (iPhone, step
bars with key), B2 (readiness sheet), B3 (iPad ledger), A3 (invoice creation details).
The boards are direction; native SwiftUI controls, SF typography and the named color
assets are authoritative.

## Decisions

- Payments becomes a **month close**: pick a month, see every event in it with four
  gates — **Work · Fee · Receipts · Client** — grouped by client, the month's money split
  by state per currency, and money still open from earlier months beneath.
- **Receipts gate**: any draft receipt on the event holds up invoicing, so the bookkeeping
  gets done. Finished receipts never block; only finished reimbursable ones can be rebilled.
- **Client gate** needs saved invoicing details: billing name, billing email, address and
  payment terms. Tax ID is optional.
- **Rebilling**: reimbursable, finished receipts can be added to an invoice as expense
  lines. Each expense can be on one active invoice.
- Expenses stay their own tab. Payments only surfaces receipts that block an invoice.

## Data

**V15** adds one optional attribute, `Client.invoicingJSON` (String, default ""), holding
`ClientInvoicing` (`billingName`, `email`, `address`, `termsDays: Int?`, `taxID`). Lightweight
migration; older builds ignore it. Backups accept archives without it. CloudKit:
initialise and export Development, then deploy to Production before the next release.

`InvoiceValue` gains `expenseLines: [BilledExpense]?` (`expenseID`, `label`, `amount`). It is
optional so older builds decode the invoice and ignore the lines (they will show a lower
total until updated). `total()`, `validate()` (unique expense IDs, non-negative) and
`sameBilledTerms` include them. `InvoiceIndex` tracks active invoices per expense; saving
rejects an expense already on another active invoice, a draft or non-reimbursable
expense, another event's client, or another currency.

## Derivation — `Cuekeeper/PaymentsReadiness.swift` (no UI, unit tested)

`EventReadiness` is built from a `Job` (plain facts, like `EventDetailFacts`):

| Gate | done | missing (amber) | not yet |
|---|---|---|---|
| Work | completed | — | booked/tentative and not finished |
| Fee | amount > 0 known | unknown amount or conflict | — |
| Receipts | no draft receipts | ≥1 draft receipt | — (no receipts counts as done) |
| Client | client with complete invoicing details | no client, or details incomplete | — |

State, in priority order: `review` (billing issue) · `paid` · `invoiced(sent, balance)` ·
`draft` · `directPaid` · `noFee` (fee is exactly 0; listed quietly) · `ready` (all four done) ·
`heldUp` (work done, another gate missing) · `upcoming` (work not yet). Cancelled events
appear only with money attached.

`PaymentsMonth` groups a month's events (by `eventStartDay`) by client, totals each
currency by state (paid, invoiced, ready, held up, still to happen) and lists money open
from earlier months: unpaid sent invoices, drafts, and earlier finished work that is
ready or held up.

The event page's *Ready to invoice* open item uses the same gates, and adds *Invoicing
details to add* when only the client details are missing.

## UI

- **PaymentsView (compact)**: tab header with + Invoice; month stepper; currency bars with
  legend; *By client* with the step-bar key (labels and arrows into each segment, then
  Done / Missing / Not yet); client panels (name, details state or *Add details*, events
  with date rail, step bar, the gap named in text, amount; *Invoice n ready* when any are
  ready); *Still open from earlier*; *All invoices and payments* → the existing lists
  (needs review, drafts, awaiting payment, paid, direct, voided).
- **Readiness sheet**: tapping a held-up row opens the four gates with actions, and the
  client invoicing form inline when that is the gap.
- **Wide (≥ 900 pt, non-accessibility)**: ledger table with gate columns beside a 340 pt
  column holding currency bars and *Still open*.
- **Invoice editor**: opened from a ready group, it preselects those events, offers that
  client's finished reimbursable receipts as optional lines, and sets the due date from
  the client's terms.
- **Client editor** (libraries): an *Invoicing details* section.

## Verification

Unit tests for every gate and state, month grouping, currency separation, expense lines
(validation, duplicate rejection, total), invoicing completeness, backup without the new
attribute and V14→V15 migration. UI tests updated for the new Payments layout. Simulator
evidence in `design/payments/verification/`. DESIGN.md and PRODUCT.md updated.

## Out of scope

Concept A's Collect queue, reminders, document generation, client/event-specific
reimbursement rules.
