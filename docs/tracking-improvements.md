# Tracking improvements

## Optional tracking policies

Acquisition settings, saved-point selection and upload scheduling remain separate. New policies are
off by default and survive Usage Preset changes. They do not change the five
preset dictionaries, GeoJSON/OwnTracks request shapes or acknowledgment rules.

`GLTrackingPolicy` contains the deterministic stop, jump and selection rules.
`GLManager` owns their state and Core Location transitions. The SwiftUI bridge
writes every setting through `GLManager`. Identical acquisition configurations
do not restart services; one server response reconciles its changes together.

### Permission and movement

Motion classification requests permission through the explicit button, never
by changing an advanced option. Existing trip step queries can also request
Motion & Fitness access. Authorized motion metadata remains available without enabling assistance.
Denied/restricted permission leaves ordinary tracking available. Overland queries
up to 24 hours of activity on start and foreground return, retains at most 512
changes, and assigns GeoJSON labels using each fix's timestamp. It does not
poll motion history in the background. Core Motion callbacks alone cannot wake
a suspended process.

Adaptive tracking requires at least three fresh, ordered, accurate observations
within the configured cluster across the dwell period. Confident moving activity
or an accurate moving-speed observation releases quiet mode. With motion
confirmation required, unknown motion keeps detailed acquisition active.
GPS-only confirmation is a separate choice. Quiet mode uses coarse
`CLLocationManager` updates with native automatic pause off and, with Always
access, an exit region. Movement restores the saved engine/accuracy/pause
configuration. Trips have a separate adaptive opt-in. This can reduce GPS demand,
but it can delay recording a departure; no energy saving has been measured yet.

Explicit Stop wins over asynchronous callbacks. Motion cannot undo a radius
pause unless both recovery options are enabled and the activity began after
the pause. Radius pause clears adaptive state and its region, so a later resume
starts a new dwell. Pre-pause or old fixes cannot resume that pause; otherwise
valid delayed fixes can still be archived and queued.

### Selection and quality

The default distance AND time rule remains intact. Optional Any threshold uses
enabled distance OR time OR turn thresholds. Disabled thresholds cannot qualify
every point, and all-disabled saves every otherwise valid fix. Turns require
moving fixes with usable course accuracy and compare the shortest angle.

Jump rejection subtracts both reported error radii before comparing displacement
with elapsed time and the configured maximum speed. An implausible relocation
is held back until a nearby fix at least one second later corroborates it. Dense
subsecond samples retain that candidate rather than restarting confirmation.
This is a plausibility filter, not proof of true accuracy. It does not smooth,
road-snap or rewrite coordinates. The raw quality observation is independent of
the accepted-fix baseline; only a successful queue commit advances that baseline.

### Delivery and recovery

`background_recovery` is a separate, default-off choice to retain significant-
change monitoring during Standard tracking and trips. It requires Always access
and device support. Normal Both mode already has this monitor; the new choice
also covers trips and Standard mode without changing preset recognition. Stop,
radius pause and event-only modes keep their existing decisions. This is an
additional relaunch opportunity after system termination, with coarse movement
and no fixed delivery interval. Background App Refresh restrictions can limit
relaunch. The Background screen shows the system's current refresh status.

`automatic_location_retry` and `location_health_log` are independent, default-off
choices under Background → Location Updates & Recovery. `GLLocationHealthPolicy`
uses monotonic elapsed time to distinguish absent callbacks, old or unusable
readings, and fresh readings skipped by saved-point filters. The retry threshold
defaults to 120 seconds, bounded to 60–1,800 seconds. It requests at most three
acquisition restarts per app session without a fresh fix, with waits of twice and
five times the threshold after the first two attempts. Fresh raw readings reset
the budget; saved-point acceptance does not establish provider freshness. Manual
retry, explicit Start and retry-setting changes also reset the budget. This check
preserves the existing terminal live-stream failure latch and fallback.

The check runs only while continuous updates are expected and the process has
execution time. Stop, event-only modes, lost permission, native automatic pauses,
radius pauses and adaptive idle mode suspend it. A timer cannot wake a suspended
or terminated app. The existing notification reminder and Live Activity deadline
are unchanged. Local diagnostics describe observed events and never attribute an
unobserved interval to a particular system termination reason.

