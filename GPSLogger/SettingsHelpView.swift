import SwiftUI

struct SettingsHelpButton: View {
    let topic: SettingsHelpTopic
    @State private var showingHelp = false

    var body: some View {
        Button {
            showingHelp = true
        } label: {
            Image(systemName: "info.circle")
                .frame(minWidth: 32, minHeight: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("About \(topic.rawValue)")
        .sheet(isPresented: $showingHelp) {
            SettingsHelpView(topic: topic)
        }
    }
}

struct SettingsSectionHeader: View {
    let title: String
    let topic: SettingsHelpTopic

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            SettingsHelpButton(topic: topic)
        }
        .textCase(nil)
    }
}

struct SettingsHelpView: View {
    let topic: SettingsHelpTopic
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(topic.entries, id: \.title) { entry in
                    Section {
                        Text(entry.detail)
                        Link(entry.source.title, destination: entry.source.url)
                            .font(.footnote)
                    } header: {
                        Text(entry.title)
                    }
                }
            }
            .navigationTitle(topic.rawValue)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

private struct SettingExplanation {
    let title: String
    let detail: String
    let source: SettingsSource

    init(_ title: String, _ detail: String, _ source: SettingsSource) {
        self.title = title
        self.detail = detail
        self.source = source
    }
}

private enum SettingsSource {
    case accuracy, activity, significant, background, coreLocation, locationEngine, motion, adaptive, readme, implementation, activityKit, audio, stikDebug

    var title: String {
        switch self {
        case .activityKit: return "Apple: Live Activities"
        case .audio: return "Apple: Background execution modes"
        case .stikDebug: return "StikDebug: Silent audio implementation"
        case .accuracy: return "Apple: Desired accuracy"
        case .activity: return "Apple: Activity type"
        case .significant: return "Apple: Significant-change monitoring"
        case .background: return "Apple engineer: Background updates (iOS 16.4+)"
        case .coreLocation: return "Apple: Core Location"
        case .locationEngine: return "Apple: Live location updates"
        case .motion: return "Apple: Core Motion activity"
        case .adaptive: return "Traccar: Position filtering"
        case .readme: return "WhereWolf README: Usage profiles"
        case .implementation: return "WhereWolf README (published version)"
        }
    }

    var url: URL {
        let path: String
        switch self {
        case .activityKit: path = "https://developer.apple.com/documentation/activitykit/displaying-live-data-with-live-activities"
        case .audio: path = "https://developer.apple.com/documentation/xcode/configuring-background-execution-modes"
        case .stikDebug: path = "https://github.com/StikDebug/StikDebug/blob/main/StikDebug/Services/BackgroundAudioManager.swift"
        case .accuracy: path = "https://developer.apple.com/documentation/corelocation/cllocationmanager/desiredaccuracy"
        case .activity: path = "https://developer.apple.com/documentation/corelocation/cllocationmanager/activitytype"
        case .significant: path = "https://developer.apple.com/documentation/corelocation/cllocationmanager/startmonitoringsignificantlocationchanges()"
        case .background: path = "https://developer.apple.com/forums/thread/726945"
        case .coreLocation: path = "https://developer.apple.com/documentation/corelocation"
        case .locationEngine: path = "https://developer.apple.com/videos/play/wwdc2023/10180/"
        case .motion: path = "https://developer.apple.com/documentation/coremotion/cmmotionactivitymanager"
        case .adaptive: path = "https://www.traccar.org/position-filtering/"
        case .readme: path = "https://github.com/SoPat712/WhereWolf#usage-profiles"
        case .implementation: path = "https://github.com/SoPat712/WhereWolf#api"
        }
        return URL(string: path)!
    }
}

enum SettingsHelpTopic: String {
    case runtime = "Background Runtime"
    case presets = "Usage Presets"
    case permissions = "Permissions"
    case tracking = "Tracking"
    case engine = "Location Engine"
    case precision = "Precision"
    case motionAdaptive = "Motion & Adaptive Tracking"
    case quality = "Point Selection & Quality"
    case stationary = "Stationary Behavior"
    case batching = "Logging and Sending"
    case background = "Background Indicator"
    case automation = "WiFi and Notifications"
    case backup = "Backup & Sync"
    case coverage = "Coverage"
    case server = "Server Configuration"
    case trip = "Trip Settings"
    case locationHealth = "Location Updates & Recovery"

