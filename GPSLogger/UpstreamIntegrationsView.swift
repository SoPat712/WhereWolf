import SwiftUI

struct UpstreamIntegrationsView: View {
    @State private var bridge = GLManagerBridge.shared

    var body: some View {
        Form {
            Section {
                Picker("Save Locations To", selection: $bridge.savesToICloudDrive) {
                    Text("Server").tag(false)
                    Text("iCloud Drive").tag(true)
                }
                if bridge.savesToICloudDrive {
                    Picker("File Organization", selection: $bridge.cloudFileMode) {
                        Text("One File per Day").tag(0)
                        Text("One File per Trip").tag(1)
                    }
                    if !bridge.cloudAvailable {
                        Label("iCloud Drive is unavailable", systemImage: "icloud.slash")
                            .foregroundStyle(.orange)
                        Text("Enable iCloud Drive for Where in iOS Settings. The installed build also needs iCloud support. Unwritten data stays in the queue.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                SettingsSectionHeader(title: "Location Destination", topic: .server)
            } footer: {
                Text(bridge.savesToICloudDrive
                     ? "Exports GeoJSON to Where’s folder in iCloud Drive. iOS manages cloud synchronization after the file is saved. Trip files omit records outside a trip. Your server settings remain saved."
                     : "Uses your configured server and the existing upload queue. iCloud export is optional.")
            }

            Section {
                NavigationLink("Import Workout Routes") { WorkoutImportView() }
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
                SettingsSectionHeader(title: "Apple Health", topic: .trip)
            } footer: {
                Text("Optional workout and route export for selected trip modes. Health access is requested when you enable this. It uses a separate local route store and does not remove points from the upload queue.")
            }

            Section {
                LabeledContent("Widget Sharing", value: SharedTripState.isSharedStorageAvailable ? "Available" : "Unavailable in This Build")
                Text("Add Where to the Home Screen or Lock Screen for tracking status and trip controls. Control Center controls are available on iOS 18 and later.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Shortcuts and Siri can start or end trips, send queued data, change trip settings, and report tracking status.")
                    .font(.footnote).foregroundStyle(.secondary)
            } header: {
                SettingsSectionHeader(title: "Widgets & Shortcuts", topic: .trip)
            }
        }
        .navigationTitle("Integrations & Exports")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { bridge.refresh() }
    }
}
