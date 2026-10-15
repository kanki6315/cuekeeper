# Public-release preparation

Prepared October 15, 2026 for the current 0.1.10 source. These are reviewable drafts,
not a published policy, an App Store Connect submission, or an approved release.
No browser or computer-control tools were used. Official documentation was read
through terminal HTTP requests.

## Public pages and owner setup

The owner supplied `cuekeeper.arjunakankipati.com` and
`cuekeeper@arjunakankipati.com`. Settings uses HTTPS links to support and privacy. The support page provides the
email address; there is no separate email button in the app.

The subdomain failed DNS resolution during the October 15 terminal check. This
may be environment-dependent; public availability is not established. The owner
must configure DNS/hosting and TLS, verify the support mailbox, and publish:

| URL | Content |
| --- | --- |
| `https://cuekeeper.arjunakankipati.com/` | Public product page; `listing.txt` supplies factual product copy |
| `https://cuekeeper.arjunakankipati.com/privacy` | Reviewed `privacy.txt` |
| `https://cuekeeper.arjunakankipati.com/support` | Reviewed `support.txt` |

Serve readable public pages without login. Redirect HTTP to HTTPS. Hosting is
intentionally not changed here. Review the policy's developer identity, support
handling and retention language before publishing; it describes current code,
including retention of deleted records, rather than promising secure erasure.
Do not ship the new links until their destinations work.

## Privacy-manifest audit

- Main app: `NSPrivacyAccessedAPICategoryUserDefaults`, reason `CA92.1`. Used for
  app-owned preferences, setup completion, calendar connection/publisher state,
  reminder preference and view state in `UserDefaults.standard` / `@AppStorage`.
- Widget: no direct required-reason API usage found. The shared schedule is a JSON
  file in the App Group, not shared UserDefaults, so `1C8F.1` is not declared.
- Both manifests declare no tracking, tracking domains or collected data types.
  No developer analytics/advertising SDK or developer-operated data endpoint was
  found. Daybook and backups use the user's private CloudKit database. MapKit and
  WeatherKit requests go to Apple. Recognized text from receipts too long for the
  on-device model goes to Apple Private Cloud Compute. This is not a claim that nothing
  leaves the device.
- The backup file-size read uses `URLResourceKey.fileSizeKey`; that key is not on
  Apple's current required-reason API list. No direct timestamp, disk-capacity,
  active-keyboard or system-uptime API calls were found in shipping source.
- XcodeGen includes each manifest in its own target's resources. Inspect the
  final archive as well; a plist lint alone does not prove distribution acceptance.
- Re-audit if a dependency, telemetry endpoint, shared-defaults implementation or
  required-reason API is introduced.

## App Store privacy answers — proposed, owner confirmation required

For the current app binary, **Data Not Collected** is the proposed label, with no
tracking. Apple's definition concerns off-device data accessible to the developer
or partners beyond servicing a request. Apple says developers are not responsible
for disclosing Apple's own collection through frameworks such as MapKit/CloudKit.
The private database is not a developer-readable daybook service.

Before selecting that answer, confirm actual operational practices: no external
analytics or crash-reporting SDK, no collection/export of identifiable user data
from Apple services, and no support workflow collecting data beyond the described
user-initiated email. Email correspondence is described separately in the policy;
do not assume that every future support form or diagnostic-upload flow qualifies
for Apple's optional-disclosure exception. Reassess labels and manifests if any
of these assumptions change. Website hosting logs/cookies also need separate
assessment when the owner chooses hosting; the app manifest does not cover them.

## Store assets and metadata

`listing.txt` contains name, subtitle, keywords, promotional text, description and
URLs. `review-notes.txt` provides an account-free walkthrough and explains optional
integrations. Do not use the internal preparation paragraphs as public copy.

Still needed from the owner in App Store Connect:

- Final release version/build choice; no version bump was made here.
- Pricing, availability/territories, category confirmation, age-rating answers,
  rights and any applicable business/trader information.
- Review contact name, phone and email. The public support address alone does
  not supply all review-contact fields.
- Confirm privacy answers against actual operations and enter the public URLs.
- Use current App Store Connect device-size requirements to upload a final set
  of accurate, synthetic-data screenshots; old design fixtures are not a final
  listing set. Capture from the final build after remaining release issues close.

Suggested screenshot story, on both advertised device classes:

1. Today: a realistic session schedule and next call — “Know your next call”.
2. Event detail: client, dates and sessions — “Keep every engagement together”.
3. Payments: invoices and partial payments — “See what is still outstanding”.
4. Receipt review: editable suggested fields — “Keep receipts with the work”.
5. Optional actual system-hosted widget — “Your schedule at a glance”. Do not
   substitute the in-app widget gallery for a Home/Lock Screen screenshot.

Use fictional names/receipts. Do not imply invoice generation, automatic Wallet
access, guaranteed live widget updates or Apple Intelligence on every device.
This scope does not close production-schema, real-device, or backup-capacity work.

## Primary sources checked

- [Required-reason API guidance](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api)
- [API categories and approved reasons](https://developer.apple.com/documentation/bundleresources/app-privacy-configuration/nsprivacyaccessedapitypes/nsprivacyaccessedapitype)
- [App privacy details and collection definition](https://developer.apple.com/app-store/app-privacy-details/)
- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/), especially 1.5 and 5.1.1

## Validation of this change

- Unsigned generic-device Release build passed for app and embedded widget.
  An initial sandboxed build failed in Icon Composer asset export; the retry
  with access to Xcode system services succeeded.
- Both manifests passed plist validation and matched the copies inside the built
  app and embedded `.appex`.
- All 27 existing Python tooling tests passed; listing field lengths checked.
- `git diff --check` passed. No new UI automation or visual captures were run for
  the standard Settings links. No archive upload or App Store acceptance
  is implied. The public URLs remain unverified because DNS did not resolve.

## Settings visual follow-up

Settings now contains Help & Support and Privacy Policy, with Version below
both links. Email contact remains on the support website. The links use the
surrounding section's row padding without an additional 44-point inner height.
The isolated iPhone simulator capture workflow passed for link visibility and
absence of Email Support. Screenshots under `design/verification/public-release/`
record earlier iterations: `settings-links-iphone.png` includes Email Support;
`settings-links-compact-iphone.png` shows the final compact links before Version
was moved below them. They are development evidence, not App Store screenshots.
The temporary screenshot test was removed after capture.
