import SwiftUI
import MapKit

enum SettingsDestination: Hashable {
    case server
    case wifiPlaces
    case trip
    case tracking
    case stationary
    case sending
    case background
}

struct WhereWolfRootView: View {
    @State private var sceneID = UUID()
    @State private var selection = 0
    @State private var tabActivation = 0
    @State private var mapTab = 0
    @State private var speedometerHeight: CGFloat = 0
    @State private var replayStatusHeight: CGFloat = 0
    @State private var settingsPath: [SettingsDestination] = []
    @State private var mapAppearance = MapAppearance.standard
    @State private var camera = MapCameraPosition.userLocation(fallback: .automatic)
    @State private var trip = TripMapState()
    @State private var tripRevision: Int?
    @State private var history = HistoryPlaybackModel()
    @State private var bridge = GLManagerBridge.shared
    @State private var onboarding = OnboardingModel.live()
    @State private var drawerGeometry = MapDrawerGeometry()
    @State private var recenterRequest = 0
    @State private var replayCameraDistance: CLLocationDistance?
    @State private var replayOverview = false
    @State private var replayCameraFree = false
    @State private var replayCameraAction = 0
    @State private var mapRotated = false
    @Environment(\.scenePhase) private var scenePhase

    private var rulerOwnsCamera: Bool {
        selection == 0 && scenePhase == .active && history.isBrowsing
            && history.rulerZoom != nil && !replayOverview && !replayCameraFree
    }

    private enum MapAppearance: String, CaseIterable {
        case standard = "Map"
        case hybrid = "Hybrid"
        case imagery = "Satellite"

        var mapType: MKMapType {
            switch self {
            case .standard: return .standard
            case .hybrid: return .hybrid
            case .imagery: return .satellite
            }
        }
    }

    var body: some View {
        ZStack {
            appContent
                .blur(radius: onboarding.isPresented ? 1.5 : 0)
                .allowsHitTesting(!onboarding.isPresented)
                .accessibilityHidden(onboarding.isPresented)
            if onboarding.isPresented {
                Color.black.opacity(0.08).ignoresSafeArea().allowsHitTesting(false)
                OnboardingView(model: onboarding)
            }
        }
    }

