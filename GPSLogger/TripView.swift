import SwiftUI
import MapKit

struct TripView: View {
    @State private var bridge = GLManagerBridge.shared
    @Binding var camera: MapCameraPosition
    @Binding var trip: TripMapState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .caption) private var modeWidth: CGFloat = 64
    @State private var sheet: TripSheet?
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
        }
        .padding(.top, 4)
        .fixedSize(horizontal: false, vertical: true)
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(duration: 0.4, bounce: 0.15),
                   value: bridge.tripInProgress)
        .sensoryFeedback(.start, trigger: started)
        .sensoryFeedback(.stop, trigger: ended)
        .sensoryFeedback(.selection, trigger: picked)
        .onAppear {
            bridge.refresh()
        }
        .onChange(of: bridge.tripMode) { _, mode in
            guard let coordinate = GLManager.shared().lastLocation?.coordinate else { return }
            camera = .camera(MapKit.MapCamera(centerCoordinate: coordinate,
                distance: TripModeStore.closeZoom(mode) ? 1_000 : 10_000))
        }
        .sheet(item: $sheet) { sheet in
            TripSettingsSheet(opensModes: sheet == .modes) { self.sheet = nil }
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

    @ViewBuilder
    private func modeIcon(_ symbol: String) -> some View {
        if let image = TripModeStore.image(symbol: symbol) {
            Image(uiImage: image).renderingMode(.template).resizable().scaledToFit()
        } else {
            Image(systemName: "location.fill").resizable().scaledToFit()
        }
    }

    // MARK: Recording

    private var stats: some View {
        VStack(spacing: 10) {
            HStack(spacing: 6) {
                RecordingDot()
                modeIcon(TripModeStore.symbol(bridge.tripMode))
                    .frame(width: 16, height: 16)
                Text("Recording · \(TripModeStore.name(bridge.tripMode))")
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
            Text(TripFormat.duration(bridge.tripDuration))
                .font(.system(.largeTitle, design: .rounded).weight(.bold).monospacedDigit())
                .contentTransition(.numericText())
                .animation(reduceMotion ? nil : .default, value: Int(bridge.tripDuration))
                .accessibilityLabel("Elapsed time")
                .accessibilityValue(TripFormat.duration(bridge.tripDuration))
            let metric = Locale.current.measurementSystem == .metric
            let measures = Group {
                tripStat("Distance", value: TripFormat.distance(bridge.tripDistance, metric: metric))
                tripStat("Avg Speed", value: TripFormat.averageSpeed(distance: bridge.tripDistance,
                                                                     duration: bridge.tripDuration, metric: metric))
            }
            if dynamicTypeSize.isAccessibilitySize {
                VStack(spacing: 10) { measures }
            } else {
                HStack(spacing: 16) { measures }
            }
        }
        .frame(maxWidth: .infinity)
        .drawerCard()
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
    case settings, modes
    var id: Self { self }
}

// Breathes while a trip records; still with Reduce Motion.
private struct RecordingDot: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let dot = Circle().fill(.red).frame(width: 8, height: 8)
        if reduceMotion {
            dot
        } else {
            dot.phaseAnimator([1, 0.35]) { content, opacity in
                content.opacity(opacity)
            } animation: { _ in .easeInOut(duration: 0.8) }
        }
    }
}

enum TripFormat {
    static func duration(_ seconds: Double) -> String {
        let t = Int(max(0, seconds))
        return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }

    static func distance(_ meters: Double, metric: Bool) -> String {
        let v = metric ? meters / 1000 : meters / 1609.344
        return String(format: v < 10 ? "%.2f %@" : "%.1f %@", v, metric ? "km" : "mi")
    }

    static func averageSpeed(distance meters: Double, duration seconds: Double, metric: Bool) -> String {
        let unit = metric ? "km/h" : "mph"
        guard seconds >= 1, meters.isFinite, meters >= 0 else { return "– \(unit)" }
        let speed = meters / seconds * (metric ? 3.6 : 2.236_936)
        return String(format: "%.1f %@", speed, unit)
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
