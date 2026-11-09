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
                        VStack(alignment: .leading, spacing: 8) {
                            Text(entry.summary)
                            ForEach(entry.pros, id: \.self) { SettingsHelpPoint(text: $0, kind: .pro) }
                            ForEach(entry.cons, id: \.self) { SettingsHelpPoint(text: $0, kind: .con) }
                            ForEach(entry.notes, id: \.self) { SettingsHelpPoint(text: $0, kind: .note) }
                        }
                        .padding(.vertical, 2)
                        if let source = entry.source {
                            Link(source.title, destination: source.url)
                                .font(.footnote)
                        }
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

private struct SettingsHelpPoint: View {
    enum Kind { case pro, con, note }

    let text: String
    let kind: Kind
    @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 22

    var body: some View {
        Label {
            Text(text)
        } icon: {
            switch kind {
            case .pro: Image(systemName: "plus.circle.fill").foregroundStyle(.green)
            case .con: Image(systemName: "minus.circle.fill").foregroundStyle(.orange)
            // A full-size symbol scaled down keeps the dot centered on the first line.
            case .note: Image(systemName: "circle.fill").foregroundStyle(.secondary).scaleEffect(0.35)
            }
        }
        .labelStyle(SettingsHelpPointStyle(iconWidth: iconWidth))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        switch kind {
        case .pro: return "Advantage: \(text)"
        case .con: return "Drawback: \(text)"
        case .note: return text
        }
    }
}

private struct SettingsHelpPointStyle: LabelStyle {
    let iconWidth: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            configuration.icon.frame(width: iconWidth)
            configuration.title.frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct SettingExplanation {
    let title: String
    let summary: String
    let pros: [String]
    let cons: [String]
    let notes: [String]
    let source: SettingsSource?

    init(_ title: String, _ summary: String, pros: [String] = [], cons: [String] = [],
         notes: [String] = [], source: SettingsSource? = nil) {
        self.title = title
        self.summary = summary
        self.pros = pros
        self.cons = cons
        self.notes = notes
        self.source = source
    }
}

private enum SettingsSource {
    case accuracy, activity, significant, background, coreLocation, locationEngine, motion, adaptive, readme, implementation, activityKit, audio, healthKit
#if WHEREWOLF_SILENT_AUDIO
    case stikDebug
#endif

