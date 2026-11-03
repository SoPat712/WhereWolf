import AppIntents
import SwiftUI

struct TrackingLockScreenCard: View {
    let state: TrackingActivityAttributes.ContentState
    var isStale = false
    var preview = false

    private var needsReopen: Bool { isStale || state.reminderDeadline.map { $0 <= Date() } == true }
    private var status: String {
        if needsReopen { return "Open WhereWolf" }
        switch state.trackingStatus ?? .tracking {
        case .tracking: return "Tracking"
        case .paused: return "Paused"
        case .stopped: return "Stopped"
        }
    }
    private var statusColor: Color { needsReopen ? .orange : state.trackingStatus == .stopped ? .secondary : .green }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "mappin.and.ellipse")
                    .font(.system(size: 14, weight: .semibold)).foregroundStyle(.white)
                    .frame(width: 24, height: 24).background(.blue, in: RoundedRectangle(cornerRadius: 6))
                Text("WhereWolf").font(.system(.subheadline, weight: .semibold))
                Spacer(minLength: 0)
                Label(status, systemImage: needsReopen ? "exclamationmark.triangle.fill" : "circle.fill")
                    .font(.caption).foregroundStyle(statusColor)
                    .padding(.horizontal, 8).padding(.vertical, 4)
                    .background(statusColor.opacity(0.12), in: Capsule())
            }
            if state.showsTrip, let start = state.tripStart {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(state.tripModeName ?? "Trip") · \(distance)")
                        .font(.system(.title3, weight: .bold))
                    Text(timerInterval: start...max(start, Date().addingTimeInterval(365 * 86400)), countsDown: false)
                        .font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                }
            } else {
                HStack(spacing: 4) {
                    Text("Last fix")
                    if let date = state.lastFix { Text(date, style: .relative) + Text(" ago") }
                    else { Text("—") }
                }
                .font(.subheadline)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { details; Spacer(minLength: 0); actions }
                VStack(alignment: .leading, spacing: 8) { details; actions }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, preview ? 12 : 14)
        .accessibilityElement(children: .contain)
    }

    private var distance: String {
        let meters = max(0, state.tripDistance ?? 0)
        return meters >= 1000 ? String(format: "%.1f km", meters / 1000) : String(format: "%.0f m", meters)
    }

    private var details: some View {
        HStack(spacing: 0) {
            if let date = state.lastSent { Text("Sent ") + Text(date, style: .relative) + Text(" ago") }
            else { Text("Not sent yet") }
            Text(" · \(state.queuedCount ?? 0) waiting")
        }
        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var actions: some View {
        HStack(spacing: 6) {
            Button(intent: SendNowIntent()) { Text("Send Now") }
                .buttonStyle(.bordered)
            if state.isTrip {
                Button(intent: EndTripIntent()) { Text("End Trip") }
                    .buttonStyle(.bordered).tint(.red)
            }
        }
        .font(.caption.weight(.semibold))
        .controlSize(.small)
        .disabled(preview)
    }
}
