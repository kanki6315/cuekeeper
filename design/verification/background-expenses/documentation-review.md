# Background expense documentation review

Reviewed October 15, 2026 against PRODUCT.md, DESIGN.md, the task brief,
PendingExpensesView.swift, ExpenseAutomationSettingsView.swift and ExpenseView.swift.

This is an ordinary extension of the incumbent native Daybook system. PRODUCT.md
already records background capture, the completion list, preserved payment details,
optional reminders and Wallet setup. These implement its capture-first principle
without adding a navigation destination or changing the product identity.

The finished views reuse DaybookForm, DaybookLink, DaybookPicker and DaybookTextField,
semantic SF styles, appearance-aware SecondaryText and native sheets, alerts and
toolbar controls. The completion prompt uses a single disclosure indicator. Reading
surfaces remain matte and ruled; native glass remains confined to navigation and
actions. No new shared visual tokens or component system require documentation.
DESIGN.md and .impeccable/design.json were therefore preserved.

Known preexisting sidecar drift remains outside this task: its scopeControls entry
still describes older Upcoming labels and native segmented pickers. The current
prompt evidence shows Today / Week / All, while DESIGN.md already describes the
custom DaybookSegments treatment (its older scope labels also predate this work).
This review does not regenerate that sidecar or claim a full-product documentation
refresh.

Directly inspected visual evidence:

- iphone/pending-upcoming-prompt-final.png and ipad/pending-upcoming-prompt-final.png:
  final single-chevron prompt, incumbent typography, colors and native shell.
- iphone/background-draft.png: native receipt sheet, retained captured-payment
  comparison and existing ruled panels.
- ipad/wallet-automation-steps.png: numbered, wrapping setup steps and optional
  reminder section. Its background prompt predates the chevron correction; the
  final prompt capture above supersedes that portion.
- iphone/pending-dark-large.png and iphone/automation-dark-large.png: existing dark
  palette and enlarged semantic type with wrapping text in scrolling forms.

The evidence README and image inventory were also checked. Images show synthetic
simulator state; they do not verify Wallet delivery, locked-device capture, OS
notification taps, camera behavior or physical-device receipt extraction. Those
limits remain explicitly documented in README.md. No browser or computer-control
tools were used.
