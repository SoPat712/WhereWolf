import ActivityKit
import SwiftUI
import WidgetKit

struct TrackingActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TrackingActivityAttributes.self) { _ in
            EmptyView()
                .activityBackgroundTint(.clear)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.center) {
                    if context.state.appearance == .blank {
                        emptyContent
                    } else if context.isStale {
                        VStack(spacing: 4) {
                            Label("Open Where", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Location updates were stopped. Launch the app to resume.")
                                .font(.caption)
                        }
                    } else {
                        VStack(spacing: 4) {
                            Label(context.state.isTrip ? "Recording trip" : "Tracking on", systemImage: "location.fill")
                            if context.state.appearance == .status {
                                if let sent = context.state.lastSent {
                                    Text("Last sent \(sent, style: .relative) ago").font(.caption)
                                } else {
                                    Text("No successful send yet").font(.caption)
                                }
                            }
                        }
                    }
                }
            } compactLeading: {
                if context.state.appearance == .blank {
                    emptyContent
                } else if context.isStale {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    Image(systemName: "location.fill").foregroundStyle(.blue)
                }
            } compactTrailing: {
                if context.state.appearance == .blank { emptyContent }
                else if context.isStale { Text("Open").font(.caption) }
                else if context.state.appearance == .status { Text("On").font(.caption) }
                else { emptyContent }
            } minimal: {
                if context.state.appearance == .blank {
                    emptyContent
                } else if context.isStale {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    Image(systemName: "location.fill").foregroundStyle(.blue)
                }
            }
            .widgetURL(URL(string: "overland://tracker"))
        }
    }

    // iOS may retain its surface even with transparent, zero-sized content.
    private var emptyContent: some View {
        Color.clear.frame(width: 0, height: 0).accessibilityHidden(true)
    }
}

@main
struct OverlandWidgetBundle: WidgetBundle {
    var body: some Widget {
        TrackingActivityWidget()
        TripLiveActivityWidget()
        StatusWidget()
        if #available(iOS 18.0, *) {
            TripControl()
            SendNowControl()
        }
    }
}
