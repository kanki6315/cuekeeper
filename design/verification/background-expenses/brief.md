# Background expense capture

Mode: Operate. Extend Cuekeeper’s existing native Daybook surfaces.

User request: a background Capture Expense action saves partial Wallet expenses;
optional local notifications open the matching draft; a persistent list lets the
user add a receipt, choose an event and confirm details later. Settings must explain
how to configure the Wallet personal automation. Preserve Scan Receipt for the
Action Button. Version 0.1.10, feature branch/commit/local merge requested.

Structure: Upcoming has a conditional completion prompt; Payments always links to
Expenses to complete. Native review sheet accepts incomplete drafts, retains
captured payment evidence, and fills only blank fields from receipt extraction.
Conflicting receipt fields require explicit review. Keep Draft works without a
photo or event. Removing a personal/duplicate draft requires confirmation.
Settings → Integrations → Wallet Automation gives numbered setup instructions,
notification opt-in/status controls and input availability expectations.

No new visual identity, tokens, browser, or computer-control tools. Reuse semantic
SF text, Daybook forms/pickers/links, native sheets, lists and toolbar actions.
Synthetic UI fixtures test presentation and routing, not actual Apple Pay delivery.
