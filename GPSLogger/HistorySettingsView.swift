import SwiftUI

struct HistorySettingsView: View {
    @State private var bridge = GLManagerBridge.shared
    @State private var summary: HistoryStorageSummary?
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                SliderRow(title: "Keep History", value: $bridge.historyRetentionHours,
                          range: 24...168, unit: "hours", format: Self.duration)
            } header: {
                Text("On-Device Replay")
            } footer: {
                Text("Keep between 24 hours and 7 days of points recorded by this app. Uploaded points remain available here until this window expires. Increasing the window keeps future points longer; expired points cannot be recovered. Shortening it removes older local history.")
            }

            Section {
                if let summary {
                    LabeledContent("Stored Points", value: summary.pointCount.formatted())
                    LabeledContent("On-Device Storage", value: ByteCountFormatter.string(
                        fromByteCount: summary.storageBytes, countStyle: .file))
                } else {
                    ProgressView("Reading History Storage…")
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Storage depends on how often points are saved and the information in each record. Freed space may be reused for new points. The upload queue and your server’s history have their own lifetimes.")
            }

            Section {
                Label("Hold the ruler, then drag", systemImage: "hand.draw")
                Text("A time bubble appears during coarse scrolling. Release to stop, then drag normally for a precise time.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Browsing")
            }
        }
        .navigationTitle("Local History & Replay")
        .navigationBarTitleDisplayMode(.inline)
        .settingsFormStyle()
        .task(id: scenePhase == .active ? bridge.historyRetentionHours : 0) {
            guard scenePhase == .active else { return }
            let result = await bridge.loadHistoryStorageSummary()
            guard !Task.isCancelled else { return }
            summary = result
        }
    }

    static func duration(_ value: Double) -> String {
        let hours = Int(value.rounded())
        if hours == 24 { return "24 hours" }
        if hours.isMultiple(of: 24) { return "\(hours / 24) days" }
        return "\(hours) hours"
    }
}
