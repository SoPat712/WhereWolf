import SwiftUI

struct TripSettingsSheet: View {
    let onDone: () -> Void
    @State private var detent: PresentationDetent = .medium
    @State private var showingModes: Bool

    init(opensModes: Bool = false, onDone: @escaping () -> Void) {
        self.onDone = onDone
        _showingModes = State(initialValue: opensModes)
    }

    var body: some View {
        NavigationStack {
            TripSettingsView(title: "Trip Settings")
                .navigationDestination(isPresented: $showingModes) { TripModesView() }
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
    // The Trip tab's sheet keeps the name of the button that opens it.
    var title = "Trips"
    @State private var bridge = GLManagerBridge.shared

    var body: some View {
        Form {
            Section {
                NavigationLink("Trip Modes") { TripModesView() }
                NavigationLink { LiveActivitySettingsView() } label: {
                    LabeledContent("Live Activity", value: bridge.tripLiveActivityEnabled ? "On" : "Off")
                }
            }
            .settingsRowBackground()

            Section {
                Toggle("Ask to End Trip When Stopped", isOn: $bridge.tripAskToEndWhenStopped)
            } footer: {
                Text("After 5 minutes within 75 m, a notification asks whether to end the trip.")
            }
            .settingsRowBackground()

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
                SettingsSectionHeader(title: "Location Request", topic: .locationRequest)
            } footer: {
                Text("Used while a trip is in progress.")
            }
            .settingsRowBackground()

            Section {
                Picker("Logging Mode", selection: $bridge.tripLoggingModeIndex) {
                    Text("All Data").tag(0)
                    Text("Only Latest").tag(1)
                    Text("OwnTracks").tag(2)
                }
                SliderRow(title: "Locations per Batch", value: $bridge.tripBatchValue, range: 1...1000, format: SettingFormat.count)
            } header: {
                SettingsSectionHeader(title: "Sending", topic: .sending)
            }
            .settingsRowBackground()

            Section {
                Toggle("Discard Points Without GPS", isOn: $bridge.tripDiscardWithoutGPS)
                Toggle("Discard Points While Stationary", isOn: $bridge.tripDiscardStationary)
                SliderRow(title: "Min Distance Between Points", value: $bridge.tripDiscardDistanceMeters, range: 0...1000, offBelow: 1, unit: "meters", format: SettingFormat.meters)
                SliderRow(title: "Min Time Between Points", value: $bridge.tripDiscardSecondsValue, range: 0...600, offBelow: 1, unit: "seconds", format: SettingFormat.seconds)
                LabeledContent("Max Saved-Point Error", value: Self.meters(bridge.discardAccuracyMeters))
            } header: {
                SettingsSectionHeader(title: "Saved Points", topic: .savedPoints)
            } footer: {
                Text("Max Saved-Point Error is shared with Tracking & Accuracy.")
            }
            .settingsRowBackground()

            Section {
                Toggle("Location Indicator", isOn: $bridge.tripBackgroundIndicator)
                Toggle("Pause Updates Automatically", isOn: $bridge.tripPausesAutomatically)
                if bridge.tripPausesAutomatically {
                    LabeledContent("Resume After Moving", value: Self.meters(bridge.resumeDistanceMeters))
                }
            } header: {
                SettingsSectionHeader(title: "Background & Pausing", topic: .trip)
            } footer: {
                Text(bridge.tripPausesAutomatically
                     ? "Resume After Moving is shared with Tracking & Accuracy."
                     : "Automatic pausing can end a trip.")
            }
            .settingsRowBackground()

            Section {
                Toggle("Prevent Screen Lock", isOn: $bridge.screenLock)
            } header: {
                SettingsSectionHeader(title: "Screen", topic: .trip)
            } footer: {
                Text("Keeps the screen on while a trip is in progress.")
            }
            .settingsRowBackground()
        }
        .settingsFormStyle()
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { bridge.refresh() }
    }

    private static func meters(_ value: Double) -> String {
        value < 1 ? "Off" : SettingFormat.meters(value)
    }
}