    fileprivate var entries: [SettingExplanation] {
        switch self {
        case .locationHealth:
            return [
                .init("Automatically Retry Location Updates", "Off by default. When continuous tracking is expected but no fresh location arrives for the chosen time, WhereWolf can restart acquisition. Old or repeated readings do not reset the retry limit. Fresh readings reset it even if your saved-point filters reject them. This avoids restarting GPS just because an accuracy, distance, time or stationary filter kept a point out of the queue.", .implementation),
                .init("Retry limits and pauses", "The default wait is two minutes, adjustable from one to thirty minutes. After the first attempt, the next waits are twice and five times your chosen wait. Each app session permits at most three attempts without a fresh reading. A manual retry, an explicit tracking restart or a retry-setting change also resets the limit. Stop, lost location access, event-only modes, automatic pauses, radius pauses and adaptive power saving prevent automatic retries. Failed new-engine streams keep their existing fallback to the original engine.", .implementation),
                .init("What a check can do", "These checks run only when iOS lets WhereWolf execute. A timer cannot wake a suspended or terminated app. Background Recovery Monitoring and Visit Tracking provide separate location events that may let iOS relaunch the app. The checks do not change the ten-minute notification reminder, Live Activity appearance or saved-point settings, and cannot reconstruct points that were never received.", .coreLocation),
                .init("Saving received locations", "A short iOS background execution allowance covers queue commits and waits for already-enqueued local history and Health route writes. It ends when those writes finish or iOS expires it. This protects work already received; it does not keep tracking alive indefinitely or acknowledge an upload.", .implementation),
                .init("Save Location Health Log", "Off by default and independent of automatic retries. Saves at most 200 events from the past seven days in a protected, backup-excluded file on this device. It records observed gaps, skipped-point reasons, retries and resumed updates without coordinates, server addresses or credentials. It is never uploaded automatically. Share Health Log is an explicit sharing action. Turning logging off preserves existing entries; Clear Health Log deletes them without deleting locations. Events cannot prove why iOS stopped running the app.", .implementation)
            ]
        case .presets:
            return [
                .init("What changes", "Presets change normal tracking mode, accuracy, activity, pausing, resume distance, stationary thresholds, point filters, the background indicator and visit tracking. They leave the server, credentials, logging format, send interval, batch size and trip-specific settings alone. The resume distance is shared with trips and does change. They do not start a stopped tracker. Finish an active trip before applying one. Editing a covered setting changes the selector to Custom.", .implementation),
                .init("Everyday Detailed", "The default for new installations. Uses High Resolution's Standard updates, Best accuracy and Other activity, with automatic pausing, geofence resume, stationary stopping and visits off. The background indicator is off, and saved points must be at least 10 m apart and 5 seconds apart. These filters reduce saved points while GPS keeps running; battery savings are not guaranteed. Existing installations keep their saved settings.", .implementation),
                .init("High Resolution", "For detailed route recording. Standard updates, Best accuracy, Other activity, automatic pausing and geofence resume off. Point filters and stationary stopping are off; the indicator is on and visits are off. Based on the README's high-resolution profile. More detail costs power; one point per second is not guaranteed.", .readme),
                .init("Low Power", "For coarse location history. Significant-change updates, Other activity, automatic pausing on and a 500 m resume distance. The stored standard-update accuracy is 100 m, but it does not control significant-change accuracy. Pausing and resume values also concern standard updates, not the timing of significant changes. Point filters, stationary stopping, the indicator and visits are off. Based on the README's low-resolution profile; this cannot capture a detailed route.", .readme),
                .init("Balanced", "For everyday history with more detail while moving. Both update sources, 100 m requested accuracy, Other activity, and stationary stopping within 50 m after 3 minutes. Automatic pausing and geofence resume are off; significant changes resume tracking. Point filters are off, the indicator is on and visits are off. WhereWolf's concrete starting values for the README's battery-saving/high-resolution approach; battery savings are not measured or guaranteed.", .readme),
                .init("Walking / Running", "High Resolution with Fitness activity, to describe the expected movement to iOS. All other High Resolution values apply. This is a WhereWolf recommendation based on Apple's activity guidance, not an Apple-provided preset.", .activity),
                .init("Driving", "High Resolution with Automotive activity and Navigation accuracy. All other High Resolution values apply. This is a WhereWolf recommendation for detailed driving tracks, not an Apple-provided preset. Navigation accuracy can use more power.", .activity)
            ]
        case .permissions:
            return [
                .init("Location access", "iOS controls whether WhereWolf may obtain location. When in Use permits foreground use and some active background sessions; Always supports background location use more broadly. Denied or restricted access must be addressed in iOS Settings. Permission alone does not start tracking.", .coreLocation),
                .init("Precise Location", "If Precise Location is disabled in iOS Settings, requesting a smaller accuracy value cannot restore precise fixes.", .accuracy),
                .init("Motion & Fitness", "Core Motion permission is separate from Location Access. Use Allow Motion & Fitness to grant activity access. Existing trip step counting also uses this permission. Denied or restricted access disables motion confirmation but does not stop ordinary location tracking.", .motion)
            ]
        case .tracking:
            return [
                .init("Tracking Enabled", "Starts or stops collection. Stopping keeps queued records for later sending. Trips temporarily use their own tracking configuration and restore the earlier tracking state when ended.", .implementation),
                .init("Update Mode", "Off disables standard and significant-change updates; visit tracking is separate. Standard requests regular location updates. Significant uses iOS's coarse movement service. Both enables both sources and permits WhereWolf's stationary radius/time logic to pause standard updates until significant movement.", .implementation),
                .init("Significant changes", "iOS schedules these events, not the send interval or distance filter. Apple describes movements of around 500 m or more and says not to expect updates more often than every five minutes. Network availability affects timeliness. This is unsuitable for a detailed walking route.", .significant),
                .init("Visit Tracking", "Records iOS-detected arrivals and departures at places. Visit events are separate from continuous route points and may arrive after the visit occurred.", .coreLocation)
            ]
        case .engine:
            return [
                .init("Benefits", "The new engine automatically pauses GPS while stationary and resumes when you move. It avoids delivering the same stationary locations repeatedly. On iOS 18 and later, it also reports more detailed reasons for missing updates, such as limited accuracy or authorization.", .locationEngine),
                .init("Tradeoffs", "iOS chooses accuracy and pause timing using your Activity Type. Desired Accuracy and Pause Updates Automatically cannot override live updates. Use the original engine to request custom or Navigation accuracy, or to disable automatic pausing. The new engine does not guarantee lower battery use, higher precision or uninterrupted recording.", .locationEngine),
                .init("Both engines can pause", "The original engine also supports automatic pausing when Pause Updates Automatically is enabled. WhereWolf can install a resume region after a pause. The new engine handles movement-based resume itself, so pausing is not a capability unique to the new engine.", .coreLocation),
                .init("Trip behavior", "An automatic pause ends an active trip. The new engine can pause even when the trip's Pause Updates Automatically setting is off. To disable automatic pauses during trips, leave Use new location engine off and turn the trip's Pause Updates Automatically setting off.", .implementation),
                .init("Background and the indicator", "With Always access and the background indicator off, the new engine needs an active widget-backed Live Activity for background updates: Status, Minimal, or Blank with Lock Screen Card on. Blank with the card off uses the original engine in this configuration. If an activity ends, WhereWolf also falls back to the original engine without changing your preferences. Trips have a separate indicator setting. When in Use access may require the system indicator.", .locationEngine),
                .init("Defaults and presets", "The toggle defaults off and does not change preset values, saved-point filters, queueing or uploads. Off preserves the existing engine selection: Best accuracy with automatic pausing can still use live updates. Disabling automatic pausing with this toggle off selects the original engine.", .implementation),
                .init("Stream recovery", "After three retries fail, WhereWolf falls back to the original engine. This failure remains latched until an explicit start, Retry, refresh, engine change or restored location access. Foregrounding alone does not repeat the failed retry cycle.", .implementation)
            ]
        case .precision:
            return [
                .init("Requested Accuracy / Target Accuracy", "Custom requests an accuracy in meters; a smaller value asks for a more precise fix. Best requests the best available accuracy; Navigation requests navigation-grade accuracy. These are requests, not guarantees: less accurate fixes may arrive first, and higher precision can take more time and power. The new engine lets iOS choose accuracy. This request does not change the saved-point filter.", .accuracy),
                .init("Why the request and filter are separate", "A 10 m request can return a valid 20 m fix. Automatically setting the saved-point limit to 10 m would discard it and could create gaps. Requested Accuracy changes the request only. The main Usage Presets set both, with the saved-point accuracy filter Off. Custom filters stay independent of the request.", .implementation),
                .init("Activity Type", "Tells iOS the expected activity: Other, Automotive, Fitness, other Navigation, or Airborne. It is a hint used when deciding whether updates can pause, not a motion classifier or trip label. Choose the activity you actually expect to perform.", .activity),
                .init("Min Distance Between Points", "Discards received points closer than this many meters to the last accepted fix. Off keeps them. This filters recorded data after delivery; it does not directly reduce GPS sampling or guarantee lower battery use.", .implementation),
                .init("Min Time Between Points", "Discards received points less than this many seconds after the last accepted fix. Off disables this filter. It is not a request to iOS for a fixed sampling interval.", .implementation),
                .init("Max Saved-Point Error", "Rejects fixes whose reported horizontal uncertainty exceeds this many meters. Lower values are stricter and may leave gaps indoors or during a weak fix. Off accepts any otherwise-valid accuracy. This filter applies to normal tracking and trips, independently of the accuracy requested from iOS.", .implementation),
                .init("Slider detents", "Tick marks snap to common time, distance and count settings with selection feedback. Values between the marks are still available. Tap the displayed value to enter an exact number. Dragging previews the setting; releasing the slider saves it.", .implementation)
            ]
        case .motionAdaptive:
            return [
                .init("Motion & Fitness permission", "Core Motion can classify activity such as walking, running, cycling, automotive movement and stillness. Use Allow Motion & Fitness to grant activity access; changing an advanced option never prompts. Existing trip step queries can also request this permission. Denied or restricted access leaves motion confirmation unavailable; a motion callback cannot wake a suspended app by itself.", .motion),
                .init("Motion-assisted tracking", "An opt-in motion hint can help WhereWolf interpret movement and, when separately enabled, resume after a motion-confirmed stop. It does not replace location, improve reported accuracy or guarantee a timely callback.", .motion),
                .init("Adaptive Tracking", "After a sustained, confirmed stop, adaptive tracking lowers the requested accuracy while retaining coarse updates and an exit region. This can save power but may delay departure detection. Moving tracking returns to the saved accuracy and pause settings. Existing trips remain unchanged unless Apply During Trips is enabled.", .adaptive),
                .init("Adaptive thresholds", "Dwell, radius and resume-radius values describe WhereWolf's stop confirmation and movement watch. Require Motion Confirmation keeps detailed tracking active when motion is unknown or permission is unavailable. Turn it off to allow GPS-only stop confirmation. It never prompts for permission automatically.", .implementation),
                .init("Trip behavior", "Adaptive Tracking is independent of the existing trip controls. Enable Apply During Trips explicitly if you accept quieter trip tracking; otherwise trips retain their saved accuracy and pause behavior.", .implementation)
            ]
        case .quality:
            return [
                .init("Any threshold", "The existing distance AND time minima remain unchanged when this is off. When on, a point can qualify by distance, time or the optional turn trigger. This changes which returned fixes are saved; it is not a request for a particular sampling interval.", .adaptive),
                .init("Reject Implausible Jumps", "The filter compares displacement, elapsed time and reported uncertainty against your maximum speed. An implausible jump is held back until another nearby fix, at least one second later, confirms relocation. Raise the limit for fast travel or leave it off. It does not guarantee true accuracy or road-snap points.", .adaptive),
                .init("Adaptive Max Error / Idle Accuracy", "Max Error limits fixes used to confirm a stop. Idle Accuracy is the location request after that stop. Both remain separate from Max Saved-Point Error, which controls saved points. These values are thresholds and requests, not guarantees about the true position on the ground.", .implementation)
            ]
        case .stationary:
            return [
                .init("Stop Within Radius / Stop After", "In Both mode, WhereWolf pauses standard updates after validated raw fixes remain within the radius for the configured time. Significant-change monitoring continues and a fresh movement event can resume them. Old callbacks cannot clear the pause. Radius Off disables this behavior. This is separate from iOS automatic pausing and does not stop an active trip.", .implementation),
                .init("Pause Updates Automatically", "Allows iOS to decide when the original engine's standard updates can pause. Turning it off favors continuity and may use more power. The new engine manages pausing itself. WhereWolf handles pause callbacks and can install a resume region; during a trip, automatic pausing can end the trip.", .implementation),
                .init("Resume After Moving", "After an automatic pause, WhereWolf creates a circular region around the last fix. Exiting it can resume an enabled tracker. This distance is shared by normal and trip settings. Region delivery is not an exact crossing alarm. Off disables the resume region; disabling automatic pausing also clears this value.", .implementation)
            ]
        case .batching:
            return [
                .init("Logging Mode", "All Data queues GeoJSON records. Only Latest deliberately replaces queued location data with the latest update. OwnTracks uses OwnTracks JSON and sends one location per request; unsent fixes stay queued. Select the format your server accepts.", .implementation),
                .init("Locations per Batch", "Limits the number of queued records in a GeoJSON request. Smaller batches make smaller requests; larger ones can drain a backlog with fewer requests. OwnTracks sends one point at a time regardless of this setting.", .implementation),
                .init("Send Interval / Send Every", "Automatic sends are considered when locations arrive after this interval. This is not an exact background timer. Off means manual sending. Failed attempts retain their points; Last Sent changes only after the server acknowledges success.", .implementation),
                .init("Background Uploads", "An opt-in operating-system scheduler can ask WhereWolf to drain pending records while the app is not active. It has no exact interval and does not change the queue acknowledgment rules.", .implementation),
                .init("Retry Connectivity Failures", "When enabled, eligible network failures can retry when connectivity returns. Retry-After and authentication errors remain authoritative; this option does not retry a server rejection indefinitely.", .implementation),
                .init("Include Tracking Stats", "Adds tracking configuration to new GeoJSON points and queues diagnostic events such as pause and resume. OwnTracks omits these stats. Applies to new records; previously saved records are unchanged.", .implementation),
                .init("Delete Pending Uploads", "After confirmation, permanently deletes the records currently queued for your destination, including trip summaries and imported workout points. It preserves local history, saved workout routes, active tracking and the active trip. Deletion is unavailable during an upload; if the database commit fails, records and retry state are kept.", .implementation)
            ]
        case .runtime:
            return [
                .init("Background Recovery Monitoring", "An independent, default-off significant-change monitor runs alongside Standard tracking and during trips when enabled with Always access. It can give iOS a reason to relaunch WhereWolf after system termination. It does not replace precise tracking, guarantee a wake interval, override Stop or radius pause, or bypass force-quit. Background App Refresh restrictions can prevent relaunch. Coarse fixes still pass the existing saved-point filters. Extra callbacks may cost energy; device battery savings have not been measured.", .significant),
                .init("Tracking Live Activity", "Starts while tracking is enabled and WhereWolf is in the foreground. Blank is the default for new installs; saved appearance choices remain. Minimal shows a location icon. Status adds the last successful send time in the expanded Dynamic Island. Blank keeps the Island empty, including reminders. Lock Screen Card defaults off; with it off, Blank starts an app-only activity and uses the original engine with Always access and the background indicator off. Turning the card on uses the widget-backed activity, like Minimal. Minimal and Status always include the rich Lock Screen card, showing tracking, fix and send times, queued records and Send Now. Active trips add distance, duration and End Trip; the trip line is omitted when a separate trip Live Activity is active. Activities expire after up to eight hours and can be dismissed. Open WhereWolf or tap Retry to start another; tracking itself continues independently.", .activityKit),
                .init("Dynamic Island priority", "WhereWolf uses a relevance score of zero and sends no Live Activity alerts. The score ranks activities from WhereWolf; it cannot give Music or another app priority. iOS chooses which activities appear attached to the Island or in a smaller bubble. WhereWolf cannot force the smaller presentation while keeping its activity active.", .activityKit),
                .init("Hide While Audio Plays", "Off by default. With Always location access, two audio checks at least 15 seconds apart end tracking and trip Live Activities while another app plays audio. Without Always access they stay visible to protect background tracking. It reacts within about 15 seconds while WhereWolf is running in the background (moving or with Silent Audio on). While iOS has WhereWolf suspended, it reacts at the next location update or when you open the app. When audio stops, the same confirmation allows one attempt to restore them in the background; iOS may require you to open WhereWolf. Ask to Reopen When Audio Stops can remind you to do that. Indicator-off tracking uses the original engine while hidden. WhereWolf's own silent audio does not count and is unaffected.", .activityKit),
                .init("Ask to Reopen When Audio Stops", "Off by default and shown while Hide While Audio Plays is on. After audio has stopped for 15 seconds, a refused or deferred background restore schedules one silent notification five minutes later, without sound or vibration: Music stopped — Open WhereWolf to bring back its Live Activity. It can arrive while the app is suspended. Opening WhereWolf, Retry, a restored activity, renewed audio, turning either switch off, losing Always access, stopping tracking, or having no activity left to restore removes the prompt. It needs existing notification permission; only the inline Allow button requests it. Notifications and Problems Only do not control this prompt. The missed-update reminder keeps its own deadline.", .activityKit),
                .init("Open WhereWolf reminder", "Uses the same deadline as the existing ten-minute location reminder. When it passes, Status and Minimal show the same message in the Dynamic Island asking you to open WhereWolf. Blank stays empty. Tap the activity to open Tracker. The separate notification remains controlled by Notifications, and its existing suppression rules still apply. A missed deadline cannot prove the app was killed or the server is offline. iOS controls when the warning appears, and cannot show it after the activity ends or is dismissed.", .activityKit),
                .init("Silent Audio", "An optional loop of digital silence using the audio playback background mode. It mixes with other audio, uses no microphone, and stops when tracking stops or location access is lost. While enabled and playing, a health check detects unexpected stops. Recovery tries up to three times with backoff, then waits for Retry Background Helpers. Automatic recovery waits during calls, interruptions and audio-service loss, and resumes only when allowed. This is an experimental keepalive technique, not a guarantee or a battery improvement.", .stikDebug),
                .init("Distribution and reliability", "Apple documents the audio background mode for audible playback. A silent keepalive may conflict with App Store review requirements. These options do not bypass force-quit, permissions, system termination, or your existing stationary-pause settings. Test background recording on a physical device.", .audio)
            ]
        case .background:
            return [
                .init("Show Background Indicator", "Controls the location-use indicator during background tracking. Trips have a separate setting. With Always access, turning it off releases the indicator session. The new engine needs an active Status, Minimal, or Blank-with-card Live Activity for background updates; Blank without the card or no activity uses the original engine to honor this setting. When in Use access can require the system indicator. Turning it off does not stop collection.", .coreLocation),
                .init("Explicit Service Session", "On iOS 18 and later, asks Core Location for an explicit authorization session for background delivery. It requires already-Always access and remains opt-in. The request does not guarantee that iOS will run the app or deliver a fix at a particular time.", .coreLocation),
                .init("Background continuity", "In the linked iOS 16.4 discussion, an Apple engineer describes suspension with combined standard/significant updates at low accuracy and with distance filtering. The guidance uses continuous background permission, no manager distance filter, and requested accuracy below 1,000 m, or enables the indicator. This is guidance for that configuration, not a guarantee for every device or OS release. WhereWolf's saved-point filters are separate from the manager's distance filter.", .background)
            ]
        case .automation:
            return [
                .init("Wi-Fi Places", "Give a place a point and one or more network names. While connected within about \(WifiPlace.distanceLabel(GLWifiPlaceMatchDistance)) of the pin, record the place’s point (on arrival, then every 5 minutes) or save nothing. If iOS can’t read the network name in the background, the match holds until a fix lands outside or another network connects. Each fix’s uncertainty adds up to 200 m; the nearer place wins when places share a network. Drag the map to move the pin. The picker shows connected, observed and configured names, with manual entry. iOS reveals only the connected network; it does not scan. Identification needs location permission and Access WiFi Information in the signing profile.", .implementation),
                .init("Notifications", "Controls WhereWolf's local tracking and send-related notifications. Problems Only keeps the existing missed-update reminder and upload errors, while hiding routine pause, resume and trip messages. iOS notification permission is also required. Notifications do not turn location tracking or background execution on. They are separate from the blank Island's presentation.", .implementation)
            ]
        case .backup:
            return [
                .init("Settings files", "Exports only configuration as a versioned JSON file. Include Server URL and Token defaults on and includes custom headers; the file contains your server credential. Turning it off omits all three. Import validates every known value, previews changes and confirms credential replacement. Tracking on/off, active trips and permissions are kept; finish a trip before importing.", .implementation),
                .init("Optional iCloud sync", "Off by default. Latest changes win per setting. Server URL, token and headers use iCloud Keychain; other settings use ubiquitous key-value storage. Device ID, permissions, activity IDs, queues, history and Health records do not sync. Incoming changes wait until a trip ends. Turning sync off stops this iPhone from syncing; existing iCloud values remain.", .implementation)
            ]
        case .coverage:
            return [
                .init("Recorded, paused and gaps", "Recorded spans connect accepted fixes up to ten minutes apart. A longer silence while tracking is expected marks a gap; tap it for times and duration. Stop, tracking off, automatic and stationary pauses, event-only tracking and lost access show paused. Time before the log began is unknown. Reception and point filters can cause gaps too, so gaps cannot prove iOS terminated the app.", .implementation),
                .init("Local totals", "The report uses the history retention window, hourly accepted-point counts, send outcomes and current queued points. Its protected, coordinate-free log keeps at most 2,000 state transitions and 20,000 sends. Nothing in the report uploads. Keep-alive links show saved options; helpers require tracking and location access, and iOS still controls background execution.", .implementation)
            ]
        case .server:
            return [
                .init("Test Connection", "Saves your server edits and immediately sends your current location as a real point, even on cellular. Uses a fix at most 30 seconds old or a one-shot request with a 15-second timeout. GeoJSON marks the point test: true; OwnTracks stays plain. The test uses the uploader’s shape, headers and token without changing its queue, history, trips or statistics. The result shows HTTP status and result: ok acknowledgement, or a failure with a fix hint.", .implementation),
                .init("Endpoint and token", "The endpoint is your receiving server's HTTP(S) URL. Normal GeoJSON requests use Bearer authentication when a token is provided. OwnTracks uses Basic authentication with the Base64-encoded username:password you enter. Save applies the draft; Clear Server URL disconnects the endpoint without deleting queued points.", .implementation),
                .init("Device ID / Include unique_id", "Device ID labels records; it is not the login username. Include unique_id adds the device's vendor identifier to supported location payloads. Leave it off if your server does not need it.", .implementation),
                .init("Custom HTTP Headers", "Adds headers required by your server or reverse proxy. Names must be unique and values cannot contain line breaks. Authorization and transport-controlled headers are reserved. Header values can contain credentials, so treat them like your access token.", .implementation),
                .init("Accept Any Successful HTTP Response", "When enabled, any successful 2xx response acknowledges a batch, including an empty body. Otherwise WhereWolf requires a JSON object with result set to ok. Match your server's contract: acknowledgment removes the sent records from the queue.", .implementation),
                .init("Status and Recent Sends", "Configured means a URL is saved, not that a connection has been verified. The chart shows up to 50 outcomes from this app process: green success, orange server rejection, red network failure. It resets after relaunch.", .implementation)
            ]
        case .trip:
            return [
                .init("Trip overrides", "Accuracy, activity, logging mode, batch size, point filters, the indicator and pausing override normal settings only during a trip. Their meanings match the normal controls. The resume-region distance is shared. Automatic pausing can end a trip; leave it off if you want to end trips manually.", .implementation),
                .init("Prevent Screen Lock", "Keeps the display awake during an active trip. The display can consume substantial power. Ending the trip releases the override.", .implementation),
                .init("Trip mode and timeline", "The selected mode labels the trip; it is separate from iOS Activity Type. The timeline shows up to 1,000 recent trip points. Scrubbing selects an older point; Live follows the latest point again.", .implementation)
            ]
        }
    }
}
