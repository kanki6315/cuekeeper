# Website verification

October 15, 2026. The independent reviewer returned **ship within source-only
scope**. The site has not been published. This is not rendered visual approval.

## Evidence

Reviewed `build.py`, `assets/site.css`, `content/support.json`,
`content/privacy.json`, `README.md`, the website direction contract and surface
brief against the incumbent root `DESIGN.md` and product context. The recorded
build checks passed all five tests: internal routes and anchors; semantic page
structure; JSON section coverage; sitemap, security and output size; and primary
text contrast pairs. These checks validate generated files, not deployed routing
or response headers.

The source implements the selected full guide with a topic index, visible
answers and direct section links. The shared shell provides named navigation,
one main landmark, skip links, current-page indication and email actions. The
homepage remains a minimal branded introduction; it has no unavailable download
action. Content is readable without JavaScript.

## Design-system extension

- Palette: forest `#073E27`, mint `#A7DCB4`, ivory `#FAF8F2`, charcoal `#171E19`,
  surface, muted-text and amber focus pairs match the native design tokens.
- Type: the system sans-serif stack adapts the app's SF identity; body leading is
  `1.65`, page headings span `2.6–4.8rem`, section headings `1.5–2rem`, and the
  homepage headline `3.2–6rem`. This is a web scale, not a native token change.
- Appearance Pair Rule: CSS switches foregrounds and backgrounds together;
  `--ink` becomes ivory in dark appearance. The detector's black-on-dark warning
  does not reflect that cascade and was reviewed as a false positive.
- Quiet Reading Rule: opaque reading surfaces and ruled sections preserve the
  app's Daybook character. Capsules, 12px notes and the existing vector mark carry
  its shape language; native glass is not simulated in CSS.
- Web layout: a 75rem container, 14rem topic index and 70ch article width support
  long reading. At 56rem the index moves above the guide; at 36rem it becomes one
  column. Focus, increased contrast, reduced motion and print have explicit rules.

Root native design files remain authoritative and unchanged by this verification
pass. Pre-existing sidecar drift was neither repaired nor adopted as a web rule.
No craft defect was canonized to suppress a finding.

## Verification limits

Repository instructions prohibit browser and computer-control tools, including
headless browsers. No browser was used and no screenshots, computed-style checks,
keyboard interaction tests or rendered desktop/mobile/print checks were made.
Source inspection cannot establish actual wrapping, clipping or assistive
technology behavior. Human visual and interaction review remains required using
the checklist in `README.md`, followed by live HTTPS, route, security-header and
mailbox verification after deployment.

Terminal HTTP smoke checks also passed for /, /support, /privacy, stylesheet, SVG mark (200), and an unknown route (custom 404). The temporary localhost server was stopped afterward. Deployable output: 9 files, 42,312 bytes; direct-upload ZIP: 16,397 bytes. No deployment performed.

The user reviewed the local preview and approved the website on October 15, 2026.
This records their approval, not an automated desktop/mobile or accessibility
verification. Cloudflare deployment remains a separate setup step.