The optional health log uses a serial queue and an atomic, protected,
backup-excluded JSON file. It retains at most 200 events from seven days, with
an allowlist of event fields, reason codes and rejection counters. It excludes
coordinates, endpoints and credentials; no automatic upload path reads it. Reads
and clearing occur off the main thread. UI sharing is explicit.

Every nonempty received location batch acquires a short UIKit background task
before processing. `GLLocationSaveAllowance` ends it once on completion or
expiration, including expiration during registration. Successful queue commits
wait for FIFO barriers behind the batch's local history and Health route writes
before releasing the allowance. Rejected batches and failed commits release it
immediately. Queue acknowledgment and accepted-fix advancement remain tied to a
successful queue commit.

The live engine makes one attempt plus three bounded retries. Exhaustion clears
the stream before publishing one fallback event, latches failure, and selects
`CLLocationManager`. Explicit start, Retry, refresh, engine change or restored
location authorization releases the latch. Cancellation, replaced tasks and
radius stopping do not report a terminal failure.

Background Uploads registers a network-required `BGProcessingTask`. It schedules
only eligible pending queues, coalesces equivalent requests, respects retry dates,
and completes once on expiration. A 25-second local work budget leaves pending
intent for a later opportunity. Scheduling is discretionary; the 60-second earliest
date is not a promised interval. It reuses the existing one-request uploader and
its yield after 20 drain requests. Completion notifications do not bypass that yield.

Connection recovery uses `NWPathMonitor` only when opted in. The first path is
a baseline; an unsatisfied-to-satisfied transition can clear only transport-error
backoff. HTTP Retry-After and authentication/configuration blocks remain in force.
Turning automatic sending off still prevents new automatic upload intent; a
previous manual drain remains a manual request.

The optional iOS 18+ `CLServiceSession` retains already-Always authorization
intent while continuous tracking is enabled. It is invalidated on Stop,
option-off or lost Always access and restored promptly after a background
relaunch when it was previously active. It neither prompts for an upgrade nor
guarantees background execution. No helper bypasses force-quit or revoked access.

### Remote configuration

`set.advanced_tracking` merges these keys with existing choices. Booleans and
numbers are accepted. Unknown keys, other types and nonfinite numbers are ignored;
numeric values are clamped to their ranges. All quantities use seconds, meters,
meters per second or degrees as indicated.

| Key | Default | Allowed values / meaning |
| --- | --- | --- |
| `any_threshold` | `false` | Use enabled OR thresholds |
| `turn_degrees` | `0` | 0–180°; 0 disables the turn trigger |
| `reject_jumps` | `false` | Enable displacement plausibility filtering |
| `maximum_speed` | `100` | 5–500 m/s |
| `motion_assist` | `false` | Help resume a native stationary acquisition |
| `motion_resume_radius` | `false` | Also resume radius pause; requires motion assist |
| `motion_confidence` | `2` | 1 medium, 2 high; rounded |
| `adaptive` | `false` | Enable confirmed-stop accuracy reduction |
| `adaptive_in_trips` | `false` | Apply adaptive policy during trips |
| `adaptive_require_motion` | `true` | Require stationary motion confirmation |
| `adaptive_dwell` | `120` | 30–3,600 s |
| `adaptive_radius` | `30` | 10–500 m stop cluster |
| `adaptive_max_error` | `25` | 5–200 m confirmation error limit |
| `adaptive_idle_accuracy` | `100` | 50–3,000 m coarse request |
| `adaptive_resume_radius` | `100` | 25–1,000 m exit region |
| `background_uploads` | `false` | Request system upload opportunities |
| `connectivity_retry` | `false` | Retry eligible transport errors on connection return |
| `explicit_service_session` | `false` | Retain iOS 18+ Always authorization intent |
| `background_recovery` | `false` | Add significant-change relaunch monitoring to Standard tracking and trips with Always access |
| `automatic_location_retry` | `false` | Limited retries when expected continuous updates stop or become outdated |
| `location_retry_after` | `120` | 60–1,800 seconds without a fresh fix before an automatic retry |
| `location_health_log` | `false` | Local, bounded event log for gaps, retries and skipped points |

### Sources and validation scope

