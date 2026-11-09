import SwiftUI
import Charts

struct CoverageView: View {
    @State private var bridge = GLManagerBridge.shared
    @State private var days = 1
    @State private var report: CoverageReport?
    @State private var gap: CoverageSpan?
    @State private var loading = false
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        Form {
            Section {
                Picker("Window", selection: $days) {
                    Text("Last 24 Hours").tag(1)
                    Text("Last 7 Days").tag(7)
                }
            } header: {
                SettingsSectionHeader(title: "History Window", topic: .coverage)
            } footer: {
                Text("Bounded by your \(HistorySettingsView.duration(bridge.historyRetentionHours)) history retention. A gap is over 10 minutes without an accepted fix while tracking was on and not paused.")
            }
            if let report {
                Section("Timeline") {
                    ForEach(windows(report), id: \.start) { window in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(window.start.formatted(date: .abbreviated, time: .shortened)).font(.caption)
                            CoverageTimeline(spans: report.spans, start: window.start, end: window.end) { gap = $0 }
                        }
                    }
                    HStack {
                        legend(.green, "Recorded"); legend(.orange, "Paused"); legend(.red, "Gap"); legend(.gray, "Unknown")
                    }
                    .font(.caption2)
                }
                Section("Totals") {
                    LabeledContent("Points Recorded", value: report.pointCount.formatted())
                        .accessibilityIdentifier("wherewolf.coverage.points")
                    LabeledContent("Longest Gap", value: duration(report.longestGap))
                        .accessibilityIdentifier("wherewolf.coverage.longestGap")
                    LabeledContent("Sends Succeeded", value: report.sendsSucceeded.formatted())
                        .accessibilityIdentifier("wherewolf.coverage.sendsSucceeded")
                    LabeledContent("Sends Failed", value: report.sendsFailed.formatted())
                        .accessibilityIdentifier("wherewolf.coverage.sendsFailed")
                    if let error = report.lastError { LabeledContent("Last Send Error", value: bridge.latestSendError ?? error) }
                    LabeledContent("Points Still Queued", value: bridge.queueCount.formatted())
                        .accessibilityIdentifier("wherewolf.coverage.queued")
                }
                Section("Points per Hour") {
                    Chart(report.hours) { hour in
                        BarMark(x: .value("Hour", hour.start, unit: .hour), y: .value("Points", hour.points))
                    }
                    .frame(height: 150)
                    .accessibilityLabel("Points recorded each hour")
                }
                if !report.gaps.isEmpty {
                    Section("Gaps") {
                        ForEach(report.gaps) { span in
                            Button { gap = span } label: {
                                LabeledContent(span.start.formatted(date: .abbreviated, time: .shortened), value: duration(span.duration))
                            }
                        }
                    }
                }
            } else {
                Section { ProgressView("Reading Coverage…").accessibilityIdentifier("wherewolf.coverage.loading") }
            }
            Section {
                Button("Refresh") { Task { await load() } }.disabled(loading)
            } footer: {
                Text("Totals cover this window. Nothing in this report is uploaded.")
            }
        }
        .navigationTitle("Coverage")
        .navigationBarTitleDisplayMode(.inline)
        .task(id: "\(days)-\(bridge.historyRetentionHours)-\(scenePhase == .active)") {
            guard scenePhase == .active else { return }; await load()
        }
        .sheet(item: $gap) { span in
            NavigationStack {
                Form {
                    LabeledContent("Start", value: span.start.formatted(date: .complete, time: .standard))
                    LabeledContent("End", value: span.end.formatted(date: .complete, time: .standard))
                    LabeledContent("Duration", value: duration(span.duration))
                    Text("No accepted fix for over 10 minutes while tracking was on and not paused. Check Background Reliability, Permissions, and the Saved Points filters in Tracking & Accuracy.")
                }
                .navigationTitle("Recording Gap")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { gap = nil } } }
            }
            .presentationDetents([.medium, .large])
        }
    }
    private func legend(_ color: Color, _ title: String) -> some View {
        HStack(spacing: 3) { Circle().fill(color).frame(width: 5, height: 5); Text(title) }
    }
    private static let durationFormatter: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .abbreviated
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.maximumUnitCount = 2
        return formatter
    }()
    private func duration(_ seconds: TimeInterval) -> String {
        Self.durationFormatter.string(from: seconds) ?? "0s"
    }
    private func windows(_ report: CoverageReport) -> [DateInterval] {
        guard days > 1 else { return [DateInterval(start: report.start, end: report.end)] }
        var result: [DateInterval] = []
        var date = report.start
        while date < report.end {
            let next = min(report.end, Calendar.current.dateInterval(of: .day, for: date)?.end ?? date.addingTimeInterval(86400))
            result.append(DateInterval(start: date, end: next)); date = next
        }
        return result
    }
    private func load() async {
        guard !loading else { return }
        loading = true
        defer { loading = false }
        bridge.refresh()
        async let times: [Date] = withCheckedContinuation { continuation in
            RecentLocationHistory.shared.loadTimestamps { continuation.resume(returning: $0) }
        }
        async let log: CoverageLogSnapshot = withCheckedContinuation { continuation in
            TrackingTransitionLog.shared.load { continuation.resume(returning: $0) }
        }
        let (timestamps, snapshot) = await (times, log)
        guard !Task.isCancelled else { return }
        let end = Date()
        let start = end.addingTimeInterval(-min(Double(days * 24), bridge.historyRetentionHours) * 3600)
        let queued = bridge.queueCount
        report = await Task.detached(priority: .utility) {
            CoverageReport.compute(timestamps: timestamps, transitions: snapshot.transitions, sends: snapshot.sends,
                                   start: start, end: end, queued: queued)
        }.value
    }
}

private struct CoverageTimeline: View {
    let spans: [CoverageSpan]
    let start: Date
    let end: Date
    let select: (CoverageSpan) -> Void
    private var duration: Double { max(1, end.timeIntervalSince(start)) }

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Color.gray.opacity(0.2)
                ForEach(spans.filter { $0.end > start && $0.start < end }) { span in
                    let a = max(span.start, start), b = min(span.end, end)
                    let width = b.timeIntervalSince(a) / duration * geometry.size.width
                    let offset = a.timeIntervalSince(start) / duration * geometry.size.width
                    if span.kind == .gap {
                        Button { select(span) } label: { color(span.kind).frame(width: width, height: 30) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Gap from \(span.start.formatted()) to \(span.end.formatted())")
                            .offset(x: offset)
                    } else {
                        color(span.kind).frame(width: width, height: 30).offset(x: offset)
                            .accessibilityLabel(span.kind.rawValue.capitalized)
                    }
                }
            }
            .clipped()
        }
        .frame(height: 30)
    }
    private func color(_ kind: CoverageSpan.Kind) -> Color {
        switch kind { case .recorded: return .green; case .paused: return .orange; case .gap: return .red; case .unknown: return .gray.opacity(0.4) }
    }
}
