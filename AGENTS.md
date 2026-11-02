# AGENTS.md

Fork of [aaronpk/Overland-iOS](https://github.com/aaronpk/Overland-iOS).

## Build

Requires Xcode 27+, CocoaPods, minimum deployment target iOS 17.0.

```bash
pod install
nice -n 10 xcodebuild -jobs 1 -workspace Overland.xcworkspace -scheme Overland \
  -destination 'platform=iOS Simulator,name=Overland Regression' build
```

- Networking uses native URLSession; FMDB 2.7.12 is the only pod. `Podfile`
  post_install bumps pod deployment targets to 17.0 and retains the conditional
  legacy AFNetworking header patch. Keep both hooks if changing pods.
  post_integrate declares the resource manifest and exact FMDB privacy-bundle
  outputs, and makes the copier write in place. Keep script sandboxing enabled.
- Simulator names: `iPhone 17 Pro` / `iPhone 17 Pro Max` (no plain "iPhone 17").
- Run only one build at a time, using `nice -n 10` and `-jobs 1` to preserve
  desktop responsiveness. Two jobs is the maximum. These are scheduling controls,
  not a hard CPU-percentage cap. The smoke script defaults to `BUILD_JOBS=1`.
- Coordinate with Iron/Light through `~/.local/share/agent-coord/` (the old
  `~/Library/Caches/agent-coord` path is a compatibility symlink). Read the
  Overland inbox before each build, test run or resource claim using
  `python3 ~/Library/Caches/agent-coord/coord.py inbox Overland`.
  Use `coord.py run compiler Overland 'operation, ~duration' -- COMMAND...`
  for builds and `coord.py run check Overland 'operation, ~duration' -- COMMAND...`
  for simulator tests or UI checks. Checks reserve both slots so they cannot
  overlap another agent's build. Claims include the active child PID and start
  time; the helper releases them when the operation exits and permits takeover
  after process exit or restart. Do not wait on a dead process. Send Iron/Light
  messages with `coord.py message Iron 'message'`. This inbox does not wake an
  idle chat. Overland and Light are Claude Code sessions, either of which may
  drive Codex workers. Message directly with `SendMessage` when the peer appears
  in `ListAgents`; the shared README records session names. Keep `coord.py` for
  resource claims. Keep one shared
  iPhone simulator across serial checks (currently Overland Regression,
  `42FA2C2F-F66C-41DB-A33C-A018165BB0D7`). Do not boot a second phone.
  Use `ci_scripts/resource_guard.py --work-root UNIQUE_DERIVED_DATA -- COMMAND...`
  inside claims for builds/checks. For simulator checks, also pass
  `--process-path EXACT_INSTALLED_APP_EXECUTABLE` to include the app launched by
  the simulator service. Under an exclusive check claim, also use
  `--simulator-pid PID` from `simctl spawn UDID launchctl managerpid` to include
  that device's system processes in pause/resume feedback. These processes are
  never terminated by the guard. Use `--target 50 --resume 35` to leave headroom beneath
  the owner's 75–80% ceiling. The guard samples total Mac CPU every 100 ms; unrelated apps and subsecond spikes
  remain outside its control. Keep checks focused. Keep the shared phone booted
  between adjacent checks only while its idle CPU load is healthy; coordinate
  shutdown if the runtime consumes sustained CPU with the app closed. Do not use `/tmp` for
  authoritative coordination files.
- Physical-device builds can override `OVERLAND_BUNDLE_IDENTIFIER` and
  `DEVELOPMENT_TEAM`; the Live Activity extension derives its identifier from
  the app's base identifier. Match an installed fork's identity for an in-place update.
  `OVERLAND_APP_ENTITLEMENTS` overrides only the main app's entitlement file;
  prefer it to a global `CODE_SIGN_ENTITLEMENTS` override so app capabilities
  are not also requested by the Live Activity extension.
  `OVERLAND_WIDGET_ENTITLEMENTS` independently overrides the extension's file.
  A limited profile can use `GPSLogger/GPSLogger.entitlements` for both, with
  `OVERLAND_HEALTHKIT_ENABLED=NO` and `OVERLAND_ICLOUD_ENABLED=NO`. This disables
  unsupported APIs; it does not grant WiFi or App Group access. See
  `docs/upstream-integration.md` for the capability-dependent features.

## Regression tests

```bash
nice -n 10 xcodebuild -jobs 1 -workspace Overland.xcworkspace -scheme Overland \
  -destination 'platform=iOS Simulator,name=Overland Regression' \
  -parallel-testing-enabled NO test
```

Use the shared phone under the resource claim and CPU guard described above.
On Xcode 27 this command can fail before any test starts with "test runner hung
before establishing connection". That result says nothing about the tests. Run
the suite in-process with a standalone XCTest runner instead, and keep the
XCTestSuite hierarchy intact: flattening it skips class setup, including the
mocked URLSession configuration.
Tests use an in-memory queue and mocked `overland.test` requests.
Background-runtime integration tests require location access on the disposable
simulator. The system-reminder integration test also requires notification
permission and `OVERLAND_NOTIFICATION_INTEGRATION=1` in the test scheme
environment; otherwise it is skipped. Do not run
these on a simulator containing important trial data; tests replace app preferences temporarily.

## Simulator resource limit

Share one booted iPhone with Light and serialize access through resource claims.
Keep it booted between adjacent checks when idle CPU is healthy. A paired Watch may run only for an essential Watch
check. Never run tests against important trial data; preserve each app's preferences.

## Run / test on simulator

```bash
./ci_scripts/smoke_test.sh            # build, install, launch
./ci_scripts/idb_ui_test.sh           # drive tabs via Facebook IDB (needs idb_companion)
xcrun simctl location booted set 45.5152,-122.6784   # set location
xcrun simctl openurl booted "overland://setup?url=https%3A%2F%2Fhost%2Fpath"  # configure endpoint
```

IDB notes: start the companion detached (`setsid idb_companion --udid $UDID &`),
connect with `idb connect localhost 10882`. Screenshot capture is off by default.
Only capture when the owner requests it; `CAPTURE_SCREENSHOTS=1` writes to `Screenshots/`.

## Architecture

- **Core stays Objective-C**: `GLManager` owns location, queueing
  (LOLDatabase/SQLite), batching, and HTTP. Don't rewrite it.
- **Upstream integrations**: `TripModeStore` owns stable mode IDs, editable
  metadata and defaults migration. `GLTripActions` shares the existing trip
  lifecycle across UI, Shortcuts, widgets and controls; ending a trip restores
  tracking only after its summary commits. App Group identifiers derive from
  `OVERLAND_BUNDLE_IDENTIFIER`. Without a shared container, app preferences
  remain local and widget snapshot work stays idle. `GLCloudFileWriter` is an
  optional queue destination; acknowledge only successful atomic file writes,
  with stable record IDs for retries. `HealthTripRecorder` receives committed
  locations into a separate protected route store and recovers unfinished
  workout/route exports. It never acknowledges upload records. New trip Live
  Activities, filters, Health and cloud export default off. Keep the original
  tracking activity and app-only Blank Island behavior.
- **Workout import**: `WorkoutRouteImporter` reads other apps' saved Health routes
  after explicit read-access setup. Manual imports and optional foreground checks
  use a separate protected SQLite collection; keep every valid point, source and
  original timestamp. Route sample revisions replace local geometry; missing routes
  remain retryable. Exclude Overland exports and remember local removals until a
  manual restore. Never feed imported points through live acquisition, trip or
  replay state. Destination queueing is explicit, GeoJSON-only, and uses stable
  point IDs with `LOLDatabase` receipts committed atomically with each queue chunk.
  Preserve pending imports when Only Latest prunes ordinary locations. Never
  automatically upload imported Health routes or write them back to Health.
  See `docs/workout-import.md` for ordering and signing constraints.
- **Screens are SwiftUI** (`GPSLogger/*.swift`). SceneDelegate creates the root
  hosting controller; `OverlandShell` stacks the shared map host, the Settings
  host, and the drawer. `MapControlPanel` is a Find My style drawer: one glass
  sheet with Tracker/Trip controls above `DrawerTabStrip` (no system tab bar).
  Settings hides the map, keeps the drawer collapsed, and takes its bottom inset
  from the drawer top. Keep per-frame drawer geometry and map-credit updates in
  UIKit. The spring requests the screen's maximum refresh rate, with the iPhone
  ProMotion plist opt-in enabled. Freeze drawer sizing while the history ruler
  drags or coasts on the active Tracker tab; update hosted controls only when
  their tab changes. Tab replacement releases the previous interaction and
  spring. New content measurements retarget an unfinished spring immediately;
  compare its target before restarting it. Ignore measurements from replaced
  hosting roots. Fitting content has no vertical scrolling or bounce; enable
  scrolling only for content exceeding the screen's available height.
  Tracker starts with a glass history ruler and one compact control row. Live
  location details and replay point details default collapsed, with explicit
  show/hide controls. Animate content resizing without fading the timeline.
  Pin the hosting content to its measured height during resizing so controls
  do not shift after the drawer. The hosting root must accept a zero minimum
  height and align its intrinsic controls to the top while measurement is pending;
  otherwise SwiftUI centers the changed content inside the previous host height.
  Details uses one labeled capsule in both modes.
  The history ruler enters coarse scrolling after a brief hold; preserve normal
  scrolling and inertia, stop coarse motion on release, and cancel it when the
  tab, scene or ruler interaction revision changes. Show the time bubble with
  Liquid Glass and primary text (blur material before iOS 26) above the ruler
  only while held, without changing drawer height; remove
  it from the window on release or cancellation. Retain every stored route point.
  Trip Settings uses `ExpandingSheetBackgroundView`: glass beneath a grouped
  Settings background that eases with the sheet's visible height. Use secondary
  grouped colors for row cards. `SettingsFormStyle` clears Form and navigation
  backgrounds only inside the glass sheet; regular Settings navigation retains
  its native grouped Form. Stop frame updates when settled, detached or
  backgrounded. Respect Reduce Transparency and dark appearance.
  The speed readout slides directly between readings, including during replay.
  Higher speeds enter from above; lower speeds enter from below. Finish each
  slide and briefly hold the reading, keeping only the latest pending value.
  Respect Reduce Motion and do not interpolate intermediate speed values.
  Shared glass helpers, drawer header/card styles, and
  settings icons live in `GlassStyle.swift`. `TipJarView` presents SoPat712's existing
  in-app tips through StoreKit 2, with a bottom recipient selector. Aaronpk's
  one-time donation links appear only for the US App Store storefront; other
  storefronts show his credit and GitHub link. `TipDonation` validates amounts
  and builds the three payment URLs. The app has no main storyboard; the launch
  storyboard remains.
- **`GLManagerBridge`** (`@Observable`) is the only bridge: views read live
  status from it and write settings through it so GLManager side effects run.
- **Route replay**: `RecentLocationHistory` archives each accepted upload record
  in a separate SQLite store, with a validated 24–168 hour retention window that
  defaults to 24 hours. `GLManager` calls it only after a successful queue commit;
  the archive never participates in queue deletion or HTTP. `HistoryPlaybackModel`
  owns only presentation state and stops its display link off the Tracker tab.
  Replay speeds are relative to `ReplayTimeline`'s movement pacing, not recorded-time
  multipliers. Default to 1× and offer 0.25×, 0.5×, 1×, 2×, 5×, 10×, 25× and 50×.
  At 1×, a moving segment lasts `sqrt(distance × interval) / 18`, never slower than
  20 m/s on the map, bounded to 16 seconds. Time keeps a share of 1/300 of the interval,
  at most 2 seconds, because a phone that logs only when it moves leaves long silent gaps.
  Invalid intervals use 0.2 seconds. Map speed grows with the square root of real speed.
  A stay is at least 5 minutes of fixes that all fit in one box 60 m across. It holds for
  1.25–3 seconds at 1×, longer for a longer stay, and at least 1 second at any rate, so
  time in one place stays visible. Playback does not follow the route inside a stay: the pose glides between
  its end points and its route directions hold, so wandering fixes do not shake the pin or
  camera. Do not widen this until it can hide real movement. The box must not drift, and
  any fix outside it ends the stay, since nothing distinguishes a stray fix from a trip
  that turned around. Trim a stay to end before movement begins, stopping at a silence of
  over 60 seconds. Outside stays the marker visits every fix; segments of at most 25 m with
  a net speed under 0.5 m/s over ±30 seconds pace as stationary. Scrubbing still shows
  exact points. Retain every point, and retain fractional progress across speed changes
  and pause/resume. Keep the chosen zoom. Original timestamps and recorded speed values remain unchanged.
  `ReplayStatusOverlay` shares the speedometer's row during replay, with the same top,
  height and corner radius, stops short of the Legal link and never takes touches. It shows the activity, time,
  altitude and distance since the last stop, updating per point rather than per frame.
  Keep its width steady, and stack readings that do not fit instead of truncating them. Recorded motion outranks speed inference,
  except that flying speeds win. Hide altitude when vertical accuracy is negative. Nearby
  payloads use a bounded prefetch cache and coalesced reads; format JSON only for
  inspection. Cache the complete route through every stored point, without
  sampling. Publish replay position and coordinate together in one `ReplayPose`.
  `ReplayRoutePresentation` retains every vertex and draws every route line with a
  plain `MKPolylineRenderer`, the only renderer MapKit draws as vector geometry at
  a constant screen width. Path renderer subclasses become bitmap tiles that stretch
  between zoom levels, so do not use them for routes.
  Dots show only the route ahead, and none may exist at or behind the marker: logged points
  can be over 100 m apart, and the blue tail floats above the map, so anything beneath it
  shows when the two briefly disagree. Each section has its own dotted line, drawn backward
  so the dash pattern stays put. The map's line starts at the next step ahead of the marker,
  and a foreground `ReplayTrailLayer` draws the dots up to it in the marker's transaction.
  They sit beneath the blue sections, which are
  bounded to 1,024 segments and 100,000 map points of length; isolate long jumps.
  A short shared tail preserves joins. The active section's blue line is an exact
  vertex prefix, replaced at 64-point boundaries while retaining every intervening vertex.
  Going forward the previous prefix stays until the next boundary, so a replacement
  never shows a gap. Scrubbing updates only crossed sections and the active prefix.
  Add and remove section overlays instead of changing `strokeColor`, which can take
  over a second to appear. End the foreground tail at the marker's exact pose
  coordinate. Never use `strokeEnd` percentages for replay progress.
  Blue, including trip and imported workout routes,
  is 2.5 points wide; future dots are 1.25, with
  round caps. A bounded `ReplayTrailLayer` draws the last 128 route segments and
  interpolated endpoint in the marker's own projection/transaction, covering
  asynchronous overlay redraw at the moving tip. Retain the complete cached
  route beneath it. Cache unchanged projections; hide the layer offscreen.
  Replay uses
  Apple's `MKMarkerAnnotationView`, without an entrance animation. Rotate only
  its arrow glyph along the active route segment, using the current map projection
  so it follows camera rotation and pitch. Ease the geographic heading through
  corners over the shortest arc, preserving angular velocity when retargeted.
  Apply the current camera projection after smoothing so rotating the map does
  not make the arrow lag. Stop the heading display link when settled or hidden,
  and respect Reduce Motion. Cache segment directions, retain the
  previous direction at stationary fixes, and show a neutral dot if no direction
  exists. A native `CAShapeLayer` projects its pale blue accuracy area beneath the marker, centered on
  the same interpolated coordinate. The radius uses recorded horizontal accuracy in meters, blending
  neighboring values during playback; omit it when accuracy is unavailable.
  Hide the live-location dot in replay.
  Project the native pin after camera updates and MapKit layout, preserving its
  `centerOffset`, so deferred annotation positioning does not trail playback.
  Native camera follow uses that same pose, without waiting for the outer camera
  binding to catch up.
  Rebuild route sections only when stored points change.
  Defer presentation reloads during ruler interaction and playback, then coalesce
  them on release or pause. Never defer raw collection or uploads. Retention changes
  force a deduplicated snapshot load, apply the current cutoff to in-flight results,
  and preserve the selected coordinate, route index and ruler position together.
  Keep pruning and storage-summary work on the archive's serial queue;
  only the history settings page requests aggregate storage statistics.
  During replay the location button toggles between following the selected
  coordinate and fitting the entire trail above the drawer. Only the ruler's
  Live action exits replay. Overview persists during scrubbing and playback;
  preserve the point-following zoom when toggling back.
  After manual map gestures, the location button first chooses the closer point
  or trail zoom; once anchored it toggles between them. Send explicit camera
  animation requests across the separate map host, keep playback from cancelling
  that transition, and honor Reduce Motion. `MapCameraTransition` drives the full
  move with a one-second display link, logarithmic zoom and coordinated panning.
  Complete the curve instead of cutting off MapKit's animation with a timeout.
- **Visible map center**: `NativeMapSurface` keeps the live or selected replay
  coordinate centered between the top safe area and the closed drawer's top. As in
  Find My, opening, closing or dragging the drawer must not move the map. The target
  shifts only when an open drawer would otherwise cover the coordinate, stopping 48
  points above the drawer, preserving zoom and heading. Replay overview fits the trail
  when requested and does not refit as the drawer moves. Manual map gestures release the camera anchor while replay
  continues, including after gesture deceleration and at the final frame.
  Selecting another point or Show My Location resumes anchoring.
  While a finger is on the map, pause automatic camera corrections and camera
  transition time so MapKit can take the pan; the contact recognizer must never
  recognize or prevent gestures. Explicit recenter requests must reach the map
  even when its cached request is already follow.
  Offset programmatic cameras before animating, and ignore subpixel follow
  jitter. Do not animate to the full-map center and correct it afterward.
  Live presentation uses a critically damped `LiveMapMotion`, preserving velocity
  as fixes arrive and settling at the last fix without extrapolating. Move the
  native Apple location view and camera from that same displayed coordinate.
  `PresentedUserLocationView` retains Apple's drawing while constraining native
  position assignments to the current presentation. Keep the chosen zoom
  and heading. Stop presentation links when settled, hidden or offscreen. An inactive
  scene is still on screen, as when sliding up to the app switcher, so the map keeps its
  location dot, route and markers until the scene enters the background. Raw
  locations, recorded history and tracking settings do not use these display values.
  Keep MapKit's native credit and working Legal link at the top left, just under
  the clock on phones with a tall status area. Keep the
  speedometer above Map Style, Location, Zoom In and Zoom Out glass controls
  in one column at the top right. Place tab controls just above the home indicator;
  their geometry is measured from Find My screenshots on a 402-point phone. Closed, the
  capsule is 346 wide and about 76 tall with its bottom 28 points up, clear of the home
  indicator. Open, the sheet is 382 wide with its bottom 8 points up, and the 352-wide tab
  strip sits 20.5 points up. Blend between them as the drawer moves. Lay the strip out at its
  open size and scale it evenly when closed; do not stretch it sideways. Zoom buttons
  preserve replay following and rotation; manual map gestures remain free.
  Move the native attribution views in UIKit without changing map margins or
  the camera projection. Give Legal a 44-point touch target, try its native
  accessibility action, and fall back to Apple's Maps legal page if unavailable.
- **`OverlandLocationEngine`** uses iOS 17 `CLLocationUpdate.liveUpdates` for
  Best accuracy with automatic pausing. An active Status or Minimal Live Activity supports
  background updates with the indicator off. With Always access and no active
  supporting Live Activity, indicator-off tracking falls back to `CLLocationManager`.
  Blank also uses this fallback; its app-only activity did not maintain live-update
  delivery in the iOS 27 background route check.
  `CLBackgroundActivitySession` is used only for live updates that request or
  require the indicator. Reconcile sessions when normal/trip indicator settings,
  authorization or Live Activity state changes; radius stopping invalidates them.
  The opt-in `GLUseNewLocationEngine` toggle selects live updates for any
  continuous mode without changing preset values. It defaults off. With it off,
  custom/navigation accuracy or disabled pausing use CLLocationManager as before.
  Live updates cannot enforce numeric accuracy or a pause-off policy. Engine
  state includes iOS 18 diagnostics; stream errors get at most three retries.
  Delegate paths also handle significant-change, region, and visit events.
  Live updates feed `-[GLManager processEngineLocation:]`. Its dedicated info
  explains benefits, accuracy/pause tradeoffs, trip behavior and background fallback.
- **Watch app**: `OverlandWatch` is a small companion for managing tracking from the
  wrist: tracking on/off, retry updates, start/end trip, send now and Usage Preset. It
  holds no location or queue data. `OverlandWatchLink` activates `WCSession` at launch
  and sends each command through the same calls as the phone's controls, with the same
  limits and Stop confirmation. `GPSLogger/Shared/WatchLink.swift` defines the messages
  and belongs to both targets. Commands use live `sendMessage` only and are never queued,
  because a Stop or End Trip delivered later would do the wrong thing. Status reaches the
  watch through `updateApplicationContext`, at most once a minute for location updates
  and only with the watch app installed. Tracking must never depend on the link. Keep the
  watch version and build number equal to `GPSLogger/Info.plist`.
  A signing profile without the watch bundle identifier can build the phone app alone with
  `OVERLAND_WATCH_SIGNING=NO EXCLUDED_SOURCE_FILE_NAMES=OverlandWatch.app`.
- **Reminder action**: the missed-update reminder offers a background Resume Tracking
  action, which also appears when iOS mirrors the notification to a watch and runs on
  the iPhone without a watch app. A background launch restores tracking through
  `restoreTrackingState`; the action then calls `refreshLocation`. It must not override
  Stop or a pause. iOS generally does not relaunch force-quit apps.
- **Optional tracking policies** live in `GLTrackingPolicy` and are configured
  through the validated `GLAdvancedTrackingOptions` dictionary in `GLManager`.
  They default off and are independent of all five Usage Presets. Keep acquisition,
  point selection and upload scheduling separate. Adaptive tracking confirms a
  stop from fresh raw fixes before WiFi replacement, then requests coarse accuracy
  through the original engine; movement restores saved engine settings. Retain
  coarse updates and an Always-authorized exit region. Motion confirmation defaults
  required, with a separate GPS-only choice and separate trip opt-in. Motion
  classification permission is requested only by its explicit UI action (legacy
  trip step queries also use Motion & Fitness); query timestamped history
  on start/foreground and bound it to 512 entries. Motion cannot wake suspension.
  Guard asynchronous results by generation and respect Stop and radius pause.
  Optional OR selection includes enabled distance/time/turn triggers; default AND
  remains unchanged. Jump filtering accounts for reported uncertainty and permits
  corroborated relocation. Raw quality state is separate from the committed-fix
  baseline. Identical acquisition configurations must not restart hardware;
  reconcile remote settings in one batch. Preserve persisted radius pause on
  relaunch and ignore pre-pause callbacks for resumption.
  Terminal live-stream errors latch after three retries and fall back to
  `CLLocationManager` once; cancellation and replaced tasks must not trigger fallback.
  Independent `background_recovery` defaults off and retains significant-change
  monitoring alongside Standard tracking and trips with Always access and device
  support. Both already monitors significant changes. Never override Stop,
  radius pause or event-only choices; do not treat coarse events as a fixed wake
  schedule. Keep the Background screen's system refresh status and info current.
- **Location update health**: `GLLocationHealthPolicy` separates callback silence,
  outdated readings and saved-point rejection using monotonic elapsed time.
  `automatic_location_retry` and `location_health_log` default off independently;
  `location_retry_after` is validated to 60–1,800 seconds, default 120. Allow at most
  three restarts per app session without a fresh raw reading, with increasing
  delays. Keep the terminal live-stream failure latch; do not restart on filter
  rejection. Respect Stop, lost access, event-only modes, automatic/radius pauses
  and adaptive idle mode. The health timer is independent of scene visibility
  and cannot wake suspension. Its deadline must not replace the reminder deadline.
  `GLLocationSaveAllowance` protects each received batch, ends once on expiration
  or completion, and waits behind queued archive/Health writes only after a queue
  commit. Health logs use a serial queue, protected atomic writes, backup exclusion
  and a strict metadata allowlist; retain at most 200 events for seven days.
  Never store coordinates, endpoints or credentials, or upload logs automatically.
- **`OverlandUploadScheduler`** registers one network-required `BGProcessingTask`
  at launch. Background scheduling and connection-return retries are independent,
  default-off choices. Both call the existing uploader; retain its one-request
  limit, 20-request yield, backoff, Retry-After and authentication block. Coalesce
  equivalent schedules, complete expired tasks once, and preserve pending intent.
  `NWPathMonitor` runs only when enabled, and only a false-to-true transition can
  clear eligible transport backoff. iOS schedules processing opportunistically.
  Optional iOS 18 `CLServiceSession` retains already-Always authorization intent;
  invalidate it on Stop, option-off or lost authorization.
- **Background helpers**: `OverlandBackgroundRuntime` controls the ActivityKit
  extension and opt-in `SilentAudioSession`. Live Activity staleness mirrors the
  pending `reminder` notification deadline. Keep its scheduling rules in
  `GLManager`; do not drive activity staleness from another timeout. The shared ActivityAttributes
  source belongs to both the app and `OverlandTrackingActivity` targets. Blank uses
  `IslandOnlyTrackingAttributes` in the app target only. Do not register it in the
  widget extension: the unrendered activity is what avoids the Lock Screen card.
  End and recover both activity types, and replace the type when appearance changes.
  Relevance remains zero. It ranks Overland's own activities, not other apps;
  iOS controls which activity occupies the main Island or a detached bubble.
  Silent audio checks playback only while opted in. Unexpected stops get three
  bounded retries; calls and media-service loss block automatic recovery.
- Settings sliders use common-value detents with exact numeric entry. Commit
  slider drafts on release, preserving saved defaults and all Usage Presets.
  Requested accuracy controls collection; Max Saved-Point Error filters returned
  fixes and is shared with trips. Do not couple those settings implicitly.
  App preferences live in the app; no Settings.bundle is shipped. Sending owns
  tracking stats and confirmed queue deletion. Delete only the pending queue,
  refuse in-flight batches, and reset retry state only after a successful commit.
  Preserve import receipts, local history, saved workouts and active trips.
- Notifications remain opt-in. Problems Only suppresses routine status and trip
  messages while retaining upload errors and the existing missed-update reminder.
- WiFi zones: `WifiZones` defaults key, array of `{name, latitude, longitude[,
  bssid]}` dicts; legacy single-zone keys migrate on first access. Matching is
  SSID-first, BSSID tiebreaker. Canonical SSID/BSSID identity has one coordinate
  pair; upsert it when reassigned and permit different BSSIDs under one SSID.
  Batch saves validate every network before changing preferences. Keep the flat
  schema. The multi-select editor uses connected, observed and configured networks,
  with manual entry; do not imply nearby scanning or access to iOS's saved networks.
  Observed identities are bounded to 64 and persisted only when changed. WiFi
  identification requires a capable signing profile and location authorization.

## Tracking constraints

- Gate only presentation timers, replay loads and trip-map queries on scene
  visibility. Location processing, storage, uploads, reminders and Live Activity
  updates must work without an active scene. Silent audio remains opt-in.
- Keep all five preset dictionaries and existing defaults unchanged. The new
  engine toggle is independent of preset recognition. Automatic pauses end trips.
- LOLDatabase returns transaction success; accepted-fix and trip-finalization
  state may advance only after the queue commit. Replay is not an acknowledgment.
- Uploads keep one request in flight, yield after 20 drain requests, persist
  retry/flush intent, and retain records on failure. GeoJSON and OwnTracks keep
  their existing request shapes. See `docs/tracking-improvements.md` for sources.

## Before App Store release

- [ ] Remove `TestFlightDiagnostics.swift`, `DiagnosticsView.swift`, their Settings
  and AppDelegate entry points, and `OVERLAND_TESTFLIGHT_DIAGNOSTICS` from both
  Swift and Objective-C Release settings. Verify the collector is absent from
  the App Store binary. TestFlight reports stay in the app container, excluded
  from backups, until the user explicitly shares one.

## Code style

Match the existing Obj-C: `#pragma mark -` sections, terse names, flat logic
with early returns, `static NSString *const` defaults keys, direct
NSUserDefaults access. No comments restating what code does. Swift: one file
per screen, flat `Form`/`Section`, and `@Observable` for the bridge and shared
replay presentation state. Keep Liquid Glass APIs behind `if #available(iOS 26, *)`
with `.borderedProminent` /
`.ultraThinMaterial` fallbacks.

## Writing

For documentation, comments, UI copy and prose reviews, keep API names,
attribution, code examples, and technical caveats. Describe current behavior; remove stale progress notes and unsupported claims.
Comments should explain constraints or decisions that the code does not show.

## Remotes

- `origin` → this fork (push here)
- `upstream` → aaronpk/Overland-iOS (fetch only; never push without owner approval)
