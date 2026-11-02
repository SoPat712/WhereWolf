import SwiftUI
import UIKit

struct TrackerView: View {
    var history: HistoryPlaybackModel
    var onLive: () -> Void
    @State private var confirmingStop = false
    @State private var showingDetails = false
    @State private var bridge = GLManagerBridge.shared
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 8) {
            if let error = bridge.latestSendError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
                    .accessibilityLabel("Last send failed: \(error)")
            } else if bridge.waitingForWifi && bridge.queueCount > 0 {
                Label("Waiting for Wi-Fi to send", systemImage: "wifi")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HistoryRuler(history: history, onLive: onLive)
            if history.isBrowsing {
                HistoryPlaybackView(history: history)
                    .transition(.opacity.combined(with: .offset(y: 8)))
            } else {
                VStack(spacing: 8) {
                    HStack(spacing: 8) {
                        trackingButton
                        DrawerDetailsButton(expanded: $showingDetails, subject: "location")
                        DrawerCircleButton(symbol: bridge.sending ? "arrow.up.circle" : "paperplane.fill",
                                           label: bridge.sending ? (bridge.savesToICloudDrive ? "Saving" : "Sending") : (bridge.savesToICloudDrive ? "Save Now" : "Send Now"), contentSize: 32) {
                            GLManager.shared().sendQueueNow()
                        }
                        .disabled(!bridge.destinationSet || bridge.queueCount == 0)
                    }
                    .controlSize(.small)
                    .frame(minHeight: 44)
                    .padding(.horizontal, 16)
                    if showingDetails { overview }
                }
                .transition(.opacity.combined(with: .offset(y: 8)))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .animation(history.isRulerInteracting ? nil : .easeInOut(duration: 0.3), value: history.isBrowsing)
        .confirmStopTracking($confirmingStop) { bridge.trackingOn = false }
        .onAppear {
            bridge.refresh()
            history.reload()
        }
    }

    private var statusLine: String {
        let state = bridge.trackingEnabled ? bridge.engineStatus + " · " + bridge.authorizationStatus : "Tracking paused"
        guard bridge.lastLocationAge != "–" else { return "\(state) · Waiting for a location" }
        return "\(state) · Updated \(bridge.lastLocationAge) ago"
    }

    private var overview: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(statusLine)
                .font(.caption)
                .foregroundStyle(.secondary)
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 8) {
                    locationDetails
                    locationAccuracy
                }
            } else {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    locationDetails
                    Spacer(minLength: 0)
                    locationAccuracy
                }
            }
            Divider()
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 10) { metrics }
            } else {
                HStack(alignment: .top, spacing: 12) { metrics }
            }
            Divider()
            health
        }
        .drawerCard()
    }

    private var locationDetails: some View {
        VStack(alignment: .leading, spacing: 3) {
            Label("Current location", systemImage: "location.fill")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(bridge.lastLocationText == "–" ? "No location yet"
                 : dynamicTypeSize.isAccessibilitySize ? bridge.lastLocationText
                 : bridge.lastLocationText.replacingOccurrences(of: "\n", with: ", "))
                .font(.body.weight(.medium).monospacedDigit())
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .minimumScaleFactor(0.8)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var locationAccuracy: some View {
        if bridge.lastLocationText != "–" {
            Text(bridge.lastAccuracyText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var metrics: some View {
        deliveryMetric("Queued", value: bridge.queueCount.formatted(), icon: "tray.full")
        deliveryMetric(bridge.savesToICloudDrive ? "Last saved" : "Last sent", value: bridge.lastSentText, icon: "paperplane")
        deliveryMetric("Auto-send", value: bridge.sendIntervalValue < 1
                       ? "Off" : SettingFormat.seconds(bridge.sendIntervalValue), icon: "timer")
    }

    private func deliveryMetric(_ title: String, value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.subheadline.weight(.medium).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var health: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Health")
                .font(.caption.weight(.semibold))
            healthRow("Received fix", value: receivedFixSummary, icon: "location")
            healthRow("Saved point", value: savedPointSummary, icon: "checkmark.circle")
            healthRow("Upload", value: uploadSummary, icon: "arrow.up.circle")
            if bridge.adaptiveTrackingStatus != "Off" {
                healthRow("Adaptive", value: bridge.adaptiveTrackingStatus, icon: "dial.low")
            }
            if bridge.rejectedJumpCount > 0 {
                Text("\(bridge.rejectedJumpCount.formatted()) jump candidate\(bridge.rejectedJumpCount == 1 ? "" : "s") rejected")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func healthRow(_ title: String, value: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.monospacedDigit())
                .multilineTextAlignment(.trailing)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .minimumScaleFactor(0.75)
        }
    }

    private var receivedFixSummary: String {
        guard bridge.lastReceivedLocationAge != "–" else { return "No fix received" }
        return "\(bridge.lastReceivedLocationAge) ago · \(bridge.lastReceivedAccuracyText)"
    }

    private var savedPointSummary: String {
        guard bridge.lastLocationAge != "–" else { return "No point saved" }
        return "\(bridge.lastLocationAge) ago · \(bridge.lastAccuracyText)"
    }

    private var uploadSummary: String {
        if bridge.sending { return "Sending" }
        if bridge.uploadsBlocked { return "Blocked" }
        if bridge.waitingForWifi && bridge.queueCount > 0 { return "Waiting for Wi-Fi" }
        if bridge.pendingUploads { return "Pending" }
        return "Up to date"
    }

    private var trackingButton: some View {
        Button {
            if bridge.trackingEnabled {
                confirmingStop = true
            } else {
                bridge.trackingOn = true
            }
            bridge.refresh()
        } label: {
            Label(bridge.trackingEnabled ? "Stop Tracking" : "Start Tracking",
                  systemImage: bridge.trackingEnabled ? "stop.fill" : "play.fill")
                .font(.subheadline.weight(.semibold))
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity, minHeight: 32)
        }
        .glassButtonStyle(prominent: true, tint: bridge.trackingEnabled ? .red : .blue)
    }
}

struct TrackerSpeedometer: View {
    var replaySpeed: Double? = nil
    var isReplaying = false
    @State private var bridge = GLManagerBridge.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var speedValue: Int? {
        guard isReplaying else { return bridge.speed }
        guard let replaySpeed, replaySpeed.isFinite else { return nil }
        let multiplier = bridge.speedUnit == "KM/H" ? 3.6 : 2.23694
        return max(0, Int((replaySpeed * multiplier).rounded()))
    }

    private var displayedSpeed: String { speedValue.map(String.init) ?? "–" }

    var body: some View {
        VStack(spacing: 0) {
            Text(isReplaying ? "REPLAY" : "SPEED")
                .font(.system(size: 9, weight: .bold))
                .tracking(0.6)
                .foregroundStyle(isReplaying ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
            SlidingSpeedReadout(value: speedValue, animated: !reduceMotion)
                .frame(width: 48, height: 34)
            Text(bridge.speedUnit)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .foregroundStyle(.primary)
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .frame(minWidth: 64)
        .glassPanel(cornerRadius: 20)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(isReplaying ? "Recorded" : "Current") speed \(displayedSpeed) \(bridge.speedUnit)")
        .accessibilityIdentifier("where.map.speed")
    }
}

struct ReplayStatusOverlay: View {
    var history: HistoryPlaybackModel
    var active: Bool
    var height: CGFloat
    @State private var bridge = GLManagerBridge.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var status: ReplayStatus? { active ? history.replayStatus : nil }
    private var metric: Bool { bridge.speedUnit == "KM/H" }

    var body: some View {
        ZStack {
            if let status {
                panel(status)
                    .padding(.leading, MapChrome.replayStatusClearance)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.opacity)
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: status == nil)
    }

    // A steady size keeps the panel from shifting as values change. Readings that do not fit stack
    // instead of truncating, and the panel then grows past the speedometer's height.
    private func panel(_ status: ReplayStatus) -> some View {
        ViewThatFits(in: .horizontal) {
            VStack(alignment: .leading, spacing: 2) {
                title(status)
                time(status)
                HStack(spacing: 10) {
                    altitude(status)
                    distance(status)
                }
            }
            .lineLimit(1)
            VStack(alignment: .leading, spacing: 2) {
                title(status)
                time(status)
                altitude(status)
                distance(status)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: MapChrome.replayStatusWidth, minHeight: height)
        .glassPanel(cornerRadius: 20)
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText(status))
        .accessibilityIdentifier("where.map.replay-status")
    }

    private func title(_ status: ReplayStatus) -> some View {
        Label {
            Text(status.activity.title).font(.callout.weight(.semibold))
        } icon: {
            Image(systemName: status.activity.symbol).font(.subheadline.weight(.semibold)).foregroundStyle(.tint)
        }
    }

    private func time(_ status: ReplayStatus) -> some View {
        Text(timeText(status.time)).metricStyle()
    }

    @ViewBuilder
    private func altitude(_ status: ReplayStatus) -> some View {
        if let altitude = status.altitude {
            HStack(spacing: 3) {
                Image(systemName: trendSymbol(status.altitudeTrend))
                Text(ReplayStatus.altitudeText(altitude, metric: metric))
            }
            .metricStyle()
        }
    }

    @ViewBuilder
    private func distance(_ status: ReplayStatus) -> some View {
        if let distance = status.legDistance, distance >= 100 {
            HStack(spacing: 3) {
                Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                Text(ReplayStatus.distanceText(distance, metric: metric))
            }
            .metricStyle()
        }
    }

    private func trendSymbol(_ trend: Int) -> String {
        trend > 0 ? "arrow.up.right" : trend < 0 ? "arrow.down.right" : "mountain.2"
    }

    private func timeText(_ date: Date) -> String {
        Calendar.current.isDateInToday(date)
            ? date.formatted(date: .omitted, time: .shortened)
            : date.formatted(.dateTime.weekday(.abbreviated).hour().minute())
    }

    private func accessibilityText(_ status: ReplayStatus) -> String {
        var parts = [status.activity.title, timeText(status.time)]
        if let altitude = status.altitude {
            let trend = status.altitudeTrend > 0 ? ", rising" : status.altitudeTrend < 0 ? ", falling" : ""
            parts.append("Altitude \(ReplayStatus.altitudeText(altitude, metric: metric))\(trend)")
        }
        if let distance = status.legDistance, distance >= 100 {
            parts.append("\(ReplayStatus.distanceText(distance, metric: metric)) since last stop")
        }
        return parts.joined(separator: ", ")
    }
}

private extension View {
    func metricStyle() -> some View {
        font(.footnote.monospacedDigit().weight(.medium)).foregroundStyle(.secondary)
    }
}

private struct SlidingSpeedReadout: UIViewRepresentable {
    let value: Int?
    let animated: Bool

    func makeUIView(context: Context) -> SlidingSpeedLabel {
        SlidingSpeedLabel()
    }

    func updateUIView(_ view: SlidingSpeedLabel, context: Context) {
        view.setValue(value, animated: animated)
    }

    static func dismantleUIView(_ view: SlidingSpeedLabel, coordinator: ()) {
        view.finishImmediately()
    }
}

private final class SlidingSpeedLabel: UIView {
    private var currentLabel = UILabel()
    private var incomingLabel = UILabel()
    private var displayedValue: Int?
    private var requestedValue: Int?
    private var animator: UIViewPropertyAnimator?
    private var settleWork: DispatchWorkItem?
    private var generation = 0

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        isUserInteractionEnabled = false
        let font = UIFont.monospacedDigitSystemFont(ofSize: 28, weight: .semibold)
        let descriptor = font.fontDescriptor.withDesign(.rounded) ?? font.fontDescriptor
        for label in [currentLabel, incomingLabel] {
            label.font = UIFont(descriptor: descriptor, size: 28)
            label.textColor = .label
            label.textAlignment = .center
            label.adjustsFontSizeToFitWidth = true
            label.minimumScaleFactor = 0.5
            label.isAccessibilityElement = false
            addSubview(label)
        }
        currentLabel.text = "–"
        incomingLabel.isHidden = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        for label in [currentLabel, incomingLabel] {
            label.bounds = bounds
            label.center = CGPoint(x: bounds.midX, y: bounds.midY)
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { finishImmediately() }
    }

    func setValue(_ value: Int?, animated: Bool) {
        requestedValue = value
        guard animated, window != nil, value != nil, displayedValue != nil else {
            finishImmediately()
            return
        }
        slideToLatest()
    }

    func finishImmediately() {
        generation += 1
        animator?.stopAnimation(true)
        animator = nil
        settleWork?.cancel()
        settleWork = nil
        UIView.performWithoutAnimation {
            currentLabel.transform = .identity
            incomingLabel.transform = .identity
            currentLabel.text = requestedValue.map { $0.formatted(.number.grouping(.never)) } ?? "–"
            currentLabel.isHidden = false
            incomingLabel.isHidden = true
        }
        displayedValue = requestedValue
    }

    private func slideToLatest() {
        guard animator == nil, settleWork == nil,
              let source = displayedValue, let destination = requestedValue,
              source != destination else { return }
        layoutIfNeeded()
        let distance = max(1, bounds.height) * (destination > source ? 1 : -1)
        UIView.performWithoutAnimation {
            incomingLabel.text = destination.formatted(.number.grouping(.never))
            incomingLabel.transform = CGAffineTransform(translationX: 0, y: -distance)
            incomingLabel.isHidden = false
        }
        let revision = generation
        let transition = UIViewPropertyAnimator(duration: 0.14, curve: .easeOut) { [weak self] in
            self?.currentLabel.transform = CGAffineTransform(translationX: 0, y: distance)
            self?.incomingLabel.transform = .identity
        }
        animator = transition
        transition.addCompletion { [weak self] _ in
            guard let self, self.generation == revision else { return }
            self.animator = nil
            self.displayedValue = destination
            let previousLabel = self.currentLabel
            self.currentLabel = self.incomingLabel
            self.incomingLabel = previousLabel
            self.incomingLabel.isHidden = true
            self.incomingLabel.transform = .identity
            // Finish each slide and hold the reading; fast updates replace one pending value.
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.generation == revision else { return }
                self.settleWork = nil
                self.slideToLatest()
            }
            self.settleWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12, execute: work)
        }
        transition.startAnimation()
    }
}
