import SwiftUI
import MapKit

struct TripView: View {
    @State private var bridge = GLManagerBridge.shared
    @Binding var camera: MapCameraPosition
    @Binding var trip: TripMapState
    var historyStart: Date?
    var onShowTrip: (ClosedRange<Date>) -> Void = { _ in }
    // The drawer keeps this page built behind the Tracker, so it refreshes when shown rather than on appear.
    var shown = true
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var modeWidth: CGFloat = 64
    @State private var sheet: TripSheet?
    @State private var shownTrip: ClosedRange<Date>?
    @State private var started = 0
    @State private var ended = 0
    @State private var picked = 0

    var body: some View {
        VStack(spacing: 14) {
            if bridge.tripInProgress {
                stats
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            } else {
                modeRow
                    .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96, anchor: .bottom)))
            }
            HStack(spacing: 10) {
                tripButton
                DrawerCircleButton(symbol: "slider.horizontal.3", label: "Trip Settings") { sheet = .settings }
            }
            .padding(.horizontal, 16)
            if !bridge.tripInProgress && !bridge.recentTrips.isEmpty {
                recentTrips
                    .transition(.opacity)
            }
        }
        .padding(.top, 4)
        .fixedSize(horizontal: false, vertical: true)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.15),
                   value: bridge.tripInProgress)
        .sensoryFeedback(.start, trigger: started)
        .sensoryFeedback(.stop, trigger: ended)
        .sensoryFeedback(.selection, trigger: picked)
        .onChange(of: shown, initial: true) { _, shown in
            guard shown else { return }
            bridge.refresh()
            bridge.loadRecordedTrips()
        }
        .onChange(of: bridge.tripInProgress) { _, recording in
            if !recording { bridge.loadRecordedTrips() }
        }
        .onChange(of: bridge.tripMode) { _, mode in
            guard let coordinate = GLManager.shared().lastLocation?.coordinate else { return }
            camera = .camera(MapKit.MapCamera(centerCoordinate: coordinate,
                distance: TripModeStore.closeZoom(mode) ? 1_000 : 10_000))
        }
        // The Tracker opens once the sheet has gone, so the tab switch does not race its dismissal.
        .sheet(item: $sheet, onDismiss: {
            if let trip = shownTrip { shownTrip = nil; onShowTrip(trip) }
        }) { sheet in
            if sheet == .trips {
                AllTripsView(trips: bridge.recentTrips, historyStart: historyStart) { trip in
                    shownTrip = trip
                    self.sheet = nil
                }
            } else {
                TripSettingsSheet(opensModes: sheet == .modes) { self.sheet = nil }
            }
        }
    }

    // MARK: Modes

    private var modeRow: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(bridge.tripModes, id: \.id) { mode in
                        modeButton(mode).id(mode.id)
                    }
                    editModesButton
                }
                .padding(.horizontal, 16)
            }
            .onAppear { proxy.scrollTo(bridge.tripMode, anchor: .center) }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Travel Mode")
    }

    private func modeButton(_ mode: TripMode) -> some View {
        let selected = mode.id == bridge.tripMode
        return Button {
            guard !selected else { return }
            bridge.tripMode = mode.id
            picked += 1
        } label: {
            VStack(spacing: 6) {
                modeIcon(mode.symbol)
                    .frame(width: 24, height: 24)
                    .foregroundStyle(selected ? Color.white : Color.primary)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(selected ? AnyShapeStyle(.tint) : AnyShapeStyle(Color.drawerCard)))
                Text(mode.name)
                    .font(.caption.weight(selected ? .semibold : .regular))
                    .foregroundStyle(selected ? Color.primary : Color.secondary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .minimumScaleFactor(0.8)
                    .multilineTextAlignment(.center)
            }
            .frame(width: max(64, modeWidth))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: selected)
        .accessibilityLabel(mode.name)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var editModesButton: some View {
        Button { sheet = .modes } label: {
            VStack(spacing: 6) {
                Image(systemName: "ellipsis")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Color.drawerCard))
                Text("Edit")
                    .font(.caption)
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
            }
            .frame(width: max(64, modeWidth))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Edit Trip Modes")
    }

    private func modeIcon(_ symbol: String) -> some View { tripModeIcon(symbol) }

    // MARK: Recording

    private var stats: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                RecordingDot(active: shown)
                modeIcon(TripModeStore.symbol(bridge.tripMode))
                    .frame(width: 16, height: 16)
                Text("Recording · \(TripModeStore.name(bridge.tripMode))")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            // The app's one-second clock drifts against the trip's start, so it would sometimes show a
            // second twice and then skip one. This redraws on each whole second since the start.
            if let start = bridge.tripStart {
                TimelineView(.periodic(from: start, by: 1)) { context in
                    elapsed(context.date.timeIntervalSince(start))
                }
            } else {
                elapsed(bridge.tripDuration)
            }
            let metric = Locale.current.measurementSystem == .metric
            let distance = tripStat("Distance", value: TripFormat.distance(bridge.tripDistance, metric: metric))
            let average = TripFormat.usesPace(bridge.tripMode)
                ? tripStat("Avg Pace", value: TripFormat.pace(distance: bridge.tripDistance, duration: bridge.tripDuration, metric: metric))
                : tripStat("Avg Speed", value: TripFormat.averageSpeed(distance: bridge.tripDistance,
                                                                       duration: bridge.tripDuration, metric: metric))
            let top = tripStat("Top Speed", value: TripFormat.speed(bridge.tripTopSpeed, metric: metric))
            let climb = tripStat("Climb", value: TripFormat.climb(bridge.tripClimb, metric: metric))
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) { distance; average; top; climb }
            } else {
                Grid(horizontalSpacing: 16, verticalSpacing: 10) {
                    GridRow { distance; average }
                    GridRow { top; climb }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .drawerCard()
    }

    private func elapsed(_ seconds: Double) -> some View {
        // Timeline entries land on exact seconds, where rounding error could show the previous one.
        let text = TripFormat.duration(seconds + 0.001)
        return Text(text)
            .font(.system(.largeTitle, design: .rounded).weight(.bold).monospacedDigit())
            .contentTransition(.numericText())
            .animation(reduceMotion ? nil : .default, value: text)
            .accessibilityLabel("Elapsed time")
            .accessibilityValue(text)
    }

    private func tripStat(_ title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold).monospacedDigit())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }

    // MARK: Recent trips

    private var recentTrips: some View {
        let metric = Locale.current.measurementSystem == .metric
        let trips = Array(bridge.recentTrips.prefix(3))
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent Trips")
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 8)
                if bridge.recentTrips.count > trips.count {
                    Button("See All") { sheet = .trips }
                        .accessibilityLabel("See All Trips")
                }
            }
            .font(.footnote.weight(.semibold))
            .padding(.horizontal, 20)
            VStack(spacing: 0) {
                ForEach(trips) { trip in
                    if trip.id != trips.first?.id { Divider().padding(.leading, 58) }
                    RecentTripButton(trip: trip, metric: metric, historyStart: historyStart, showsDay: true,
                                     insets: EdgeInsets(top: 9, leading: 14, bottom: 9, trailing: 14)) {
                        onShowTrip(trip.start...trip.end)
                    }
                }
            }
            .background(Color.drawerCard, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding(.horizontal, 16)
        }
    }

    // MARK: Start and end

    private var tripButton: some View {
        let recording = bridge.tripInProgress
        return Button(action: toggleTrip) {
            HStack(spacing: 8) {
                Image(systemName: recording ? "stop.fill" : "play.fill")
                    .contentTransition(.symbolEffect(.replace))
                    .symbolEffect(.bounce, value: started + ended)
                Text(recording ? "End Trip" : "Start Trip")
            }
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
        }
        .glassButtonStyle(prominent: true, tint: recording ? .red : .green)
    }

    private func toggleTrip() {
        if bridge.tripInProgress {
            GLTripActions.endTripRestoringTracking()
            IntentDonations.tripEnded()
            ended += 1
        } else {
            GLTripActions.startTrip(withMode: nil)
            IntentDonations.tripStarted(mode: GLManager.shared().currentTripMode)
            started += 1
        }
        trip = TripMapState()
        camera = .userLocation(followsHeading: camera.followsUserHeading, fallback: .automatic)
        bridge.refresh()
    }
}

