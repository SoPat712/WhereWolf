# Upstream integration

Integrated functional updates from upstream `main` through
[`247eaa25e0aa12b7ae8af59a4f719d93ea2abde3`](https://github.com/aaronpk/Overland-iOS/commit/247eaa25e0aa12b7ae8af59a4f719d93ea2abde3)
(October 28, 2026). The comparison starts at `d9125c5`, the common ancestor,
and covers 83 commits, including merges. This is an adaptation into the fork's
existing working tree; it does not create an upstream merge commit or publish
changes.

| Upstream changes | Integration in this fork |
| --- | --- |
| Native URLSession uploader and FMDB 2.7.12 | Removed AFNetworking. Retained one upload in flight, generation cancellation, committed queue acknowledgements, retry backoff, Retry-After, authentication blocking and existing HTTP payload shapes. |
| Editable trip modes, workout types, server values and icons | Added the 21 built-in modes through Funicular, plus the complete icon catalog and a SwiftUI editor. Stable IDs preserve stored settings and statistics. Names, synonyms, server values, icons, zoom and Health workout types are configurable. |
| Shortcuts, Siri, widgets and Control Center | Added the app intents, shared state, status widgets and iOS 18 controls to the existing extension. Quick actions use the same Objective-C trip lifecycle. |
| Trip Live Activity | Added a separate opt-in card with trip statistics, Send Now and End Trip. The existing tracking activity and app-only Blank Island keep their appearance and defaults. |
| iCloud Drive destination | Optional daily or per-trip GeoJSON files. Stable queue IDs and atomic writes prevent duplicate records after partial export or acknowledgement failures. Files that cannot be read are retained. |
| Apple Health workouts and routes | Optional, explicit authorization. A separate protected route store receives raw locations only after queue acceptance. Workout and route progress survive failed exports and relaunch. |
| GPS and stationary point filters | Independent normal/trip choices, off by default. The GPS choice uses missing speed and altitude accuracy as a proxy. Stationary filtering requires Motion & Fitness, tolerates uncertain readings after stopping, and retains a stopping point and hourly heartbeat. |
| Boat activity type | Available on iOS 27 in settings, remote configuration, Shortcuts and both acquisition engines. |
| WiFi-zone map editing | Added a map picker to the existing multi-network editor. Connected-network autofill, manual entry, atomic batch validation and one coordinate pair per SSID/BSSID identity remain. |
| Nonfinite JSON and send diagnostics | Nonfinite metadata becomes JSON null. Send errors remain visible when notifications are disabled. |
| Privacy manifest and dependency resources | Added the manifest for app and shared preferences. CocoaPods declares the exact manifest/privacy-resource outputs; script sandboxing stays enabled. |

The glass styling, drawer, shared native map, replay renderer and app icon are
retained. Upstream storyboard/tab-bar presentation and Icon Composer appearance
changes are not applied. The fork already had StoreKit 2 tips, custom HTTP
headers, WiFi/BSSID mappings, trip-distance caching and queue fixes; those
implementations are retained. All five Usage Presets and existing defaults are
unchanged. New export, Health, trip-card and filtering choices are opt-in.

## Storage and signing

Daily cloud files use UTC paths such as `2026/10/2026-10-19.geojson`. Trip files
use `Trips/<trip start>.geojson`. Trips Only deliberately omits records without
a trip association, including old OwnTracks records that do not contain one.
Cloud acknowledgement means the file was saved to the local iCloud container;
iOS manages subsequent synchronization. Atomic daily-file updates read and
rewrite the collection, so large daily exports have an I/O cost that still
needs device measurement.

Health export never deletes upload-queue records. It keeps pending route files
when access is unavailable, disabled or denied, and after a failed export.
Recovery reuses a saved workout before attaching a missing route.

The normal app entitlements include HealthKit, iCloud, WiFi information, Siri
and an App Group. The extension needs the same App Group. Their identifiers
derive from `OVERLAND_BUNDLE_IDENTIFIER` so an installed fork can be updated
in place.

A limited signing profile can still build the core app and ActivityKit features.
When using the existing empty entitlement file, also disable the unsupported
Health/iCloud code paths explicitly:

```text
OVERLAND_APP_ENTITLEMENTS=GPSLogger/GPSLogger.entitlements
OVERLAND_WIDGET_ENTITLEMENTS=GPSLogger/GPSLogger.entitlements
OVERLAND_HEALTHKIT_ENABLED=NO
OVERLAND_ICLOUD_ENABLED=NO
```

Without an App Group, the app keeps its trip catalog in its own preferences;
widgets show that sharing is unavailable and the background snapshot observer
stays idle. The trip control reports unavailable rather than displaying a
fabricated off state, and trip starts require location authorization. The
stateless Send Now control and app Shortcuts remain independent of shared
widget storage. Without the required entitlement, WiFi identity access remains
unavailable. These build choices do not grant missing system capabilities.

The trip symbols and SVG payloads come from Google's
[Material Symbols](https://github.com/google/material-design-icons), under
Apache License 2.0. The existing repository license is retained. SF Symbols
are sent by name, rather than exported as SVG.

## Verification

Coverage includes cloud retries, partial writes, failed queue acknowledgements,
destination changes, URLSession requests, JSON sanitization, mode migration,
Health workout/route export and recovery, stationary heartbeats, GPS filtering,
and the tracking, replay and drawer regressions. UI checks cover the mode editor,
integration defaults, capability status and the WiFi map picker.

Real Health authorization and iCloud synchronization need a capable device
profile and account. The tests use fake Health clients and local export
directories; they do not establish battery savings or real cloud delivery.

Trip Settings uses the drawer's UIKit glass effect beneath a grouped Settings
fill. The fill follows the sheet's visible height and eases through abrupt
layout updates, becoming opaque as the sheet expands and translucent again as
it collapses. Cards use the secondary grouped background color, keeping them
distinct from the grouped background in light and dark appearance. Form and
navigation backgrounds stay clear only in the glass sheet; regular Settings
navigation keeps its native grouped Form. Reduce Transparency is respected. A frame-sampled
integration test verifies intermediate opacity values, reversal and idle cleanup.

The fork also adds [workout route import](workout-import.md), independently of
upstream 1.4's Health export. It uses read-only Health access, a separate local
route collection, optional foreground import and explicit destination queueing.
Real Health access requires a capable signed build.

Holding the history ruler for 0.35 seconds enables coarse dragging. Its gain
scales with loaded history at three times the full-span sensitivity, with a
minimum of 24× and a 16384× cap. A Liquid Glass time bubble with primary text
appears above the ruler only while held, with blur material before iOS 26.
It retains every stored point. Releasing
stops coarse motion without inertia. Normal dragging and accessibility stepping
retain their existing behavior.

Map pans and pinches release replay camera following while playback continues.
Subsequent replay frames and MapKit's gesture deceleration retain the manual
camera center and zoom. The location button restores the selected-point or
whole-trail view. The tab controls sit just above the home indicator. Native
Apple Maps attribution and its working Legal link sit at the top left. The
speedometer sits above the glass Map Style, Location, Zoom In and Zoom Out controls
in one column at the top right. The zoom buttons preserve replay following, rotation and tilt, while
a manually detached camera stays free. Zooming from the whole-trail view returns
to the selected point. Each tap halves or doubles the camera distance over
0.32 seconds; repeated taps compound the requested distance.

Local replay retention is configurable from 24 to 168 hours, with 24 hours as
the unchanged default. Policy changes prune only the separate archive, reload
the presentation with ID deduplication, and filter stale in-flight results against
the current cutoff. The settings page shows aggregate point count and actual
database/sidecar file sizes. Increasing retention cannot restore deleted history.
At a continuous five-second save rate, a week contains about 120,960 points.
Typical GeoJSON records suggest roughly 80–170 MB including database overhead;
custom metadata, filters and actual recording cadence change this estimate.
The regression suite includes a route of that size and verifies every vertex
is retained while cached geometry is reused during interaction.
