import SwiftUI
import MapKit

struct TripView: View {
    @State private var bridge = GLManagerBridge.shared
    @Binding var camera: MapCameraPosition
    @Binding var trip: TripMapState
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var timelineHeight: CGFloat = 34
    @State private var showingSettings = false



    var body: some View {
        VStack(spacing: 12) {
            header
            if bridge.tripInProgress {
                scrubber
            }
            card
        }
        .fixedSize(horizontal: false, vertical: true)
        .onAppear {
            bridge.refresh()
        }
        .onChange(of: bridge.tripMode) { _, mode in
            guard trip.followingLive, let coordinate = GLManager.shared().lastLocation?.coordinate else { return }
            camera = .camera(MapKit.MapCamera(centerCoordinate: coordinate,
                distance: TripModeStore.closeZoom(mode) ? 1_000 : 10_000))
        }
        .sheet(isPresented: $showingSettings) {
            TripSettingsSheet { showingSettings = false }
        }
    }

    private var header: some View {
        DrawerHeader(title: "Trip",
                     subtitle: bridge.tripInProgress ? "Recording · \(TripModeStore.name(bridge.tripMode))" : "Ready to record",
                     indicator: bridge.tripInProgress ? .red : nil) {
            DrawerCircleButton(symbol: "slider.horizontal.3", label: "Trip Settings") {
                showingSettings = true
            }
        }
    }

    private var isLive: Bool { trip.followingLive }

    // MARK: Scrubber

    private var scrubber: some View {
        VStack(spacing: 8) {
            HStack {
                Text(isLive ? "Live" : timeLabel(trip.scrubIndex) ?? "--:--:--")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isLive ? .green : .secondary)
                Spacer()
                if !isLive {
                    Button("Live") {
                        trip.followingLive = true
                        trip.scrubID = trip.points.last?["id"]?.int64Value
                        camera = .userLocation(fallback: .automatic)
                    }
                    .font(.caption.bold())
                    .tint(.green)
                }
            }
            Group {
                if trip.points.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 8) {
                            ForEach(trip.points.indices, id: \.self) { i in
                                Button {
                                    trip.followingLive = false
                                    trip.scrubID = trip.points[i]["id"]?.int64Value
                                    focusScrub()
                                } label: { chip(i) }
                                .buttonStyle(.plain)
                                .id(trip.points[i]["id"]?.int64Value ?? Int64(i))
                            }
                        }
                        .scrollTargetLayout()
                        .padding(.horizontal, 4)
                    }
                    .scrollTargetBehavior(.viewAligned)
                    .scrollPosition(id: Binding(
                        get: { trip.scrubID },
                        set: { id in
                            guard let id, id != trip.scrubID else { return }
                            trip.scrubID = id
                            if id != trip.points.last?["id"]?.int64Value { trip.followingLive = false }
                            if !trip.followingLive { focusScrub() }
                        }
                    ))
                } else {
                    Color.clear
                        .accessibilityHidden(true)
                }
            }
            .frame(height: max(34, timelineHeight))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 4)
    }

    private func chip(_ i: Int) -> some View {
        let selected = !isLive && trip.scrubIndex == i
        let live = isLive && i == trip.points.count - 1
        return Text(timeLabel(i) ?? "")
            .font(.caption2.monospacedDigit())
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .frame(minHeight: max(34, timelineHeight))
            .contentShape(Capsule())
            .background {
                Capsule().fill(selected ? AnyShapeStyle(.tint) : live ? AnyShapeStyle(Color.green.opacity(0.25)) : AnyShapeStyle(Color.drawerCard))
            }
            .foregroundStyle(selected ? Color.white : live ? Color.primary : Color.secondary)
    }

    // MARK: Trip card

    private var card: some View {
        VStack(spacing: 12) {
            VStack(spacing: 14) {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 10) {
                        tripStat("DISTANCE", value: distText)
                        tripStat("TIME", value: durationText)
                    }
                } else {
                    HStack(spacing: 16) {
                        tripStat("DISTANCE", value: distText)
                        tripStat("TIME", value: durationText)
                    }
                }
                Divider()
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Travel Mode").font(.subheadline)
                        modePicker
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    HStack {
                        Text("Travel Mode").font(.subheadline)
                        Spacer()
                        modePicker
                    }
                }
            }
            .drawerCard()

            Button {
                if bridge.tripInProgress {
                    GLTripActions.endTripRestoringTracking()
                    IntentDonations.tripEnded()
                } else {
                    GLTripActions.startTrip(withMode: nil)
                    IntentDonations.tripStarted(mode: GLManager.shared().currentTripMode)
                }
                trip = TripMapState()
                camera = .userLocation(followsHeading: camera.followsUserHeading, fallback: .automatic)
                bridge.refresh()
            } label: {
                Label(bridge.tripInProgress ? "Stop Trip" : "Start Trip",
                      systemImage: bridge.tripInProgress ? "stop.fill" : "play.fill")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .glassButtonStyle(prominent: true, tint: bridge.tripInProgress ? .red : .blue)
            .padding(.horizontal, 16)
        }
    }

    private func tripStat(_ title: String, value: String) -> some View {
        VStack(spacing: 2) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.monospacedDigit())
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
    }

    private var modePicker: some View {
        Picker("Travel Mode", selection: $bridge.tripMode) {
            ForEach(bridge.tripModes, id: \.id) { mode in
                Label {
                    Text(mode.name)
                } icon: {
                    if let image = TripModeStore.image(symbol: mode.symbol) {
                        Image(uiImage: image).renderingMode(.template).resizable().scaledToFit().frame(width: 18, height: 18)
                    }
                }.tag(mode.id)
            }
        }
        .pickerStyle(.menu)
        .labelsHidden()
        .tint(.primary)
        .font(.subheadline.weight(.medium))
        .disabled(bridge.tripInProgress)
    }

    // MARK: Data

    private var distText: String {
        let metric = (Locale.current.measurementSystem == .metric)
        let v = metric ? bridge.tripDistance / 1000 : bridge.tripDistance / 1609.34
        return String(format: v < 10 ? "%.2f %@" : "%.1f %@", v, metric ? "km" : "mi")
    }

    private var durationText: String {
        let t = Int(bridge.tripDuration)
        return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }

    private func timeLabel(_ i: Int?) -> String? {
        guard let i, trip.points.indices.contains(i), let ts = trip.points[i]["timestamp"]?.doubleValue else { return nil }
        return Date(timeIntervalSince1970: ts).formatted(date: .omitted, time: .standard)
    }

    private func focusScrub() {
        guard let coord = trip.scrubbedCoordinate else { return }
        camera = .region(MKCoordinateRegion(
            center: coord,
            span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
        ))
    }

}

struct TripMapState {
    var points: [[String: NSNumber]] = []
    var scrubID: Int64?
    var followingLive = true

    var scrubIndex: Int? {
        guard let scrubID else { return nil }
        return points.firstIndex { $0["id"]?.int64Value == scrubID }
    }

    var scrubbedCoordinate: CLLocationCoordinate2D? {
        guard let i = scrubIndex,
              let lat = points[i]["latitude"]?.doubleValue,
              let lon = points[i]["longitude"]?.doubleValue else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    var displayCoords: [CLLocationCoordinate2D] {
        let end = followingLive ? points.count : (scrubIndex.map { $0 + 1 } ?? points.count)
        return points.prefix(end).compactMap { point -> CLLocationCoordinate2D? in
            guard let lat = point["latitude"]?.doubleValue,
                  let lon = point["longitude"]?.doubleValue else { return nil }
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
    }
}
