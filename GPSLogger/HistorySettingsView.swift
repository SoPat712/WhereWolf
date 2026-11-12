import SwiftUI

struct HistorySettingsView: View {
    @State private var bridge = GLManagerBridge.shared
    @State private var serverHistory = ServerHistoryStore.shared
    @State private var clearingServerHistory = false
    @State private var summary: HistoryStorageSummary?
    @State private var insightsBytes: Int64 = 0
    @State private var clearingInsights = false
    @State private var insightsClearFailed = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                SliderRow(title: "Keep History", value: $bridge.historyRetentionHours,
                          range: 24...168, unit: "hours", format: Self.duration)
            } header: {
                SettingsSectionHeader(title: "On-Device Replay", topic: .history)
            } footer: {
                Text("Keep 24 hours to 7 days of points. Shortening it removes older local history.")
            }

            Section {
                if let summary {
                    LabeledContent("Stored Points", value: summary.pointCount.formatted())
                    LabeledContent("On-Device Storage", value: ByteCountFormatter.string(
                        fromByteCount: summary.storageBytes, countStyle: .file))
                } else {
                    ProgressView("Reading History Storage…")
                }
                if serverHistory.available || serverHistory.storageBytes > 0 {
                    HStack {
                        LabeledContent("Server History", value: ByteCountFormatter.string(
                            fromByteCount: serverHistory.storageBytes, countStyle: .file))
                        Button("Clear", role: .destructive) {
                            clearingServerHistory = true
                            Task {
                                await serverHistory.clear()
                                clearingServerHistory = false
                            }
                        }
                        .disabled(clearingServerHistory)
                        .accessibilityLabel("Clear Server History")
                        .accessibilityIdentifier("wherewolf.history.clear-server")
                    }
                    if let error = serverHistory.errorMessage {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                if insightsBytes > 0 || ShellTabPolicy.showsInsights(status: bridge.dawarich) {
                    HStack {
                        LabeledContent("Insights Cache", value: ByteCountFormatter.string(
                            fromByteCount: insightsBytes, countStyle: .file))
                        Button("Clear", role: .destructive) {
                            clearingInsights = true
                            Task {
                                do { try await DawarichInsightsCache.shared.clear() }
                                catch { insightsClearFailed = true }
                                insightsBytes = await DawarichInsightsCache.shared.storageBytes()
                                clearingInsights = false
                            }
                        }
                        .disabled(clearingInsights)
                        .accessibilityLabel("Clear Dawarich Insights Cache")
                    }
                }
            } header: {
                SettingsSectionHeader(title: "Storage", topic: .history)
            } footer: {
                Text("Clear removes downloaded copies from this iPhone. Your server and upload queue keep their data.")
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
        .navigationTitle("History & Replay")
        .navigationBarTitleDisplayMode(.inline)
        .settingsFormStyle()
        .task(id: scenePhase == .active ? bridge.historyRetentionHours : 0) {
            guard scenePhase == .active else { return }
            let result = await bridge.loadHistoryStorageSummary()
            guard !Task.isCancelled else { return }
            summary = result
            insightsBytes = await DawarichInsightsCache.shared.storageBytes()
            await serverHistory.refreshStorageSize()
        }
        .alert("Couldn’t Clear Insights", isPresented: $insightsClearFailed) {
            Button("OK", role: .cancel) { }
        } message: { Text("Try again after unlocking this iPhone.") }
    }

    static func duration(_ value: Double) -> String {
        let hours = Int(value.rounded())
        if hours == 24 { return "24 hours" }
        if hours.isMultiple(of: 24) { return "\(hours / 24) days" }
        return "\(hours) hours"
    }
}
