import SwiftUI
import UserNotifications

// Trips opens this from its glass sheet too, so rows follow the sheet's background.
struct LiveActivitySettingsView: View {
    @State private var bridge = GLManagerBridge.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var audioNotificationsAllowed = true
    @State private var requestingAudioNotifications = false

    var body: some View {
        Form {
            Section {
                Toggle("Tracking Live Activity", isOn: $bridge.liveActivityEnabled)
                if bridge.liveActivityEnabled {
                    Picker("Island Appearance", selection: $bridge.liveActivityAppearance) {
                        Text("Status").tag("status")
                        Text("Minimal").tag("minimal")
                        Text("Blank").tag("blank")
                    }
                    Toggle("Lock Screen Card", isOn: Binding(
                        get: { bridge.liveActivityPresentation.cardOn },
                        set: { bridge.liveActivityLockScreenCard = $0 }))
                        .disabled(!bridge.liveActivityPresentation.cardEditable)
                    LabeledContent("Live Activity", value: bridge.liveActivityStatus)
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                SettingsSectionHeader(title: "Tracking", topic: .liveActivities)
            } footer: {
                Text(bridge.liveActivityEnabled && bridge.liveActivityPresentation.cardRequired
                     ? "Minimal and Status always include the Lock Screen card."
                     : "Shows tracking status in the Dynamic Island and on the Lock Screen.")
            }
            .settingsRowBackground()

            Section {
                Toggle("Trip Live Activity", isOn: $bridge.tripLiveActivityEnabled)
            } header: {
                SettingsSectionHeader(title: "Trips", topic: .liveActivities)
            } footer: {
                Text("A separate trip card with elapsed time, distance, Send Now and End Trip.")
            }
            .settingsRowBackground()

            // Both switches act on the tracking and trip activities, so they need one of them.
            if bridge.liveActivityEnabled || bridge.tripLiveActivityEnabled {
                Section {
                    Toggle("Hide While Audio Plays", isOn: $bridge.hideLiveActivityWhileAudioPlays)
                    if bridge.hideLiveActivityWhileAudioPlays {
                        Toggle("Ask to Reopen When Audio Stops", isOn: $bridge.askToReopenAfterAudio)
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
                } header: {
                    SettingsSectionHeader(title: "Audio", topic: .liveActivities)
                } footer: {
                    Text("Hiding while audio plays needs Always location access.")
                }
                .settingsRowBackground()
            }
        }
        .settingsFormStyle()
        .navigationTitle("Live Activities")
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