    private var appContent: some View {
        GeometryReader { geometry in
            WhereWolfShell(
                drawerGeometry: drawerGeometry,
                setupPresented: onboarding.isPresented,
                selection: selection,
                activation: tabActivation,
                controlsID: mapTab,
                contentInteracting: selection == 0 && history.isRulerInteracting,
                map: AnyView(mapPage(viewport: geometry.frame(in: .global).inset(by: UIEdgeInsets(
                                        top: -geometry.safeAreaInsets.top, left: 0,
                                        bottom: -geometry.safeAreaInsets.bottom, right: 0)),
                                     safeTop: geometry.safeAreaInsets.top)),
                controls: AnyView(panelContent),
                onSelect: selectTab,
                settings: AnyView(settingsPage)
            )
            .ignoresSafeArea(.container)
        }
        .onChange(of: camera.followsUserLocation) { _, follows in
            if follows {
                trip.followingLive = true
                trip.scrubID = trip.points.last?["id"]?.int64Value
                if history.isBrowsing { history.returnToLive() }
            }
        }
        .onChange(of: history.cameraCenter) { previous, center in
            focusHistoryPosition(center, from: previous)
        }
        .onChange(of: history.rulerHold != nil) { _, holding in
            // Starting a gesture recaptures the camera; changing the persistent scale alone must not.
            if holding, selection == 0, !replayOverview { replayCameraFree = false }
        }
        .onChange(of: bridge.tripInProgress) { _, _ in
            tripRevision = nil
            trip = TripMapState()
            reloadTripPoints()
        }
        .onChange(of: bridge.tick) { _, _ in reloadTripPoints() }
        .onChange(of: bridge.clockTick) { _, tick in
            if scenePhase == .active, selection == 0, tick % 60 == 0 { history.expireOldPoints() }
        }
        .onChange(of: selection) { _, _ in updateConsumers() }
        .onReceive(NotificationCenter.default.publisher(for: .recentLocationHistoryChanged)) { _ in
            history.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .recentLocationHistoryRetentionChanged)) { _ in
            history.retentionDidChange()
        }
        .onChange(of: bridge.wifiPlaces) { _, _ in history.reload() }
        .onReceive(NotificationCenter.default.publisher(for: NSLocale.currentLocaleDidChangeNotification)) { _ in
            history.reload()
        }
        .onReceive(NotificationCenter.default.publisher(for: .NSSystemTimeZoneDidChange)) { _ in
            history.reload()
        }
        .onChange(of: scenePhase) { _, phase in
            bridge.setSceneActive(phase == .active, id: sceneID)
            updateConsumers()
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("WhereWolfOpenTracker"))) { _ in
            selectTab(0)
        }
        .onAppear {
            bridge.setSceneActive(scenePhase == .active, id: sceneID)
            updateConsumers()
        }
        .onDisappear {
            bridge.setSceneActive(false, id: sceneID)
            history.setConsumerActive(false)
        }
        .tint(.blue)
    }

    private func mapPage(viewport: CGRect, safeTop: CGFloat) -> some View {
        Color.clear
            .background {
                map()
                    .ignoresSafeArea()
            }
            .overlay(alignment: .topTrailing) {
                if !onboarding.isPresented {
                    HStack(alignment: .top, spacing: 8) {
                        ReplayStatusOverlay(history: history, active: mapTab == 0, height: speedometerHeight)
                            .allowsHitTesting(false)
                            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { replayStatusHeight = $0 }
                        VStack(alignment: .center, spacing: 8) {
                            TrackerSpeedometer(replaySpeed: history.payload?.speed,
                                               isReplaying: mapTab == 0 && history.isBrowsing)
                                .allowsHitTesting(false)
                                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { speedometerHeight = $0 }
                            mapControls(auditValue: cameraAuditValue(safeTop: viewport.minY + safeTop))
                            if mapRotated {
                                MapCompassControl(readMap: drawerGeometry.readMap, action: faceNorth)
                                    .frame(width: MapChrome.width, height: MapChrome.width)
                                    .transition(.opacity)
                            }
                        }
                        .animation(.easeOut(duration: 0.2), value: mapRotated)
                    }
                    .padding(.trailing, MapChrome.edge)
                    .padding(.top, MapChrome.topInset)
                }
            }
    }

    @ViewBuilder
    private var panelContent: some View {
        if mapTab == 0 {
            TrackerView(history: history, onLive: returnToLive)
        } else {
            TripView(camera: $camera, trip: $trip)
        }
    }

    private var settingsPage: some View {
        NavigationStack(path: $settingsPath) {
            SettingsView(openSetup: { selectTab(0); onboarding.reopen() })
                .navigationDestination(for: SettingsDestination.self) { destination in
                    switch destination {
                    case .server:
                        EndpointView()
                    case .wifiPlaces:
                        WifiPlaceListView()
                    case .trip:
                        TripSettingsView()
                    case .tracking:
                        TrackingSettingsView()
                    case .stationary:
                        StationarySettingsView()
                    case .sending:
                        SendingSettingsView()
                    case .background:
                        BackgroundSettingsView()
                    }
                }
        }
    }

    private func updateConsumers() {
        history.setConsumerActive(scenePhase == .active && selection == 0)
        reloadTripPoints()
    }

    private func reloadTripPoints() {
        guard scenePhase == .active, selection == 1, tripRevision != bridge.tick else { return }
        tripRevision = bridge.tick
        guard let gl = GLManager.shared(), bridge.tripInProgress,
              let points = gl.currentTripPoints() as? [[String: NSNumber]] else {
            trip = TripMapState()
            return
        }
        trip.points = points
        if trip.followingLive {
            trip.scrubID = points.last?["id"]?.int64Value
        } else if trip.scrubIndex == nil {
            trip.scrubID = points.first?["id"]?.int64Value
            if let coordinate = trip.scrubbedCoordinate {
                camera = .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.005, longitudeDelta: 0.005)
                ))
            }
        }
    }

    private func map() -> some View {
        let replayPose = history.renderPose
        let coords = mapTab == 1 ? trip.displayCoords : []
        let selected = mapTab == 1 && !trip.followingLive ? trip.scrubbedCoordinate
            : mapTab == 0 && history.isBrowsing
                ? replayPose?.coordinate.coordinate : nil
        return NativeMapSurface(position: camera, mapType: mapAppearance.mapType,
                                coordinates: coords,
                                replayRoute: mapTab == 0 && replayPose != nil ? history.routeGeometry : nil,
                                replayPosition: replayPose?.position ?? 0,
                                replayAccuracy: history.playbackAccuracy,
                                replayActive: mapTab == 0 && history.isBrowsing,
                                replayFollowing: !replayCameraFree,
                                replayFollowDistance: replayCameraDistance ?? 2_000,
                                replayOverview: mapTab == 0 && replayOverview,
                                rulerZoom: mapTab == 0 ? history.rulerZoom : nil,
                                rulerZoomActive: selection == 0,
                                replayStatusHeight: mapTab == 0 && history.isBrowsing
                                    ? max(speedometerHeight, replayStatusHeight) : 0,
                                replayCameraAction: replayCameraAction, recenterAction: recenterRequest,
                                selected: selected,
                                selectedTitle: mapTab == 1 ? "Trip point" : "Recorded point",
                                scenePhase: scenePhase, pageActive: selection < 2,
                                trackingEnabled: bridge.trackingEnabled,
                                onCameraChange: cameraChanged, onInteraction: stopFollowing,
                                onRotationChange: { mapRotated = $0 },
                                onRulerCameraRestore: { restored, base in
            guard history.isBrowsing, !rulerOwnsCamera else { return }
            replayCameraDistance = base
            if mapTab == 0, !replayOverview { camera = .camera(restored) }
        })
    }

    private func stopFollowing() {
        if mapTab == 0, history.isBrowsing {
            replayCameraFree = true
            replayOverview = false
        }
        // A drag stops following as it starts, so the location button empties at once.
        if camera.followsUserLocation, let map = drawerGeometry.readMap?() {
            camera = .camera(MapCamera(map.camera))
        }
    }

    private func cameraChanged(_ current: MapCamera, byUser: Bool) {
        if byUser {
            if mapTab == 0, history.isBrowsing { replayCameraFree = true }
            replayOverview = false
            mapPanned(current)
            return
        }
        guard mapTab != 0 || (!replayOverview && !rulerOwnsCamera) else { return }
        guard !camera.followsUserLocation, let region = camera.region,
              region.span.latitudeDelta.isFinite, region.span.latitudeDelta > 0 else { return }
        camera = .camera(current)
    }

    private func mapControls(auditValue: String) -> some View {
        MapControlsHost(content: AnyView(VStack(spacing: 0) {
            Menu {
                Picker("Map style", selection: $mapAppearance) {
                    ForEach(MapAppearance.allCases, id: \.self) { appearance in
                        Text(appearance.rawValue).tag(appearance)
                    }
                }
            } label: {
                Image(systemName: "map.fill")
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Map style")
            Button(action: locationButtonPressed) {
                Image(systemName: mapTab == 0 && history.isBrowsing
                      ? (replayOverview || replayCameraFree ? "location" : "location.fill")
                      : camera.followsUserHeading ? "location.north.line.fill"
                      : (camera.followsUserLocation ? "location.fill" : "location"))
                    .frame(width: 48, height: 48)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel(mapTab == 0 && history.isBrowsing
                                 ? (locationButtonShowsOverview ? "Show Entire Trail" : "Show Recorded Location")
                                 : !camera.followsUserLocation || !DeviceHeadingSource.available ? "Show My Location"
                                 : camera.followsUserHeading ? "Stop Following Heading" : "Follow Heading")
            .accessibilityIdentifier("wherewolf.map.location")
            .accessibilityValue(auditValue)
            Button { zoomMap(inward: true) } label: {
                Image(systemName: "plus")
                    .frame(width: 48, height: MapChrome.buttonHeight)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Zoom In")
            .accessibilityIdentifier("wherewolf.map.zoom-in")
            Button { zoomMap(inward: false) } label: {
                Image(systemName: "minus")
                    .frame(width: 48, height: MapChrome.buttonHeight)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("Zoom Out")
            .accessibilityIdentifier("wherewolf.map.zoom-out")
        }
        .font(.system(size: 20, weight: .medium))
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
        .padding(.vertical, 4)
        .frame(width: MapChrome.width)
        .glassCapsule()
        .contentShape(Capsule())
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.12), radius: 8, y: 3)))
        .frame(width: MapChrome.width, height: MapChrome.controlsHeight)
    }

    private func zoomMap(inward: Bool) {
        guard let map = drawerGeometry.readMap?(), let result = NativeMapSurface.zoom(inward: inward, on: map) else { return }
        applyCameraResult(result)
    }

    private func faceNorth() {
        // Leaving heading mode turns the map north on its own.
        if camera.followsUserHeading {
            camera = .userLocation(fallback: .automatic)
            return
        }
        guard let map = drawerGeometry.readMap?(), let result = NativeMapSurface.faceNorth(on: map) else { return }
        applyCameraResult(result)
    }

    private func applyCameraResult(_ result: MapZoomResult) {
        if mapTab == 0, history.isBrowsing {
            let scaleZoom = rulerOwnsCamera
            if !scaleZoom { replayCameraDistance = result.camera.distance }
            replayCameraFree = !result.replayFollowing
            replayOverview = false
            if !scaleZoom { camera = .camera(result.camera) }
        } else if !camera.followsUserLocation {
            camera = .camera(result.camera)
        }
    }

    private func mapPanned(_ current: MapCamera) {
        camera = .camera(current)
    }

    private func locationButtonPressed() {
        if mapTab == 0, history.isBrowsing {
            let overview = locationButtonShowsOverview
            if replayCameraFree, !overview, history.rulerZoom == nil, let map = drawerGeometry.readMap?() {
                replayCameraDistance = map.camera.centerCoordinateDistance
            }
            withAnimation(.easeInOut(duration: 0.45)) {
                replayCameraFree = false
                replayOverview = overview
                replayCameraAction &+= 1
            }
            if !replayOverview { focusHistoryPosition(history.cameraCenter) }
            return
        }
        // As in Find My, once the map follows you the button switches heading mode on and off.
        if camera.followsUserLocation, DeviceHeadingSource.available {
            camera = .userLocation(followsHeading: !camera.followsUserHeading, fallback: .automatic)
            return
        }
        trip.followingLive = true
        trip.scrubID = trip.points.last?["id"]?.int64Value
        returnToLive()
    }

    private var locationButtonShowsOverview: Bool {
        guard replayCameraFree, let map = drawerGeometry.readMap?(),
              let trail = NativeMapSurface.replayOverviewDistance(on: map) else { return !replayOverview }
        return ReplayCameraFocus.nearest(current: map.camera.centerCoordinateDistance,
                                         point: replayCameraDistance ?? 2_000, trail: trail) == .trail
    }

    private func selectTab(_ index: Int) {
        tabActivation += 1
        if index == 2 { settingsPath = [] }
        if index != 0 { history.pause() }
        selection = index
        if index < 2 { mapTab = index }
        if index == 0 { focusHistoryPosition(history.cameraCenter) }
    }

    private func focusHistoryPosition(_ position: ReplayCoordinate?, from previous: ReplayCoordinate? = nil) {
        guard selection == 0, history.isBrowsing, !replayOverview,
              let coordinate = position?.coordinate else { return }
        if replayCameraFree {
            // Playback, including its final frame, must not recapture a manually moved camera.
            guard history.isRulerInteracting || history.playbackTime == nil else { return }
            if history.rulerZoom == nil {
                replayCameraDistance = drawerGeometry.readMap?()?.camera.centerCoordinateDistance ?? replayCameraDistance
            }
            replayCameraFree = false
        }
        // The native surface follows this same pose without publishing the scale distance to SwiftUI.
        guard !rulerOwnsCamera else { return }
        let target = MapCameraPosition.camera(MapCamera(centerCoordinate: coordinate,
                                                        distance: replayCameraDistance ?? 2_000))
        let jumpDistance = previous.map {
            CLLocation(latitude: $0.latitude, longitude: $0.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        } ?? 0
        if history.isPlaying || history.isRulerInteracting || jumpDistance > 1_000 || UIAccessibility.isReduceMotionEnabled {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) { camera = target }
        } else {
            let duration = camera.followsUserLocation ? 0.65 : 0.32
            withAnimation(.easeInOut(duration: duration)) { camera = target }
        }
    }

    private func returnToLive() {
        replayOverview = false
        replayCameraFree = false
        withAnimation(.easeInOut(duration: 0.35)) { history.returnToLive() }
        camera = .userLocation(fallback: .automatic)
        recenterRequest += 1
    }

    private func cameraAuditValue(safeTop: CGFloat) -> String {
#if targetEnvironment(simulator)
        let map = drawerGeometry.readMap?()
        let target = map.map { $0.convert(NativeMapSurface.visibleCenter(on: $0), to: nil) } ?? .zero
        let coordinate = map.flatMap { NativeMapSurface.displayedUserCoordinate(on: $0) }
            ?? drawerGeometry.userLocation?.coordinate
        let replayMarker = map.flatMap { map in
            guard history.isBrowsing,
                  let annotation = map.annotations.first(where: { $0 is MKPointAnnotation }) else { return nil as CGPoint? }
            if let view = map.view(for: annotation), let container = view.superview {
                return container.convert(CGPoint(x: view.center.x - view.centerOffset.x,
                    y: view.center.y - view.centerOffset.y), to: nil)
            }
            return map.convert(annotation.coordinate, toPointTo: nil)
        } ?? .zero
        let trailMarker = map.flatMap { map in
            NativeMapSurface.displayedTrailCoordinate(on: map).map { map.convert($0, toPointTo: nil) }
        } ?? .zero
        let projectedMarker = map.flatMap { map in
            map.annotations.first(where: { $0 is MKPointAnnotation }).map { map.convert($0.coordinate, toPointTo: nil) }
        } ?? .zero
        let drawerTop = Double(drawerGeometry.read?()?.top ?? 0)
        var values: [String: Double] = [
            "safeTop": safeTop, "drawerTop": drawerTop,
            "mapSafeTop": Double(map?.safeAreaInsets.top ?? 0),
            "mapFrameY": Double(map.map { $0.convert($0.bounds, to: nil).minY } ?? 0),
            "slowDrawer": ProcessInfo.processInfo.environment["WHEREWOLF_UI_AUDIT"] == "1" ? 1 : 0,
            "targetX": target.x, "targetY": target.y,
            "targetDrawerTop": drawerTop, "targetSafeTop": safeTop,
            "latitude": coordinate?.latitude ?? 0, "longitude": coordinate?.longitude ?? 0,
            "displayedLatitude": drawerGeometry.userLocation?.coordinate.latitude ?? 0,
            "replayBrowsing": history.isBrowsing ? 1 : 0,
            "replayOverview": replayOverview ? 1 : 0,
            "replayCameraFree": replayCameraFree ? 1 : 0,
            "replayPosition": history.playbackIndex,
            "replayPlaying": history.isPlaying ? 1 : 0,
            "replayCount": Double(history.points.count),
            "mapDistance": map?.camera.centerCoordinateDistance ?? 0,
            "cameraLatitude": map?.camera.centerCoordinate.latitude ?? 0,
            "cameraLongitude": map?.camera.centerCoordinate.longitude ?? 0,
            "replayMarkerX": replayMarker.x, "replayMarkerY": replayMarker.y,
            "trailMarkerX": trailMarker.x, "trailMarkerY": trailMarker.y,
            "projectedMarkerX": projectedMarker.x, "projectedMarkerY": projectedMarker.y,
        ]
        if let map { values.merge(NativeMapSurface.replayAuditValues(on: map)) { _, current in current } }
        if let data = try? JSONSerialization.data(withJSONObject: values),
           let value = String(data: data, encoding: .utf8) { return value }
#endif
        return ""
    }

}

final class WhereWolfRootHosting: NSObject {
    @objc static func makeRoot() -> UIViewController {
        WhereWolfHostingController()
    }
}

private final class WhereWolfHostingController: UIHostingController<AnyView> {
    private var visible = false

    init() {
        super.init(rootView: AnyView(WhereWolfRootView().environment(\.scenePhase, .background)))
        for name in [UIScene.didActivateNotification, UIScene.willDeactivateNotification,
                     UIScene.didEnterBackgroundNotification, UIScene.willEnterForegroundNotification] {
            NotificationCenter.default.addObserver(self, selector: #selector(sceneChanged(_:)), name: name, object: nil)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { NotificationCenter.default.removeObserver(self) }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        visible = true
        let state = view.window?.windowScene?.activationState
        setPhase(state == .foregroundActive ? .active : state == .foregroundInactive ? .inactive : .background)
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        visible = false
        setPhase(.background)
    }

    @objc private func sceneChanged(_ notification: Notification) {
        guard let scene = notification.object as? UIWindowScene, scene === viewIfLoaded?.window?.windowScene else { return }
        guard visible else { return }
        switch notification.name {
        case UIScene.didActivateNotification: setPhase(.active)
        case UIScene.didEnterBackgroundNotification: setPhase(.background)
        default: setPhase(.inactive)
        }
    }

    private func setPhase(_ phase: ScenePhase) {
        rootView = AnyView(WhereWolfRootView().environment(\.scenePhase, phase))
    }
}

// MapKit's compass draws the live heading. A tap goes through the same camera transition as the zoom
// buttons, so following and replay keep their state while the map turns north.
struct MapCompassControl: UIViewRepresentable {
    let readMap: (() -> MKMapView?)?
    let action: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(action: action) }

    func makeUIView(context: Context) -> UIControl {
        let control = UIControl()
        let compass = MKCompassButton(mapView: readMap?())
        compass.compassVisibility = .visible
        compass.isUserInteractionEnabled = false
        compass.translatesAutoresizingMaskIntoConstraints = false
        control.addSubview(compass)
        NSLayoutConstraint.activate([
            compass.centerXAnchor.constraint(equalTo: control.centerXAnchor),
            compass.centerYAnchor.constraint(equalTo: control.centerYAnchor),
        ])
        control.addAction(UIAction { [coordinator = context.coordinator] _ in coordinator.action() }, for: .touchUpInside)
        control.isAccessibilityElement = true
        control.accessibilityLabel = "Compass"
        control.accessibilityHint = "Turns the map to face north."
        control.accessibilityTraits = .button
        control.accessibilityIdentifier = "wherewolf.map.compass"
        return control
    }

    func updateUIView(_ control: UIControl, context: Context) {
        context.coordinator.action = action
        guard let compass = control.subviews.first as? MKCompassButton, let map = readMap?(), compass.mapView !== map else { return }
        compass.mapView = map
    }

    final class Coordinator {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
    }
}

private struct MapControlsHost: UIViewControllerRepresentable {
    let content: AnyView

    func makeUIViewController(context: Context) -> MapControlsController {
        MapControlsController(content: content)
    }

    func updateUIViewController(_ controller: MapControlsController, context: Context) {
        controller.host.rootView = content
    }
}

private final class MapControlsController: UIViewController {
    let host: UIHostingController<AnyView>

    init(content: AnyView) {
        host = UIHostingController(rootView: content)
        host.safeAreaRegions = []
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func loadView() {
        view = MapControlsBoundary(frame: .zero)
        view.accessibilityIdentifier = "wherewolf.map.controls"
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(host)
        host.view.backgroundColor = .clear
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        host.didMove(toParent: self)
    }
}

private final class MapControlsBoundary: UIView {
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        UIBezierPath(roundedRect: bounds, cornerRadius: bounds.width / 2).contains(point)
    }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        guard self.point(inside: point, with: event) else { return nil }
        return super.hitTest(point, with: event)
    }
}
