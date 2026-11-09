import SwiftUI

struct AppleHealthSettingsView: View {
    @State private var bridge = GLManagerBridge.shared

    var body: some View {
        Form {
            Section {
                Toggle("Save Trips to Apple Health", isOn: Binding(
                    get: { bridge.healthEnabled }, set: { bridge.setHealthEnabled($0) }
                ))
                .disabled((!bridge.healthAvailable && !bridge.healthEnabled) || bridge.healthRequestInFlight)
                if !bridge.healthAvailable {
                    Text("Apple Health is unavailable in this build.").font(.footnote).foregroundStyle(.secondary)
                }
                if bridge.healthRequestInFlight { ProgressView("Requesting Health Access…") }
                if let error = bridge.healthAuthorizationError ?? bridge.healthLastError {
                    Text(error).font(.footnote).foregroundStyle(.orange)
                }
                NavigationLink("Choose Workouts by Trip Mode") { TripModesView() }
            } header: {
                SettingsSectionHeader(title: "Trip Workouts", topic: .health)
            } footer: {
                Text("Saves trips in the modes you choose as workouts with routes.")
            }

            Section {
                NavigationLink("Import Workout Routes") { WorkoutImportView() }
            } header: {
                SettingsSectionHeader(title: "Workout Routes", topic: .health)
            } footer: {
                Text("Copies routes other apps saved to Health into a separate local collection.")
            }
        }
        .navigationTitle("Apple Health")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { bridge.refresh() }
    }
}
