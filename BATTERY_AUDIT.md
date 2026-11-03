# Battery and behavior audit

This describes the current implementation. Battery savings and continuous background delivery have not been established by measurement.

## Evidence and current behavior

The [original upstream report](https://github.com/aaronpk/Overland-iOS/pull/180#issuecomment-3447908515)
described heat, freezing and battery loss near a stationary stop. It did not
establish a cause. Repeated Core Location start calls alone do not prove a loop.
The following repairs address identifiable work or state errors; they are not a
claim to have reproduced that device issue.

| Area | Current behavior | Remaining tradeoff |
| --- | --- | --- |
| Acquisition transitions | Identical accuracy/activity/pause/indicator/engine configurations do not restart acquisition. Remote response changes reconcile together. | Service behavior still depends on iOS and authorization. |
| Stationary radius | Dwell observes validated raw fixes before saved-point filters and WiFi replacement. Pause persists across relaunch. Pre-pause or old callbacks cannot resume it. Explicit Start resets it. | Significant changes are coarse; departure may be missed until a fresh event or configured exit region. |
| Adaptive accuracy | Optional confirmed-stop policy lowers requested accuracy while retaining coarse updates and an Always-authorized exit region. Motion confirmation defaults required; GPS-only and trips are separate choices. | Lower accuracy can delay departure capture. A strict saved-point filter may reject coarse fixes. Moving acquisition uses the saved engine's accuracy/pause capabilities. |
| Motion | Activity access has an explicit permission button; legacy trip step queries also use Motion & Fitness. Authorized metadata uses bounded timestamped history. Optional assistance respects Stop and requires a separate opt-in to resume radius pause. | Core Motion cannot wake suspension by itself. Classification is uncertain and does not improve GPS accuracy. |
| Live engine recovery | One initial attempt plus three retries, then a latched fallback to CLLocationManager. Explicit recovery actions release the latch. | No source can guarantee fixes with revoked permission or unavailable GPS. |
| Background sessions | CLBackgroundActivitySession exists only for live updates that request or need the indicator. Stop, radius pause, noncontinuous modes and lost authorization release it. Optional iOS 18 CLServiceSession retains already-Always authorization intent. | Sessions express eligibility and intent, not unlimited execution time. |
| Background recovery | An optional significant-change monitor accompanies Standard tracking and trips with Always access on supported devices. Both mode already monitors significant changes. Stop and event-only settings retain their existing behavior. | It can provide an OS relaunch trigger after system termination. Events are coarse and delayed; Background App Refresh restrictions and force-quit can prevent relaunch. Energy cost is unmeasured. |
| Presentation | Scene visibility gates bridge timers, replay reads, trip-map queries and map animation links. Settled links stop. | Foreground map rendering and replay still consume energy. |
| Uploads | One request at a time, a yield after 20 drain requests, persisted intent/backoff, Retry-After and retained failed records. Optional system processing and connection-return retries reuse this path. | iOS chooses processing opportunities. Network traffic and short send intervals cost energy. |
| Storage | Each accepted, committed point is copied to a separate replay archive. Retention defaults to 24 hours and can extend to seven days. Payload reads stay bounded; presentation reloads wait during dragging/playback. | Serialization and a local write per point add work. Longer retention increases disk use and initial route work; device energy cost has not been measured. |

All five Usage Presets and their defaults remain unchanged. Advanced choices are
independent and off by default. Requested accuracy controls acquisition; Max
Saved-Point Error filters returned fixes. Keeping only accurate saved points does
not, by itself, reduce the GPS work used to obtain them.

## Live Activity and audio

Status and Minimal have a widget-backed Live Activity. Blank uses app-only
ActivityAttributes absent from the extension. It produced a short blank Island
without a WhereWolf Lock Screen card in the owner's device check. Its unrendered
activity did not maintain live-update delivery in the iOS 27 background route
check, so indicator-off tracking with Always access uses the original engine.
This presentation is version-dependent and needs rechecking after system updates.

Live Activity staleness mirrors the existing pending reminder deadline; it does
not create a second location timeout. Activities are adopted after relaunch and
ended on Stop, lost access or option-off. Expiry and dismissal do not cause a
background restart loop. iOS controls presentation, priority and lifetime.

Silent Audio remains optional and off by default. It loops a silent PCM buffer
through AVAudioPlayer on a serial queue, mixes with other apps and uses no
microphone. Playback checks run only while enabled. Unexpected stops have three
bounded retries; calls, interruptions without resume permission and media-service
loss block automatic recovery. Stop or lost location access stops playback.

[StikDebug's audio manager](https://github.com/StikDebug/StikDebug/blob/main/StikDebug/Services/BackgroundAudioManager.swift)
provided a public reference for the approach. No StikDebug code or assets were
copied. SuperAlarm's implementation has not been verified from public source.
Apple documents audio background mode for audible playback; a silent keepalive
may not satisfy [App Review guideline 2.5.4](https://developer.apple.com/app-store/review/guidelines/#software-requirements).
Its energy cost remains unmeasured.

Notifications remain an independent, opt-in warning mechanism. Problems Only
hides routine status while retaining existing missed-update and upload-error
messages. A notification does not keep WhereWolf running. A missed deadline does
not identify whether suspension, missing fixes or termination caused the gap.

## What still needs measurement

Use the same phone, route, requested accuracy, point filters and send interval
for comparisons. Change one advanced option at a time. Record route gaps,
received/saved point counts, reported accuracy, departure latency, upload backlog,
location indicator state and energy use. Include:

- A long stationary period followed by walking, driving and transit.
- Weak GPS, tunnels, low-power mode and reduced-accuracy permission.
- Screen locking, background relaunch, motion denied and revoked location access.
- Airplane mode, network return, server Retry-After and invalid credentials.
- Calls, other audio, activity dismissal and activity expiry.

Use a physical-device Instruments energy trace or delivered MetricKit reports;
a simulator route or successful build cannot establish a battery percentage.
The temporary TestFlight collector stores reports locally and uploads none.

The original remote pause-setting normalization question is separate: the UI
clears incompatible radius/automatic-pause choices, while remote settings retain
inactive values. Advanced options do not silently normalize those legacy values.

No helper bypasses force-quit, revoked access or operating-system scheduling.
Location processing, storage, reminders and uploads remain independent of an
active SwiftUI scene. Endpoint URLs, credentials, custom headers and GeoJSON/
OwnTracks request contracts are unaffected by acquisition policies.

## October 30 background-reliability review

The new `background_recovery` option closes a specific gap: trips previously
disabled significant-change monitoring even when normal tracking used Both.
It is independent of presets and defaults off. Settings → Background exposes
the option, the system Background App Refresh status, and the limitations in
its info sheet. Existing point-quality filters still apply to delivered fixes.

Apple documents relaunch through significant-change events. Its modern location
session guidance also requires prompt restoration after launch; WhereWolf already
restores its saved acquisition state during `GLManager` initialization. Neither
route guarantees continuous process execution or a fixed recording interval.
See [significant-change monitoring](https://developer.apple.com/documentation/corelocation/cllocationmanager/startmonitoringsignificantlocationchanges())
and [authorization-session restoration](https://developer.apple.com/videos/play/wwdc2024/10212/).

The current [Traccar iOS source](https://github.com/traccar/traccar-client-sdk/blob/main/core/src/iosMain/kotlin/org/traccar/client/IosLocationSource.kt)
starts significant-change and continuous updates together. Its maintainer also
reports that [iOS heartbeat scheduling is unreliable](https://github.com/traccar/traccar-client/issues/96)
in the issue discussion; adding a timer does not establish a wake guarantee.
[OwnTracks](https://owntracks.org/booklet/features/ios/) combines movement,
significant-change and region mechanisms rather than promising fixed wakeups.

[LocoKit2](https://github.com/sobri909/LocoKit2/blob/main/Sources/LocoKit2/Managers/LocomotionManager.swift)
currently uses a second, low-accuracy manager alongside its recording manager
in one operating mode. WhereWolf's classic manager already requests unrestricted
distance delivery, background updates and the user's accuracy. With accuracy
better than 1 km, that matches [Apple DTS's documented conditions](https://developer.apple.com/forums/thread/726945)
for indicator-off continuous tracking. A second manager has no measured benefit
for our classic path and would add another service to reconcile. It remains a
candidate for a controlled modern-engine experiment, not a default helper.

`BGContinuedProcessingTask` is designed for finite, user-started jobs and displays
progress in a Live Activity. It may help a future large export, but does not
provide an indefinite location session. A Location Push Service Extension is
intended for approved person-to-person location sharing or emergency response;
it needs its capability and a server, and does not sustain continuous logging.
See [continued processing](https://developer.apple.com/documentation/backgroundtasks/bgcontinuedprocessingtask)
and [location push extensions](https://developer.apple.com/documentation/corelocation/creating-a-location-push-service-extension).

Recovery tests cover Standard and trip monitoring, permission and device gates,
Stop, event-only modes, disabling recovery without restarting GPS, and preset
recognition. These checks establish state transitions, not successful OS
relaunch or battery savings. Recovery remains off by default.

## References

- [Apple: Background location](https://developer.apple.com/documentation/corelocation/handling-location-updates-in-the-background)
- [Apple: Streamlined location updates](https://developer.apple.com/videos/play/wwdc2023/10180/)
- [Apple: Modern authorization sessions](https://developer.apple.com/videos/play/wwdc2024/10212/)
- [Apple DTS: Background execution limits](https://developer.apple.com/forums/thread/685525)
- [Apple: Core Motion activity](https://developer.apple.com/documentation/coremotion/cmmotionactivitymanager)
- [Apple: Significant-change monitoring](https://developer.apple.com/documentation/corelocation/cllocationmanager/startmonitoringsignificantlocationchanges())
- [Implementation, options and research](docs/tracking-improvements.md)
