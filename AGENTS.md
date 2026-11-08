# AGENTS.md

Fork of [aaronpk/Overland-iOS](https://github.com/aaronpk/Overland-iOS).

The app is named WhereWolf throughout: bundle identifiers (default `me.joshpatra.WhereWolf`),
`WHEREWOLF_*` build settings, defaults keys, Swift types and source files, the Xcode project,
workspace, scheme, targets (`WhereWolf`, `WhereWolfTests`, `WhereWolfTrackingActivity`, `WhereWolfWatch`)
and Swift module (`WhereWolf-Swift.h`). Overland appears only where it means the original app:
credits to Aaron Parecki's Overland, the `upstream` remote, the upload format that Overland
servers accept, and the `overland://` URL scheme, registered beside `wherewolf://` so setup
links from those servers keep working.
README screenshots live in `docs/screenshots` and are linked through
raw.githubusercontent.com on `main`.
GitHub Pages serves support at `https://sopat712.github.io/WhereWolf/` and privacy
at `/WhereWolf/privacy/` from `docs`. Keep internal Markdown docs excluded in
`docs/_config.yml`; preserve screenshots at their existing paths.

## Build

Requires Xcode 27+, CocoaPods, minimum deployment target iOS 17.0.

```bash
pod install
nice -n 10 xcodebuild -jobs 1 -workspace WhereWolf.xcworkspace -scheme WhereWolf \
  -destination 'platform=iOS Simulator,name=WhereWolf Regression' build
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
- Coordinate with liteweight through `~/.local/share/agent-coord/`. Nothing lives
  under `~/Library/Caches`, which Mac cleaners wipe. Read the
  WhereWolf inbox before each build, test run or resource claim using
  `python3 ~/.local/share/agent-coord/coord.py inbox WhereWolf`.
  Use `coord.py run compiler WhereWolf 'operation, ~duration' -- COMMAND...`
  for builds and `coord.py run check WhereWolf 'operation, ~duration' -- COMMAND...`
  for simulator tests or UI checks. Checks reserve both slots so they cannot
  overlap another agent's build. Claims include the active child PID and start
  time; the helper releases them when the operation exits and permits takeover
  after process exit or restart. Do not wait on a dead process. Send liteweight
  messages with `coord.py message liteweight 'message'`. This inbox does not wake an
  idle chat. WhereWolf and liteweight are Claude Code sessions, either of which may
  drive Codex workers. Message directly with `SendMessage` when the peer appears
  in `ListAgents`; the shared README records session names. Keep `coord.py` for
  resource claims. Keep one shared
  iPhone simulator across serial checks (currently WhereWolf Regression,
  `42FA2C2F-F66C-41DB-A33C-A018165BB0D7`). Do not boot a second phone.
  Use `ci_scripts/resource_guard.py --work-root UNIQUE_DERIVED_DATA -- COMMAND...`
  inside claims for builds/checks. For simulator checks, also pass
  `--process-path EXACT_INSTALLED_APP_EXECUTABLE` to include the app launched by
  the simulator service. Under an exclusive check claim, also use
  `--simulator-pid PID` from `simctl spawn UDID launchctl managerpid` to include
  that device's system processes in pause/resume feedback. These processes are
  never terminated by the guard. Stop a guard only with SIGTERM or SIGINT so it
  resumes what it paused; SIGKILL leaves the shared phone's system processes
  stopped. Use `--target 70 --resume 55` to leave headroom beneath the owner's
  75–80% ceiling. The guard samples total Mac CPU every 100 ms; unrelated apps and
  subsecond spikes remain outside its control. Keep checks focused. Keep the shared phone booted
  between adjacent checks only while its idle CPU load is healthy; coordinate
  shutdown if the runtime consumes sustained CPU with the app closed. Do not use `/tmp` for
  authoritative coordination files.
- Physical-device builds can override `WHEREWOLF_BUNDLE_IDENTIFIER` and
  `DEVELOPMENT_TEAM`; the Live Activity extension derives its identifier from
  the app's base identifier. Match an installed fork's identity for an in-place update.
  `WHEREWOLF_APP_ENTITLEMENTS` overrides only the main app's entitlement file;
  prefer it to a global `CODE_SIGN_ENTITLEMENTS` override so app capabilities
  are not also requested by the Live Activity extension.
  `WHEREWOLF_WIDGET_ENTITLEMENTS` independently overrides the extension's file.
  A limited profile can use `GPSLogger/GPSLogger.entitlements` for both, with
  `WHEREWOLF_HEALTHKIT_ENABLED=NO` and `WHEREWOLF_ICLOUD_ENABLED=NO`. This disables
  unsupported APIs; it does not grant WiFi or App Group access. See
  `docs/upstream-integration.md` for the capability-dependent features.

## Regression tests

```bash
nice -n 10 xcodebuild -jobs 1 -workspace WhereWolf.xcworkspace -scheme WhereWolf \
  -destination 'platform=iOS Simulator,name=WhereWolf Regression' \
  -parallel-testing-enabled NO test
```

Use the shared phone under the resource claim and CPU guard described above.
On Xcode 27 this command can fail before any test starts with "test runner hung
before establishing connection". That result says nothing about the tests. Run
the suite in-process with a standalone XCTest runner instead, and keep the
XCTestSuite hierarchy intact: flattening it skips class setup, including the
mocked URLSession configuration.
`python3 ~/.local/share/agent-coord/wherewolf/wherewolf/verify.py` builds for testing,
runs the standalone suite twice and checks native Forms, tabs and setup accessibility
without screenshots. Its build log and `full-1.json` / `full-2.json` stay in that
`wherewolf` folder; its DerivedData is isolated under `wherewolf/three-features`.
Test the smallest thing first: `verify.py --only "Class,Class/testMethod"` builds and runs
just those tests once (class setup intact, no screen audits, result in `focused.json`), and
`verify.py --last-failed` reruns only what failed last time. The two full runs are for
landing, not progress checks. Triage a flaky test by running it alone several times; fix
the timing assumption rather than raising timeouts. Run one heavy test run at a time.

Tests use an in-memory queue and mocked `wherewolf.test` requests. Objective-C tests
reach app Swift types through protocols and `NSClassFromString`; never import the
app's generated Swift header into the test target.
Background-runtime integration tests require location access on the disposable
simulator. The system-reminder integration test also requires notification
permission and `WHEREWOLF_NOTIFICATION_INTEGRATION=1` in the test scheme
environment; otherwise it is skipped. Do not run
these on a simulator containing important trial data; tests replace app preferences temporarily.

## Simulator resource limit

Share one booted iPhone with liteweight and serialize access through resource claims.
Keep it booted between adjacent checks when idle CPU is healthy. A paired Watch may run only for an essential Watch
check. Never run tests against important trial data; preserve each app's preferences.

## Run / test on simulator

```bash
./ci_scripts/smoke_test.sh            # build, install, launch
./ci_scripts/idb_ui_test.sh           # drive tabs via Facebook IDB (needs idb_companion)
xcrun simctl location booted set 45.5152,-122.6784   # set location
xcrun simctl openurl booted "wherewolf://setup?url=https%3A%2F%2Fhost%2Fpath"  # configure endpoint
```

IDB notes: start the companion detached (`setsid idb_companion --udid $UDID &`),
connect with `idb connect localhost 10882`. Screenshot capture is off by default.
Only capture when the owner requests it; `CAPTURE_SCREENSHOTS=1` writes to `Screenshots/`.

## Architecture

- **Onboarding**: nine native glass panels float over the existing, non-interactive
  map: Welcome, Permissions, Destination, Tracking, Fine-Tune, Sending, Live Activity,
  Staying Active and Done. Tracking is a six-row native inset preset list; Fine-Tune
  owns accuracy, distance/time menus and pause/visit toggles. Default text never
  scrolls on 390/402-point phones; use `ViewThatFits` for larger text only.
  Summary preset edits return to Tracking; accuracy/filter edits to Fine-Tune.
  `OnboardingModel` owns order, live status and injected actions; permissions
  run only from buttons. Settings' first row reopens it. Done and Skip All set
  `WhereWolfOnboardingCompleted`; only Done's Start Tracking starts recording.
  Skip advances a step; its menu and accessibility action offer Skip All.
  Presets and edits apply through `GLManagerBridge` immediately; finishing must
  not reapply a preset over Custom edits. Scene and pasted setup links share its
  validated parser. Health uses the export/import request types with
  `getRequestStatusForAuthorization`: Allow before review, Reviewed afterward,
  never read approval or Open Settings. Manage in Health uses a checked
  `x-apple-health://` URL; hide its button if unavailable and the row without HealthKit.
  Other permission Settings actions use the injected main-actor URL opener.
  The map enables its location dot only with existing authorization.
- **Core stays Objective-C**: `GLManager` owns location, queueing
  (LOLDatabase/SQLite), batching, and HTTP. Don't rewrite it.
- **Upstream integrations**: `TripModeStore` owns stable mode IDs, editable
  metadata and defaults migration. Custom symbols use `wherewolf.*`; lookup accepts
  the old `where.*` names for saved modes and remote configuration.
  `GLTripActions` shares the existing trip
  lifecycle across UI, Shortcuts, widgets and controls; ending a trip restores
  tracking only after its summary commits. App Group identifiers derive from
  `WHEREWOLF_BUNDLE_IDENTIFIER`. Without a shared container, app preferences
  remain local and widget snapshot work stays idle. `GLCloudFileWriter` is an
  optional queue destination; acknowledge only successful atomic file writes,
  with stable record IDs for retries. `HealthTripRecorder` receives committed
  locations into a separate protected route store and recovers unfinished
  workout/route exports. It never acknowledges upload records. New trip Live
  Activities, filters, Health and cloud export default off. Keep the original
  tracking activity and app-only Blank Island behavior. `GLTripActions` also sets the
  Home Screen quick actions on every trip start or end, including background ones, and
  when the scene resigns active. Siri phrases name trip modes with or without "trip";
  `AppShortcutParameters` gives Siri the modes at launch and when they change.
  `IntentDonations` donates trip and tracking changes made with WhereWolf's own controls;
  intents run by the system are not donated again.
  `INAlternativeAppNames` in the phone's Info.plist supplies "Werewolf" and
  "Where Wolf" for the App Shortcuts' application-name token. Keep the display
  name WhereWolf and the token in every phrase.
  The Today widget shares coordinate-free daily totals from `RecentLocationHistory`,
  computed incrementally on its queue with replay distance rules and the existing minor-reload budget; its timeline resets at local midnight.
- **Workout import**: `WorkoutRouteImporter` reads other apps' saved Health routes
  after explicit read-access setup. Manual imports and optional foreground checks
  use a separate protected SQLite collection; keep every valid point, source and
  original timestamp. Route sample revisions replace local geometry; missing routes
  remain retryable. Exclude WhereWolf's own exports and remember local removals until a
  manual restore. Never feed imported points through live acquisition, trip or
  replay state. Destination queueing is explicit, GeoJSON-only, and uses stable
  point IDs with `LOLDatabase` receipts committed atomically with each queue chunk.
  Preserve pending imports when Only Latest prunes ordinary locations. Never
  automatically upload imported Health routes or write them back to Health.
  See `docs/workout-import.md` for ordering and signing constraints.
- **Screens are SwiftUI** (`GPSLogger/*.swift`). SceneDelegate creates the root
  hosting controller; `WhereWolfShell` uses `UITabBarController` with a regular
  Settings child, one persistent map host moved between the map-tab placeholders,
  and the drawer above all tab pages. `MapControlPanel` is a Find My style drawer:
  one glass sheet with Tracker/Trip controls above `DrawerTabStrip`. The system
  bar is hidden on those tabs. Settings hides the map and uses the native bar
  and safe area. Both bars call the root's `selectTab`. The drawer's existing
  display-link spring tweens its current frame and corner radius into the native
  bar's measured glass platter, fading its controls and grabber. The tab items keep
  their size: only the strip's side insets and margins shrink to the system bar's, so
  at the handoff each icon sits on its native counterpart. UIKit lays out
  the transparent native bar from the start so Settings' safe area stays fixed;
  the landing frame exchanges the bars without a native animation. A native bar tap updates the
  drawer strip's selection before the handoff, since SwiftUI publishes it a few frames later. The
  shell lays Settings out behind the map for one pass a second after it first appears, since SwiftUI
  builds hosted views only in a window, so the first switch is as quick as later ones. Returning
  tweens from the platter to the closed drawer. Retarget from the current geometry
  on interruption; Reduce Motion swaps instantly. A completed handoff clears its
  spring and geometry; leaving native Settings starts from a fresh platter measure.
  Ignore old SwiftUI selection renders until an eager native selection is acknowledged
  or a later tab activation replaces it. Replaced springs cannot finish a newer handoff.
  Measure layout bounds of visible native item controls or button-trait views,
  ignoring item press transforms, expanded by the measured 4-point
  platter padding; fall back to the container frame. Keep the native bar transparent
  after UIKit's unhide/layout and through every tween frame until handoff.
  Before iOS 26, tween to the full-width native bar with square
  corners. Keep per-frame drawer geometry and map-credit updates in UIKit. The
  spring requests the screen's maximum refresh rate, with the iPhone
  ProMotion plist opt-in enabled. Freeze drawer sizing while the history ruler
  drags or coasts on the active Tracker tab; update hosted controls only when
  their tab changes. Switching between Tracker and Trip fades a snapshot of the previous
  controls out over the new ones inside the clipping content view while the drawer resizes; a closed
  drawer and Settings' bar handoff swap without it. Outside a bar tween, tab replacement releases the previous
  interaction and spring. New content measurements retarget an unfinished drawer
  settle immediately; compare its target before restarting it. Ignore measurements from replaced
  hosting roots. Fitting content has no vertical scrolling or bounce; enable
  scrolling only for content exceeding the screen's available height.
  Trip has no title: while idle a scrolling row of mode buttons, ending in Edit (Trip Modes), sits above a
  green Start Trip button beside the Trip Settings button. Recording replaces the row with a card whose
  breathing red dot names the mode above elapsed time, redrawn on each whole second since the start,
  and a grid of distance, average speed (pace on foot),
  top speed and climb, and the button turns
  into a red End Trip with a symbol replace and start/stop haptics; Reduce Motion crossfades and keeps
  the dot still. Scrub a trip with the Tracker ruler; Trip has no point timeline.
  The trip database stores each fix's speed and altitude with their accuracies; `TripStatsAccumulator`
  keeps the top speed with speed accuracy within 5 m/s and counts climbs of at least 5 m with vertical
  accuracy within 10 m, replaying the stored fixes after a restore or a late batch.
  While idle, Trip lists the five newest of up to 20 finished trips from `TripLog`: mode, distance, start
  and duration, without coordinates, on this device only and outside Backup & Sync. GLManager records each
  after its summary commits. A row opens its start on the Tracker ruler, after history loads if needed,
  and is disabled once the trip has left local history.
  `TripTabPolicy` selects Trip when the scene becomes active during a trip it hasn't shown yet,
  once per trip start, never while active or with setup presented.
  Tracker starts with a glass history ruler and one compact control row. Live
  location details and replay point details default collapsed, with explicit
  show/hide controls. Animate content resizing without fading the timeline.
  Pin the hosting content to its measured height during resizing so controls
  do not shift after the drawer. The hosting root must accept a zero minimum
  height and align its intrinsic controls to the top while measurement is pending;
  otherwise SwiftUI centers the changed content inside the previous host height.
  Details uses one labeled capsule in both modes.
  The history ruler is 56 points high, with a 16-point top label lane. Cached
  `HistoryLandmarks` point-index metadata builds on a utility queue, coalescing new
  points to at most once per 30 seconds and promptly rebuilding for snapshots, expiry,
  retention, Wi-Fi Places, calendar or locale changes. A reload that both expires and appends
  rebuilds once, after appending; opening Go To starts any pending build at once. Generation checks discard stale
  builds; pending builds retain the previous landmarks with indices clamped to current points.
  Minute marks use time-zone arithmetic and visible labels format through a bounded cache.
  Stop navigation and Go To share the existing `ReplayTimeline` stays.
  UIKit draws only visible landmarks alongside the bars, including during scale easing.
  Local-midnight dividers and weekday labels outrank stop labels, which outrank no-data labels, then time
  labels; time marks coarsen through 1/5/15 minutes, 1 hour and 6 hours to keep at least
  60 points between labels. Stop capsules use the nearest Wi-Fi Place within
  `GLWifiPlaceMatchDistance` of the stay center, otherwise gray `mappin` and a duration.
  The ruler shows time (`HistoryRulerSpacing`). A slot is the median interval between fixes outside stops;
  each step outside a stop is as wide as its duration in slots and never under one, so a bar covers the same
  time wherever the phone was moving and every fix stays reachable. A stop is one stretch of its whole
  length, with its fixes placed by time. Close up a stretch or step longer than 8 slots is capped at 8 bars
  plus 3 for each doubling, so it is never a wall of bars; zoomed out time past 5 minutes counts as
  5 minutes × √(minutes / 5), so stops stay smaller than the drives between them and the coarsest step still
  fits the whole history. Time and day marks sit at their exact time between fixes. Scroll offsets, stop
  snapping, label spacing and the map's ruler fit window go through that spacing; new landmarks apply only
  while the ruler is still. A stop's label centers
  on it, falling back to the symbol alone where labels collide. A silence of at least Coverage's 10-minute
  gap between stored fixes outside a stop gets a red band and a red "No data" label with its length; a stop
  explains its own silences, since a phone that logs only when it moves goes quiet while parked.
  Keep every stored point.
  The buttons beside Play jump to the previous/next arrival or departure through the
  existing selection path; disable at the ends and name the target for VoiceOver.
  The time beneath the ruler opens the native Go To sheet while browsing; Live keeps
  its plain label. Go To uses medium/large detents, compact date/time pickers bounded
  from the oldest retained point to now, and selects the nearest stored point.
  Its day sections, and the stops and movements within each day, are newest first, with
  shared activity/distance calculations and a tinted Viewing badge on the selected row. It uses the
  glass Settings sheet styling; day headers read Today, Yesterday or the date with the day's stop count
  and distance, and rows show a colored icon, the time range, the duration and any distance.
  Selecting a row jumps to its start and dismisses. Cancel and Go use native toolbars.
  Pinching the history ruler changes a scale retained across tabs, playback and pinches at
  Live, without defaults; returning to Live from history resets it to every point. Spread for fewer points per bar;
  pinch together for more. Use every 1–2–5 step from one point per bar through the
  step that rounds up to cover loaded history, stops and silences included, in one ruler width, or 48 time ticks
  before points load. Clamp when the ladder shrinks. Pinches continuously divide the
  displayed points per bar by finger scale, with light log-space rubber banding at
  the ends. Keep the needle and selection anchored, including at Live. Crossfade
  neighboring ladder bars at the continuous density, drawing shared ticks once.
  Release projects velocity by 0.12 seconds, at most one extra step, then settles in
  log space over 0.22 seconds before committing once. Pinches and settles have no
  haptics; a new pinch takes over the displayed scale, while other interactions
  finish the settle first. The pinch bubble names the nearest step without animation.
  Bar spacing (12–18), heights, width and bottom grow with log(points per bar) / log(coarsest),
  with zero coarseness for a one-step ladder. Evaluate geometry continuously in UIKit;
  menu and VoiceOver changes commit immediately and ease density over 0.22 seconds.
  Reduce Motion jumps to the settled scale. One-finger scrolling and momentum use
  the committed scale; ticks move with the finger 1:1. A 0.35-second hold scrubs at
  that scale; vertical travel does nothing. Hold and pinch are exclusive; the scroll pan takes one touch.
  Stop held motion on release and cancel interactions when the tab, scene or ruler
  interaction revision changes. Hold and pinch show a Liquid Glass time/scale bubble
  with primary text (blur material before iOS 26), centered eight points above the
  drawer's `wherewolf.panel.sheet` view and below the top safe area; fall back to
  above the ruler if absent. The capsule, bubble and menu derive a bar's time from the ruler's slot, so they
  change only with the scale, or from retention time before points load. Remove the window bubble on release or
  cancellation without changing drawer height. Reaching Live clamps at zero
  without ending a drag or hold; return to Live when the finger lifts there, or as soon as
  momentum aimed at the Live edge arrives, stopping there without its bounce. Momentum and
  bounces settle on whole pixels, so an end within a pixel of the Live edge counts as Live.
  Only held scrubbing coarser than one point per bar snaps within six screen points
  of a stop boundary. Hold the exact index until the finger moves over ten points,
  then rebase at the current finger without a jump. Give each snap a selection haptic;
  its bubble adds the colored stop symbol and arrival/departure event above the scale.
  Ordinary drags, inertia and pinches never snap. The 18-point row under the ruler
  keeps the time (and at Live the hint "Pinch for scale; hold to scrub"), a scale capsule
  styled like the Go To time, and Live; the capsule opens a native Menu headed One bar covers: Every point,
  1 minute, 5 minutes, 15 minutes, 1 hour, 6 hours and Whole history. Map durations
  to the nearest step in log space using the bubble's estimate, drop later duplicate
  steps and check the current entry. Menu changes anchor the needle. VoiceOver's
  value names a containing stop and its arrival; keep its
  one-point increment/decrement, add Finer Scale and Coarser Scale actions, and
  announce scale changes. Hold and pinch use cached payloads; release loads the
  final selection once. Retain every stored route point.
  A Tracker replay hold or pinch recaptures a manually moved camera, preserving
  overview mode. Tracker point following uses the persistent ruler scale at Live and during
  browsing, scrubbing, momentum and playback, with heading mode on or off. One point per
  bar uses that mode's saved follow distance D0; coarser detents fit the route within ±(2 + (half the visible bars − 2) × coarseness²)
  ruler bars of the needle, measured through the ruler's spacing, into the overview's clear map area, never closer than D0, so mid
  detents stay close and only the coarsest fit the whole visible ruler. Compute the
  box when scale zoom starts, the scale changes or the needle moves greater than
  half a window, never per frame. At Live the window ends at the newest loaded point and
  includes the displayed live coordinate, anchored in the same clear area. Cache loaded
  coordinates only when history reloads; draw no route at Live. Refit when new points
  move the newest end more than half a window, not on live fixes. With no points keep D0.
  Live motion and heading still own centering and rotation; scale changes only distance.
  Pinches and settles send continuous scale through
  a non-observed UIKit channel; interpolate neighboring step distances in log space,
  fitting each step once per anchored gesture. Menu and VoiceOver changes ease map
  zoom in log space over 0.3 seconds. Release and gesture cancellation retain it.
  Keep `rulerZoom` separate from gesture-only `rulerHold`, payload gating and interaction
  deferrals. Do not write the saved follow distance or outer SwiftUI camera while
  scale zoom applies; sync once when it ends. Every point returns to D0 with the
  pinch settle or the existing discrete camera transition. Leaving Tracker or the
  active scene restores D0 immediately; returning reapplies scale zoom without
  animation. A freed camera and overview ignore the scale; resuming point following
  uses its own D0 for the fit. Live captures D0 before scale zoom starts and preserves it
  through camera release and history; following again flies to the current Live fit.
  Leaving history at a coarse scale lands at the live zoom from before history, also after a
  freed replay camera; with every point it keeps the replay zoom. Re-entering history uses
  replay's own D0. Zoom buttons keep following until the next refit takes back the zoom.
  The Trip map ignores the ruler. Respect Reduce Motion.
  Trip Settings uses `ExpandingSheetBackgroundView`: glass beneath a grouped
  Settings background that eases with the sheet's visible height. Row cards use
  `settingsRowBackground()`: in the glass sheet they ease from a translucent fill to the
  secondary grouped color on the background's own UIKit frames, without SwiftUI updates. `SettingsFormStyle` clears Form and navigation
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
- **Settings portability**: Backup & Sync uses native Forms. `SettingsSchema` is the
  allowlist for JSON and optional, default-off iCloud sync. Export includes schema/app
  versions and optionally the URL, token and custom headers; warn about credentials.
  Import validates the whole file, previews changes and requires confirmation. Never
  restore tracking on/off, permissions, active trips or device state. Import waits for
  a trip to end; sync defers incoming changes during trips. Apply through the bridge
  and GLManager's batch so acquisition and HTTP reconfigure once, without permission
  prompts. Merge per key by modification time, breaking ties by writer ID. The URL,
  token and headers never enter ubiquitous key-value storage; sync them through a
  synchronizable Keychain item. URL/token stay in a local Keychain item when sync is
  off; migrate old defaults only after a successful save. Device ID is backup-only.
- **Connection test**: Server and the guide's glass Destination sheet share one native
  section. Save edits through the bridge, then use a valid fix at most 30 seconds old
  or a separate one-shot location manager with a 15-second deadline. GLManager reuses
  the upload payload builders, URL templates, headers and authentication; GeoJSON
  marks `test: true`, OwnTracks stays plain. Send directly with a 15-second timeout,
  including on cellular. Never queue, acknowledge, archive, apply response settings,
  update trips or count send statistics. Show HTTP status, acknowledgement and a fix
  hint; disclose that the server receives a real current-location point.
- **Coverage**: native Form and Swift Charts use archive timestamps, current queue count
  and local send outcomes. A gap exceeds ten minutes between accepted fixes while
  recording is expected; pause/off spans and time before the state log began are
  separate. Gaps can also reflect reception or filters, not only system suspension.
  `TrackingTransitionLog` writes coordinate-free start/stop/pause/resume transitions
  and send categories on a serial queue with protected atomic writes and backup
  exclusion. Retain the history window, at most 2,000 transitions and 20,000 sends;
  preserve one state at the cutoff. Keep all location acquisition and storage active
  without a scene. Status reads use an already-created location manager and never
  initialize acquisition. Read timestamps without loading route geometry. Nothing uploads.
- **Route replay**: `RecentLocationHistory` archives each accepted upload record
  in a separate SQLite store, with a validated 24–168 hour retention window that
  defaults to 24 hours. `GLManager` calls it only after a successful queue commit;
  the archive never participates in queue deletion or HTTP. `HistoryPlaybackModel`
  owns only presentation state and stops its display link off the Tracker tab.
  Pacing, stays, status values and route directions live in `ReplayTimeline.swift`;
  camera transition, zoom, live-motion and heading math lives in `MapMotion.swift`.
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
  over 60 seconds. A silence of at least 5 minutes followed by a fix 60–100 m away ends the stay at that fix,
  because a phone that logs only when it moves goes quiet while parked and wakes wherever its owner
  got moving again, such as the car across the lot. Outside stays the marker visits every fix; segments of at most 25 m with
  a net speed under 0.5 m/s over ±30 seconds pace as stationary. Scrubbing still shows
  exact points. Retain every point, and retain fractional progress across speed changes
  and pause/resume. Keep the chosen zoom. Original timestamps and recorded speed values remain unchanged.
  `ReplayStatusOverlay` shares the speedometer's row during replay, with the same top,
  height and corner radius, stops short of the Legal link and never takes touches. It shows the activity, time,
  altitude and distance since the last stop, updating per point rather than per frame. That distance leaves out
  wandering that paces as stationary, and a fix over 100 m out and straight back at over three times the
  speed on either side, which counts as the direct distance across it.
  Keep its width steady, and stack readings that do not fit instead of truncating them. Recorded motion outranks speed inference,
  except that flying speeds win. Cached Go To movement rows use inferred activity
  because recorded motion lives in payloads; snapshot loads read only point metadata. A row is named
  after the activity that covered the most corrected distance, and is a flight only once flying covers
  a quarter, so a stray fix far off a drive cannot name it a flight.
  `ReplayTimeline` shares corrected cumulative distance with those rows.
  Hide altitude when vertical accuracy is negative. Nearby
  payloads use a bounded prefetch cache and coalesced reads; a ruler hold or pinch
  shows only cached payloads and starts no reads, including from in-flight completions.
  On release, load around the final selection once. Normal drags and playback keep
  prefetching. Format JSON only for inspection. Cache the complete route through
  every stored point, without sampling. Publish replay position and coordinate together in one `ReplayPose`.
  `ReplayRoutePresentation` retains every vertex and draws every route line with a
  plain `MKPolylineRenderer`, the only renderer MapKit draws as vector geometry at
  a constant screen width. Path renderer subclasses become bitmap tiles that stretch
  between zoom levels, so do not use them for routes.
  Dots show only the route ahead, and none may exist at or behind the marker: logged points
  can be over 100 m apart, and the blue tail floats above the map, so anything beneath it
  shows when the two briefly disagree. Each section has its own dotted line, drawn backward
  so the dash pattern stays put. Foreground `ReplayTrailLayer`s draw the whole active
  section, split at the marker's exact pose, with dots beneath blue in the marker's
  transaction. The other sections use MapKit overlays, which are
  bounded to 1,024 segments and 100,000 map points of length; isolate long jumps.
  A short shared tail preserves joins. Marker movement changes overlays only when
  crossing a section boundary. Layers also cover newly installed overlays, and during
  zoom, rotation or pitch changes the blue of up to four sections behind the marker, until a
  fully rendered map callback from a render begun after their addition, or a two-second
  deadline that camera motion does not extend.
  Add and remove section overlays instead of changing `strokeColor`, which can take
  over a second to appear. End the foreground tail at the marker's exact pose
  coordinate. Never use `strokeEnd` percentages for replay progress.
  Blue, including trip and imported workout routes,
  is 2.5 points wide; future dots are 1.25, with
  round caps. Layers cull offscreen sections and share a validated Mercator-to-screen
  homography, including pitch, with per-point MapKit conversion when the fit fails.
  Keep their projection within half a point of MapKit, cache unchanged projections
  and hide the layers offscreen. Retain the complete cached route beneath them.
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
  Reload the route presentation in place using stored record IDs. Appends extend only
  the tail sections; expiry removes leading sections and rebuilds the first partial
  section without shifting retained boundaries. Reuse unchanged overlays by identity;
  rebuild all sections only when the retained points differ from an append or trim.
  Defer presentation reloads during ruler interaction and playback, then coalesce
  them on release or pause. Never defer raw collection or uploads. Retention changes
  force a deduplicated snapshot load, apply the current cutoff to in-flight results,
  and preserve the selected coordinate, route index and ruler position together.
  Keep pruning and storage-summary work on the archive's serial queue;
  only the history settings page requests aggregate storage statistics.
  During replay the location button toggles between following the selected
  coordinate and fitting the projected trail below the credit and replay status,
  left of the map controls and above the current drawer, preserving heading and requesting
  the current pitch within MapKit's zoom limits. Fit and return the camera MapKit applies.
  Only the ruler's Live action exits replay. Overview persists during scrubbing and playback;
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
  when requested or the map viewport resizes, and does not refit as the drawer moves.
  Manual map gestures release the camera anchor while replay
  continues, including after gesture deceleration and at the final frame.
  A map gesture stops live following as it begins, so the location button empties at once.
  MapKit can report the last region while the finger is still down and nothing afterward,
  so a gesture that stops without decelerating commits its camera when the finger lifts.
  Selecting another point or Show My Location resumes anchoring.
  While a finger is on the map, pause automatic camera corrections and camera
  transition time so MapKit can take the pan; the contact recognizer must never
  recognize or prevent gestures. Explicit recenter requests must reach the map
  even when its cached request is already follow.
  Offset programmatic cameras before animating, and ignore subpixel follow
  jitter. Do not animate to the full-map center and correct it afterward. The offset
  turns with any change of heading, so the dot holds still while the map rotates.
  Every switch to following the live location flies there along `MapFlight`, van Wijk and
  Nuij's zoom-and-pan path: long moves zoom out on the way, short ones are nearly a pan,
  0.6–2 seconds. It keeps heading and aims at the moving fix, landing at the Tracker ruler's
  Live fit while scale zoom applies and otherwise keeping zoom. The first camera at
  launch and Reduce Motion jump instead. Once following, the location button switches a
  Find My style heading mode on and off where the device has a compass. `DeviceHeadingSource`
  reads the compass from its own `CLLocationManager` with a 2° filter while tracking is on,
  the scene is active and the live Tracker/Trip map is visible. Stop, Settings, replay and inactive
  or background scenes stop it. `LiveHeadingController` shares those readings with a soft
  blue 46-point beam under the native dot, independently of heading mode; invalid accuracy
  hides it, and worse accuracy widens and fades it. Prefer true heading, then magnetic;
  Core Location adjusts for interface orientation. Smooth geographic heading with
  `HeadingMotion`, then apply the camera projection, respecting Reduce Motion. The beam
  shares the dot's layer movement and adds no touch view. Keep `userTrackingMode` at `.none`;
  MapKit exposes no independent native beam switch. A separate `HeadingMotion` spring turns
  the map about the dot in heading mode. Turning heading
  mode off while still following turns the map north; map gestures and replay leave the
  rotation as it is.
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
  strip sits 20.5 points up. Blend between them as the drawer moves. Tab items match the
  system tab bar measured on iOS 27 (54-point cells; UIKit draws 16-point semibold symbols about
  1.4 times larger, so a 22.6-point semibold symbol centered 20 points down; a 10-point medium
  label centered 41 down) and are never scaled; the drawer
  changes only the strip's layout width, so open and closed change the spacing. Like the
  system's, the selection reaches 4 points past its cell; the strip's 8-point side insets keep
  a 4-point gap around it on every side, and the strip fills the platter at handoff. The closed
  capsule keeps 10.6 points above the strip for the grabber mark and 3.2 below. Zoom buttons
  preserve replay following and rotation; manual map gestures remain free.
  A compass below Zoom Out appears while the heading is more than 1° from north, reported
  only when that changes. MapKit's compass draws the live needle; a tap turns north through
  the zoom buttons' camera transition, keeping center, distance, pitch and replay state.
  In heading mode the tap ends heading mode instead, which turns the map north.
  The map host sends every touch to the map except chrome it lists by identifier, so a new
  control over the map must be added to `FullScreenMapTouchView`'s list.
  Move the native attribution views in UIKit without changing map margins or
  the camera projection. Give Legal a 44-point touch target, try its native
  accessibility action, and fall back to Apple's Maps legal page if unavailable.
- **`WhereWolfLocationEngine`** uses iOS 17 `CLLocationUpdate.liveUpdates` for
  Best accuracy with automatic pausing. An active widget-backed tracking activity
  (Status, Minimal, or Blank with Lock Screen Card on) supports background updates
  with the indicator off. With Always access and no active
  supporting Live Activity, indicator-off tracking falls back to `CLLocationManager`.
  Hide While Audio Plays uses the same reconciliation when ending or restoring
  an activity; it requires Always access even when an indicator session exists.
  Blank with the card off uses this fallback; its app-only activity did not
  maintain live-update delivery in the iOS 27 background route check.
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
- **Watch app**: `WhereWolfWatch` is a small companion for managing tracking from the
  wrist: tracking on/off, retry updates, start/end trip, send now and Usage Preset. It
  holds no location or queue data. `WhereWolfWatchLink` activates `WCSession` at launch
  and sends each command through the same calls as the phone's controls, with the same
  limits and Stop confirmation. `GPSLogger/Shared/WatchLink.swift` defines the messages
  and the pure `WatchHomePresentation` mapping, and belongs to both targets. Home uses a
  black native List with a scaled 84-point tracking hero: green ring while tracking,
  solid green while off, orange ring for stale fixes and gray when unreachable. Recovery
  comes first, then Start Trip (or the mode/timer/distance card and a separate End Trip row),
  Send Now and Preset, on native gray row platters. Keep text untinted, Dynamic Type and
  44-point targets. The owner rejected glass on the watch: keep the hero a flat filled or
  ringed circle and add no glass styles or tinted backgrounds. Mode icons come from the
  phone's `TripModeStore`; include `TripModes.xcassets` in watch resources and fall back to
  `location.fill` for missing or unknown symbols. Preset has checkmarks and stays locked
  during trips. Starting a trip while off restores off after its summary commits.
  Commands use live `sendMessage` only and are never queued,
  because a Stop or End Trip delivered later would do the wrong thing. Status reaches the
  watch through `updateApplicationContext`, at most once a minute for location updates
  and only with the watch app installed. Tracking must never depend on the link. Keep the
  watch version and build number equal to `GPSLogger/Info.plist`.
  A signing profile without the watch bundle identifier can build the phone app alone with
  `WHEREWOLF_WATCH_SIGNING=NO EXCLUDED_SOURCE_FILE_NAMES=WhereWolfWatch.app`.
- **Reminder action**: the missed-update reminder offers a background Resume Tracking
  action, which also appears when iOS mirrors the notification to a watch and runs on
  the iPhone without a watch app. A background launch restores tracking through
  `restoreTrackingState`; the action then calls `refreshLocation`. It must not override
  Stop or a pause. iOS generally does not relaunch force-quit apps.
- **Trip end prompt**: `TripEndPrompt` (Ask to End Trip When Stopped, default off, remote
  `trip.ask_to_end_when_stopped`) sends one notification per stop: 75 m for 5 minutes with
  motion reporting stationary at least once and no driving or cycling, or 10 minutes without
  authorized motion data. It never requests Motion & Fitness and runs from location callbacks
  without a scene. Only the in-app switch requests notification permission; it does not need
  the Notifications setting. Moving on or the trip ending another way withdraws the prompt.
  Its End Trip action ends a matching trip at the stop through `endTripAtDate:location:`, so
  the summary's end, duration, distance and location stop there; other End Trip prompts end it
  now. `GLLastTripEndDefaults` is written before the trip start is cleared, so the Health
  workout and route end then too. The visit prompt is skipped while this is on.
- **Optional tracking policies** live in `GLTrackingPolicy` and are configured
  through the validated `GLAdvancedTrackingOptions` dictionary in `GLManager`.
  They default off and are independent of all six Usage Presets. Keep acquisition,
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
- **`WhereWolfUploadScheduler`** registers one network-required `BGProcessingTask`
  at launch. Background scheduling and connection-return retries are independent,
  default-off choices. Both call the existing uploader; retain its one-request
  limit, 20-request yield, backoff, Retry-After and authentication block. Coalesce
  equivalent schedules, complete expired tasks once, and preserve pending intent.
  `NWPathMonitor` runs only when enabled, and only a false-to-true transition can
  clear eligible transport backoff. iOS schedules processing opportunistically.
  Send Only on Wi-Fi (`WifiOnlySending`, default off, remote `send_wifi_only`) holds every
  send the app starts itself while the path is expensive and the destination is HTTP:
  interval sends, pause and trip flushes, retries and background tasks, which count as
  blocked. It keeps the flush intent and resumes on the first Wi-Fi path. An unknown path
  waits. Send Now, intents, widgets, controls, the Live Activity and the watch always send,
  and a user's drain continues through every batch. Its monitor runs only while it is on.
  Optional iOS 18 `CLServiceSession` retains already-Always authorization intent;
  invalidate it on Stop, option-off or lost authorization.
- **Background helpers**: `WhereWolfBackgroundRuntime` controls the ActivityKit
  extension and opt-in `SilentAudioSession`. Live Activity staleness mirrors the
  pending `reminder` notification deadline. Keep its scheduling rules in
  `GLManager`; do not drive activity staleness from another timeout. The shared ActivityAttributes
  source belongs to both the app and `WhereWolfTrackingActivity` targets. Blank is
  the default appearance for new installs; saved choices remain. `LiveActivityLockScreenCard` defaults off. Blank with the card off uses
  `IslandOnlyTrackingAttributes` in the app target only; never register that type
  in the extension. Blank with the card on uses the widget-backed activity with
  empty Island views. Minimal and Status always include the card; Settings shows
  its toggle on and disabled, and hides it when tracking activities are off.
  The shared `TrackingLockScreenCard` shows status, last fix/send, queue count and
  Send Now. A trip adds mode, distance, live duration and End Trip; omit the trip
  line while a separate trip activity is active. Fix, distance and queue growth
  changes coalesce to 60 seconds; sends, queue drains, trip/status changes and
  reminder deadlines update immediately. Observe queue, send, trip and engine
  events without requiring a scene. End and recover both types; replace the type
  when appearance or card selection requires it.
  Relevance remains zero. It ranks WhereWolf's own activities, not other apps;
  iOS controls which activity occupies the main Island or a detached bubble.
  Hide While Audio Plays defaults off. Two other-audio readings
  at least 15 seconds apart hide Status, Minimal, Blank and separate trip activities,
  only with Always location access. Sample on existing lifecycle/activity/audio
  events and location callbacks (at most once per 15 seconds). A pending audio
  change schedules one cancellable refresh just after 15 seconds, for both hiding
  and restoring; use no repeating timer or audio-session activation. Cancel it when
  resolved, disabled, tracking stops or Always access is lost. It reacts within
  about 15 seconds while WhereWolf runs in the background (moving or with Silent
  Audio on); while suspended, it reacts at the next location update or app open.
  Own silent audio does not count or stop. Confirmed audio ending permits one
  background restore attempt per activity family, then waits for
  foreground or explicit Retry after a refusal. Hiding is not a failure. Preserve
  Stop, pauses, trip state and the reminder deadline.
  Settings and the guide show Hide While Audio Plays only while the tracking or trip Live
  Activity is enabled. Ask to Reopen When Audio Stops defaults off and appears under
  Hide While Audio Plays. After confirmed audio ending, a refused or deferred
  restore schedules one authorized passive (silent) local prompt five minutes later,
  so short pauses never send it, with the fixed
  `WhereWolfLiveActivityAudioReopen` identifier. Withdraw pending and delivered
  prompts on renewed audio, foreground, restore, Retry, either switch off, lost
  Always access, Stop or no remaining activity to restore. Only the inline Allow
  button requests notification permission; never request it in the background.
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
  The trip-end and audio-reopen prompts use their own switches and existing
  notification permission, independently of Notifications and Problems Only.
- Current Wi-Fi identity uses only the connected SSID. Try `CNCopyCurrentNetworkInfo`,
  then a cached `NEHotspotNetwork.fetchCurrent` result under two minutes old; a miss
  refreshes the cache. Add Networks refreshes on appear and scene activation.
- **Wi-Fi Places**: `WifiPlaces` is a flat plist-safe array of `{id, name, latitude,
  longitude, networks, symbol, color, record}` dictionaries, with optional
  `symbolChosen` to preserve manual icons on rename. Validate each whole place;
  SSIDs are ordered, unique and 1–32 UTF-8 bytes.
  Migrate `WifiZones` and single-zone keys by equal coordinates, keeping the first
  network’s name, dropping BSSIDs and removing old keys only after a successful save.
  Match SSID plus raw-fix distance within `GLWifiPlaceMatchDistance` (300 m) +
  min(accuracy, 200); invalid accuracy never matches and the nearest point wins.
  Point replaces only a <=20-second current fix, reporting min(300, fix accuracy)
  so Max Saved-Point Error never drops a point it would have kept, and drops the batch's
  other fixes inside the place. The point saves on arrival whatever the point filters allow,
  then at most once per `GLWifiPlaceHeartbeatInterval` (5 minutes) while matched, so stays and
  Coverage still see the visit. Nothing rejects matching fixes through `wifi_place` before
  accepted-fix, trip, Health or replay updates; keep acquisition and uploads active.
  iOS often cannot name the network in the background: an empty name keeps the last match
  while fresh fixes stay inside that place and never starts one. Another network or a
  fresh fix outside ends it; delayed batches leave it unchanged.
  Native Forms, navigation and sheets own the list, editor, network and icon pickers.
  The map has a fixed center pin and a 400 m region; dragging moves the point, with
  rotation and pitch off. Never imply scanning or access to iOS’s saved networks.
  `WifiKnownNetworks` is device-only state,
  bounded to 64 SSIDs by recency: lastSeen, last <=100 m fix coordinate and seven UTC
  day buckets of connected seconds. Count only consecutive same-SSID gaps <=10 minutes,
  split at midnight and persist only changes. Frequent suggestions exclude assigned
  names, require an hour and show the top three. Identification needs location access
  and a capable signing profile. Backup & Sync uses `wifiPlaces`; imports accept old
  `wifiZones` by conversion and discard legacy distance fields on import and save.
  Never export or sync the observed catalog.

## Tracking constraints

- Gate only presentation timers, replay loads and trip-map queries on scene
  visibility. Location processing, storage, uploads, reminders and Live Activity
  updates must work without an active scene. Silent audio remains opt-in.
- Preserve the five original preset dictionaries and saved settings. Everyday
  Detailed (ID 6) defaults only an empty new-install preference domain: Standard,
  Best, Other, pausing/resume/stationary stopping/visits off, indicator off,
  minimum distance 10 m and time 5 s. The engine toggle is independent of all six
  presets. Automatic pauses end trips.
- LOLDatabase returns transaction success; accepted-fix and trip-finalization
  state may advance only after the queue commit. Replay is not an acknowledgment.
- Uploads keep one request in flight, yield after 20 drain requests, persist
  retry/flush intent, and retain records on failure. GeoJSON and OwnTracks keep
  their existing request shapes. See `docs/tracking-improvements.md` for sources.

## Before App Store release

- [ ] Remove `TestFlightDiagnostics.swift`, `DiagnosticsView.swift`, their Settings
  and AppDelegate entry points, and `WHEREWOLF_TESTFLIGHT_DIAGNOSTICS` from both
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
