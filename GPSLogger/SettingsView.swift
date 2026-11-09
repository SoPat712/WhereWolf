import SwiftUI

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
                     : UsagePreset.description(bridge.usageProfile) + " Tap ⓘ for exact values.")
            }

            Section {
                NavigationLink(value: SettingsDestination.server) {
                    LabeledContent {
                        Text(destinationStatus)
                    } label: {
                        SettingsRowLabel(title: "Destination", symbol: "antenna.radiowaves.left.and.right",
                                         color: destinationReady ? .green : .orange)
                    }
                }
                .accessibilityLabel("Destination")
                .accessibilityIdentifier("wherewolf.settings.server")
                .accessibilityValue(destinationStatus)
                NavigationLink { PermissionsSettingsView() } label: {
                    SettingsRowLabel(title: "Permissions", symbol: "checkmark.shield.fill", color: .blue)
                }
            }

            Section {
                NavigationLink(value: SettingsDestination.tracking) {
                    SettingsRowLabel(title: "Tracking & Accuracy", symbol: "scope", color: .blue)
                }
                NavigationLink(value: SettingsDestination.trip) {
                    SettingsRowLabel(title: "Trips", symbol: "figure.walk", color: .pink)
                }
                NavigationLink(value: SettingsDestination.wifiPlaces) {
                    SettingsRowLabel(title: "Wi-Fi Places", symbol: "wifi", color: .blue)
                }
                .accessibilityIdentifier("wherewolf.settings.wifiPlaces")
            } header: {
                Text("Recording")
            }

            Section {
                NavigationLink(value: SettingsDestination.sending) {
                    SettingsRowLabel(title: "Sending", symbol: "paperplane.fill", color: .teal)
                }
            }

            Section {
                NavigationLink { LiveActivitySettingsView() } label: {
                    SettingsRowLabel(title: "Live Activities", symbol: "platter.filled.top.iphone", color: .indigo)
                }
                NavigationLink(value: SettingsDestination.background) {
                    SettingsRowLabel(title: "Background Reliability", symbol: "moon.stars.fill", color: .purple)
                }
            } header: {
                Text("Background")
            }

            Section {
                NavigationLink { HistorySettingsView() } label: {
                    SettingsRowLabel(title: "History & Replay", symbol: "clock.arrow.circlepath", color: .blue)
                }
                // An export enabled before HealthKit left the build can still be turned off.
                if bridge.healthAvailable || bridge.healthEnabled {
                    NavigationLink { AppleHealthSettingsView() } label: {
                        SettingsRowLabel(title: "Apple Health", symbol: "heart.fill", color: .pink)
                    }
                }
                NavigationLink { SettingsBackupView() } label: {
                    SettingsRowLabel(title: "Backup & Sync", symbol: "icloud", color: .blue)
                }
                .accessibilityLabel("Backup & Sync")
                .accessibilityIdentifier("wherewolf.settings.backup")
            } header: {
                Text("Your Data")
            }

            Section {
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
                SettingsSectionHeader(title: "Notifications", topic: .notifications)
            } footer: {
                Text("Alerts for interrupted tracking and upload errors.")
            }

            Section {
                NavigationLink { CoverageView() } label: {
                    SettingsRowLabel(title: "Coverage", symbol: "chart.bar.xaxis", color: .green)
                }
                .accessibilityLabel("Coverage")
                .accessibilityIdentifier("wherewolf.settings.coverage")
                NavigationLink { LocationHealthView() } label: {
                    SettingsRowLabel(title: "Location Log", symbol: "location.magnifyingglass", color: .blue)
                }
#if WHEREWOLF_TESTFLIGHT_DIAGNOSTICS
                // TestFlight diagnostics: left out of App Store builds (WHEREWOLF_APP_STORE=YES).
                NavigationLink(destination: DiagnosticsView()) {
                    SettingsRowLabel(title: "Diagnostics", symbol: "waveform.path.ecg", color: .gray)
                }
#endif
            } header: {
                Text("Troubleshooting")
            }

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

    private var destinationReady: Bool {
        bridge.savesToICloudDrive ? bridge.cloudAvailable : bridge.endpointSet
    }

    private var destinationStatus: String {
        if bridge.savesToICloudDrive { return bridge.cloudAvailable ? "iCloud Drive" : "iCloud Drive Unavailable" }
        return bridge.endpointSet ? "Server" : "Not Set"
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
                Text("Significant-change mode records larger movements while conserving battery.")
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
                SettingsSectionHeader(title: "Location Request", topic: .locationRequest)
            } footer: {
                Text("A target for iOS, not a guarantee. It does not change which points are saved.")
            }

            Section {
                Toggle("Discard Points Without GPS", isOn: $bridge.discardWithoutGPS)
                Toggle("Discard Points While Stationary", isOn: $bridge.discardStationary)
                SliderRow(title: "Min Distance Between Points", value: $bridge.discardDistanceMeters, range: 0...1000, offBelow: 1, unit: "meters", format: SettingFormat.meters)
                SliderRow(title: "Min Time Between Points", value: $bridge.discardSecondsValue, range: 0...600, offBelow: 1, unit: "seconds", format: SettingFormat.seconds)
                SliderRow(title: "Max Saved-Point Error", value: $bridge.discardAccuracyMeters, range: 0...5000, offBelow: 1, unit: "meters", format: SettingFormat.meters)
                Toggle("Save When Any Limit Is Met", isOn: advancedBoolBinding(bridge, key: "any_threshold"))
                SliderRow(title: "Turn Trigger", value: advancedValueBinding(bridge, key: "turn_degrees"), range: 0...180, offBelow: 1, unit: "degrees", format: { "\(Int($0))°" })
                    .disabled(!bridge.advancedBool("any_threshold"))
                Toggle("Reject Implausible Jumps", isOn: advancedBoolBinding(bridge, key: "reject_jumps"))
                SliderRow(title: "Maximum Speed", value: advancedValueBinding(bridge, key: "maximum_speed"), range: 5...500, unit: "m/s", format: { "\(Int($0)) m/s" })
                    .disabled(!bridge.advancedBool("reject_jumps"))
            } header: {
                SettingsSectionHeader(title: "Saved Points", topic: .savedPoints)
            } footer: {
                Text("These filters decide which returned locations are saved. Tap a value to enter it exactly.")
            }

            Section {
                SliderRow(title: "Stop Within Radius", value: $bridge.stopRadiusMeters, range: 0...1000, offBelow: 1, unit: "meters", format: SettingFormat.meters)
                    .disabled(bridge.trackingModeIndex != 3 || bridge.pausesAutomatically)
                SliderRow(title: "Stop After", value: $bridge.stopAfterValue, range: 30...3600, unit: "seconds", format: SettingFormat.seconds)
                    .disabled(bridge.trackingModeIndex != 3 || bridge.pausesAutomatically || bridge.stopRadiusMeters < 1)
                Toggle("Pause Updates Automatically", isOn: $bridge.pausesAutomatically)
                    .disabled(bridge.stopRadiusMeters >= 1)
                // Trips show this shared distance read-only, so it stays editable here while either pauses.
                if bridge.pausesAutomatically || bridge.tripPausesAutomatically {
                    SliderRow(title: "Resume After Moving", value: $bridge.resumeDistanceMeters, range: 0...2000, offBelow: 1, unit: "meters", format: SettingFormat.meters)
                }
            } header: {
                SettingsSectionHeader(title: "When Stopped", topic: .stationary)
            } footer: {
                Text("Stop Within Radius works in Both update mode. Resume After Moving is shared with Trips.")
            }

            Section {
                NavigationLink("Advanced") { TrackingAdvancedSettingsView() }
            } footer: {
                Text("Location engine, motion assist and adaptive tracking.")
            }
        }
        .navigationTitle("Tracking & Accuracy")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { bridge.refresh() }
    }
}