private enum TripSheet: Identifiable {
    case settings, modes, trips
    var id: Self { self }
}

@ViewBuilder
private func tripModeIcon(_ symbol: String) -> some View {
    if let image = TripModeStore.image(symbol: symbol) {
        Image(uiImage: image).renderingMode(.template).resizable().scaledToFit()
    } else {
        Image(systemName: "location.fill").resizable().scaledToFit()
    }
}

private struct RecentTripButton: View {
    let trip: TripSummary
    let metric: Bool
    let historyStart: Date?
    let showsDay: Bool
    var insets = EdgeInsets()
    let action: () -> Void
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    // A trip that has left local history has nothing to show on the ruler.
    private var available: Bool { historyStart.map { trip.end >= $0 } ?? true }

    var body: some View {
        let when = showsDay ? TripFormat.day(trip.start) : trip.start.formatted(date: .omitted, time: .shortened)
        Button(action: action) {
            HStack(spacing: 12) {
                tripModeIcon(TripModeStore.symbol(trip.mode))
                    .frame(width: 17, height: 17)
                    .foregroundStyle(Color.white)
                    .frame(width: 32, height: 32)
                    .background(Circle().fill(.tint))
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(TripModeStore.name(trip.mode)) · \(TripFormat.distance(trip.distance, metric: metric))")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                    Text("\(when) · \(ReplayActivity.format(trip.end.timeIntervalSince(trip.start)))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                Spacer(minLength: 8)
                if available {
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(insets)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!available)
        .accessibilityElement(children: .combine)
        .accessibilityHint(available ? "Shows this trip on the Tracker ruler." : "")
    }
}

// Every trip the Trip tab knows, newest first by day, styled like Go To.
private struct AllTripsView: View {
    let trips: [TripSummary]
    let historyStart: Date?
    let onShow: (ClosedRange<Date>) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var detent: PresentationDetent = .large

    private var days: [(day: Date, trips: [TripSummary])] {
        let calendar = Calendar.current
        let grouped = Dictionary(grouping: trips) { calendar.startOfDay(for: $0.start) }
        return grouped.keys.sorted(by: >).map { ($0, grouped[$0, default: []].sorted { $0.start > $1.start }) }
    }

    private func title(_ day: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    var body: some View {
        let metric = Locale.current.measurementSystem == .metric
        NavigationStack {
            Form {
                ForEach(days, id: \.day) { day in
                    Section(title(day.day)) {
                        ForEach(day.trips) { trip in
                            RecentTripButton(trip: trip, metric: metric, historyStart: historyStart, showsDay: false) {
                                onShow(trip.start...trip.end)
                            }
                        }
                    }
                    .settingsRowBackground()
                }
            }
            .settingsFormStyle()
            .navigationTitle("Trips")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
        .environment(\.glassSettingsSheet, true)
        .presentationDetents([.medium, .large], selection: $detent)
        .presentationBackground { ExpandingSheetBackground(detent: detent) }
    }
}

// Breathes while a trip records; still with Reduce Motion. Core Animation breathes it in the render server,
// where a SwiftUI phase animator updated the card on the main thread every frame of the trip.
private struct RecordingDot: UIViewRepresentable {
    // The drawer keeps the Trip page built behind the Tracker, where an animation would keep the display busy.
    var active = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeUIView(context: Context) -> RecordingDotView { RecordingDotView() }

    func updateUIView(_ view: RecordingDotView, context: Context) { view.breathes = active && !reduceMotion }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: RecordingDotView, context: Context) -> CGSize? {
        CGSize(width: 8, height: 8)
    }
}

final class RecordingDotView: UIView {
    var breathes = true {
        didSet { if breathes != oldValue { breathe() } }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .systemRed
        layer.cornerRadius = 4
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    // A layer loses its animations when it leaves the window, as the drawer swaps tabs.
    override func didMoveToWindow() {
        super.didMoveToWindow()
        breathe()
    }

    private func breathe() {
        layer.removeAnimation(forKey: "breathe")
        guard breathes, window != nil else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = 1
        animation.toValue = 0.35
        animation.duration = 0.8
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.isRemovedOnCompletion = false
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.preferredFrameRateRange = CAFrameRateRange(minimum: 80, maximum: 120, preferred: 120)
        layer.add(animation, forKey: "breathe")
    }
}

enum TripFormat {
    // Pace reads better than speed on foot.
    static func usesPace(_ mode: String) -> Bool {
        ["walking", "running", "hiking"].contains(TripModeStore.healthWorkout(mode) ?? "")
    }

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today, \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
        return "\(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())), \(time)"
    }

    static func speed(_ metersPerSecond: Double, metric: Bool) -> String {
        let unit = metric ? "km/h" : "mph"
        guard metersPerSecond >= 0, metersPerSecond.isFinite else { return "– \(unit)" }
        return String(format: "%.1f %@", metersPerSecond * (metric ? 3.6 : 2.236_936), unit)
    }

    static func pace(distance meters: Double, duration seconds: Double, metric: Bool) -> String {
        let unit = metric ? "/km" : "/mi"
        guard seconds >= 1, meters >= 10, meters.isFinite else { return "– \(unit)" }
        let perUnit = Int((seconds / (meters / (metric ? 1_000 : 1_609.344))).rounded())
        guard perUnit < 100 * 60 else { return "– \(unit)" }
        return String(format: "%d:%02d %@", perUnit / 60, perUnit % 60, unit)
    }

    static func climb(_ meters: Double, metric: Bool) -> String {
        guard meters >= 0, meters.isFinite else { return metric ? "– m" : "– ft" }
        return metric ? "\(Int(meters.rounded())) m" : "\(Int((meters * 3.280_84).rounded())) ft"
    }

    static func duration(_ seconds: Double) -> String {
        let t = Int(max(0, seconds))
        return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }

    static func distance(_ meters: Double, metric: Bool) -> String {
        let v = metric ? meters / 1000 : meters / 1609.344
        return String(format: v < 10 ? "%.2f %@" : "%.1f %@", v, metric ? "km" : "mi")
    }

    static func averageSpeed(distance meters: Double, duration seconds: Double, metric: Bool) -> String {
        guard seconds >= 1, meters.isFinite, meters >= 0 else { return metric ? "– km/h" : "– mph" }
        return speed(meters / seconds, metric: metric)
    }
}

struct TripMapState {
    var points: [[String: NSNumber]] = []

    var displayCoords: [CLLocationCoordinate2D] {
        points.compactMap { point -> CLLocationCoordinate2D? in
            guard let lat = point["latitude"]?.doubleValue,
                  let lon = point["longitude"]?.doubleValue else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }
}
