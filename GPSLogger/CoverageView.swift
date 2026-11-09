import SwiftUI
import Charts
import CoreLocation

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
                Text("Bounded by your \(HistorySettingsView.duration(bridge.historyRetentionHours)) history retention. Coverage before the state log began is unknown. A gap is more than 10 minutes without an accepted fix while tracking was on and not paused. iOS suspension, reception and point filters can all cause gaps.")
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
            keepAlive
            Section {
                Button("Refresh") { Task { await load() } }.disabled(loading)
            } footer: {
                Text("Totals cover this window. Send logging starts with this version and retains at most 20,000 attempts. Queued points are the current pending count. Recorded spans connect accepted fixes up to 10 minutes apart; longer silence marks the full interval as a gap. Paused includes Stop, tracking off, automatic and stationary pauses, event-only modes and missing location access. Nothing in this report is uploaded.")
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
                    Text("No accepted fix for over 10 minutes while tracking was on and not paused. Review keep-alive settings, location access and point filters.")
                }
                .navigationTitle("Recording Gap")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { gap = nil } } }
            }
            .presentationDetents([.medium, .large])
        }
    }
    private var keepAlive: some View {
        Section("Keep-alive in Use") {
            NavigationLink { BackgroundSettingsView() } label: {
                LabeledContent("Live Activity", value: bridge.liveActivityEnabled ? bridge.liveActivityAppearance.capitalized : "Off")
            }
            NavigationLink { BackgroundSettingsView() } label: {
                LabeledContent("Lock Screen Card", value: bridge.liveActivityEnabled && bridge.liveActivityPresentation.cardOn ? "On" : "Off")
            }
            NavigationLink { BackgroundSettingsView() } label: { LabeledContent("Indicator", value: indicator ? "On" : "Off") }
            NavigationLink { BackgroundSettingsView() } label: { LabeledContent("Background Recovery", value: onOff("background_recovery")) }
            NavigationLink { BackgroundSettingsView() } label: { LabeledContent("Service Session", value: serviceSessionStatus) }
            NavigationLink { LocationHealthView() } label: { LabeledContent("Retry", value: onOff("automatic_location_retry")) }
#if WHEREWOLF_SILENT_AUDIO
            NavigationLink { BackgroundSettingsView() } label: { LabeledContent("Silent Audio", value: bridge.silentAudioEnabled ? bridge.silentAudioStatus : "Off") }
#endif
            Link(destination: URL(string: UIApplication.openSettingsURLString)!) {
                LabeledContent("Always Location", value: bridge.locationPermission == "Always" ? "Allowed" : bridge.locationPermission)
            }
            Link(destination: URL(string: UIApplication.openSettingsURLString)!) {
                LabeledContent("Precise Location", value: bridge.hasLocationAccess ? (GLManager.shared().locationManager.accuracyAuthorization == .fullAccuracy ? "On" : "Off") : "No Access")
            }
            Text(bridge.trackingEnabled ? bridge.liveActivityStatus : "Tracking is off. Background helpers are inactive.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private var serviceSessionStatus: String {
        if #available(iOS 18, *) { return onOff("explicit_service_session") }
        return "Requires iOS 18"
    }
    private var indicator: Bool { bridge.tripInProgress ? bridge.tripBackgroundIndicator : bridge.backgroundIndicator }
    private func onOff(_ key: String) -> String { bridge.advancedBool(key) ? "On" : "Off" }
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
