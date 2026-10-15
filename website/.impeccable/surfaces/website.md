---
version: 1
slug: "website"
primary_target: "website"
related_targets: []
---

# Cuekeeper public website

Mode: Read for support and privacy. The homepage is a deliberately small marketing
shell, ready for a later screenshot/content pass. Preserve the native app's identity;
this document describes the web adaptation and does not replace root DESIGN.md.

## Direction contract

THESIS: A complete, readable daybook guide with a topic index, not a collection of
FAQ cards. Answers remain visible, linkable and printable without JavaScript.

OWN-WORLD: Approved kept-cues mark, forest and mint accents, ivory/charcoal grounds,
SF-style system typography, capsule actions and quiet ruled sections. The app's
existing sans-serif identity governs display as well as body text. No font downloads.

STORY: Find the relevant topic, follow concrete steps, understand the limits, then
email support if needed. The privacy policy explains storage and retention plainly.

FIRST VIEWPORT: Brand/navigation across the top; large left-aligned page title and
short introduction; direct email action; below, a narrow topic index beside a
comfortable reading column. Mobile places the index above the guide. The homepage
uses generous type and one concise product introduction, with support as its action.

FORM: User chose the complete guide with a topic index from the structured chooser.
The browser chooser was excluded by AGENTS.md. Code-led surface expansion within
the established brand; no visual-world replacement. Surface seed run: read mode,
recorded in the project roll record; candidate 7 selected (full guide); alternatives were expandable
questions (4) and a topic directory (2).

RESPONSIVE & STATES: Freelancers may read on a phone between calls or at a desk.
Follow system light/dark preference; ivory in daylight and warm charcoal at night.
Single column below 56rem. Visible keyboard focus, skip link, current-page nav,
anchor targets, native scrolling, reduced-motion support and print layout. No
hidden answers, search dependency, loading state or account requirement.

## Verification boundary

No browser or computer-control tools, including headless browsers, may be used.
Run static build, HTML/link/content/security checks and HTTP checks through the
terminal. Human desktop/mobile visual review remains required; do not describe
source inspection as rendered screenshot verification.
