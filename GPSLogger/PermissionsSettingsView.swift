import SwiftUI

struct PermissionsSettingsView: View {
    @State private var bridge = GLManagerBridge.shared
    @State private var status: OnboardingStatus?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
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
                if bridge.hasLocationAccess, let status {
                    LabeledContent {
                        Text(status.preciseLocation ? "On" : "Off")
                    } label: {
                        SettingsRowLabel(title: "Precise Location", symbol: "scope", color: .green)
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                SettingsSectionHeader(title: "Location", topic: .permissions)
            } footer: {
                Text("Always access lets WhereWolf record locations in the background.")
            }

            Section {
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
            } header: {
                Text("Motion & Fitness")
            }

            Section {
                LabeledContent {
                    Text(status.map { notificationText($0.notifications) } ?? "")
                } label: {
                    SettingsRowLabel(title: "Notifications", symbol: "bell.badge.fill", color: .red)
                }
                .accessibilityElement(children: .combine)
            } header: {
                Text("Notifications")
            }

            if bridge.healthAvailable {
                Section {
                    LabeledContent {
                        Text(status.map { $0.health == .reviewed ? "Reviewed" : "Not Requested" } ?? "")
                    } label: {
                        SettingsRowLabel(title: "Apple Health", symbol: "heart.fill", color: .pink)
                    }
                    .accessibilityElement(children: .combine)
                } header: {
                    Text("Apple Health")
                } footer: {
                    Text("Health doesn’t tell apps what you allowed. Change access in the Health app.")
                }
            }

            Section {
                Link("Open iOS Settings", destination: URL(string: UIApplication.openSettingsURLString)!)
            }
        }
        .navigationTitle("Permissions")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { bridge.refresh() }
        .task { await load() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await load() } }
        }
    }

    // Shares the guide's reader, which asks Health only whether its request was answered.
    private func load() async {
        status = await bridge.onboardingStatus { UIApplication.shared.canOpenURL($0) }
    }

    private func notificationText(_ permission: OnboardingPermissionStatus) -> String {
        switch permission {
        case .granted: return "Allowed"
        case .denied: return "Denied"
        case .notDetermined: return "Not Requested"
        case .limited: return "Provisional"
        case .reviewed, .unavailable: return "Unavailable"
        }
    }
}