struct TrackingAdvancedSettingsView: View {
    @State private var bridge = GLManagerBridge.shared

    var body: some View {
        Form {
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
                Text(bridge.motionAuthorizationStatus == "Allowed"
                     ? "Confidence sets the activity threshold; it does not improve location accuracy."
                     : "Allow Motion & Fitness in Permissions to use motion assist.")
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
                SettingsSectionHeader(title: "Adaptive Tracking", topic: .motionAdaptive)
            } footer: {
                Text("Lowers the requested accuracy only after a confirmed stop, so departures can be detected later.")
            }

            Section {
                SliderRow(title: "Adaptive Max Error", value: advancedValueBinding(bridge, key: "adaptive_max_error"), range: 5...200, unit: "meters", format: SettingFormat.meters)
                    .disabled(!bridge.advancedBool("adaptive"))
                SliderRow(title: "Adaptive Idle Accuracy", value: advancedValueBinding(bridge, key: "adaptive_idle_accuracy"), range: 50...3000, unit: "meters", format: SettingFormat.meters)
                    .disabled(!bridge.advancedBool("adaptive"))
            } header: {
                SettingsSectionHeader(title: "Adaptive Point Quality", topic: .motionAdaptive)
            } footer: {
                Text("Both are separate from Max Saved-Point Error, which controls saved points.")
            }
        }
        .navigationTitle("Advanced")
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
                Toggle("Include Tracking Stats", isOn: $bridge.includeTrackingStats)
            } header: {
                SettingsSectionHeader(title: "What to Send", topic: .sending)
            } footer: {
                Text("Tracking stats apply to new GeoJSON records.")
            }

            Section {
                SliderRow(title: "Send Interval", value: $bridge.sendIntervalValue, range: 0...3600, offBelow: 1, unit: "seconds", format: SettingFormat.seconds)
                SliderRow(title: "Locations per Batch", value: $bridge.batchValue, range: 1...1000, format: SettingFormat.count)
                Toggle("Send Only on Wi-Fi", isOn: $bridge.sendOnlyOnWifi)
                Toggle("Background Uploads", isOn: advancedBoolBinding(bridge, key: "background_uploads"))
                Toggle("Retry When Back Online", isOn: advancedBoolBinding(bridge, key: "connectivity_retry"))
            } header: {
                SettingsSectionHeader(title: "When to Send", topic: .sending)
            } footer: {
                Text("Send Only on Wi-Fi holds automatic sends; Send Now still sends.")
            }

            Section {
                LabeledContent("Upload Queue", value: bridge.queueCount > 0 ? "\(bridge.queueCount) queued" : "Empty")
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
                LabeledContent("Upload Scheduler", value: bridge.uploadSchedulerStatus)
                Button("Delete Pending Uploads…", role: .destructive) {
                    confirmingDelete = true
                }
                .disabled(bridge.queueCount == 0 || bridge.sending)
            } header: {
                SettingsSectionHeader(title: "Queue", topic: .sending)
            } footer: {
                Text(bridge.sending
                     ? "Wait for the current upload to finish before deleting pending records."
                     : "Deleting keeps local history, saved workout routes and active tracking.")
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

    var body: some View {
        Form {
            Section {
                Toggle("Location Indicator", isOn: $bridge.backgroundIndicator)
            } header: {
                SettingsSectionHeader(title: "Indicator", topic: .background)
            } footer: {
                Text("Without a Live Activity, hiding it needs Always location access. Trips have their own setting.")
            }

            Section {
                Toggle("Relaunch Monitoring", isOn: advancedBoolBinding(bridge, key: "background_recovery"))
                if #available(iOS 18.0, *) {
                    Toggle("Keep Always Access Active", isOn: advancedBoolBinding(bridge, key: "explicit_service_session"))
                } else {
                    LabeledContent("Keep Always Access Active", value: "Requires iOS 18")
                }
                Toggle("Retry Stalled Updates", isOn: advancedBoolBinding(bridge, key: "automatic_location_retry"))
                if bridge.advancedBool("automatic_location_retry") {
                    SliderRow(title: "Retry After", value: advancedValueBinding(bridge, key: "location_retry_after"),
                              range: 60...1800, unit: "seconds", format: SettingFormat.seconds)
                }
                LabeledContent("Background App Refresh", value: bridge.backgroundRefreshStatus)
            } header: {
                SettingsSectionHeader(title: "Staying Active", topic: .background)
            } footer: {
                Text("These help WhereWolf keep recording in the background; iOS still decides when it runs.")
            }

#if WHEREWOLF_SILENT_AUDIO
            Section {
                Toggle("Silent Audio", isOn: $bridge.silentAudioEnabled)
                if bridge.silentAudioEnabled {
                    LabeledContent("Audio", value: bridge.silentAudioStatus)
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                SettingsSectionHeader(title: "Silent Audio", topic: .background)
            } footer: {
                Text("Experimental. Plays silence to keep WhereWolf running and can use more battery.")
            }
#endif

            Section {
                Button("Restart Background Features") { bridge.retryBackgroundRuntime() }
                    .disabled(!bridge.trackingEnabled)
            } footer: {
                Text("Restarts the location engine and Live Activities while tracking is on.")
            }
        }
        .navigationTitle("Background Reliability")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { bridge.refresh() }
    }
}

struct MotionActivityStatusRow: View {
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