    var title: String {
        switch self {
        case .activityKit: return "Apple: Live Activities"
        case .audio: return "Apple: Background execution modes"
        case .healthKit: return "Apple: HealthKit"
#if WHEREWOLF_SILENT_AUDIO
        case .stikDebug: return "StikDebug: Silent audio implementation"
#endif
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
        case .healthKit: path = "https://developer.apple.com/documentation/healthkit"
#if WHEREWOLF_SILENT_AUDIO
        case .stikDebug: path = "https://github.com/StikDebug/StikDebug/blob/main/StikDebug/Services/BackgroundAudioManager.swift"
#endif
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
    case presets = "Usage Presets"
    case permissions = "Permissions"
    case destination = "Destination"
    case tracking = "Tracking"
    case locationRequest = "Location Request"
    case savedPoints = "Saved Points"
    case stationary = "When Stopped"
    case engine = "Location Engine"
    case motionAdaptive = "Motion & Adaptive Tracking"
    case trip = "Trips"
    case wifiPlaces = "Wi-Fi Places"
    case sending = "Sending"
    case liveActivities = "Live Activities"
    case background = "Background Reliability"
    case history = "History & Replay"
    case health = "Apple Health"
    case backup = "Backup & Sync"
    case notifications = "Notifications"
    case coverage = "Coverage"
    case locationLog = "Location Log"

    // Only builds that ship silent audio explain it.
    private static var silentAudioEntries: [SettingExplanation] {
#if WHEREWOLF_SILENT_AUDIO
        [
            .init("Silent Audio", "Experimental: plays silence to try to keep WhereWolf running in the background.",
                  pros: ["May prevent background suspension"],
                  cons: ["Can use more battery", "A keepalive technique, not a guarantee"],
                  notes: ["Mixes with other audio; never uses the microphone",
                          "Stops with tracking or lost location access",
                          "Three retries, then waits for Restart Background Features",
                          "Waits out calls and audio-service loss"],
                  source: .stikDebug),
            .init("Distribution and Reliability", "Apple documents this mode for audible playback, so App Store builds leave it out.",
                  notes: ["Doesn’t bypass force-quit, permissions, termination or pauses",
                          "Test on a physical device"],
                  source: .audio)
        ]
#else
        []
#endif
    }

    private static var healthPermissionEntries: [SettingExplanation] {
        guard HealthTripRecorder.isAvailable else { return [] }
        return [
            .init("Apple Health", "Health never tells apps what you allowed, only that you answered.",
                  notes: ["Reviewed means you answered WhereWolf’s request",
                          "Change access in the Health app"],
                  source: .healthKit)
        ]
    }

    private static var widgetEntry: SettingExplanation {
        .init("Widgets & Shortcuts", "Status and trip controls outside the app.",
              notes: ["Widgets for the Home Screen and Lock Screen",
                      "Control Center controls on iOS 18 and later",
                      "Siri and Shortcuts handle trips, sending, settings and status"]
                + (SharedTripState.isSharedStorageAvailable ? [] : ["This build can’t share data, so widgets show no status"]),
              source: .implementation)
    }

    fileprivate var entries: [SettingExplanation] {
        switch self {
        case .presets:
            // One entry per preset, in the picker's order.
            return [
                .init("What a Preset Sets", "Sets many tracking options at once; editing one switches to Custom.",
                      notes: ["Also sets Resume After Moving, shared with trips",
                              "Leaves server, sending and trip settings alone",
                              "Doesn’t start tracking; unavailable during a trip"],
                      source: .implementation),
                .init("Driving", "The most precise request, for detailed driving tracks.",
                      pros: ["Navigation accuracy, the most precise",
                             "Automatic pausing off, so stops stay recorded"],
                      cons: ["Can use the most power",
                             "Location indicator on",
                             "Every fix saved and uploaded"],
                      notes: ["Automotive hint; point filters and visits off"],
                      source: .activity),
                .init("High Resolution", "Best accuracy and no automatic pausing, for detailed routes.",
                      pros: ["Best accuracy, every fix saved",
                             "Automatic pausing off, so stops stay recorded"],
                      cons: ["High battery use, even when still",
                             "Location indicator on",
                             "Every fix saved and uploaded"],
                      notes: ["One fix per second isn’t guaranteed"],
                      source: .readme),
                .init("Walking / Running", "High Resolution with the Fitness activity hint, for outdoor exercise.",
                      pros: ["High Resolution’s detail",
                             "Tells iOS you’re exercising"],
                      cons: ["High Resolution’s battery use",
                             "Location indicator on"],
                      source: .activity),
                .init("Everyday Detailed", "Best accuracy without the indicator, skipping points within 10 m or 5 s.",
                      pros: ["Best accuracy while moving",
                             "No location indicator",
                             "Quiet when still: fewer points to upload",
                             "Drops stray fixes worse than ±50 m; Wi-Fi Place points stay"],
                      cons: ["GPS still runs, so savings aren’t guaranteed",
                             "Loses detail under 10 m or 5 s",
                             "Coarse indoor fixes can leave short gaps at stops",
                             "Hiding the indicator needs Always access or a Live Activity"],
                      notes: ["The default for new installs"],
                      source: .implementation),
                .init("Balanced", "100 m accuracy that stops standard updates when you stay put.",
                      pros: ["100 m requests can use less power",
                             "Stops standard updates after 3 minutes within 50 m"],
                      cons: ["Coarser points than Best",
                             "Departures can be recorded late",
                             "Location indicator on"],
                      notes: ["Uses Both mode; savings aren’t measured"],
                      source: .readme),
                .init("Low Power", "Significant changes only, for coarse history at the lowest power.",
                      pros: ["Lowest power: iOS reports only larger moves",
                             "No location indicator"],
                      cons: ["About every 500 m, at most every 5 minutes",
                             "No detailed route"],
                      notes: ["Timing depends on iOS and the network",
                              "Its accuracy and pause values affect only standard updates"],
                      source: .readme)
            ]
        case .permissions:
            return [
                .init("Location Access", "iOS decides whether WhereWolf may use location; access alone doesn’t start tracking.",
                      notes: ["While Using covers the app and some background sessions",
                              "Always supports background tracking more broadly",
                              "Relaunch Monitoring and Hide While Audio Plays need Always"],
                      source: .coreLocation),
                .init("Precise Location", "With Precise Location off in iOS Settings, iOS returns only approximate locations.",
                      notes: ["A smaller accuracy request can’t restore precise fixes"],
                      source: .accuracy),
                .init("Motion & Fitness", "Lets Core Motion tell walking, running, cycling, driving and stillness apart.",
                      pros: ["Enables motion assist, adaptive stops and the stationary filter",
                             "Trips use it for stops and steps"],
                      notes: ["Asked only by its Allow button or trip step counting",
                              "Can’t wake a suspended app",
                              "Location tracking works without it"],
                      source: .motion),
                .init("Notifications", "iOS permission that every WhereWolf alert and prompt needs.",
                      notes: ["Each switch still controls its own messages"],
                      source: .implementation)
            ] + Self.healthPermissionEntries
        case .destination:
            return [
                .init("Save to Server", "Uploads queued records to your own endpoint.",
                      pros: ["Points reach your server as they’re sent",
                             "Works with Overland GeoJSON and OwnTracks servers"],
                      cons: ["Needs a server you run or trust",
                             "Uses mobile data unless Send Only on Wi-Fi is on"],
                      source: .implementation),
                .init("Save to iCloud Drive", "Writes GeoJSON files to WhereWolf’s iCloud Drive folder instead.",
                      pros: ["No server needed"],
                      cons: ["Needs iCloud Drive on and an iCloud-enabled build"],
                      notes: ["iOS syncs each file after it’s saved",
                              "Unwritten data stays queued; server settings stay saved"],
                      source: .implementation),
                .init("File Organization", "One iCloud file per day, or one per trip.",
                      notes: ["Per trip leaves out records outside trips"],
                      source: .implementation),
                .init("Test Connection", "Saves your edits and sends your current location as a real point.",
                      pros: ["Checks URL, format, headers and token",
                             "Shows HTTP status and a fix hint"],
                      cons: ["Your server receives a real location",
                             "Sends even on cellular"],
                      notes: ["Uses a fix up to 30 s old, or waits up to 15 s",
                              "GeoJSON marks it test: true",
                              "Queue, history, trips and statistics untouched"],
                      source: .implementation),
                .init("Endpoint and Token", "Your server’s HTTP(S) URL and the credential sent with each request.",
                      notes: ["GeoJSON: Bearer token in the Authorization header",
                              "OwnTracks: Basic auth, Base64 username:password",
                              "Clear Server URL keeps queued points"],
                      source: .implementation),
                .init("Device ID and unique_id", "Device ID labels your records; it isn’t a login.",
                      notes: ["unique_id adds the iOS vendor identifier",
                              "Leave unique_id off unless your server needs it"],
                      source: .implementation),
                .init("Custom HTTP Headers", "Extra headers your server or proxy needs.",
                      notes: ["Unique names; no line breaks in values",
                              "Authorization and transport headers are reserved",
                              "Guard credential values like your token"],
                      source: .implementation),
                .init("Accept Any Successful HTTP Response", "Counts any 2xx reply, even an empty one, as acknowledgement.",
                      pros: ["Works with servers that don’t send result: ok"],
                      cons: ["Clears records the server may not have stored"],
                      notes: ["Off requires a JSON result: ok"],
                      source: .implementation),
                .init("Status and Recent Sends", "Configured means a URL is saved, not that it works.",
                      notes: ["The chart shows up to 50 sends since launch",
                              "Green success, orange rejection, red network failure"],
                      source: .implementation)
            ]
        case .tracking:
            // Update modes in the picker's order, most continuous first.
            return [
                .init("Tracking Enabled", "Starts or stops collection; stopping keeps queued records.",
                      notes: ["Trips restore this state when they end"],
                      source: .implementation),
                .init("Update Mode: Standard", "Continuous location updates for detailed routes.",
                      pros: ["The most detailed, continuous route"],
                      cons: ["The most battery of the modes",
                             "Runs while you’re still unless pausing is on"],
                      source: .coreLocation),
                .init("Update Mode: Both", "Standard updates plus significant changes, which restart them after a stop.",
                      pros: ["Detail while moving",
                             "Stop Within Radius can pause GPS when still"],
                      cons: ["Departures can be recorded late"],
                      source: .implementation),
                .init("Update Mode: Significant", "Only iOS’s coarse movement service.",
                      pros: ["Much lower power than GPS",
                             "Can relaunch WhereWolf after iOS ends it"],
                      cons: ["About every 500 m, at most every 5 minutes",
                             "No detailed route"],
                      notes: ["Timing depends on iOS and the network",
                              "No relaunch after you force-quit"],
                      source: .significant),
                .init("Update Mode: Off", "No standard or significant-change updates.",
                      notes: ["Visit Tracking runs separately"],
                      source: .implementation),
                .init("Visit Tracking", "Records iOS-detected arrivals and departures.",
                      pros: ["A very low-power way to mark stops"],
                      cons: ["Events can arrive late",
                             "Can add jumps to detailed routes"],
                      source: .coreLocation),
                Self.widgetEntry
            ]
        case .locationRequest:
            // Accuracy options in the picker's order, most precise first.
            return [
                .init("How Accuracy Requests Work", "A request to iOS, not a guarantee or a filter.",
                      notes: ["More precision can take more time and power",
                              "A 10 m request can return a valid 20 m fix",
                              "Max Saved-Point Error filters separately",
                              "The new location engine lets iOS choose"],
                      source: .accuracy),
                .init("Accuracy: Navigation", "The most precise request, adding other sensors for navigation.",
                      pros: ["The highest precision iOS offers"],
                      cons: ["Can use the most power"],
                      source: .accuracy),
                .init("Accuracy: Best", "The best accuracy the device can give.",
                      pros: ["Precise fixes for detailed routes"],
                      cons: ["More power than coarser requests"],
                      source: .accuracy),
                .init("Accuracy: Custom", "A Target Accuracy from 5 m to 3 km.",
                      pros: ["Larger targets can use less power"],
                      cons: ["Coarser points as the target grows"],
                      source: .accuracy),
                .init("Activity Type", "A hint about how you travel; iOS uses it to decide when to pause.",
                      notes: ["Other: no particular activity",
                              "Fitness: walking, running or cycling",
                              "Automotive: driving",
                              "Navigation: other vehicles, such as trains",
                              "Boat (iOS 27 and later): on water",
                              "Airborne: flying",
                              "Not a motion classifier or trip label"],
                      source: .activity),
                .init("Trip Accuracy and Activity", "Trips have their own accuracy and activity, used only during a trip.",
                      source: .implementation)
            ]
        case .savedPoints:
            return [
                .init("Discard Points Without GPS", "Skips fixes that don’t seem to come from GPS.",
                      pros: ["Fewer coarse network fixes"],
                      cons: ["Can leave gaps indoors"],
                      notes: ["Judged from altitude accuracy and speed"],
                      source: .implementation),
                .init("Discard Points While Stationary", "Skips points while Motion & Fitness says you’re still.",
                      pros: ["Fewer repeated points while parked"],
                      cons: ["Does nothing without Motion & Fitness"],
                      notes: ["Keeps a stopping point and an hourly heartbeat"],
                      source: .motion),
                .init("Min Distance Between Points", "Drops points closer than this to the last saved one.",
                      pros: ["Fewer points to store and upload"],
                      cons: ["Loses fine detail",
                             "GPS still runs, so battery may not improve"],
                      source: .implementation),
                .init("Min Time Between Points", "Drops points sooner than this after the last saved one.",
                      pros: ["Caps points saved per minute"],
                      cons: ["Loses detail at speed"],
                      notes: ["Not a sampling interval for iOS"],
                      source: .implementation),
                .init("Max Saved-Point Error", "Rejects fixes with more reported uncertainty than this.",
                      pros: ["Removes wild indoor fixes"],
                      cons: ["Strict values leave gaps with weak signal"],
                      notes: ["Shared with trips; separate from Requested Accuracy"],
                      source: .implementation),
                .init("Save When Any Limit Is Met", "Saves when distance, time or turn qualifies; off needs distance and time.",
                      pros: ["More points on slow stretches and turns"],
                      cons: ["More points to store and upload"],
                      source: .adaptive),
                .init("Turn Trigger", "Saves a point when your heading turns this many degrees.",
                      pros: ["Sharp corners with sparse limits"],
                      notes: ["Needs Save When Any Limit Is Met; zero is off"],
                      source: .adaptive),
                .init("Reject Implausible Jumps", "Holds back fixes that would need more than Maximum Speed.",
                      pros: ["Removes stray fixes far off your route",
                             "Keeps flights: a fix's own GPS speed can allow more"],
                      cons: ["Drops the first fix after a flight without fixes"],
                      notes: ["A nearby fix a second later confirms a real move",
                              "Allows for reported uncertainty; doesn’t snap to roads"],
                      source: .adaptive),
                .init("Slider Detents", "Sliders snap to common values; tap a value to type it.",
                      notes: ["Releasing the slider saves"],
                      source: .implementation)
            ]
        case .stationary:
            return [
                .init("Stop Within Radius / Stop After", "In Both mode, pauses standard updates after you stay in the radius this long.",
                      pros: ["No standard GPS updates while parked"],
                      cons: ["Resuming waits for movement, so can be late",
                             "Both mode only, with automatic pausing off"],
                      notes: ["Not applied during trips"],
                      source: .implementation),
                .init("Pause Updates Automatically", "Lets iOS pause the original engine’s updates when you seem stopped.",
                      pros: ["Can save power when you stop"],
                      cons: ["Can end an active trip",
                             "iOS decides when to pause"],
                      notes: ["The new engine manages its own pausing"],
                      source: .implementation),
                .init("Resume After Moving", "After an automatic pause, moving this far from the last fix can resume.",
                      notes: ["Shared with trips",
                              "Region exits aren’t exact alarms"],
                      source: .implementation)
            ]
        case .engine:
            return [
                .init("New Location Engine", "iOS 17 live updates, which pause and resume GPS themselves.",
                      pros: ["Pauses when still, resumes when you move",
                             "No repeated stationary locations",
                             "iOS 18 explains missing updates"],
                      cons: ["iOS picks accuracy and pausing from Activity Type",
                             "Ignores Requested Accuracy and Pause Updates Automatically",
                             "No guaranteed battery savings or gap-free recording"],
                      notes: ["Use the original engine for Custom, Navigation or no pausing"],
                      source: .locationEngine),
                .init("New Engine During Trips", "Its automatic pauses end trips, whatever the trip’s pause setting.",
                      notes: ["To avoid that, turn this off and trip pausing off"],
                      source: .implementation),
                .init("Background and the Indicator", "With the indicator off, the new engine needs a widget-backed Live Activity.",
                      notes: ["Status, Minimal, or Blank with Lock Screen Card qualify",
                              "Otherwise the original engine runs, with Always access",
                              "While Using access may require the indicator"],
                      source: .locationEngine),
                .init("Active Engine", "The engine in use, and why when it differs from your choice.",
                      notes: ["The toggle defaults off and changes no presets",
                              "With it off, Best with pausing can still use live updates"],
                      source: .implementation),
                .init("Stream Recovery", "After three failed retries, WhereWolf falls back to the original engine.",
                      notes: ["Cleared by a start, refresh, engine change or Restart Background Features",
                              "Restored location access also clears it",
                              "Opening the app alone doesn’t retry"],
                      source: .implementation)
            ]
        case .motionAdaptive:
            return [
                .init("Motion-Assisted Tracking", "Uses motion activity to restart GPS after a native pause.",
                      pros: ["Can restart GPS after iOS pauses it"],
                      cons: ["Needs Motion & Fitness",
                             "Can’t improve accuracy or guarantee a wake"],
                      notes: ["Resume Radius Pause on Movement needs movement after the pause",
                              "Confidence: Medium accepts more readings; High, only sure ones"],
                      source: .motion),
                .init("Adaptive Tracking", "After a confirmed stop, requests coarse accuracy until you move.",
                      pros: ["Can save power while stopped"],
                      cons: ["Departures can be detected later"],
                      notes: ["Keeps coarse updates and an exit region",
                              "Trips unaffected unless Apply During Trips is on"],
                      source: .adaptive),
                .init("Adaptive Thresholds", "Dwell, Stop Radius and Resume Radius define a stop and leaving it.",
                      notes: ["Require Motion Confirmation keeps detail when motion is unknown",
                              "Off allows GPS-only stop confirmation"],
                      source: .implementation),
                .init("Adaptive Max Error / Idle Accuracy", "Max Error limits fixes that confirm a stop; Idle Accuracy is the stopped request.",
                      notes: ["Separate from Max Saved-Point Error"],
                      source: .implementation)
            ]
        case .trip:
            return [
                .init("Trip Overrides", "Trip settings replace normal ones only during a trip.",
                      notes: ["Max Saved-Point Error and Resume After Moving are shared",
                              "Change shared values in Tracking & Accuracy"],
                      source: .implementation),
                .init("Trip Location Indicator", "Shows or hides the location indicator during trips only.",
                      pros: ["On: the most reliable background recording"],
                      cons: ["On: an indicator in the status bar"],
                      source: .coreLocation),
                .init("Trip Pausing", "Lets iOS pause trip updates when you stop.",
                      pros: ["Can save power on long stops"],
                      cons: ["An automatic pause ends the trip"],
                      notes: ["Off also turns off resuming on movement"],
                      source: .implementation),
                .init("Ask to End Trip When Stopped", "After 5 minutes within 75 m, asks whether to end the trip.",
                      pros: ["Ends it where you stopped, not when you answer"],
                      cons: ["Needs notification permission"],
                      notes: ["Motion & Fitness keeps traffic stops from counting",
                              "Without it, waits 10 minutes"],
                      source: .implementation),
                .init("Prevent Screen Lock", "Keeps the display awake during a trip.",
                      pros: ["Map and stats stay in view"],
                      cons: ["The display can use a lot of power"],
                      source: .implementation),
                .init("Trip Modes", "A mode labels the trip; it isn’t Activity Type.",
                      notes: ["Edit names, icons and Health workouts in Trip Modes"],
                      source: .implementation)
            ]
        case .wifiPlaces:
            return [
                .init("Wi-Fi Places", "Connected to a place’s network near its pin, WhereWolf uses the pin instead of indoor GPS.",
                      pros: ["No indoor GPS wander",
                             "Stays and Coverage still see the visit"],
                      cons: ["iOS names only the connected network",
                             "Needs location access and a Wi-Fi-capable signing profile"],
                      notes: ["Matches within about \(WifiPlace.distanceLabel(GLWifiPlaceMatchDistance)) of the pin, plus fix uncertainty",
                              "The nearer place wins a shared network"],
                      source: .implementation),
                .init("Record: Place’s Point", "Saves the pin on arrival, then every 5 minutes while you stay.",
                      pros: ["One steady point for the stay"],
                      source: .implementation),
                .init("Record: Nothing", "Saves nothing while connected near the pin.",
                      pros: ["Keeps the place out of your history"],
                      cons: ["No record of time there"],
                      source: .implementation),
                .init("When a Match Ends", "If iOS can’t read the network name, the match holds.",
                      notes: ["A fix outside or another network ends it",
                              "A nameless network never starts a match"],
                      source: .implementation)
            ]
        case .sending:
            // Logging modes in the picker's order, most of the track first.
            return [
                .init("Logging: All Data", "Queues every point as GeoJSON.",
                      pros: ["Your whole track, many points per request"],
                      cons: ["The most data to upload"],
                      source: .implementation),
                .init("Logging: OwnTracks", "Sends each point as OwnTracks JSON, one per request.",
                      pros: ["Works with OwnTracks servers"],
                      cons: ["One request per point; backlogs drain slowly",
                             "No tracking stats"],
                      source: .implementation),
                .init("Logging: Only Latest", "Keeps only the newest location in the queue.",
                      pros: ["The smallest queue and uploads"],
                      cons: ["Discards your route between sends"],
                      notes: ["Events and trip records stay"],
                      source: .implementation),
                .init("Include Tracking Stats", "Adds tracking settings and pause/resume events to new GeoJSON records.",
                      pros: ["Helps explain gaps on your server"],
                      cons: ["Larger records"],
                      notes: ["OwnTracks leaves them out"],
                      source: .implementation),
                .init("Send Interval", "The wait between automatic sends.",
                      pros: ["Shorter keeps your server current"],
                      cons: ["Shorter means more requests and radio use"],
                      notes: ["Checked as fixes arrive, not an exact timer",
                              "Off sends only manually"],
                      source: .implementation),
                .init("Locations per Batch", "The most records in one GeoJSON request.",
                      pros: ["Larger drains backlogs in fewer requests"],
                      cons: ["Larger means bigger requests"],
                      notes: ["OwnTracks sends one at a time"],
                      source: .implementation),
                .init("Send Only on Wi-Fi", "Holds automatic sends until you’re on Wi-Fi.",
                      pros: ["Saves mobile data"],
                      cons: ["Your server lags while you’re away"],
                      notes: ["Send Now, widgets, Shortcuts, Live Activity and watch still send"],
                      source: .implementation),
                .init("Background Uploads", "Lets iOS schedule sends while WhereWolf isn’t open.",
                      pros: ["Drains the queue without opening the app"],
                      cons: ["iOS picks the time"],
                      source: .implementation),
                .init("Retry When Back Online", "Retries network failures when a connection returns.",
                      pros: ["Catches up sooner after dead zones"],
                      notes: ["Retry-After and authentication errors still apply"],
                      source: .implementation),
                .init("Upload Queue and Retries", "Counts records waiting for your destination.",
                      notes: ["Failed sends keep their records",
                              "Authentication errors wait for Retry Uploads"],
                      source: .implementation),
                .init("Delete Pending Uploads", "Permanently deletes every record waiting to be sent.",
                      cons: ["Can’t be undone; includes trip summaries"],
                      notes: ["Keeps history, workout routes, tracking and the active trip",
                              "Unavailable during an upload"],
                      source: .implementation)
            ]
        case .liveActivities:
            // Appearances in the picker's order, richest first.
            return [
                .init("Tracking Live Activity", "Tracking status in the Dynamic Island and on the Lock Screen.",
                      notes: ["Starts while tracking is on and WhereWolf is open",
                              "Lasts up to eight hours; reopen WhereWolf for another",
                              "Tracking continues without it"],
                      source: .activityKit),
                .init("Appearance: Status", "A location icon and On, plus the last send when expanded.",
                      pros: ["The most at a glance",
                             "Warns when updates stop"],
                      cons: ["Fills both sides of the compact Island"],
                      notes: ["Always shows the Lock Screen card"],
                      source: .activityKit),
                .init("Appearance: Minimal", "A location icon only.",
                      pros: ["Warns when updates stop",
                             "One side of the compact Island"],
                      cons: ["No send time"],
                      notes: ["Always shows the Lock Screen card"],
                      source: .activityKit),
                .init("Appearance: Blank", "An empty Island; the default for new installs.",
                      pros: ["Nothing in the Island"],
                      cons: ["No stopped-update warning",
                             "Without the card, indicator-off tracking uses the original engine"],
                      source: .activityKit),
                .init("Lock Screen Card", "Shows tracking, last fix and send, queue count and Send Now on the Lock Screen.",
                      pros: ["Send Now without opening the app",
                             "Lets the new engine run in the background without the indicator"],
                      notes: ["Off by default; only Blank can turn it off",
                              "Trips add distance, duration and End Trip"],
                      source: .activityKit),
                .init("Trip Live Activity", "A separate card with time, distance, speed, Send Now and End Trip.",
                      source: .activityKit),
                .init("Dynamic Island Priority", "iOS decides which activity takes the Island.",
                      notes: ["WhereWolf uses relevance zero and no alerts",
                              "It can’t force the small bubble"],
                      source: .activityKit),
                .init("Hide While Audio Plays", "Ends Live Activities while another app plays audio.",
                      pros: ["Gives Music the Dynamic Island"],
                      cons: ["Needs Always location access",
                             "Reacts in about 15 s only while WhereWolf runs",
                             "Restoring may need you to open WhereWolf"],
                      notes: ["While suspended, reacts at the next location or app open",
                              "Indicator-off tracking uses the original engine while hidden"],
                      source: .activityKit),
                .init("Ask to Reopen When Audio Stops", "A silent reminder to reopen WhereWolf if its activity couldn’t return.",
                      pros: ["Gets the Island back after music"],
                      cons: ["Needs notification permission; use its Allow button"],
                      notes: ["Sent five minutes after a refused restore",
                              "Withdrawn when you reopen, audio resumes or tracking stops"],
                      source: .activityKit),
                .init("Open WhereWolf Reminder", "When the ten-minute reminder passes, Status and Minimal ask you to open WhereWolf.",
                      notes: ["Blank stays empty",
                              "iOS controls timing; ended activities can’t show it",
                              "A missed deadline can’t prove the app was killed"],
                      source: .activityKit)
            ]
        case .background:
            return [
                .init("Location Indicator", "Shows or hides iOS’s location indicator in the background.",
                      pros: ["On: the most reliable background recording"],
                      cons: ["On: an indicator in the status bar"],
                      notes: ["Off needs Always access or a Live Activity",
                              "While Using access may require it anyway",
                              "Turning it off doesn’t stop collection",
                              "Trips have their own setting"],
                      source: .coreLocation),
                .init("Relaunch Monitoring", "Significant-change monitoring so iOS can relaunch WhereWolf after ending it.",
                      pros: ["A way back after iOS terminates the app"],
                      cons: ["Coarse, delayed events; no set wake time",
                             "Extra callbacks may cost energy"],
                      notes: ["Needs Always access; Both mode already has it",
                              "Can’t bypass force-quit, Stop or a radius pause",
                              "Background App Refresh limits can block relaunch"],
                      source: .significant),
                .init("Keep Always Access Active", "On iOS 18 and later, holds a Core Location session for background delivery.",
                      notes: ["Needs Always access already",
                              "No guarantee iOS runs the app on time"],
                      source: .coreLocation),
                .init("Retry Stalled Updates", "Restarts location updates when no fresh fix arrives in time.",
                      pros: ["Recovers from stalled delivery",
                             "Filter rejections never trigger it"],
                      cons: ["Extra battery with poor reception"],
                      notes: ["Waits 2 minutes by default; choose 1 to 30",
                              "Later waits are twice and five times longer",
                              "Three tries per session without a fresh fix",
                              "Never overrides Stop, pauses, adaptive idle or event-only modes"],
                      source: .implementation),
                .init("Background App Refresh", "iOS’s Background App Refresh setting for WhereWolf.",
                      notes: ["Restrictions can block relaunch"],
                      source: .coreLocation),
                .init("Background Continuity", "An Apple engineer on when iOS suspends low-accuracy background updates.",
                      notes: ["Always access, no manager distance filter, accuracy under 1 km",
                              "Or turn the indicator on",
                              "Guidance for one setup, not a guarantee",
                              "Saved-point filters aren’t the manager’s distance filter"],
                      source: .background),
                .init("Restart Background Features", "Reselects the engine and restarts Live Activities and audio handling.",
                      notes: ["Clears a latched new-engine failure",
                              "iOS still decides when WhereWolf runs"],
                      source: .implementation)
            ] + Self.silentAudioEntries
        case .history:
            return [
                .init("Keep History", "Keeps 24 hours to 7 days of points on this iPhone for replay.",
                      pros: ["Longer reaches further back"],
                      cons: ["Longer uses more storage",
                             "Shortening deletes older history for good"],
                      notes: ["New installs start at 7 days"],
                      source: .implementation),
                .init("Storage", "Size depends on how often points are saved.",
                      notes: ["The queue and your server keep their own history"],
                      source: .implementation)
            ]
        case .health:
            return [
                .init("Save Trips to Apple Health", "Saves trips in chosen modes as workouts with routes.",
                      pros: ["Trips appear with your other workouts"],
                      cons: ["Asks for Health access when turned on"],
                      notes: ["Doesn’t take points from the upload queue"],
                      source: .healthKit),
                .init("Choose Workouts by Trip Mode", "Each mode can name a workout; only those modes save.",
                      source: .implementation),
                .init("Import Workout Routes", "Copies other apps’ Health routes into a separate local collection.",
                      pros: ["Brings in routes WhereWolf didn’t record"],
                      cons: ["Needs Health read access",
                             "Watch routes may take time to sync"],
                      notes: ["Never uploaded or written back automatically"],
                      source: .healthKit)
            ]
        case .backup:
            return [
                .init("Settings File", "Exports configuration, not data, as a versioned JSON file.",
                      pros: ["Restore or move settings to another iPhone"],
                      cons: ["With server details, it holds your credential"],
                      notes: ["Import previews and confirms every change",
                              "Keeps tracking state and permissions; finish trips first"],
                      source: .implementation),
                .init("iCloud Sync", "Keeps settings in step across your iPhones; off by default.",
                      pros: ["Changes follow you"],
                      notes: ["The latest change per setting wins",
                              "Credentials sync through iCloud Keychain",
                              "Device ID, tracking state, permissions, trips and data stay local",
                              "Incoming changes wait until a trip ends"],
                      source: .implementation)
            ]
        case .notifications:
            return [
                .init("Notifications", "Local alerts about tracking and sending.",
                      notes: ["Needs iOS notification permission",
                              "Never turns tracking on"],
                      source: .implementation),
                .init("Notify About: Problems and Status", "Problems plus routine pause, resume and trip messages.",
                      pros: ["Hear about every tracking change"],
                      cons: ["More interruptions"],
                      source: .implementation),
                .init("Notify About: Problems Only", "Only the missed-update reminder and upload errors.",
                      pros: ["Fewer interruptions"],
                      cons: ["No routine status messages"],
                      source: .implementation),
                .init("Trip and Audio Prompts", "Ask to End Trip and Ask to Reopen have their own switches.",
                      notes: ["They ignore Notifications and Problems Only"],
                      source: .implementation)
            ]
        case .coverage:
            return [
                .init("Recorded, Paused and Gaps", "Recorded spans join accepted fixes up to ten minutes apart.",
                      notes: ["Gap: over 10 minutes silent while recording was expected",
                              "Paused: Stop, off, pauses, event-only modes or lost access",
                              "Unknown: before the log began",
                              "Gaps can come from suspension, reception or filters"],
                      source: .implementation),
                .init("Local Totals", "Hourly points and send outcomes in your history window.",
                      notes: ["Coordinate-free and never uploaded"],
                      source: .implementation)
            ]
        case .locationLog:
            return [
                .init("Current Status", "Checks run only when iOS lets WhereWolf run; a timer can’t wake it.",
                      notes: ["Retry Location Updates Now restarts and resets the limit"],
                      source: .implementation),
                .init("What a Check Can Do", "Checks can’t recover points never received.",
                      notes: ["Relaunch Monitoring and Visit Tracking can prompt a relaunch"],
                      source: .coreLocation),
                .init("Saving Received Locations", "A short iOS allowance lets received points finish saving.",
                      notes: ["Doesn’t keep tracking alive or acknowledge uploads"],
                      source: .implementation),
                .init("Save Location Log", "Keeps up to 200 events from the past seven days.",
                      pros: ["Shows gaps, skipped points and retries"],
                      cons: ["Can’t prove why iOS stopped the app"],
                      notes: ["No coordinates, servers or credentials",
                              "Excluded from backups; never uploaded automatically"],
                      source: .implementation),
                .init("Recent Events", "What WhereWolf saw while it could run.",
                      notes: ["Missing events don’t prove iOS ended the app"],
                      source: .implementation)
            ]
        }
    }
}
