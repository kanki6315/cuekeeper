# Cuekeeper Liquid Glass explorations

Two concept treatments requested October 13, 2026, followed by the approved Combined Glass implementation. The numbered boards are synthetic design references; actual simulator captures are in `verification/`.

- **Quiet Glass:** restrained, neutral glass navigation above opaque ivory and charcoal content. The date-led agenda and forest/mint identity carry the expression.
- **Expressive Glass:** more visible optical edges, refraction and floating navigation, with the same content hierarchy and solid reading surfaces.

Both retain the supplied stacked cue-card mark, SF typography, separate USD/EUR balances, and independent booking, scheduling and payment states. Example records are fictional demonstration data.

## Native implementation considerations

Use native tab bars, navigation toolbars, sidebars and system materials. Rendered glass here is illustrative; its exact appearance is controlled by the operating system in a shipped app. Keep financial and scheduling content opaque and legible. Respect safe areas, Dynamic Type, 44-point touch targets, Increase Contrast, Reduce Transparency and Reduce Motion. Static boards cannot validate these behaviors.

Guidance: [Apple Materials](https://developer.apple.com/design/human-interface-guidelines/materials) and [Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass).

Generated with the built-in image-generation tool. Exact prompts accompany the images in JSON sidecars. The selected combined direction is implemented in native SwiftUI and recorded in `../../DESIGN.md`.

## Boards

Latest combination requested by the user: Quiet Glass as the base, expressive iPad sidebar, rounded glass action buttons.

- [Combined Glass — iPhone](04-combined-iphone.png): Upcoming light/dark, job detail light and Payments dark.
- [Combined Glass — iPad](05-combined-ipad.png): light/dark sidebar, agenda and selected detail.

The combined boards preserve quiet tabs, matte content and status badges, with glass emphasized in the sidebar and action buttons. They correct the earlier filter/date mismatch using All upcoming, replace red Unpaid badges with neutral badges, restore a visible broadcast-links section and replace iCloud status claims with an iCloud settings link. The user selected this combination and requested implementation. The images guide the material and hierarchy; native behavior remains authoritative. The iPad render omits invoice/notes values in its visible excerpt; implementation must preserve actual record values. Native material behavior and accessibility remain untested in these static concepts.

Earlier comparison boards:

- [Quiet Glass — iPhone](01-quiet-glass-iphone.png): Upcoming in both appearances, job detail and Payments.
- [Expressive Glass — iPhone](02-expressive-glass-iphone.png): matching screens with more pronounced glass controls.
- [iPad comparison](03-ipad-comparison.png): both treatments with sidebar, agenda and selected detail.

## Review notes

Quiet Glass is the recommended base for a working agenda. Borrow the expressive sidebar separation and circular toolbar actions selectively.

The generated boards have illustrative deviations that must not become implementation requirements: iPhone agendas show This week selected while including October 19 (use All upcoming); expressive status badges and balance panels are too glossy (keep content opaque); red Unpaid badges do not establish that an invoice is overdue (use neutral treatment); iPad iCloud Up to date copy must be replaced with observed local sync activity and must not claim all devices are current. The detail board is a visible excerpt, not permission to remove broadcast links or other existing fields.

These images were visually inspected for comparison and identity, not certified as native UI screenshots or accessibility-tested specifications.

## Implementation verification

See [verification report](verification/README.md) for build, workflow and visual-review evidence. The app preserves the existing forest/ivory identity and matte reading surfaces, adds native glass capsule actions, and gives the iPad sidebar a floating glass surface with an opaque accessibility fallback.
