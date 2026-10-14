# Track location and weather verification

Verified October 13, 2026. This is an implementation check, not a release.

## Behavior

- Native Apple Maps search selects a track; only its Place ID is saved and synced.
- Job details show weather for booked, on-site jobs overlapping today through the next nine days in the venue timezone.
- Daily conditions, high/low, precipitation probability and wind accompany expandable hourly forecasts covering call/session times.
- The device shares forecasts between jobs at the same track and persists a rolling 24-hour attempt limit, including failures. It does not share forecasts between users or through iCloud.
- Forecasts have a fetch timestamp and become visibly outdated after Apple's expiration date. They stop displaying after 24 hours. This stale-display policy is the user's initial product assumption, not confirmation of Apple's permitted retention period.

## Evidence

- Simulator build passed.
- All 31 unit tests passed: 7 weather/cache tests, 20 persistence/migration tests and 4 calendar tests. Migration coverage includes V1–V6 into V7.
- Both weather UI workflows passed on iPhone and iPad: forecast/hourly details in light mode and dark mode with accessibility text, plus track search, selection, save and removal.
- All 26 release-tooling tests passed, including rejection of a provisioning profile without WeatherKit.
- Development CloudKit schema initialization/export and the local schema consistency check passed. The schema adds only the track Place ID field and its generated asset field.
- A live native MapKit search returned Daytona International Speedway with a Place ID and America/New_York timezone. Weather UI tests use synthetic data and do not prove live WeatherKit access.
- Result bundles: `build/weather-iphone-reviewed.xcresult` and `build/weather-ipad-reviewed.xcresult`.
- Ten reviewed captures: `build/weather-review/weather-{iphone,ipad}-{forecast-light,forecast-dark-large,hourly-light,hourly-dark-large,track-selection}.png`.
- Independent Impeccable finish review returned **ship**, with no material fixes. It confirmed readable attribution, native Maps confirmation, freshness labels and accessibility reflow across all ten captures. The design documentation review required no changes to the existing visual contract.

## Remaining release setup

The signed device build could not proceed: Xcode reported no configured account, and the existing provisioning profile lacks WeatherKit. Enable the WeatherKit capability and App Service for the app identifier, regenerate profiles, then verify live weather on a signed device. Deploy the V7 CloudKit schema to Production and verify it before distributing the app. No Production schema deployment or app upload was performed.

The existing Daybook design direction was preserved. The design context tool reported a pre-existing stale Impeccable sidecar; it was not changed as part of this feature.