The design draws on [TraccarSDK's point-selection approach](https://github.com/traccar/traccar-client-sdk/tree/e56ca0840656e785629d7d3d2b0b275a6c110489),
[LocoKit2's stationary/acquisition separation](https://github.com/sobri909/LocoKit2/tree/d34ce096de099e766196622274a61592079041df),
and [OwnTracks' location modes](https://owntracks.org/booklet/features/location/).
No third-party implementation was copied. Apple documents the platform boundaries in
[background location](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background),
[modern authorization sessions](https://developer.apple.com/videos/play/wwdc2024/10212/),
[Core Motion](https://developer.apple.com/documentation/coremotion/cmmotionactivitymanager),
and [background processing](https://developer.apple.com/documentation/backgroundtasks/bgprocessingtaskrequest).
Deprecated deferred-location APIs are not used.

Location-health decisions draw on
[LocoKit2's stale-fix recovery](https://github.com/sobri909/LocoKit2/blob/d34ce096de099e766196622274a61592079041df/Sources/LocoKit2/Managers/LocomotionManager.swift)
and [Tracelet's separation of provider silence and filter rejection](https://github.com/Ikolvi/Tracelet/blob/37e8f2e49992a6422ff962e509a3b0265eded19b/sdk/ios/Sources/TraceletSDK/location/LocationEngine.swift).
UIKit documents the short save allowance in
[Extending your app's background execution time](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time).

Policy, manager, engine and scheduler regressions exercise denial, delayed fixes,
mode changes, settings batching, queue failures, motion timestamps, dense jump
confirmation, expiration and retry deadlines. Simulator tests cannot establish
locked-screen route completeness, real departure latency or battery savings.
Compare a stationary period, walking, driving, transit, weak GPS and connection
loss on a physical device with identical base settings and one option changed
at a time. See [the battery audit](../BATTERY_AUDIT.md).

Location-health tests cover clock adjustments, retry budgets, paused and adaptive
tracking, rejected fixes, failed queue commits, background-task expiration,
log retention and metadata exclusion. File-protection attributes need physical
device verification because the simulator does not expose them.

## WiFi network assignments

The WiFi editor selects several connected, observed, configured or manually
entered network identities and saves one coordinate pair for the entire
selection. SSIDs retain their exact spelling, including spaces and case.
BSSIDs use a canonical six-octet form. Each SSID/BSSID pair has one assignment;
reassigning it updates the existing entry. The same SSID with another BSSID
remains distinct. An SSID-only entry is a fallback for any access point, while
an exact BSSID wins. Batch validation completes before preferences change.
Legacy duplicate identities use the last valid entry, and malformed explicit
BSSIDs cannot silently turn into broad SSID matches. Coordinate updates retain
an existing configured error radius.

The local observed catalog retains at most 64 identities and writes only when
its contents change. It records networks actually reported during tracking;
it does not scan nearby networks or read iOS's saved-network list. The editor
selects the connected network on opening when iOS exposes it, preserves drafts
across a switch to iOS Settings, and accepts only a fresh location for autofill.

Apple's [WiFi API overview](https://developer.apple.com/documentation/technotes/tn3111-ios-wifi-api-overview)
describes the scanning limitations. Both autofill and automatic matching require
the [Access WiFi Information entitlement](https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.networking.wifi-info)
and appropriate location authorization. The current personal development team
was explicitly rejected by Xcode for this capability, even after account sign-in.
The limited signed build can edit assignments but cannot identify networks to
apply them. A capable provisioning profile is needed; changing the location
permission alone cannot supply a missing entitlement.

The user does not need a personal paid membership to use a build signed and
distributed by an eligible developer team. A free Personal Team cannot sign this
capability. A Shortcuts integration could pass a network snapshot to Overland,
but it is not implemented and would not provide continuous app-side identity
access. Apple documents additional Get Network Details fields and immediate
WiFi automations in its [Shortcuts release notes](https://support.apple.com/en-gu/111098).
Connection events alone cannot establish that an old network snapshot is still
current, so such snapshots must not silently replace fresh location fixes.

The motion status now uses a labeled Current Activity row with the shared
Settings icon style. Unknown motion is presented as Waiting for Update, and
stopped tracking as Tracking Off. No motion classification or payload changed.

Simulator-only network and motion fixtures are absent from the signed phone app.

## Replay pacing

Replay defaults to 1× and offers 0.25×, 0.5×, 1×, 2×, 5×, 10×, 25× and 50×.
At 1×, recorded intervals are divided by 15 and bounded to 0.2–16 seconds
before the selected rate is applied. Invalid intervals use two seconds.
The marker, trail and clock share the same fractional progress; rate changes
preserve the selected position. Recorded timestamps and speed readings remain
unchanged.

Replay tests cover rate changes, fractional progress and complete route geometry.
Uploader fixtures clear pending retry intent before resetting an endpoint and
quiesce the app host after clearing test preferences, so a discarded fixture
cannot send into the next test’s request handler.

## OwnTracks HTTP contract

Reviewed the OwnTracks docs and the Recorder, iOS and Android sources on
17–19 October 2026 before changing OwnTracks uploads.

- Recorder `/pub` processes one JSON object per POST. It does not iterate bare
  arrays or generic batch wrappers: those become unknown/raw records rather than
  a batch of location fixes. Encrypted messages are a special wrapper when built
  with encryption support. Overland keeps its single-object request format.
  [HTTP handler](https://github.com/owntracks/recorder/blob/f202b5be11fc98097d69ef460c1753cffe8300be/http.c#L632-L710),
  [message parser](https://github.com/owntracks/recorder/blob/f202b5be11fc98097d69ef460c1753cffe8300be/recorder.c#L741-L985).
- Recorder recognizes `location`, `transition`, `waypoint`, `waypoints`, `card`,
  `beacon`, `cmd`, `dump`, `lwt`, `steps` and `status`; `request` and `encrypted`
  depend on build options. Its `dump` configuration type differs from the
  documented `configuration` type. A location's `tst` is Unix epoch seconds;
  docs specify an integer, while Recorder accepts numbers and numeric strings.
  Overland retains its existing numeric timestamp representation.
  [Types](https://github.com/owntracks/recorder/blob/f202b5be11fc98097d69ef460c1753cffe8300be/misc.h#L23-L44),
  [timestamp parser](https://github.com/owntracks/recorder/blob/f202b5be11fc98097d69ef460c1753cffe8300be/recorder.c#L1009-L1026),
  [JSON specification](https://owntracks.org/booklet/tech/json/#_type-location).
- Any HTTP `2xx` acknowledges delivery. Recorder normally returns an array,
  often `[]`, optionally containing friend locations, cards, transitions or
  commands. Overland does not implement incoming OwnTracks commands or friends.
  A lost acknowledgment can cause a duplicate delivery; the protocol supplies no
  universal idempotency guarantee.
  [HTTP specification](https://owntracks.org/booklet/tech/http/).
- The iOS app sends the oldest queued object, then advances on `2xx`; it also
  removes a record on `4xx`. Other failures back off from 1 to 64 seconds.
  Android sends individual objects and retries non-`2xx` responses with backoff
  up to two minutes. Both apps accept successful responses with empty or
  unparseable bodies. Overland retains records on every failed request,
  including authentication failures.
  [iOS sender](https://github.com/owntracks/ios/blob/bbb7b76220ff5e62b46ddaf76ac47b72cfd21c95/OwnTracks/OwnTracks/Connection.m#L98-L141),
  [iOS acknowledgments](https://github.com/owntracks/ios/blob/bbb7b76220ff5e62b46ddaf76ac47b72cfd21c95/OwnTracks/OwnTracks/Connection.m#L480-L580),
  [Android HTTP sender](https://github.com/owntracks/android/blob/589e54df9685b04a1fd0824e8b11593b8b5b329f/project/app/src/main/java/org/owntracks/android/net/http/HttpMessageProcessorEndpoint.kt#L84-L178),
  [Android queue](https://github.com/owntracks/android/blob/589e54df9685b04a1fd0824e8b11593b8b5b329f/project/app/src/main/java/org/owntracks/android/services/MessageProcessor.kt#L356-L478).

Mixed queues retain each record's format and acknowledgment rule. Existing
GeoJSON events and trip summaries are not converted to OwnTracks messages;
servers receiving those records still need to support Overland's GeoJSON
contract. Only Latest replaces older location fixes and keeps events and trips.
