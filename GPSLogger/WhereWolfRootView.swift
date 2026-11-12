import SwiftUI
import MapKit
import OSLog

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
#if !WHEREWOLF_APP_STORE
    @State private var qrReviewPreview = ServerQRReview.preview()
#endif
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
    @State private var tripTab = TripTabPolicy()
    @State private var pendingTrip: ClosedRange<Date>?
    @State private var tripSlide = 0
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
        selection == 0 && scenePhase == .active
            && (history.rulerZoom != nil || history.rulerScaleChannel.frame != nil)
            && (history.isBrowsing ? !replayOverview && !replayCameraFree : camera.followsUserLocation)
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
                .allowsHitTesting(!onboarding.isPresented)
                .accessibilityHidden(onboarding.isPresented)
            if onboarding.isPresented {
                Color.black.opacity(0.08).ignoresSafeArea().allowsHitTesting(false)
                OnboardingView(model: onboarding)
            }
        }
#if !WHEREWOLF_APP_STORE
        .sheet(item: $qrReviewPreview) { review in
            ServerQRCodeSheet(current: review.values, ownTracks: review.ownTracks, preview: review,
                              onUse: { _ in true })
        }
#endif
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
                slideActivation: tripSlide,
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
            if follows, history.isBrowsing { history.returnToLive() }
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
        .onChange(of: history.landmarks.timestamps.count) { _, _ in
            guard let trip = pendingTrip, !history.landmarks.timestamps.isEmpty else { return }
            pendingTrip = nil
            openTrip(trip)
        }
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
            if phase == .active { showNewTrip() }
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
#if !WHEREWOLF_APP_STORE
        .task { await runMotionTour() }
