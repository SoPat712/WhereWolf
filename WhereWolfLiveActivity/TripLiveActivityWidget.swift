import ActivityKit
import SwiftUI
import WidgetKit

struct TripLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: TripActivityAttributes.self) { context in
            TripLockScreenView(attributes: context.attributes, state: context.state)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    TripExpandedLeading(mode: context.state.mode)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    TripExpandedTrailing(start: context.attributes.tripStart)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    TripExpandedBottom(state: context.state)
                }
            } compactLeading: {
                TripCompactLeading(mode: context.state.mode)
            } compactTrailing: {
                ElapsedTime(start: context.attributes.tripStart)
                    .frame(maxWidth: 56)
            } minimal: {
                TripMinimalView(mode: context.state.mode)
            }
        }
    }
}
