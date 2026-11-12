#if !WHEREWOLF_APP_STORE
import SwiftUI

// All geometry and readings here are invented. The fixture never starts a trip or runs its buttons.
struct TripActivityPreview: View {
    let kind: String
    private let start = Date().addingTimeInterval(-764)
    @State private var mapState: TripActivityMap?
    @State private var mapController: TripActivityMapController?
    @State private var mapAtlas: TripActivityMapAtlas?
    // Fixture files never prune or replace a real trip's snapshots.
    private let mapFiles = TripActivityMapFiles(directory: TripActivityMapFiles.sharedDirectory?
        .deletingLastPathComponent().appendingPathComponent("TripActivityMapPreview", isDirectory: true))

    static func fixture(arguments: [String] = ProcessInfo.processInfo.arguments) -> TripActivityPreview? {
        guard let index = arguments.firstIndex(of: "-WhereWolfTripActivityPreview"),
              arguments.indices.contains(index + 1),
              ["car", "walk", "short", "map", "map-atlas"].contains(arguments[index + 1]) else { return nil }
        return TripActivityPreview(kind: arguments[index + 1])
    }

    private var state: TripActivityState {
        let short = kind == "short"
        let walk = kind == "walk"
        let route = short ? [TripRouteSketch.Point(x: 128, y: 128)] : [
            .init(x: 0, y: 43), .init(x: 20, y: 45), .init(x: 40, y: 38),
            .init(x: 60, y: 25), .init(x: 80, y: 27), .init(x: 105, y: 38),
            .init(x: 125, y: 34), .init(x: 145, y: 17), .init(x: 165, y: 6),
            .init(x: 185, y: 10), .init(x: 205, y: 20), .init(x: 230, y: 16),
            .init(x: 255, y: 0)
        ]
        return TripActivityState(mode: walk ? "walk" : "car", distance: short ? 0 : (walk ? 1_018 : 13_550),
            speed: walk ? 1.3 : 15.2, topSpeed: short ? -1 : (walk ? 1.9 : 25.9),
            climb: short ? 0 : (walk ? 24 : 36.6), averageSpeed: short ? nil : (walk ? 1.33 : 13.86),
            route: kind.hasPrefix("map") ? Self.portlandRoute().routeSketch() : TripRouteSketch(points: route), map: mapState)
    }

    private static func portlandRoute() -> TripStatsAccumulator {
        let stats = TripStatsAccumulator()
        // An invented drive from downtown over the Hawthorne Bridge and east, about 4 km.
        for (latitude, longitude) in [
            (45.5152, -122.6784), (45.5140, -122.6770), (45.5128, -122.6752), (45.5133, -122.6725),
            (45.5133, -122.6690), (45.5122, -122.6650), (45.5122, -122.6600), (45.5121, -122.6540),
            (45.5121, -122.6470), (45.5121, -122.6400), (45.5090, -122.6370), (45.5050, -122.6365),
            (45.5040, -122.6300)
        ] {
            stats.add(speed: 2, speedAccuracy: 1, altitude: 10, verticalAccuracy: 1,
                      latitude: latitude, longitude: longitude)
        }
        return stats
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Trail · \(kind)").font(.headline).foregroundStyle(.white)
                VStack(alignment: .leading, spacing: 8) {
                    caption("Expanded Island · 380 × 158 pt, clipped like the phone")
                    // Measured from an iPhone 17 Pro screenshot: content starts 17 points down, 19 in from the
                    // sides, the regions sit 11 apart, and anything lower than 146 points is cut off.
                    VStack(spacing: 11) {
                        HStack(alignment: .top, spacing: 0) {
                            TripExpandedLeading(mode: state.mode)
                            Spacer(minLength: 0)
                            TripExpandedTrailing(start: start)
                        }
                        TripExpandedBottom(state: state, mapFiles: mapFiles)
                    }
                    .frame(width: 342, height: 129, alignment: .top)
                    .clipped()
                    .padding(.top, 17)
                    .frame(width: 380, height: 158, alignment: .top)
                    .background(.black, in: RoundedRectangle(cornerRadius: 46))
                    .environment(\.colorScheme, .dark)
                    .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 8) {
                    caption("Compact and minimal")
                    HStack(spacing: 14) {
                        HStack {
                            TripCompactLeading(mode: state.mode)
                            Spacer()
                            ElapsedTime(start: start).font(.subheadline.weight(.semibold)).frame(width: 70)
                        }
                        .padding(.horizontal, 12)
                        .frame(width: 250, height: 37)
                        .background(.black, in: Capsule())
                        TripMinimalView(mode: state.mode)
                            .frame(width: 37, height: 37)
                            .background(.black, in: Circle())
                    }
                    .environment(\.colorScheme, .dark)
                    .foregroundStyle(.white)
                }
                VStack(alignment: .leading, spacing: 8) {
                    caption("Lock Screen · 371 pt wide, clipped at 160 pt like the phone")
                    TripLockScreenView(attributes: .init(tripStart: start), state: state, mapFiles: mapFiles)
                        .frame(width: 371)
                        .frame(maxHeight: 160, alignment: .top)
                        .clipped()
                        .background(Color(uiColor: .secondarySystemBackground),
                                    in: RoundedRectangle(cornerRadius: 26))
                }
            }
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity)
            .allowsHitTesting(false)
        }
        .background(Color(red: 0.07, green: 0.08, blue: 0.10).ignoresSafeArea())
        .task {
            guard kind.hasPrefix("map"), mapController == nil else { return }
            let stats = Self.portlandRoute()
            let atlas = TripActivityMapAtlas(files: TripActivityMapAtlasFiles(directory: TripActivityMapAtlasFiles.defaultDirectory?
                .deletingLastPathComponent().appendingPathComponent("TripActivityMapAtlasPreview", isDirectory: true)))
            mapAtlas = atlas
            let controller = TripActivityMapController(files: mapFiles, atlas: atlas,
                isActive: { kind != "map-atlas" && UIApplication.shared.applicationState == .active })
            mapController = controller
            controller.reset()
            controller.onChange = { [weak controller] in
                mapState = controller?.map(for: stats.routeMapPoints) { stats.routeSketch(in: $0) }
            }
            if kind == "map-atlas" {
                atlas.onChange = { [weak controller, weak atlas] in
                    guard atlas?.levels.count == TripActivityMapAtlasPolicy.sides.count else { return }
                    controller?.update(points: stats.routeMapPoints, enabled: true, showsOnLockScreen: true)
                }
                atlas.update(anchor: stats.routeMapPoints.last, tripLiveActivityEnabled: true, trackingEnabled: true)
                if atlas.levels.count == TripActivityMapAtlasPolicy.sides.count {
                    controller.update(points: stats.routeMapPoints, enabled: true, showsOnLockScreen: true)
                }
            } else {
                controller.update(points: stats.routeMapPoints, enabled: true, showsOnLockScreen: true)
            }
        }
        .onDisappear {
            mapController?.reset()
            mapController = nil
            mapAtlas?.removeAll()
            mapAtlas = nil
            mapState = nil
        }
    }

    private func caption(_ text: String) -> some View {
        Text(text).font(.caption).foregroundStyle(.white.opacity(0.65))
    }
}
#endif
