import SwiftUI
import UserNotifications

struct SettingsView: View {
    var openSetup: () -> Void = {}
    @State private var confirmingStop = false
    @State private var showingTipJar = false
    @State private var bridge = GLManagerBridge.shared

    var body: some View {
        Form {
            Section {
                Button(action: openSetup) {
                    SettingsRowLabel(title: "Setup Guide", symbol: "list.bullet.clipboard", color: .blue)
                }
                .foregroundStyle(.primary)
                .accessibilityIdentifier("wherewolf.settings.setup")
            }
            Section {
                NavigationLink(value: SettingsDestination.server) {
                    LabeledContent {
                        Text(bridge.endpointSet ? "Configured" : "Not Set")
                    } label: {
                        SettingsRowLabel(title: "Server", symbol: "antenna.radiowaves.left.and.right",
                                         color: bridge.endpointSet ? .green : .orange)
                    }
                }
                .accessibilityLabel("Server")
                .accessibilityIdentifier("wherewolf.settings.server")
                .accessibilityValue(bridge.endpointSet ? "Configured" : "Not Set")
                LabeledContent {
                    Text(bridge.locationPermission)
                } label: {
                    SettingsRowLabel(title: "Location Access", symbol: "location.fill", color: .blue)
                }
                .accessibilityElement(children: .combine)
                if bridge.locationPermission == "Not Determined" {
                    Button("Allow Location Access") { bridge.requestLocationPermission() }
                } else if bridge.locationPermission == "When in Use" {
                    Button("Allow Background Location") { bridge.requestLocationPermission() }
                }
                LabeledContent {
                    Text(bridge.motionAuthorizationStatus)
                } label: {
                    SettingsRowLabel(title: "Motion & Fitness", symbol: "figure.walk", color: .orange)
                }
                .accessibilityElement(children: .combine)
                if bridge.motionAuthorizationStatus == "Not Requested" {
                    Button("Allow Motion & Fitness") { bridge.requestMotionPermission() }
                } else if bridge.motionAuthorizationStatus == "Denied" || bridge.motionAuthorizationStatus == "Restricted" {
                    Text("Allow Motion & Fitness in iOS Settings to use motion confirmation.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if bridge.motionAuthorizationStatus == "Allowed" {
                    MotionActivityStatusRow(summary: bridge.motionSummary, tracking: bridge.trackingEnabled)
                }
                Link("Open iOS Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
            } header: {
                SettingsSectionHeader(title: "Connection", topic: .permissions)
            } footer: {
                Text("Always access lets WhereWolf record locations in the background.")
            }

            Section {
                Toggle(isOn: Binding(
                    get: { bridge.trackingOn },
                    set: { enabled in
                        if enabled { bridge.trackingOn = true } else { confirmingStop = true }
                    }
                )) {
                    SettingsRowLabel(title: "Tracking Enabled", symbol: "record.circle", color: .red)
                }
                Picker(selection: $bridge.usageProfile) {
                    Text("Custom").tag(0)
                    ForEach(UsagePreset.values, id: \.self) { value in
                        Text(UsagePreset.name(value)).tag(value)
                    }
                } label: {
                    SettingsRowLabel(title: "Usage Preset", symbol: "dial.medium.fill", color: .indigo)
                }
                .disabled(bridge.tripInProgress)
            } header: {
                SettingsSectionHeader(title: "Tracking", topic: .presets)
            } footer: {
                Text(bridge.tripInProgress
                     ? "Finish the current trip before applying a preset."
                     : profileDescription + " Presets change normal tracking settings immediately. Tap ⓘ for exact values.")
            }

            Section {
                NavigationLink {
                    UpstreamIntegrationsView()
                } label: {
                    SettingsRowLabel(title: "Integrations & Exports", symbol: "square.and.arrow.up", color: .indigo)
                }
                NavigationLink {
                    HistorySettingsView()
                } label: {
                    SettingsRowLabel(title: "Local History & Replay", symbol: "clock.arrow.circlepath", color: .blue)
                }
                NavigationLink { CoverageView() } label: {
                    SettingsRowLabel(title: "Coverage", symbol: "chart.bar.xaxis", color: .green)
                }
                .accessibilityLabel("Coverage")
                .accessibilityIdentifier("wherewolf.settings.coverage")
                NavigationLink { SettingsBackupView() } label: {
                    SettingsRowLabel(title: "Backup & Sync", symbol: "icloud", color: .blue)
                }
                .accessibilityLabel("Backup & Sync")
                .accessibilityIdentifier("wherewolf.settings.backup")
                NavigationLink(value: SettingsDestination.tracking) {
                    SettingsRowLabel(title: "Tracking & Precision", symbol: "scope", color: .blue)
                }
                NavigationLink(value: SettingsDestination.stationary) {
                    SettingsRowLabel(title: "Stationary Pause", symbol: "pause.fill", color: .orange)
                }
                NavigationLink(value: SettingsDestination.sending) {
                    SettingsRowLabel(title: "Sending", symbol: "paperplane.fill", color: .teal)
                }
                NavigationLink(value: SettingsDestination.trip) {
                    SettingsRowLabel(title: "Trip Settings", symbol: "figure.walk", color: .pink)
                }
                NavigationLink(value: SettingsDestination.background) {
                    SettingsRowLabel(title: "Background", symbol: "moon.stars.fill", color: .purple)
                }
                NavigationLink(destination: MotionAdaptiveTrackingSettingsView()) {
                    SettingsRowLabel(title: "Motion & Adaptive Tracking", symbol: "figure.walk.motion", color: .orange)
                }
                NavigationLink(destination: PointSelectionQualitySettingsView()) {
                    SettingsRowLabel(title: "Point Selection & Quality", symbol: "checkmark.seal", color: .green)
                }
            }

            Section {
                NavigationLink(value: SettingsDestination.wifiZones) {
                    SettingsRowLabel(title: "WiFi Zones", symbol: "wifi", color: .blue)
                }
                Toggle(isOn: $bridge.notifications) {
                    SettingsRowLabel(title: "Notifications", symbol: "bell.badge.fill", color: .red)
                }
                if bridge.notifications {
                    Picker("Notify About", selection: $bridge.problemNotificationsOnly) {
                        Text("Problems and Status").tag(false)
                        Text("Problems Only").tag(true)
                    }
                }
            } header: {
                SettingsSectionHeader(title: "Automation", topic: .automation)
            } footer: {
                Text("Optional alerts for interrupted tracking and upload errors. Problems Only hides routine pause, resume, and trip messages. Notifications do not keep the app running.")
            }

#if WHEREWOLF_TESTFLIGHT_DIAGNOSTICS
            // TESTFLIGHT ONLY — REMOVE BEFORE APP STORE RELEASE
            Section {
                NavigationLink(destination: DiagnosticsView()) {
                    SettingsRowLabel(title: "Diagnostics", symbol: "waveform.path.ecg", color: .gray)
                }
            }
#endif

            Section {
                Button { showingTipJar = true } label: {
                    SettingsRowLabel(title: "Tip Jar", symbol: "heart.fill", color: .pink)
                }
                .foregroundStyle(.primary)
                Link(destination: URL(string: "https://sopat712.github.io/WhereWolf/")!) {
                    SettingsRowLabel(title: "Support", symbol: "questionmark.circle.fill", color: .blue)
                }
                .foregroundStyle(.primary)
                Link(destination: WhereWolfLinks.privacy) {
                    SettingsRowLabel(title: "Privacy Policy", symbol: "hand.raised.fill", color: .gray)
                }
                .foregroundStyle(.primary)
            } header: {
                Text("Support")
            }
        }
        .navigationTitle("Settings")
        .confirmStopTracking($confirmingStop) { bridge.trackingOn = false }
        .onAppear { bridge.refresh() }
        .sheet(isPresented: $showingTipJar) {
            NavigationStack { TipJarView() }
                .presentationDetents([.large])
        }
    }

    private var profileDescription: String {
        UsagePreset.description(bridge.usageProfile)
    }

}

struct TrackingSettingsView: View {
    @State private var bridge = GLManagerBridge.shared

    var body: some View {
        Form {
            Section {
                Picker("Update Mode", selection: $bridge.trackingModeIndex) {
                    Text("Off").tag(0)
                    Text("Standard").tag(1)
                    Text("Significant").tag(2)
                    Text("Both").tag(3)
                }
                Toggle("Visit Tracking", isOn: $bridge.visitTracking)
            } header: {
                SettingsSectionHeader(title: "Updates", topic: .tracking)
            } footer: {
                Text("Significant-change mode records larger movements while conserving battery. Visit tracking is controlled separately.")
            }

            Section {
                Toggle("Use new location engine", isOn: $bridge.useNewLocationEngine)
                    .disabled(!bridge.hasContinuousUpdates)
                LabeledContent("Active Engine", value: bridge.actualLocationEngine)
                if !bridge.locationEngineReason.isEmpty {
                    Text(bridge.locationEngineReason).font(.footnote).foregroundStyle(.secondary)
                }
                if !bridge.hasContinuousUpdates {
                    Text("Available when continuous updates are enabled.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                SettingsSectionHeader(title: "Location Engine", topic: .engine)
            } footer: {
                Text("Automatic pause and resume, with more detailed diagnostics. iOS controls accuracy and pausing.")
            }

            Section {
                Picker("Requested Accuracy", selection: $bridge.accuracyPreset) {
                    Text("Custom").tag(0)
                    Text("Best").tag(1)
                    Text("Navigation").tag(2)
                }
                if bridge.accuracyPreset == 0 {
                    SliderRow(title: "Target Accuracy", value: $bridge.accuracyMeters, range: 5...3000, unit: "meters", format: SettingFormat.meters)
                }
                Picker("Activity Type", selection: $bridge.activityIndex) {
                    Text("Other").tag(0)
                    Text("Automotive").tag(1)
                    Text("Fitness").tag(2)
                    Text("Navigation").tag(3)
                    Text("Airborne").tag(4)
                    if #available(iOS 27.0, *) { Text("Boat").tag(5) }
                }
            } header: {
                SettingsSectionHeader(title: "Location Request", topic: .precision)
            } footer: {
                Text("Requested Accuracy tells iOS how precise a location should be. It is a target, not a guarantee. The new engine lets iOS choose accuracy. This control does not change which points are saved.")
            }

            Section {
                Toggle("Discard Points Without GPS", isOn: $bridge.discardWithoutGPS)
                Toggle("Discard Points While Stationary", isOn: $bridge.discardStationary)
                SliderRow(title: "Min Distance Between Points", value: $bridge.discardDistanceMeters, range: 0...1000, offBelow: 1, unit: "meters", format: SettingFormat.meters)
                SliderRow(title: "Min Time Between Points", value: $bridge.discardSecondsValue, range: 0...600, offBelow: 1, unit: "seconds", format: SettingFormat.seconds)
                SliderRow(title: "Max Saved-Point Error", value: $bridge.discardAccuracyMeters, range: 0...5000, offBelow: 1, unit: "meters", format: SettingFormat.meters)
            } header: {
                SettingsSectionHeader(title: "Saved-Point Filters", topic: .precision)
            } footer: {
                Text("These filters decide which returned locations are saved. Max Saved-Point Error rejects points with a larger reported uncertainty; Off accepts any valid accuracy. A 10 m request can return a 20 m fix, so matching both limits can create gaps. Tap a value for exact entry; the slider snaps to common settings.")
            }
        }
        .navigationTitle("Tracking & Precision")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { bridge.refresh() }
    }
}

struct StationarySettingsView: View {
    @State private var bridge = GLManagerBridge.shared

    var body: some View {
        Form {
            Section {
                SliderRow(title: "Stop Within Radius", value: $bridge.stopRadiusMeters, range: 0...1000, offBelow: 1, unit: "meters", format: SettingFormat.meters)
                    .disabled(bridge.trackingModeIndex != 3 || bridge.pausesAutomatically)
                SliderRow(title: "Stop After", value: $bridge.stopAfterValue, range: 30...3600, unit: "seconds", format: SettingFormat.seconds)
                    .disabled(bridge.trackingModeIndex != 3 || bridge.pausesAutomatically || bridge.stopRadiusMeters < 1)
                Toggle("Pause Updates Automatically", isOn: $bridge.pausesAutomatically)
                    .disabled(bridge.stopRadiusMeters >= 1)
                if bridge.pausesAutomatically {
                    SliderRow(title: "Resume After Moving", value: $bridge.resumeDistanceMeters, range: 0...2000, offBelow: 1, unit: "meters", format: SettingFormat.meters)
                }
            } header: {
                SettingsSectionHeader(title: "Stop When Stationary", topic: .stationary)
            } footer: {
                Text("In Both update mode, the radius and time pause standard updates until significant movement is detected. Automatic pausing lets iOS pause updates when stationary. The resume distance is shared with trips.")
            }
        }
        .navigationTitle("Stationary Pause")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { bridge.refresh() }
    }
}

struct SendingSettingsView: View {
    @State private var bridge = GLManagerBridge.shared
    @State private var confirmingDelete = false
    @State private var showingDeleteError = false

    var body: some View {
        Form {
            Section {
                Picker("Logging Mode", selection: $bridge.loggingModeIndex) {
                    Text("All Data").tag(0)
                    Text("Only Latest").tag(1)
                    Text("OwnTracks").tag(2)
                }
                SliderRow(title: "Locations per Batch", value: $bridge.batchValue, range: 1...1000, format: SettingFormat.count)
                SliderRow(title: "Send Interval", value: $bridge.sendIntervalValue, range: 0...3600, offBelow: 1, unit: "seconds", format: SettingFormat.seconds)
                Toggle("Send Only on Wi-Fi", isOn: $bridge.sendOnlyOnWifi)
                Toggle("Background Uploads", isOn: advancedBoolBinding(bridge, key: "background_uploads"))
                Toggle("Retry Connectivity Failures", isOn: advancedBoolBinding(bridge, key: "connectivity_retry"))
                LabeledContent("Upload Queue", value: bridge.queueCount > 0 ? "\(bridge.queueCount) queued" : "Empty")
                LabeledContent("Upload Scheduler", value: bridge.uploadSchedulerStatus)
                if bridge.uploadsBlocked {
                    Text("Uploads are blocked until you retry. Server authentication errors are not retried automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Button("Retry Uploads") { bridge.retryPendingUpload() }
                        .disabled(bridge.queueCount == 0 || !bridge.endpointSet || bridge.sending)
                } else if let retryDate = bridge.uploadRetryDate {
                    LabeledContent("Next Retry") {
                        Text(retryDate, style: .relative)
                    }
                }
            } header: {
                SettingsSectionHeader(title: "Batching", topic: .batching)
            } footer: {
                Text("Automatic sending runs as locations arrive after this interval. Send Only on Wi-Fi holds automatic sends on cellular or a personal hotspot until the phone is on Wi-Fi; Send Now, widgets, Shortcuts and the watch still send. Background Uploads lets the operating system schedule pending-queue drains; it has no exact interval. Connectivity retry waits for eligible network failures and honors server Retry-After and authentication errors.")
            }

            Section {
                Toggle("Include Tracking Stats", isOn: $bridge.includeTrackingStats)
            } header: {
                Text("Upload Metadata")
            } footer: {
                Text("Adds tracking configuration to GeoJSON points and queues diagnostic events such as pause and resume. OwnTracks does not include these stats. Applies to new records.")
            }

            Section {
                Button("Delete Pending Uploads…", role: .destructive) {
                    confirmingDelete = true
                }
                .disabled(bridge.queueCount == 0 || bridge.sending)
            } header: {
                Text("Queue Management")
            } footer: {
                Text(bridge.sending
                     ? "Wait for the current upload to finish before deleting pending records."
                     : "Deletes queued records, including trip summaries and imported workout points. Local history, saved workout routes, and active tracking are kept.")
            }
        }
        .navigationTitle("Sending")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Delete pending uploads?", isPresented: $confirmingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete Pending Uploads", role: .destructive) {
                showingDeleteError = !bridge.deletePendingUploads()
            }
        } message: {
            Text("Permanently deletes all records currently waiting to be sent or saved to your destination, including trip summaries and queued workout points. Local history, saved workout routes, and your active trip are kept. This cannot be undone.")
        }
        .alert("Couldn’t Delete Pending Uploads", isPresented: $showingDeleteError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("An upload is in progress, or the queue could not be updated. Your pending records are kept. Please try again after the upload finishes.")
        }
        .onAppear { bridge.refresh() }
    }
}

struct BackgroundSettingsView: View {
    @State private var bridge = GLManagerBridge.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var audioNotificationsAllowed = true
    @State private var requestingAudioNotifications = false

    var body: some View {
        Form {
            Section {
                Toggle("Show Background Indicator", isOn: $bridge.backgroundIndicator)
            } header: {
                SettingsSectionHeader(title: "Indicator", topic: .background)
            } footer: {
                Text("Trips have a separate indicator setting. Always location access is required to hide the indicator when no Live Activity is active.")
            }

            Section {
                Toggle("Tracking Live Activity", isOn: $bridge.liveActivityEnabled)
                Toggle("Hide While Audio Plays", isOn: $bridge.hideLiveActivityWhileAudioPlays)
                if bridge.hideLiveActivityWhileAudioPlays {
                    Toggle("Ask to Reopen When Audio Stops", isOn: $bridge.askToReopenAfterAudio)
                    Text("Off by default. If the Live Activity cannot return after music stops, a silent notification about five minutes later asks you to open WhereWolf. This needs notification permission, independently of Notifications and Problems Only.")
                        .font(.footnote).foregroundStyle(.secondary)
                    if bridge.askToReopenAfterAudio && !audioNotificationsAllowed {
                        HStack {
                            Text("Allow notifications for this prompt.")
                            Spacer()
                            Button("Allow") {
                                requestingAudioNotifications = true
                                Task {
                                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
                                    await refreshAudioNotificationPermission()
                                    requestingAudioNotifications = false
                                }
                            }
                            .disabled(requestingAudioNotifications)
                        }
                    }
                }
                LabeledContent("Active Engine", value: bridge.actualLocationEngine)
                if !bridge.locationEngineReason.isEmpty {
                    Text(bridge.locationEngineReason).font(.footnote).foregroundStyle(.secondary)
                }
                if bridge.liveActivityEnabled {
                    Picker("Dynamic Island Appearance", selection: $bridge.liveActivityAppearance) {
                        Text("Status").tag("status")
                        Text("Minimal").tag("minimal")
                        Text("Blank").tag("blank")
                    }
                    Toggle("Lock Screen Card", isOn: Binding(
                        get: { bridge.liveActivityPresentation.cardOn },
                        set: { bridge.liveActivityLockScreenCard = $0 }))
                        .disabled(!bridge.liveActivityPresentation.cardEditable)
                    if bridge.liveActivityPresentation.cardRequired {
                        Text("Minimal and Status always include the Lock Screen card.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    LabeledContent("Live Activity", value: bridge.liveActivityStatus)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("Silent Audio (Experimental)", isOn: $bridge.silentAudioEnabled)
                if bridge.silentAudioEnabled {
                    LabeledContent("Audio", value: bridge.silentAudioStatus)
                        .font(.footnote).foregroundStyle(.secondary)
                }
                if #available(iOS 18.0, *) {
                    Toggle("Explicit Service Session", isOn: advancedBoolBinding(bridge, key: "explicit_service_session"))
                } else {
                    LabeledContent("Explicit Service Session", value: "Requires iOS 18")
                }
                Text("On iOS 18 and later, this requests an authorization session for background location. It requires already-Always access and does not guarantee background execution.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Toggle("Background Recovery Monitoring", isOn: advancedBoolBinding(bridge, key: "background_recovery"))
                NavigationLink(destination: LocationHealthView()) {
                    SettingsRowLabel(title: "Location Updates & Recovery", symbol: "location.magnifyingglass", color: .blue)
                }
                LabeledContent("Background App Refresh", value: bridge.backgroundRefreshStatus)
                Text("Recovery monitoring keeps significant-change location monitoring alongside Standard tracking, including trips. It requires Always location access and can help iOS relaunch WhereWolf after system termination. Events are coarse and may be delayed; Background App Refresh restrictions can limit relaunch. More wakeups can use additional battery.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Button("Retry Background Helpers") { bridge.retryBackgroundRuntime() }
                    .disabled(!bridge.trackingEnabled)
            } header: {
                SettingsSectionHeader(title: "Background Runtime", topic: .runtime)
            } footer: {
                Text("Hide While Audio Plays needs Always location access. It reacts within about 15 seconds while WhereWolf runs in the background (moving or with Silent Audio on). While suspended, it reacts at the next location update or app open. After audio stops, iOS may require you to open WhereWolf to restore the activities. Blank is the default appearance for new installs. It keeps the Island empty; Lock Screen Card defaults off. With the card off and Always access, indicator-off tracking uses the original engine. With the card on, Blank supports background live updates like Minimal. Silent audio can use more battery. Explicit Service Session requests authorization on iOS 18 and later and does not guarantee background execution. These options run only while tracking has location access.")
            }
        }
        .navigationTitle("Background")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { bridge.refresh() }
        .task { await refreshAudioNotificationPermission() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await refreshAudioNotificationPermission() } }
        }
    }

    private func refreshAudioNotificationPermission() async {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        audioNotificationsAllowed = [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus)
    }
}

struct MotionAdaptiveTrackingSettingsView: View {
    @State private var bridge = GLManagerBridge.shared

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(bridge.motionAuthorizationStatus)
                } label: {
                    SettingsRowLabel(title: "Motion Access", symbol: "figure.walk", color: .orange)
                }
                if bridge.motionAuthorizationStatus == "Allowed" {
                    MotionActivityStatusRow(summary: bridge.motionSummary, tracking: bridge.trackingEnabled)
                }
                if bridge.motionAuthorizationStatus == "Not Requested" {
                    Button("Allow Motion & Fitness") { bridge.requestMotionPermission() }
                } else if bridge.motionAuthorizationStatus == "Denied" || bridge.motionAuthorizationStatus == "Restricted" {
                    Link("Open iOS Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
                }
            } header: {
                SettingsSectionHeader(title: "Motion & Fitness", topic: .motionAdaptive)
            } footer: {
                Text("Motion callbacks describe activity but cannot wake a suspended app by themselves. Use the button above to allow activity access; changing a tracking option never prompts automatically. Trip step counting also uses Motion & Fitness permission.")
            }

            Section {
                Toggle("Motion-assisted tracking", isOn: advancedBoolBinding(bridge, key: "motion_assist"))
                    .disabled(bridge.motionAuthorizationStatus != "Allowed")
                Toggle("Resume Radius Pause on Movement", isOn: advancedBoolBinding(bridge, key: "motion_resume_radius"))
                    .disabled(!bridge.advancedBool("motion_assist"))
                Picker("Motion confidence", selection: advancedValueBinding(bridge, key: "motion_confidence")) {
                    Text("Medium").tag(1.0)
                    Text("High").tag(2.0)
                }
            } header: {
                SettingsSectionHeader(title: "Motion Assist", topic: .motionAdaptive)
            } footer: {
                Text("Motion assistance can restart acquisition after a native pause. Resuming a radius pause is a separate choice and requires movement detected after that pause. Confidence sets the activity threshold; it does not improve location accuracy.")
            }

            Section {
                Toggle("Adaptive Tracking", isOn: advancedBoolBinding(bridge, key: "adaptive"))
                LabeledContent("Status", value: bridge.adaptiveTrackingStatus)
                Toggle("Apply During Trips", isOn: advancedBoolBinding(bridge, key: "adaptive_in_trips"))
                    .disabled(!bridge.advancedBool("adaptive"))
                Toggle("Require Motion Confirmation", isOn: advancedBoolBinding(bridge, key: "adaptive_require_motion"))
                    .disabled(!bridge.advancedBool("adaptive"))
                SliderRow(title: "Confirmed Stop Dwell", value: advancedValueBinding(bridge, key: "adaptive_dwell"), range: 30...3600, unit: "seconds", format: SettingFormat.seconds)
                    .disabled(!bridge.advancedBool("adaptive"))
                SliderRow(title: "Stop Radius", value: advancedValueBinding(bridge, key: "adaptive_radius"), range: 10...500, unit: "meters", format: SettingFormat.meters)
                    .disabled(!bridge.advancedBool("adaptive"))
                SliderRow(title: "Resume Radius", value: advancedValueBinding(bridge, key: "adaptive_resume_radius"), range: 25...1000, unit: "meters", format: SettingFormat.meters)
                    .disabled(!bridge.advancedBool("adaptive"))
            } header: {
                SettingsSectionHeader(title: "Adaptive Accuracy", topic: .motionAdaptive)
            } footer: {
                Text("Adaptive tracking reduces the requested accuracy only after a sustained, confirmed stop. It keeps coarse updates and an exit region, so departure detection can be delayed. While moving, your saved accuracy and pause settings remain in effect. Existing trips are unchanged unless Apply During Trips is enabled; native automatic pauses still follow the existing trip setting.")
            }
        }
        .navigationTitle("Motion & Adaptive Tracking")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { bridge.refresh() }
    }
}

struct PointSelectionQualitySettingsView: View {
    @State private var bridge = GLManagerBridge.shared

    var body: some View {
        Form {
            Section {
                Toggle("Any threshold", isOn: advancedBoolBinding(bridge, key: "any_threshold"))
                SliderRow(title: "Turn Trigger", value: advancedValueBinding(bridge, key: "turn_degrees"), range: 0...180, offBelow: 1, unit: "degrees", format: { "\(Int($0))°" })
                    .disabled(!bridge.advancedBool("any_threshold"))
            } header: {
                SettingsSectionHeader(title: "Point Thresholds", topic: .quality)
            } footer: {
                Text("Off preserves the current distance AND time minima. On accepts a point when distance OR time OR the turn trigger qualifies. Turn Trigger is disabled at zero and is used only with Any threshold.")
            }

            Section {
                Toggle("Reject Implausible Jumps", isOn: advancedBoolBinding(bridge, key: "reject_jumps"))
                SliderRow(title: "Maximum Speed", value: advancedValueBinding(bridge, key: "maximum_speed"), range: 5...500, unit: "m/s", format: { "\(Int($0)) m/s" })
                    .disabled(!bridge.advancedBool("reject_jumps"))
            } header: {
                SettingsSectionHeader(title: "Jump Filtering", topic: .quality)
            } footer: {
                Text("An implausible jump is held back until a second nearby fix, at least one second later, confirms relocation. Flight users may raise the speed limit or leave filtering off. This filter does not road-snap points or guarantee true accuracy.")
            }

            Section {
                SliderRow(title: "Adaptive Max Error", value: advancedValueBinding(bridge, key: "adaptive_max_error"), range: 5...200, unit: "meters", format: SettingFormat.meters)
                    .disabled(!bridge.advancedBool("adaptive"))
                SliderRow(title: "Adaptive Idle Accuracy", value: advancedValueBinding(bridge, key: "adaptive_idle_accuracy"), range: 50...3000, unit: "meters", format: SettingFormat.meters)
                    .disabled(!bridge.advancedBool("adaptive"))
            } header: {
                SettingsSectionHeader(title: "Adaptive Point Quality", topic: .quality)
            } footer: {
                Text("Adaptive Max Error limits the fixes used to confirm a stop. Adaptive Idle Accuracy is the location request after that stop is confirmed. Both are independent of Max Saved-Point Error, which controls saved points.")
            }
        }
        .navigationTitle("Point Selection & Quality")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { bridge.refresh() }
    }
}

private struct MotionActivityStatusRow: View {
    let summary: String
    let tracking: Bool

    private var value: String {
        guard tracking else { return "Tracking Off" }
        return summary == "Unknown" ? "Waiting for Update" : summary
    }

    var body: some View {
        LabeledContent {
            Text(value)
                .multilineTextAlignment(.trailing)
        } label: {
            SettingsRowLabel(title: "Current Activity", symbol: "figure.walk.motion", color: .orange)
        }
        .accessibilityElement(children: .combine)
    }
}

private func advancedBoolBinding(_ bridge: GLManagerBridge, key: String) -> Binding<Bool> {
    Binding(
        get: { bridge.advancedBool(key) },
        set: { bridge.setAdvancedBool($0, forKey: key) }
    )
}

private func advancedValueBinding(_ bridge: GLManagerBridge, key: String) -> Binding<Double> {
    Binding(
        get: { bridge.advancedValue(key) },
        set: { bridge.setAdvancedValue($0, forKey: key) }
    )
}
