import SwiftUI

struct LocationHealthEntry: Identifiable, Sendable {
    let id: String
    let date: Date
    let kind: String
    let seconds: Double
    let attempt: Int
    let engine: String
    let reason: String
    let rejected: [String: Int]

    init?(_ value: [AnyHashable: Any]) {
        guard let kind = value["kind"] as? String, let time = value["time"] as? NSNumber else { return nil }
        id = value["id"] as? String ?? UUID().uuidString
        date = Date(timeIntervalSince1970: time.doubleValue)
        self.kind = kind
        seconds = (value["seconds"] as? NSNumber)?.doubleValue ?? 0
        attempt = (value["attempt"] as? NSNumber)?.intValue ?? 0
        engine = value["engine"] as? String ?? ""
        reason = value["reason"] as? String ?? ""
        rejected = (value["rejected"] as? [String: NSNumber] ?? [:]).mapValues(\.intValue)
    }

    var title: String {
        switch kind {
        case "logging_started": return "Location Log Enabled"
        case "app_launched": return "WhereWolf Opened"
        case "monitor_resumed": return "Checking Location Updates"
        case "monitor_paused": return "Location Checks Paused"
        case "updates_missing": return "Location Updates Stopped Arriving"
        case "updates_outdated": return "Waiting for Fresh Locations"
        case "retry_requested": return "Automatic Retry \(attempt) of 3"
        case "manual_retry": return "Location Retry Requested"
        case "updates_resumed": return "Fresh Locations Resumed"
        case "points_skipped": return "Received Points Were Skipped"
        case "saving_resumed": return "Saving Locations Resumed"
        case "save_time_expired": return "Extra Saving Time Ended"
        default: return "Location Update Event"
        }
    }

    var detail: String {
        var parts: [String] = []
        if seconds > 0 { parts.append(SettingFormat.seconds(seconds.rounded())) }
        if let explanation = Self.reasons[reason] { parts.append(explanation) }
        if !rejected.isEmpty {
            parts.append(rejected.keys.sorted().map { "\(Self.rejectionNames[$0] ?? $0): \(rejected[$0]!)" }.joined(separator: ", "))
        }
        if !engine.isEmpty { parts.append(engine == "new" ? "New engine" : "Original engine") }
        return parts.joined(separator: " · ")
    }

    static let reasons = [
        "tracking_off": "Tracking is off", "event_mode": "Only event-based updates are requested",
        "permission": "Location access is unavailable", "radius_pause": "Paused by your stationary radius",
        "adaptive_pause": "Adaptive tracking is conserving power", "automatic_pause": "iOS paused location updates",
        "location_event": "Launched for a location event", "other_launch": "Launch reason was not a location event"
    ]
    static let rejectionNames = [
        "invalid": "Invalid readings", "accuracy": "Accuracy limit", "jump": "Unconfirmed jumps",
        "order": "Older readings", "duplicate": "Repeated points", "stationary": "Stationary filter",
        "gps": "No GPS filter", "threshold": "Time, distance or turn limits", "storage": "Could not save"
    ]
}

struct LocationHealthView: View {
    @State private var bridge = GLManagerBridge.shared
    @State private var entries: [LocationHealthEntry] = []
    @State private var reloadRevision = 0
    @State private var confirmingClear = false

    private var health: [String: Any] { bridge.locationHealth }
    private var state: String { health["state"] as? String ?? "off" }
    private var attempts: Int { (health["attempts"] as? NSNumber)?.intValue ?? 0 }
    private var status: String {
        switch state {
        case "off": return "Checks are off"
        case "paused": return LocationHealthEntry.reasons[health["reason"] as? String ?? ""] ?? "Checks are paused"
        case "receiving": return "Locations are up to date"
        case "updates_missing": return "Location updates stopped arriving"
        case "updates_outdated": return "Waiting for fresh locations"
        case "points_skipped": return "Receiving locations; points were skipped"
        default: return "Waiting for location updates"
        }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent {
                    Text(status).multilineTextAlignment(.trailing)
                } label: {
                    SettingsRowLabel(title: "Location Updates", symbol: "location.fill", color: state == "receiving" ? .green : .blue)
                }
                if state != "off" && state != "paused" {
                    LabeledContent("Automatic Retries", value: "\(attempts) of 3")
                    if let age = health["fresh_age"] as? NSNumber {
                        LabeledContent("Time Without a Fresh Location", value: SettingFormat.seconds(age.doubleValue.rounded()))
                    }
                }
                if attempts >= 3 {
                    Text("The automatic retry limit has been reached. A fresh location or a manual retry resets it.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button("Retry Location Updates Now") { bridge.retryLocationUpdates() }
                    .disabled(!bridge.trackingEnabled || !bridge.hasContinuousUpdates || state == "paused")
            } header: {
                SettingsSectionHeader(title: "Current Status", topic: .locationLog)
            } footer: {
                Text("Retry Stalled Updates in Background Reliability retries automatically.")
            }

            Section {
                Toggle("Save Location Log", isOn: option("location_health_log"))
                if !entries.isEmpty {
                    ShareLink(item: report) { Label("Share Location Log", systemImage: "square.and.arrow.up") }
                    Button("Clear Location Log…", role: .destructive) { confirmingClear = true }
                }
            } header: {
                SettingsSectionHeader(title: "Saved Log", topic: .locationLog)
            } footer: {
                Text("Keeps up to 200 events for seven days on this device, without coordinates or credentials.")
            }

            Section {
                if entries.isEmpty {
                    Text("No events saved. Turn on Save Location Log to record future gaps and recovery attempts.")
                        .foregroundStyle(.secondary)
                }
                ForEach(entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.title)
                        Text(entry.date.formatted(date: .abbreviated, time: .standard))
                            .font(.caption).foregroundStyle(.secondary)
                        if !entry.detail.isEmpty {
                            Text(entry.detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("Recent Events")
            } footer: {
                Text("Missing events do not prove that iOS terminated the app.")
            }
        }
        .navigationTitle("Location Log")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: reloadRevision) {
            let loaded = await bridge.loadLocationHealthLog()
            guard !Task.isCancelled else { return }
            entries = loaded
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("WhereWolfLocationHealthChanged"))) { _ in
            reloadRevision += 1
        }
        .onAppear { bridge.refresh() }
        .alert("Clear the location log?", isPresented: $confirmingClear) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Location Log", role: .destructive) {
                Task { await bridge.clearLocationHealthLog(); reloadRevision += 1 }
            }
        } message: {
            Text("Removes the saved events from this device. Recorded locations and pending uploads are kept.")
        }
    }

    private func option(_ key: String) -> Binding<Bool> {
        Binding(get: { bridge.advancedBool(key) }, set: { bridge.setAdvancedBool($0, forKey: key) })
    }

    private var report: String {
        (["WhereWolf Location Log"] + entries.map {
            "\($0.date.formatted(date: .numeric, time: .standard)) — \($0.title)\($0.detail.isEmpty ? "" : ": " + $0.detail)"
        }).joined(separator: "\n")
    }
}
