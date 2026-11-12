import SwiftUI
import WidgetKit

struct TodayEntry: TimelineEntry {
    let date: Date
    let state: SharedTripState
}

struct TodayProvider: TimelineProvider {
    func placeholder(in context: Context) -> TodayEntry {
        let now = Date()
        var state = SharedTripState()
        state.trackingEnabled = true
        state.todayStart = TodayWindow(containing: now).start
        state.todayDistance = 12_345
        state.todayPoints = 1_204
        state.lastFixDate = now.addingTimeInterval(-120)
        return TodayEntry(date: now, state: state)
    }

    func getSnapshot(in context: Context, completion: @escaping (TodayEntry) -> Void) {
        let now = Date()
        completion(context.isPreview ? placeholder(in: context)
                   : TodayEntry(date: now, state: SharedTripState.read().forToday(at: now)))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<TodayEntry>) -> Void) {
        let now = Date()
        let midnight = TodayWindow(containing: now).end
        let state = SharedTripState.read()
        let entries = [TodayEntry(date: now, state: state.forToday(at: now)),
                       TodayEntry(date: midnight, state: state.forToday(at: midnight))]
        completion(Timeline(entries: entries, policy: .after(min(midnight, now.addingTimeInterval(30 * 60)))))
    }
}

struct TodayWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "Today", provider: TodayProvider()) { entry in
            TodayWidgetView(state: entry.state)
                .widgetBackground()
                .widgetURL(URL(string: "wherewolf://tracker"))
        }
        .configurationDisplayName("Today")
        .description("Today's distance, points and last fix.")
        .supportedFamilies([.systemSmall, .accessoryRectangular, .accessoryCircular, .accessoryInline])
    }
}

struct TodayWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let state: SharedTripState

    var body: some View {
        if !SharedTripState.isSharedStorageAvailable {
            Text("Open WhereWolf to set up widget sharing.")
                .font(.caption)
        } else {
            switch family {
            case .accessoryInline:
                Text("\(TripActivityFormat.distance(state.todayDistance)) \(TripActivityFormat.distanceUnit) today")
                    .lineLimit(1)
                    .minimumScaleFactor(0.1)
            case .accessoryCircular:
                ZStack {
                    AccessoryWidgetBackground()
                    VStack(spacing: 1) {
                        Text(TripActivityFormat.distance(state.todayDistance))
                            .font(.caption.bold())
                            .monospacedDigit()
                            .lineLimit(1)
                            .minimumScaleFactor(0.1)
                        Text(TripActivityFormat.distanceUnit)
                            .font(.caption2)
                    }
                    .padding(4)
                }
            case .accessoryRectangular:
                VStack(alignment: .leading, spacing: 1) {
                    Text("Today").font(.headline)
                    distance.font(.body)
                    (Text("\(state.todayPoints.formatted()) points · ") + lastFix)
                        .font(.caption2)
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            default:
                VStack(alignment: .leading, spacing: 4) {
                    Text("Today")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    distance.font(.largeTitle.bold())
                    Text("\(state.todayPoints.formatted()) points")
                        .font(.caption)
                    (Text("Last fix ") + lastFix)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    HStack(spacing: 6) {
                        Image(systemName: state.trackingEnabled ? "location.fill" : "location.slash")
                            .foregroundStyle(state.trackingEnabled ? .green : .secondary)
                        Text(state.trackingEnabled ? "Tracking" : "Not Tracking")
                    }
                    .font(.caption)
                    .widgetAccentable()
                }
                .lineLimit(1)
                .minimumScaleFactor(0.5)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var distance: some View {
        (Text(TripActivityFormat.distance(state.todayDistance))
         + Text(" \(TripActivityFormat.distanceUnit)").font(.caption))
            .monospacedDigit()
            .lineLimit(1)
            .minimumScaleFactor(0.1)
    }

    private var lastFix: Text {
        if let date = state.lastFixDate {
            return Text(date, style: .relative) + Text(" ago")
        }
        return Text("unavailable")
    }
}
