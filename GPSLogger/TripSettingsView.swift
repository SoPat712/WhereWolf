import SwiftUI

struct TripSettingsSheet: View {
    let onDone: () -> Void
    @State private var detent: PresentationDetent = .medium

    var body: some View {
        NavigationStack {
            TripSettingsView()
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done", action: onDone)
                    }
                }
        }
        .environment(\.glassSettingsSheet, true)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationBackground { ExpandingSheetBackground(detent: detent) }
    }
}

struct TripSettingsView: View {
    @State private var bridge = GLManagerBridge.shared

    var body: some View {
        Form {
            Section {
                NavigationLink("Trip Modes") { TripModesView() }
                Toggle("Trip Live Activity", isOn: $bridge.tripLiveActivityEnabled)
            } footer: {
                Text("An optional trip card with elapsed time, distance, speed, Send Now and End Trip. It is separate from the tracking activity and its Blank appearance.")
            }
            .listRowBackground(Color.settingsRow)

            Section {
                Picker("Requested Accuracy", selection: $bridge.tripAccuracyPreset) {
                    Text("Custom").tag(0)
                    Text("Best").tag(1)
                    Text("Navigation").tag(2)
                }
                if bridge.tripAccuracyPreset == 0 {
                    SliderRow(title: "Target Accuracy", value: $bridge.tripAccuracyMeters, range: 5...3000, unit: "meters", format: SettingFormat.meters)
                }
                Picker("Activity Type", selection: $bridge.tripActivityIndex) {
                    Text("Other").tag(0)
                    Text("Automotive").tag(1)
                    Text("Fitness").tag(2)
                    Text("Navigation").tag(3)
                    Text("Airborne").tag(4)
                    if #available(iOS 27.0, *) { Text("Boat").tag(5) }
                }
            } header: {
                SettingsSectionHeader(title: "Accuracy", topic: .precision)
            } footer: {
                Text("Requests location precision while a trip is in progress. Saved-point filters below decide which returned fixes are kept. The new engine lets iOS choose accuracy.")
            }
            .listRowBackground(Color.settingsRow)

            Section {
                Picker("Logging Mode", selection: $bridge.tripLoggingModeIndex) {
                    Text("All Data").tag(0)
                    Text("Only Latest").tag(1)
                    Text("OwnTracks").tag(2)
                }
                SliderRow(title: "Locations per Batch", value: $bridge.tripBatchValue, range: 1...1000, format: SettingFormat.count)
            } header: {
                SettingsSectionHeader(title: "Batching", topic: .batching)
            }
            .listRowBackground(Color.settingsRow)

            Section {
                Toggle("Discard Points Without GPS", isOn: $bridge.tripDiscardWithoutGPS)
                Toggle("Discard Points While Stationary", isOn: $bridge.tripDiscardStationary)
                SliderRow(title: "Min Distance Between Points", value: $bridge.tripDiscardDistanceMeters, range: 0...1000, offBelow: 1, unit: "meters", format: SettingFormat.meters)
                SliderRow(title: "Min Time Between Points", value: $bridge.tripDiscardSecondsValue, range: 0...600, offBelow: 1, unit: "seconds", format: SettingFormat.seconds)
                SliderRow(title: "Max Saved-Point Error", value: $bridge.discardAccuracyMeters, range: 0...5000, offBelow: 1, unit: "meters", format: SettingFormat.meters)
            } header: {
                SettingsSectionHeader(title: "Discard Filters", topic: .precision)
            } footer: {
                Text("Skip points that are too close together in space or time. Max Saved-Point Error rejects fixes with larger reported uncertainty and is shared with normal tracking. The sliders snap to common settings; tap a value for exact entry. GPS filtering estimates the source from altitude accuracy and speed. Stationary filtering needs Motion & Fitness access and keeps a stopping point and an hourly heartbeat.")
            }
            .listRowBackground(Color.settingsRow)

            Section {
                Toggle("Show Background Indicator", isOn: $bridge.tripBackgroundIndicator)
                Toggle("Pause Updates Automatically", isOn: $bridge.tripPausesAutomatically)
                if bridge.tripPausesAutomatically {
                    SliderRow(title: "Resume After Moving", value: $bridge.resumeDistanceMeters, range: 0...2000, offBelow: 1, unit: "meters", format: SettingFormat.meters)
                }
            } header: {
                SettingsSectionHeader(title: "Privacy", topic: .stationary)
            } footer: {
                Text("The resume distance is shared with normal tracking. Turning off automatic pausing also disables resuming on movement.")
            }
            .listRowBackground(Color.settingsRow)

            Section {
                Toggle("Prevent Screen Lock", isOn: $bridge.screenLock)
            } header: {
                SettingsSectionHeader(title: "Screen", topic: .trip)
            } footer: {
                Text("Keeps the screen on while a trip is in progress.")
            }
            .listRowBackground(Color.settingsRow)
        }
        .settingsFormStyle()
        .navigationTitle("Trip Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { bridge.refresh() }
    }
}