#endif
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

    private var panelContent: some View {
        DrawerPages(selection: mapTab) {
            TrackerView(history: history, onLive: returnToLive, shown: mapTab == 0)
        } trip: {
            TripView(camera: $camera, trip: $trip, historyStart: history.landmarks.timestamps.first,
                     onShowTrip: showTrip, shown: mapTab == 1)
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
                    case .tracking, .stationary:
                        TrackingSettingsView()
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
    }

    private func map() -> some View {
        let replayPose = history.renderPose
        let coords = mapTab == 1 ? trip.displayCoords : []
        let selected = mapTab == 0 && history.isBrowsing ? replayPose?.coordinate.coordinate : nil
        return NativeMapSurface(position: camera, mapType: mapAppearance.mapType,
                                coordinates: coords,
                                replayRoute: mapTab == 0 && replayPose != nil ? history.routeGeometry : nil,
                                replayPosition: replayPose?.position ?? 0,
                                replayAccuracy: history.playbackAccuracy,
                                replayActive: mapTab == 0 && history.isBrowsing,
                                replayFollowing: !replayCameraFree,
                                replayFollowDistance: replayCameraDistance ?? 2_000,
                                replayOverview: mapTab == 0 && replayOverview,
                                replayHighlight: mapTab == 0 ? history.highlightedRange : nil,
                                rulerZoom: mapTab == 0 ? history.rulerZoom : nil,
                                rulerScaleChannel: mapTab == 0 ? history.rulerScaleChannel : nil,
                                replayPoseChannel: mapTab == 0 ? history.poseChannel : nil,
                                rulerZoomActive: selection == 0,
                                liveRulerGeometry: mapTab == 0 ? history.liveRulerGeometry : nil,
                                replayStatusHeight: mapTab == 0 && history.isBrowsing
                                    ? max(speedometerHeight, replayStatusHeight) : 0,
                                replayCameraAction: replayCameraAction, recenterAction: recenterRequest,
                                selected: selected,
                                selectedTitle: "Recorded point",
                                scenePhase: scenePhase, pageActive: selection < 2,
                                trackingEnabled: bridge.trackingEnabled,
                                onCameraChange: cameraChanged, onInteraction: stopFollowing,
                                onRotationChange: { mapRotated = $0 },
                                onRulerCameraRestore: { restored, base in
            guard !rulerOwnsCamera, mapTab == 0 else { return }
            if history.isBrowsing {
                replayCameraDistance = base
                if !replayOverview { camera = .camera(restored) }
            } else if camera.followsUserLocation {
                camera = .userLocation(followsHeading: camera.followsUserHeading, fallback: .camera(restored))
            }
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
        returnToLive()
    }

    private var locationButtonShowsOverview: Bool {
        guard replayCameraFree, let map = drawerGeometry.readMap?(),
              let trail = NativeMapSurface.replayOverviewDistance(on: map) else { return !replayOverview }
        return ReplayCameraFocus.nearest(current: map.camera.centerCoordinateDistance,
                                         point: replayCameraDistance ?? 2_000, trail: trail) == .trail
    }

    // A recent trip opens on the Tracker ruler, once history has loaded there.
    private func showTrip(_ trip: ClosedRange<Date>) {
        tripSlide += 1
        selectTab(0)
        if history.landmarks.timestamps.isEmpty { pendingTrip = trip } else { openTrip(trip) }
    }

    // The ruler starts at the trip and the map fits all of it; the location button then follows the marker.
    // Opening the trip builds the replay route on the main thread, so it waits for the tab to slide over.
    private func openTrip(_ trip: ClosedRange<Date>) {
        let delay = UIAccessibility.isReduceMotionEnabled ? 0 : 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            history.showTrip(trip)
            withAnimation(.easeInOut(duration: 0.45)) {
                replayCameraFree = false
                replayOverview = true
                replayCameraAction &+= 1
            }
        }
    }

    private func showNewTrip() {
        guard let gl = GLManager.shared() else { return }
        let start = gl.tripInProgress() ? gl.currentTripStart() : nil
        if tripTab.showsTrip(onActivationWithTripStart: start, setupPresented: onboarding.isPresented), selection != 1 {
            selectTab(1)
        }
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
// Both drawer pages stay built, so switching between Tracker and Trip only changes which one shows: building
// the other page took 30–70 ms, so every switch began with a stall. The hidden page takes no room, touches or
// VoiceOver focus. The page not shown at launch is built once launch has settled.
private struct DrawerPages<Tracker: View, Trip: View>: View {
    let selection: Int
    @ViewBuilder let tracker: Tracker
    @ViewBuilder let trip: Trip
    @State private var built: Set<Int> = []

    var body: some View {
        DrawerPagesLayout(selection: selection) {
            page(0) { tracker }
            page(1) { trip }
        }
        .onChange(of: selection, initial: true) { _, selection in built.insert(selection) }
        .task {
            try? await Task.sleep(for: .seconds(1.5))
            built = [0, 1]
        }
    }

    @ViewBuilder
    private func page<Content: View>(_ index: Int, @ViewBuilder content: () -> Content) -> some View {
        let shown = index == selection
        if shown || built.contains(index) {
            content()
                .opacity(shown ? 1 : 0)
                .allowsHitTesting(shown)
                .accessibilityHidden(!shown)
        } else {
            Color.clear.frame(width: 0, height: 0)
        }
    }
}

private struct DrawerPagesLayout: Layout {
    var selection: Int

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        subviews.indices.contains(selection) ? subviews[selection].sizeThatFits(proposal) : .zero
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (index, page) in subviews.enumerated() {
            page.place(at: bounds.origin, anchor: .topLeading,
                       proposal: index == selection ? proposal : ProposedViewSize(width: bounds.width, height: nil))
        }
    }
}

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

// Opening the app during a trip shows the Trip tab once per trip, so a trip started from CarPlay,
// a Shortcut or the watch is in view, while a tab chosen during that trip stays chosen.
struct TripTabPolicy {
    private var shownTrip: Date?

    mutating func showsTrip(onActivationWithTripStart start: Date?, setupPresented: Bool) -> Bool {
        guard let start, start != shownTrip, !setupPresented else { return false }
        shownTrip = start
        return true
    }
}

#if !WHEREWOLF_APP_STORE
// `-WhereWolfMotionTour map|replay|guide|all` plays each animation of that set in turn once after launch, for
// frame-rate traces on a phone. Each runs inside a Points of Interest interval named after it, so a trace splits
// by animation, and prints how long the main thread was busy during it. It changes no settings, tracking or
// trips: the setup guide only pages and closes, and replay returns to Live.
extension WhereWolfRootView {
    private static let tourSignposter = OSSignposter(subsystem: "me.joshpatra.WhereWolf", category: .pointsOfInterest)
    @MainActor private static var tourStarted = false

    @MainActor
    func runMotionTour() async {
        guard let tour = UserDefaults.standard.string(forKey: "WhereWolfMotionTour"), !Self.tourStarted else { return }
        Self.tourStarted = true
        // Lines also go to tmp/motion-tour.txt in the app's container, since a console can drop them.
        let log = FileManager.default.temporaryDirectory.appendingPathComponent("motion-tour.txt")
        try? Data().write(to: log)
        let file = try? FileHandle(forWritingTo: log)
        func report(_ line: String) {
            print("TOUR " + line)
            fflush(stdout)
            file?.seekToEndOfFile()
            file?.write(Data(("TOUR " + line + "\n").utf8))
        }
        report("start \(tour)")
        let meter = MainThreadBusyMeter()
        func step(_ name: StaticString, _ seconds: Double, _ action: () -> Void) async {
            let state = Self.tourSignposter.beginInterval(name)
            meter.start()
            action()
            try? await Task.sleep(for: .seconds(seconds))
            report("\(name): " + meter.stop(over: seconds))
            Self.tourSignposter.endInterval(name, state)
            try? await Task.sleep(for: .seconds(0.6))
        }
        try? await Task.sleep(for: .seconds(4))
        if tour == "map" || tour == "all" {
            await step("drawer open", 1.2) { drawerGeometry.settle?(true) }
            await step("drawer close", 1.2) { drawerGeometry.settle?(false) }
            await step("tab trip", 1.4) { selectTab(1) }
            await step("tab tracker", 1.4) { selectTab(0) }
            await step("tab settings", 1.4) { selectTab(2) }
            await step("tab back", 1.4) { selectTab(0) }
            await step("zoom in", 1.3) { zoomMap(inward: true) }
            await step("zoom out", 1.3) { zoomMap(inward: false) }
            if let map = drawerGeometry.readMap?() {
                var center = map.camera.centerCoordinate
                center.latitude += 0.06
                var transaction = Transaction(animation: nil)
                transaction.disablesAnimations = true
                withTransaction(transaction) {
                    camera = .camera(MapCamera(centerCoordinate: center, distance: map.camera.centerCoordinateDistance))
                }
                try? await Task.sleep(for: .seconds(1.5))
            }
            await step("flight to live", 2.4) { returnToLive() }
        }
        if tour == "replay" || tour == "all" {
            for _ in 0..<40 where history.points.isEmpty { try? await Task.sleep(for: .seconds(0.25)) }
            await step("history open", 1.4) { history.goTo(Date().addingTimeInterval(-3 * 60 * 60)) }
            history.playbackRate = 5
            await step("replay", 5) { history.togglePlayback() }
            history.pause()
            history.playbackRate = 1
            await step("scale coarse", 1) { history.setRulerStep(50) }
            await step("scale fine", 1) { history.setRulerStep(1) }
            await step("ruler to live", 1.6) { returnToLive() }
            let oldest = history.points.first?.timestamp ?? .distantFuture
            if let trip = TripLog.trips.first(where: { $0.start >= oldest && $0.distance > 1_000 }) {
                await step("open trip", 5) { showTrip(trip.start...trip.end) }
                await step("trip to live", 2) { returnToLive() }
            }
        }
        if tour == "guide" || tour == "all" {
            await step("guide open", 1.2) { onboarding.reopen() }
            await step("guide next 1", 0.9) { onboarding.next() }
            await step("guide next 2", 0.9) { onboarding.next() }
            await step("guide next 3", 0.9) { onboarding.next() }
            await step("guide back", 0.9) { onboarding.back() }
            await step("guide close", 1) { onboarding.skipAll() }
        }
        report("done")
    }
}

// Sums the main run loop's working time between waits. A stretch longer than a 120 Hz frame delays the next one.
private final class MainThreadBusyMeter {
    private var observer: CFRunLoopObserver?
    private var woke: CFTimeInterval = 0
    private var stretches: [CFTimeInterval] = []

    func start() {
        stretches.removeAll(keepingCapacity: true)
        woke = CACurrentMediaTime()
        let activities = CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities, true, 0) { [weak self] _, activity in
            guard let self else { return }
            let now = CACurrentMediaTime()
            if activity == .beforeWaiting { stretches.append(now - woke) }
            woke = now
        }
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        self.observer = observer
    }

    func stop(over seconds: Double) -> String {
        if let observer { CFRunLoopRemoveObserver(CFRunLoopGetMain(), observer, .commonModes) }
        observer = nil
        let busy = stretches.reduce(0, +)
        let long = stretches.filter { $0 > 1.0 / 120 }
        return String(format: "busy %.0f ms/s, longest %.1f ms, %d of %d stretches over 8.3 ms (%.0f ms in them)",
                      busy * 1000 / seconds, (stretches.max() ?? 0) * 1000, long.count, stretches.count,
                      long.reduce(0, +) * 1000)
    }
}
#endif
