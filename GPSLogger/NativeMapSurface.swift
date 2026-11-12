import MapKit
import SafariServices
import SwiftUI

private final class PresentedUserLocationView: MKUserLocationView {
    var presentedCenter: CGPoint? { didSet { projectPosition() } }
    private var positionObservation: NSKeyValueObservation?
    private var projecting = false

    override init(annotation: (any MKAnnotation)?, reuseIdentifier: String?) {
        super.init(annotation: annotation, reuseIdentifier: reuseIdentifier)
        observePosition()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        observePosition()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        (layer.sublayers?.first { $0 is LiveHeadingBeamLayer } as? LiveHeadingBeamLayer)?.center(in: self)
    }

    override func action(for layer: CALayer, forKey event: String) -> (any CAAction)? {
        if event == "position", presentedCenter != nil { return NSNull() }
        return super.action(for: layer, forKey: event)
    }

    private func observePosition() {
        // MapKit can update the annotation layer without calling UIView's center setter.
        positionObservation = layer.observe(\.position, options: [.new]) { [weak self] _, _ in
            self?.projectPosition()
        }
    }

    private func projectPosition() {
        guard !projecting, let presentedCenter else { return }
        projecting = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.position = presentedCenter
        layer.removeAnimation(forKey: "position")
        CATransaction.commit()
        projecting = false
    }
}

private final class ReplayMarkerView: MKMarkerAnnotationView {
    private var directionKey: Int?
    private let glyphs: NSCache<NSNumber, UIImage> = {
        let cache = NSCache<NSNumber, UIImage>()
        cache.countLimit = 90
        return cache
    }()

    func face(_ angle: CGFloat?) {
        let degrees = angle.map { $0 * 180 / .pi } ?? -1
        let key = angle == nil ? -1 : (Int(degrees.rounded()) % 360 + 360) % 360
        guard directionKey != key else { return }
        directionKey = key
        let cacheKey = NSNumber(value: key)
        if let image = glyphs.object(forKey: cacheKey) {
            glyphImage = image
            return
        }
        let symbol = UIImage(systemName: "location.north.fill",
                             withConfiguration: UIImage.SymbolConfiguration(pointSize: 16, weight: .semibold))?
            .withTintColor(.white, renderingMode: .alwaysOriginal)
        let image = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24)).image { context in
            let drawing = context.cgContext
            drawing.translateBy(x: 12, y: 12)
            if key >= 0, let symbol {
                drawing.rotate(by: CGFloat(key) * .pi / 180)
                symbol.draw(at: CGPoint(x: -symbol.size.width / 2, y: -symbol.size.height / 2))
            } else {
                drawing.setFillColor(UIColor.white.cgColor)
                drawing.fillEllipse(in: CGRect(x: -4, y: -4, width: 8, height: 8))
            }
        }.withRenderingMode(.alwaysTemplate)
        glyphs.setObject(image, forKey: cacheKey)
        glyphImage = image
    }
}

@MainActor
private final class RulerZoomFrameTarget: NSObject {
    private weak var coordinator: NativeMapSurface.Coordinator?

    init(coordinator: NativeMapSurface.Coordinator) { self.coordinator = coordinator }

    @objc func frame(_ link: CADisplayLink) {
        guard let coordinator else { link.invalidate(); return }
        coordinator.advanceRulerZoom(at: link.timestamp)
    }
}

@MainActor
private final class ReplayHeadingFrameTarget: NSObject {
    private weak var coordinator: NativeMapSurface.Coordinator?

    init(coordinator: NativeMapSurface.Coordinator) { self.coordinator = coordinator }

    @objc func frame(_ link: CADisplayLink) {
        guard let coordinator else { link.invalidate(); return }
        coordinator.advanceReplayHeading(at: link.timestamp)
    }
}

private final class MapContactRecognizer: UIGestureRecognizer {
    var onContact: ((Bool) -> Void)?
    private var contacts: Set<UITouch> = []

    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        let first = contacts.isEmpty
        contacts.formUnion(touches)
        if first { onContact?(true) }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        contacts.subtract(touches)
        if contacts.isEmpty {
            onContact?(false)
            state = .failed
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        touchesEnded(touches, with: event)
    }

    override func reset() {
        super.reset()
        contacts.removeAll()
        onContact?(false)
    }
}

private final class AttributionMapView: MKMapView {
    private final class Credit {
        weak var view: UIView?
        let transform: CGAffineTransform

        init(_ view: UIView) {
            self.view = view
            transform = view.transform
        }
    }

    private var credits: [Credit] = []
    var drawerTop: CGFloat? {
        didSet {
            guard drawerTop != oldValue else { return }
            setNeedsLayout()
            if center(forDrawerTop: oldValue) != visibleCenter { onViewportChange?() }
        }
    }
    var closedDrawerTop: CGFloat? {
        didSet {
            guard closedDrawerTop != oldValue else { return }
            onViewportChange?()
        }
    }
    var onViewportChange: (() -> Void)?
    var onMapLayout: (() -> Void)?
    private var lastViewport: CGRect = .null
    private weak var legalLabel: UIView?
    private let legalButton = UIButton(type: .custom)

    var visibleCenter: CGPoint { center(forDrawerTop: drawerTop) }

    private func center(forDrawerTop top: CGFloat?) -> CGPoint {
        MapViewport.restingCenter(in: bounds, safeTop: bounds.minY + safeAreaInsets.top,
                                  closedDrawerTop: closedDrawerTop, drawerTop: top)
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        DispatchQueue.main.async { [weak self] in self?.onViewportChange?() }
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        insetsLayoutMarginsFromSafeArea = false
        layoutMargins = .zero
        configureLegalButton()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        insetsLayoutMarginsFromSafeArea = false
        layoutMargins = .zero
        configureLegalButton()
    }

    private func configureLegalButton() {
        legalButton.accessibilityLabel = NSLocalizedString("Legal", comment: "Apple Maps legal information")
        legalButton.accessibilityIdentifier = "wherewolf.map.legal"
        legalButton.accessibilityTraits = .link
        legalButton.addTarget(self, action: #selector(openLegal), for: .touchUpInside)
        legalButton.isHidden = true
        addSubview(legalButton)
    }

    @objc private func openLegal() {
        if legalLabel?.accessibilityActivate() == true { return }
        var responder: UIResponder? = next
        while let current = responder {
            if let controller = current as? UIViewController {
                let browser = SFSafariViewController(url: URL(string: "https://www.apple.com/legal/internet-services/maps/legal-en.html")!)
                browser.dismissButtonStyle = .done
                browser.preferredControlTintColor = .systemBlue
                controller.present(browser, animated: !UIAccessibility.isReduceMotionEnabled)
                return
            }
            responder = current.next
        }
    }

    override func layoutSubviews() {
        for credit in credits { credit.view?.transform = credit.transform }
        credits.removeAll()
        super.layoutSubviews()
        onMapLayout?()
        guard bounds.width > 0, bounds.height > 0 else { return }
        if lastViewport != bounds {
            lastViewport = bounds
            DispatchQueue.main.async { [weak self] in self?.onViewportChange?() }
        }
        var candidates: [(UIView, CGRect)] = []
        func collect(_ view: UIView) {
            guard view !== legalButton, !view.isHidden, view.alpha > 0.01,
                  !(view is MKAnnotationView) else { return }
            let frame = view.convert(view.bounds, to: self)
            if frame.width > 0, frame.height > 0, frame.height <= 64,
               frame.minY >= bounds.maxY - 96, frame.maxY <= bounds.maxY + 16 {
                candidates.append((view, frame))
                return
            }
            for child in view.subviews { collect(child) }
        }
        for child in subviews { collect(child) }
        guard !candidates.isEmpty else {
            legalButton.isHidden = true
            return
        }
        let top = bounds.minY + MapChrome.attributionTop(safeTop: safeAreaInsets.top)
        func move(_ view: UIView, to origin: CGPoint) {
            guard let parent = view.superview else { return }
            let frame = view.convert(view.bounds, to: self)
            credits.append(Credit(view))
            let start = parent.convert(CGPoint.zero, from: self)
            let end = parent.convert(CGPoint(x: origin.x - frame.minX, y: origin.y - frame.minY), from: self)
            view.transform = view.transform.concatenating(
                CGAffineTransform(translationX: end.x - start.x, y: end.y - start.y))
        }
        var fragments: [UIView] = []
        func compactContents(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            let frame = view.convert(view.bounds, to: self)
            if frame.width > 0, frame.height > 0, frame.width < bounds.width * 0.6, frame.height <= 64 {
                fragments.append(view)
                return
            }
            for child in view.subviews { compactContents(child) }
        }
        for (view, frame) in candidates {
            if frame.width < bounds.width * 0.6 {
                fragments.append(view)
            } else {
                move(view, to: CGPoint(x: frame.minX, y: top))
                for child in view.subviews { compactContents(child) }
            }
        }
        fragments.sort { $0.convert($0.bounds, to: self).minX < $1.convert($1.bounds, to: self).minX }
        let height = max(22, fragments.map { $0.convert($0.bounds, to: self).height }.max() ?? 22)
        var left = MapChrome.edge
        for fragment in fragments {
            let frame = fragment.convert(fragment.bounds, to: self)
            move(fragment, to: CGPoint(x: left, y: top + (height - frame.height) / 2))
            left += frame.width + 8
        }
        let link = fragments.first(where: { $0.accessibilityTraits.contains(.link) })
            ?? fragments.last(where: { $0.bounds.height <= 24 && $0.bounds.width >= 20 })
        if let label = link {
            if label !== legalLabel {
                legalLabel?.accessibilityElementsHidden = false
                legalLabel = label
                label.accessibilityElementsHidden = true
            }
            let frame = label.convert(label.bounds, to: self)
            legalButton.frame = CGRect(x: frame.midX - max(44, frame.width) / 2,
                y: max(bounds.minY, frame.midY - 22), width: max(44, frame.width), height: 44)
            legalButton.isHidden = false
            if subviews.last !== legalButton { bringSubviewToFront(legalButton) }
        } else {
            legalButton.isHidden = true
        }
    }

}

struct NativeMapSurface: UIViewRepresentable {
    var position: MapCameraPosition
    var mapType: MKMapType
    var coordinates: [CLLocationCoordinate2D]
    var replayRoute: ReplayRouteGeometry?
    var replayPosition: Double
    var replayAccuracy: CLLocationAccuracy? = nil
    var replayActive = false
    var replayFollowing = true
    var replayFollowDistance: CLLocationDistance? = nil
    var replayOverview = false
    // The trip opened from the Trip tab, as route indices: drawn red, and fitted by the overview.
    var replayHighlight: ClosedRange<Int>? = nil
    // The overview's fit for that trip, which is its nearest fix when it has none of its own.
    var replayFitRange: ClosedRange<Int>? = nil
    var rulerZoom: ReplayRulerHold? = nil
    var rulerScaleChannel: RulerScaleChannel? = nil
    var replayPoseChannel: ReplayPoseChannel? = nil
    var rulerZoomActive = true
    var liveRulerGeometry: LiveRulerGeometry? = nil
    var replayStatusHeight: CGFloat = 0
    // SwiftUI animation transactions do not cross the shell's separate map hosting controller.
    var replayCameraAction = 0
    // A live recenter must also reach the map when its cached request is already follow.
    var recenterAction = 0
    var selected: CLLocationCoordinate2D?
    var selectedTitle: String
    // An inactive scene is still on screen, as when sliding up to the app switcher.
    var scenePhase: ScenePhase
    var sceneVisible: Bool { scenePhase != .background }
    var pageActive: Bool
    var trackingEnabled = false
    var onCameraChange: (MapCamera, Bool) -> Void
    var onInteraction: () -> Void
    var onRotationChange: (Bool) -> Void = { _ in }
    var onRulerCameraRestore: (MapCamera, CLLocationDistance) -> Void = { _, _ in }

    @MainActor static func setDrawerTop(_ value: CGFloat, on map: MKMapView) {
        guard let map = map as? AttributionMapView else { return }
        let top = min(map.bounds.maxY, max(map.bounds.minY, value))
        if abs((map.drawerTop ?? -.greatestFiniteMagnitude) - top) > 0.1 { map.drawerTop = top }
    }

    @MainActor static func setClosedDrawerTop(_ value: CGFloat, on map: MKMapView) {
        guard let map = map as? AttributionMapView else { return }
        let top = min(map.bounds.maxY, max(map.bounds.minY, value))
        if abs((map.closedDrawerTop ?? -.greatestFiniteMagnitude) - top) > 0.1 { map.closedDrawerTop = top }
    }

    @MainActor static func visibleCenter(on map: MKMapView) -> CGPoint {
        (map as? AttributionMapView)?.visibleCenter
            ?? MapViewport.center(in: map.bounds, safeTop: map.bounds.minY + map.safeAreaInsets.top, drawerTop: nil)
    }

    @MainActor private static func cameraCenter(on map: MKMapView) -> CGPoint {
        let viewport = map.bounds.inset(by: map.layoutMargins)
        return CGPoint(x: viewport.midX, y: viewport.midY)
    }

    @MainActor static func displayedUserCoordinate(on map: MKMapView) -> CLLocationCoordinate2D? {
        (map.delegate as? Coordinator)?.displayedLiveCoordinate ?? map.userLocation.location?.coordinate
    }

#if targetEnvironment(simulator)
    @MainActor static func displayedTrailCoordinate(on map: MKMapView) -> CLLocationCoordinate2D? {
        (map.delegate as? Coordinator)?.displayedTrailCoordinate
    }
    @MainActor static func replayAuditValues(on map: MKMapView) -> [String: Double] {
        (map.delegate as? Coordinator)?.replayAuditValues ?? [:]
    }
#endif

    @MainActor static func zoom(inward: Bool, on map: MKMapView) -> MapZoomResult? {
        (map.delegate as? Coordinator)?.zoom(inward: inward, on: map)
    }

    @MainActor static func faceNorth(on map: MKMapView) -> MapZoomResult? {
        (map.delegate as? Coordinator)?.faceNorth(on: map)
    }

    // A degree of rotation is invisible; the compass would only flicker in and out.
    static func isRotated(heading: CLLocationDirection) -> Bool {
        heading.isFinite && abs(remainder(heading, 360)) > 1
    }

    @MainActor static func replayOverviewDistance(on map: MKMapView) -> CLLocationDistance? {
        (map.delegate as? Coordinator)?.replayOverviewCamera(on: map)?.distance
    }

    @MainActor static func replayClearRect(on map: MKMapView) -> CGRect {
        MapChrome.replayClearRect(in: map.bounds, safeArea: map.safeAreaInsets,
                                 drawerTop: (map as? AttributionMapView)?.drawerTop,
                                 statusHeight: (map.delegate as? Coordinator)?.parent.replayStatusHeight ?? 0)
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> MKMapView {
        makeMap(coordinator: context.coordinator)
    }

    @MainActor func makeMap(coordinator: Coordinator) -> MKMapView {
        let map = AttributionMapView(frame: .zero)
        map.delegate = coordinator
        map.showsUserLocation = GLManagerBridge.shared.hasLocationAccess
            && sceneVisible && pageActive && !replayActive && replayRoute == nil
        map.showsCompass = false
        // Native follow mode changes the chosen zoom; presentation follows fixes here.
        map.userTrackingMode = .none
        coordinator.map = map
        let contact = MapContactRecognizer(target: nil, action: nil)
        contact.cancelsTouchesInView = false
        contact.delaysTouchesBegan = false
        contact.delaysTouchesEnded = false
        contact.onContact = { [weak coordinator] active in coordinator?.mapContactChanged(active) }
        map.addGestureRecognizer(contact)
        map.onViewportChange = { [weak coordinator, weak map] in
            guard let map else { return }
            coordinator?.viewportChanged(on: map)
        }
        map.onMapLayout = { [weak coordinator, weak map] in
            guard let map else { return }
            coordinator?.alignMarkers(on: map)
        }
        coordinator.update(self, animated: false)
        DispatchQueue.main.async { [weak coordinator, weak map] in
            guard let map else { return }
            coordinator?.observeGestures(in: map)
        }
        return map
    }

    func updateUIView(_ map: MKMapView, context: Context) {
        context.coordinator.update(self, animated: context.transaction.animation != nil)
    }

    static func dismantleUIView(_ map: MKMapView, coordinator: Coordinator) {
        coordinator.stopCameraTransition()
        coordinator.stopRulerZoom()
        coordinator.detachRulerScaleChannel()
        coordinator.attachReplayPoseChannel(nil)
        coordinator.stopLiveMotion()
        coordinator.stopReplayHeading()
        coordinator.stopReplayCoverageExpiry()
        coordinator.stopHeadingMode()
        coordinator.clearMapContact()
        map.showsUserLocation = false
        map.delegate = nil
    }

    @MainActor
    final class Coordinator: NSObject, MKMapViewDelegate {
        private enum Request: Equatable {
            case camera(MapCamera)
            case region(Double, Double, Double, Double)
            case overview(ObjectIdentifier, ClosedRange<Int>?)
            case follow
            case automatic
        }

        var parent: NativeMapSurface
        weak var map: MKMapView?
        private var request: Request?
        private var revision = 0
        private var interacting = false
        private var hasMapContact = false
        private var cameraContactTime: TimeInterval?
        private var followingInitialized = false
        private var hasInitialCamera = false
        private var anchorCoordinate: CLLocationCoordinate2D?
        private var correctionsRemaining = 0
        private var aligning = false
        private var observedGestures = Set<ObjectIdentifier>()
        private var tripCoordinates: [CLLocationCoordinate2D] = []
        private var tripLine: MKPolyline?
        private var replayRoute: ReplayRouteGeometry?
        private var replayPresentation: ReplayRoutePresentation?
        private let replayTrailLayer = ReplayTrailLayer()
        private let replayFutureLayer = ReplayTrailLayer(future: true)
        private let replayHighlightLayer = ReplayTrailLayer(highlight: true)
        private var highlightBounds: (route: ObjectIdentifier, range: ClosedRange<Int>, bounds: CGRect)?
        private var revealedHighlight: ClosedRange<Int>?
        private var pendingReveal: (range: ClosedRange<Int>, since: TimeInterval)?
        private var revealEnd: TimeInterval = 0
        private let replayAccuracyLayer = ReplayAccuracyLayer()
        private var replayCoverageExpiry: DispatchWorkItem?
        private var replayCoverageDeadline: TimeInterval?
        private var replayCoverageGeneration = 0
        private var replayRenderCamera: MapCamera?
        private var overviewFit: (route: ObjectIdentifier, highlight: ClosedRange<Int>?, bounds: CGRect, clear: CGRect,
                                  heading: CLLocationDirection, pitch: CGFloat, type: MKMapType, camera: MapCamera)?
        private var overviewViewport: (bounds: CGRect, safeArea: UIEdgeInsets)?
#if targetEnvironment(simulator)
        var displayedTrailCoordinate: CLLocationCoordinate2D? { replayTrailLayer.coordinate }
        var replayAuditValues: [String: Double] {
            var values = replayPresentation?.auditValues ?? [:]
            values["nativePosePosition"] = parent.replayPosition
            if parent.replayOverview, let map, let route = replayRoute,
               let bounds = ReplayOverviewFit.projectedBounds(route.coordinates.map { map.convert($0, toPointTo: nil) }) {
                let clear = map.convert(NativeMapSurface.replayClearRect(on: map), to: nil)
                values["overviewMinX"] = bounds.minX
                values["overviewMaxX"] = bounds.maxX
                values["overviewMinY"] = bounds.minY
                values["overviewMaxY"] = bounds.maxY
                values["overviewProjectedCount"] = Double(route.coordinates.count)
                values["overviewClearMinX"] = clear.minX
                values["overviewClearMaxX"] = clear.maxX
                values["overviewClearMinY"] = clear.minY
                values["overviewClearMaxY"] = clear.maxY
            }
            if let map {
                values["mapHeading"] = map.camera.heading
                values["mapPitch"] = Double(map.camera.pitch)
            }
            // The sheet's presentation frame can lag the viewport supplied to the map during a spring.
            if let map, let top = (map as? AttributionMapView)?.drawerTop {
                values["targetDrawerTop"] = map.convert(CGPoint(x: 0, y: top), to: nil).y
                if let closed = (map as? AttributionMapView)?.closedDrawerTop {
                    values["targetClosedDrawerTop"] = map.convert(CGPoint(x: 0, y: closed), to: nil).y
                }
                values["targetSafeTop"] = map.convert(CGPoint(x: 0, y: map.bounds.minY + map.safeAreaInsets.top), to: nil).y
            }
            return values
        }
#endif
        private var selectedPoint: MKPointAnnotation?
        private var selectedIsReplay = false
        // An opened trip's marker travels in with the flight from where it was: the last trip's marker, or the live
        // location, where it grows out of the dot.
        private var markerOrigin: (coordinate: CLLocationCoordinate2D, live: Bool)?
        private var markerGlide: (from: CLLocationCoordinate2D, live: Bool, growth: Double)?
        private var mapRotated = false
        private var cameraActionAnimating = false
        private var cameraZooming = false
        private var zoomKeepsCentering = false
        private var cameraTransition: MapCameraTransition?
        // A trip's flight starts its clock on its first frame, after the replay route has been built.
        private var cameraClockPending = false
        private var cameraDestination: MapCamera?
        private var cameraDisplayLink: CADisplayLink?
        private var scaledRuler: ReplayRulerHold?
        private weak var rulerScaleChannel: RulerScaleChannel?
        private weak var replayPoseChannel: ReplayPoseChannel?
        private var rulerScaleFrame: RulerScaleChannel.Frame?
        private var rulerScalePendingCommit: RulerScaleChannel.Frame?
        private struct RulerScaleFitContext: Equatable {
            let route: ObjectIdentifier
            let position: Double
            let latitude: Double
            let longitude: Double
            let steps: [Double]
            let width: CGFloat
            let base: CLLocationDistance?
            let pitch: Double?
        }
        private var rulerScaleFitContext: RulerScaleFitContext?
        private var rulerScaleDistances: [Double: CLLocationDistance] = [:]
        private var rulerScaleZooms: [Double: ReplayRulerHold] = [:]
        private(set) var rulerScaleFitCounts: [Double: Int] = [:]
        private var rulerBaseDistance: CLLocationDistance?
        // Live has no outer distance setting; retain its base across history, tabs and camera release.
        private var liveRulerBaseDistance: CLLocationDistance?
        private var rulerPitch: Double?
        private var rulerRestoreGeneration = 0
        private var rulerDistance: CLLocationDistance?
        private(set) var rulerFitPosition: Double?
        private(set) var rulerLiveFitID: Int64?
        private var rulerCoordinate: CLLocationCoordinate2D?
        private var rulerZoomWasSuspended = false
        private var replayLiveDistance: CLLocationDistance?
        private(set) var rulerDistanceEase: ReplayHoldDistanceEase?
        private var rulerContactTime: TimeInterval?
        private var rulerZoomLink: CADisplayLink?
        private lazy var rulerProjection = MKMapView()
        private var replayHeading = HeadingMotion()
        private var replayHeadingDisplayLink: CADisplayLink?
        private var liveMotion = LiveMapMotion()
        private var liveDisplayLink: CADisplayLink?
        private(set) var displayedLiveCoordinate: CLLocationCoordinate2D?
        private var latestLiveTimestamp: Date?
        private var mapHeading = HeadingMotion(response: 9)
        private var mapHeadingDisplayLink: CADisplayLink?
        private let liveHeading: LiveHeadingController
        private var followingHeading = false
        // Switching to following flies to the live location on its next fix instead of jumping there.
        private var flyToUser = false
        private var cameraFlight = false
        private var replayDetached: Bool { parent.replayActive && !parent.replayFollowing && !parent.replayOverview }

        init(_ parent: NativeMapSurface, liveHeading: LiveHeadingController? = nil) {
            let liveHeading = liveHeading ?? LiveHeadingController()
            self.parent = parent
            self.liveHeading = liveHeading
            super.init()
            liveHeading.onHeading = { [weak self] in self?.receiveDeviceHeading($0) }
            liveHeading.onNeedsDisplay = { [weak self] in
                guard let self, let map = self.map else { return }
                self.alignMarkers(on: map)
            }
        }

        func update(_ parent: NativeMapSurface, animated: Bool) {
            let wasVisible = self.parent.sceneVisible && self.parent.pageActive
            let wasDetached = replayDetached
            let wasRulerVisible = self.parent.scenePhase == .active && self.parent.pageActive && self.parent.rulerZoomActive
            let replayModeChanged = parent.replayActive != self.parent.replayActive
            let cameraAction = parent.replayCameraAction != self.parent.replayCameraAction
                || parent.recenterAction != self.parent.recenterAction
            if parent.replayActive && !self.parent.replayActive, let map {
                replayLiveDistance = liveRulerBaseDistance ?? (cameraZooming || cameraFlight
                    ? cameraDestination?.distance ?? map.camera.centerCoordinateDistance
                    : map.camera.centerCoordinateDistance)
            }
            if !parent.replayActive && self.parent.replayActive {
                if parent.rulerZoom != nil || parent.rulerScaleChannel?.frame != nil {
                    liveRulerBaseDistance = replayLiveDistance
                } else if scaledRuler == nil && self.parent.rulerZoom == nil {
                    replayLiveDistance = nil
                }
            }
            let liveFlight = !parent.replayActive && (replayModeChanged || cameraAction
                || !self.parent.position.followsUserLocation)
            if replayModeChanged {
                if let map, let base = rulerBaseDistance,
                   parent.scenePhase != .active || !parent.pageActive || !parent.rulerZoomActive {
                    var camera = MapCamera(map.camera)
                    camera.centerCoordinate = rulerCoordinate ?? camera.centerCoordinate
                    camera.distance = base
                    stopCameraTransition()
                    setCamera(camera, on: map, animated: false)
                    rulerZoomWasSuspended = true
                }
                stopRulerZoom()
                scaledRuler = nil
                rulerBaseDistance = nil
                rulerPitch = nil
                rulerDistance = nil
                rulerFitPosition = nil
                rulerLiveFitID = nil
                rulerCoordinate = nil
                resetRulerScaleFits()
                rulerRestoreGeneration &+= 1
            }
            if parent.replayActive && replayModeChanged {
                markerOrigin = map?.showsUserLocation == true
                    ? (displayedLiveCoordinate ?? map?.userLocation.location?.coordinate).map { ($0, true) } : nil
            } else {
                markerOrigin = selectedPoint.map { ($0.coordinate, false) }
            }
            self.parent = parent
            attachRulerScaleChannel(parent.rulerScaleChannel)
            attachReplayPoseChannel(parent.replayPoseChannel)
            if cameraAction { rulerRestoreGeneration &+= 1 }
            guard let map else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            if replayDetached && !wasDetached {
                stopCameraTransition()
                anchorCoordinate = nil
                correctionsRemaining = 0
            }
            if parent.replayActive, parent.replayFollowing, !parent.replayOverview, wasDetached || cameraAction {
                interacting = false
            }
            if !parent.replayActive, parent.position.followsUserLocation, liveFlight { interacting = false }
            if map.mapType != parent.mapType { map.mapType = parent.mapType }
            let visible = parent.sceneVisible && parent.pageActive
            let showLocation = GLManagerBridge.shared.hasLocationAccess
                && visible && !parent.replayActive && parent.replayRoute == nil
            if map.showsUserLocation != showLocation { map.showsUserLocation = showLocation }
            if !showLocation { stopLiveMotion() }
            if !visible || replayModeChanged
                || (parent.replayRoute == nil && !cameraZooming && !(cameraFlight && parent.position.followsUserLocation)) {
                stopCameraTransition()
            }
            if !visible || parent.replayRoute == nil {
                stopReplayHeading()
                if parent.replayRoute == nil { replayHeading = HeadingMotion() }
            }
            updateOverlays(map)
            updateSelection(map)
            observeGestures(in: map)
            let restoredRuler = updateRulerZoom(on: map, wasVisible: wasRulerVisible, liveFlight: liveFlight)
            if !restoredRuler {
                if cameraAction {
                    applyPosition(map, animated: scaledRuler == nil && visible && !UIAccessibility.isReduceMotionEnabled, force: true)
                } else if !cameraActionAnimating && !interacting && !hasMapContact {
                    applyPosition(map, animated: scaledRuler == nil && animated && !UIAccessibility.isReduceMotionEnabled)
                }
            }
            markerOrigin = nil
            updateHeadingMode(on: map)
            if visible && !wasVisible { viewportChanged(on: map) }
            alignMarkers(on: map)
        }

        private func sameCoordinates(_ lhs: [CLLocationCoordinate2D], _ rhs: [CLLocationCoordinate2D]) -> Bool {
            guard lhs.count == rhs.count else { return false }
            // Retaining the Array keeps its shared storage immutable through copy-on-write.
            if lhs.withUnsafeBufferPointer({ left in
                rhs.withUnsafeBufferPointer { right in left.baseAddress == right.baseAddress }
            }) { return true }
            return zip(lhs, rhs).allSatisfy { pair in
                pair.0.latitude == pair.1.latitude && pair.0.longitude == pair.1.longitude
            }
        }

        private func updateOverlays(_ map: MKMapView) {
            if replayRoute !== parent.replayRoute {
                overviewFit = nil
                replayRoute = parent.replayRoute
                if let route = replayRoute, !route.coordinates.isEmpty {
                    if let presentation = replayPresentation {
                        presentation.update(coordinates: route.coordinates, pointIDs: route.pointIDs,
                            position: parent.replayPosition).apply(to: map)
                    } else {
                        let presentation = ReplayRoutePresentation(coordinates: route.coordinates,
                            pointIDs: route.pointIDs, position: parent.replayPosition)
                        replayPresentation = presentation
                        map.addOverlays(presentation.overlays, level: .aboveRoads)
                    }
                } else {
                    if let presentation = replayPresentation {
                        map.removeOverlays(presentation.overlays + presentation.highlightOverlays)
                    }
                    replayPresentation = nil
                    replayRenderCamera = nil
                }
            }
            replayPresentation?.updatePosition(parent.replayPosition).apply(to: map)
            scheduleReplayCoverageExpiry()
            if !sameCoordinates(tripCoordinates, parent.coordinates) {
                if let tripLine { map.removeOverlay(tripLine) }
                tripCoordinates = parent.coordinates
                tripLine = parent.coordinates.count > 1
                    ? MKPolyline(coordinates: parent.coordinates, count: parent.coordinates.count) : nil
                if let tripLine { map.addOverlay(tripLine, level: .aboveRoads) }
            }
        }

        func stopReplayCoverageExpiry() {
            replayCoverageGeneration &+= 1
            replayCoverageExpiry?.cancel()
            replayCoverageExpiry = nil
            replayCoverageDeadline = nil
        }

        private func scheduleReplayCoverageExpiry() {
            replayPresentation?.expireCoverage()
            let deadline = replayPresentation?.nextCoverageDeadline
            guard deadline != replayCoverageDeadline else { return }
            stopReplayCoverageExpiry()
            guard let deadline, parent.sceneVisible, parent.pageActive else { return }
            replayCoverageDeadline = deadline
            let generation = replayCoverageGeneration
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.replayCoverageGeneration == generation, let map = self.map else { return }
                self.replayCoverageDeadline = nil
                self.replayCoverageExpiry = nil
                self.alignMarkers(on: map)
                self.scheduleReplayCoverageExpiry()
            }
            replayCoverageExpiry = work
            DispatchQueue.main.asyncAfter(deadline: .now() + max(0, deadline - CACurrentMediaTime()), execute: work)
        }

        private func updateSelection(_ map: MKMapView) {
            let replay = parent.replayActive || parent.replayRoute != nil
            if selectedIsReplay != replay {
                if let selectedPoint { map.removeAnnotation(selectedPoint) }
                selectedPoint = nil
                selectedIsReplay = replay
            }
            guard let coordinate = parent.selected else {
                if let selectedPoint { map.removeAnnotation(selectedPoint) }
                selectedPoint = nil
                return
            }
            if let selectedPoint {
                // A gliding marker lands on the selection with the flight.
                if markerGlide == nil, selectedPoint.coordinate.latitude != coordinate.latitude
                    || selectedPoint.coordinate.longitude != coordinate.longitude {
                    UIView.performWithoutAnimation { selectedPoint.coordinate = coordinate }
                }
                if selectedPoint.title != parent.selectedTitle { selectedPoint.title = parent.selectedTitle }
            } else {
                let point = MKPointAnnotation()
                point.coordinate = coordinate
                point.title = parent.selectedTitle
                selectedPoint = point
                map.addAnnotation(point)
            }
        }

        func alignMarkers(on map: MKMapView) {
            guard parent.sceneVisible, parent.pageActive else {
                stopReplayCoverageExpiry()
                liveHeading.hide()
                replayTrailLayer.hide()
                replayFutureLayer.hide()
                replayHighlightLayer.hide()
                replayAccuracyLayer.hide()
                return
            }
            if cameraZooming && zoomKeepsCentering, let coordinate = zoomAnchor(on: map) {
                if anchorCoordinate?.latitude != coordinate.latitude || anchorCoordinate?.longitude != coordinate.longitude {
                    anchorCoordinate = coordinate
                    correctionsRemaining = 6
                }
                alignAnchor(on: map)
            }
            if parent.replayRoute != nil, let selectedPoint, let view = map.view(for: selectedPoint) {
                liveHeading.hide()
                // The trail splits at the replay position even while the marker glides toward it.
                let pose = parent.selected ?? selectedPoint.coordinate
                align(view, to: selectedPoint.coordinate, on: map)
                let transform = CATransform3DMakeAffineTransform(markerTransform(view))
                if !CATransform3DEqualToTransform(view.layer.sublayerTransform, transform) {
                    view.layer.sublayerTransform = transform
                }
                if markerGlide == nil {
                    replayAccuracyLayer.update(coordinate: pose, accuracy: parent.replayAccuracy, on: map, below: view)
                } else {
                    replayAccuracyLayer.hide()
                }
                if let presentation = replayPresentation, let container = view.superview {
                    let screen = ReplayScreenProjection(map: map, container: container)
                    let now = CACurrentMediaTime()
                    let span = highlightCoverage(presentation.fullRoute)
                    let range = span.map { $0.start...$0.end }
                    if let range, revealedHighlight != range {
                        // A newly opened trip stays hidden while the camera flies, then draws in. The flight
                        // starts in the same update as the highlight, so it gets a moment to begin first.
                        if pendingReveal?.range != range {
                            pendingReveal = (range, now)
                            replayHighlightLayer.conceal()
                            presentation.highlight(nil).apply(to: map)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                                guard let self, let map = self.map else { return }
                                self.alignMarkers(on: map)
                            }
                        }
                        if !cameraActionAnimating, let pending = pendingReveal, now - pending.since >= 0.15 {
                            revealedHighlight = range
                            pendingReveal = nil
                            let animated = !UIAccessibility.isReduceMotionEnabled
                            replayHighlightLayer.reveal(animated: animated)
                            revealEnd = now + (animated ? ReplayTrailLayer.revealDuration : 0)
                            if animated {
                                DispatchQueue.main.asyncAfter(deadline: .now() + ReplayTrailLayer.revealDuration) { [weak self] in
                                    guard let self, let map = self.map else { return }
                                    self.alignMarkers(on: map)
                                }
                            }
                        }
                    } else if range == nil {
                        revealedHighlight = nil
                        pendingReveal = nil
                        presentation.highlight(nil).apply(to: map)
                    }
                    // Once drawn in, the trip moves to MapKit overlays, which move with the map itself; the layer
                    // stays until MapKit has drawn them, and the blue and dots layers then leave the trip to them.
                    if let range, revealedHighlight == range, now >= revealEnd {
                        presentation.highlight(range, now: now).apply(to: map)
                    }
                    let native = range != nil && revealedHighlight == range && presentation.highlightRendered(now: now)
                    replayTrailLayer.update(route: presentation.fullRoute, position: parent.replayPosition,
                        coordinate: pose, coverage: presentation.layerCoverage(future: false, now: now),
                        hiding: native ? range : nil, projection: screen, on: map, below: view)
                    replayFutureLayer.update(route: presentation.fullRoute, position: parent.replayPosition,
                        coordinate: pose, coverage: presentation.layerCoverage(future: true, now: now),
                        hiding: native ? range : nil, projection: screen, on: map, below: view)
                    if let layers = container.layer.sublayers,
                       let future = layers.firstIndex(of: replayFutureLayer), let trail = layers.firstIndex(of: replayTrailLayer),
                       future > trail {
                        container.layer.insertSublayer(replayFutureLayer, below: replayTrailLayer)
                    }
                    if let span, !native {
                        replayHighlightLayer.update(route: presentation.fullRoute, position: parent.replayPosition,
                            coordinate: pose, coverage: [span], projection: screen, on: map, below: view)
                        if let layers = container.layer.sublayers, let highlight = layers.firstIndex(of: replayHighlightLayer),
                           let trail = layers.firstIndex(of: replayTrailLayer), highlight < trail {
                            container.layer.insertSublayer(replayHighlightLayer, above: replayTrailLayer)
                        }
                    } else {
                        replayHighlightLayer.hide()
                    }
                    scheduleReplayCoverageExpiry()
                } else {
                    replayTrailLayer.hide()
                    replayFutureLayer.hide()
                    replayHighlightLayer.hide()
                }
                updateReplayDirection(view, coordinate: selectedPoint.coordinate, on: map)
            } else {
                replayTrailLayer.hide()
                replayFutureLayer.hide()
                replayHighlightLayer.hide()
                replayAccuracyLayer.hide()
                if map.showsUserLocation, let coordinate = displayedLiveCoordinate ?? map.userLocation.location?.coordinate,
                   let view = map.view(for: map.userLocation) as? MKUserLocationView {
                    align(view, to: coordinate, on: map)
                    liveHeading.render(coordinate: coordinate, on: map, marker: view)
                } else {
                    liveHeading.hide()
                }
            }
        }

        private func align(_ view: MKAnnotationView, to coordinate: CLLocationCoordinate2D, on map: MKMapView) {
            guard let container = view.superview else { return }
            let point = map.convert(coordinate, toPointTo: container)
            guard point.x.isFinite, point.y.isFinite else { return }
            let center = CGPoint(x: point.x + view.centerOffset.x, y: point.y + view.centerOffset.y)
            (view as? PresentedUserLocationView)?.presentedCenter = center
            guard hypot(view.center.x - center.x, view.center.y - center.y) > 0.01 else { return }
            // MapKit can defer moving a native annotation until its next layout pass.
            UIView.performWithoutAnimation { view.center = center }
        }

        private func updateReplayDirection(_ view: MKAnnotationView, coordinate: CLLocationCoordinate2D,
                                           on map: MKMapView) {
            guard let view = view as? ReplayMarkerView else { return }
            guard let direction = parent.replayRoute?.direction(at: parent.replayPosition) else {
                stopReplayHeading()
                replayHeading = HeadingMotion()
                view.face(nil)
                return
            }
            replayHeading.receive(atan2(Double(direction.dx), -Double(direction.dy)), at: CACurrentMediaTime())
            if !parent.sceneVisible || !parent.pageActive || view.window == nil
                || UIAccessibility.isReduceMotionEnabled || replayHeading.settled {
                stopReplayHeading()
            } else if replayHeadingDisplayLink == nil {
                let target = ReplayHeadingFrameTarget(coordinator: self)
                let link = CADisplayLink(target: target, selector: #selector(ReplayHeadingFrameTarget.frame(_:)))
                let maximum = Float(map.window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
                link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
                link.add(to: .main, forMode: .common)
                replayHeadingDisplayLink = link
            }
            renderReplayDirection(view, coordinate: coordinate, on: map)
        }

        func stopReplayHeading() {
            replayHeadingDisplayLink?.invalidate()
            replayHeadingDisplayLink = nil
            replayHeading.finish()
        }

        fileprivate func advanceReplayHeading(at time: TimeInterval) {
            guard let map, parent.sceneVisible, parent.pageActive, parent.replayRoute != nil,
                  let selectedPoint, let view = map.view(for: selectedPoint) as? ReplayMarkerView else {
                stopReplayHeading()
                return
            }
            replayHeading.advance(at: time)
            if UIAccessibility.isReduceMotionEnabled || replayHeading.settled { stopReplayHeading() }
            renderReplayDirection(view, coordinate: selectedPoint.coordinate, on: map)
        }

        private func renderReplayDirection(_ view: ReplayMarkerView, coordinate: CLLocationCoordinate2D,
                                           on map: MKMapView) {
            guard let heading = replayHeading.angle else {
                view.face(nil)
                return
            }
            view.face(MapHeadingProjection.angle(heading: heading, coordinate: coordinate, on: map))
        }

        private func applyPosition(_ map: MKMapView, animated: Bool, force: Bool = false) {
            let next: Request
            if parent.replayOverview, let route = parent.replayRoute {
                next = .overview(ObjectIdentifier(route), parent.replayFitRange)
            } else if parent.replayFollowing, parent.replayRoute != nil, let coordinate = parent.selected {
                next = .camera(MapCamera(centerCoordinate: coordinate,
                    distance: rulerDistance ?? parent.replayFollowDistance ?? parent.position.camera?.distance ?? 2_000,
                    heading: map.camera.heading, pitch: rulerPitch ?? Double(map.camera.pitch)))
            } else if parent.position.followsUserLocation {
                next = .follow
            } else if let camera = parent.position.camera {
                next = .camera(camera)
            } else if let region = parent.position.region {
                next = .region(region.center.latitude, region.center.longitude,
                               region.span.latitudeDelta, region.span.longitudeDelta)
            } else {
                next = .automatic
            }
            guard force || request != next else { return }
            request = next
            revision += 1
            interacting = false
            followingInitialized = false
            flyToUser = false
            if animated, parent.replayRoute != nil {
                let destination: MapCamera?
                switch next {
                case .overview: destination = replayOverviewCamera(on: map)
                case .camera(let camera): destination = camera
                default: destination = nil
                }
                if let destination {
                    // An opened trip can be far away, so the map flies out and back in to show it.
                    var trip = false
                    if case .overview(_, let highlight) = next { trip = highlight != nil }
                    startCameraTransition(to: destination, on: map, flight: trip, clockOnFirstFrame: trip)
                    if trip, let origin = markerOrigin, let selectedPoint {
                        markerGlide = (origin.coordinate, origin.live, origin.live ? 0 : 1)
                        UIView.performWithoutAnimation { selectedPoint.coordinate = origin.coordinate }
                    }
                    return
                }
            }
            switch next {
            case .overview:
                anchorCoordinate = nil
                correctionsRemaining = 0
                hasInitialCamera = true
                fitReplayRoute(on: map, animated: animated)
            case .camera(let camera):
                setCamera(camera, on: map, animated: animated)
            case .region(let latitude, let longitude, let latitudeDelta, let longitudeDelta):
                let center = replayDetached ? CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                    : parent.selected ?? CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
                anchorCoordinate = replayDetached ? nil : center
                correctionsRemaining = replayDetached ? 0 : 6
                hasInitialCamera = true
                map.setRegion(MKCoordinateRegion(
                    center: center,
                    span: MKCoordinateSpan(latitudeDelta: latitudeDelta, longitudeDelta: longitudeDelta)
                ), animated: animated)
                if !animated { alignAnchor(on: map) }
            case .follow:
                // Every later switch to following flies from wherever the map is; the first camera at launch does not.
                flyToUser = hasInitialCamera && parent.sceneVisible && parent.pageActive
                    && !UIAccessibility.isReduceMotionEnabled
                if flyToUser { stopCameraTransition() }
                followUser(on: map, animated: false)
            case .automatic:
                anchorCoordinate = nil
                break
            }
        }

        private func attachRulerScaleChannel(_ channel: RulerScaleChannel?) {
            guard rulerScaleChannel !== channel else { return }
            detachRulerScaleChannel()
            rulerScaleChannel = channel
            rulerScaleFrame = channel?.frame
            channel?.onChange = { [weak self] frame in self?.receiveRulerScale(frame) }
        }

        func attachReplayPoseChannel(_ channel: ReplayPoseChannel?) {
            guard replayPoseChannel !== channel else { return }
            replayPoseChannel?.stopObserving(self)
            replayPoseChannel = channel
            channel?.observe(self) { [weak self] frame in self?.receiveReplayFrame(frame) }
        }

        // A playback frame changes only the pose, so it takes the same path as SwiftUI's update with it.
        private func receiveReplayFrame(_ frame: ReplayPoseChannel.Frame) {
            guard parent.replayActive, parent.replayRoute != nil, parent.selected != nil else { return }
            var next = parent
            next.replayPosition = frame.pose.position
            next.selected = frame.pose.coordinate.coordinate
            next.replayAccuracy = frame.accuracy
            update(next, animated: false)
        }

        func detachRulerScaleChannel() {
            rulerScaleChannel?.onChange = nil
            rulerScaleChannel = nil
            rulerScaleFrame = nil
            rulerScalePendingCommit = nil
            resetRulerScaleFits()
        }

        private func resetRulerScaleFits() {
            rulerScaleFitContext = nil
            rulerScaleDistances.removeAll(keepingCapacity: true)
            rulerScaleZooms.removeAll(keepingCapacity: true)
            rulerScaleFitCounts.removeAll(keepingCapacity: true)
        }

        private func receiveRulerScale(_ frame: RulerScaleChannel.Frame?) {
            guard let frame else {
                if let previous = rulerScaleFrame { rulerScalePendingCommit = previous }
                rulerScaleFrame = nil
                // A changed scale reaches SwiftUI later; unchanged commits can reconcile now.
                guard let pending = rulerScalePendingCommit, rulerScaleCommitIsCurrent(pending), let map else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                defer { CATransaction.commit() }
                _ = updateRulerZoom(on: map, wasVisible: parent.scenePhase == .active
                    && parent.pageActive && parent.rulerZoomActive)
                alignMarkers(on: map)
                return
            }
            if rulerScaleFrame == nil { resetRulerScaleFits() }
            rulerScalePendingCommit = nil
            rulerScaleFrame = frame
            guard let map else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            defer { CATransaction.commit() }
            applyRulerScale(frame, on: map)
        }

        private var rulerFollowing: Bool {
            !interacting && (parent.replayActive
                ? parent.replayFollowing && !parent.replayOverview
                : parent.position.followsUserLocation && parent.replayRoute == nil)
        }

        private struct RulerFitSource {
            let identity: ObjectIdentifier
            let coordinates: [CLLocationCoordinate2D]
            let position: Double
            var coordinate: CLLocationCoordinate2D
        }

        private func rulerFitSource(on map: MKMapView) -> RulerFitSource? {
            if parent.replayActive {
                guard let route = parent.replayRoute, !route.coordinates.isEmpty,
                      let coordinate = parent.selected else { return nil }
                return RulerFitSource(identity: ObjectIdentifier(route), coordinates: route.coordinates,
                    position: parent.replayPosition, coordinate: coordinate)
            }
            guard let geometry = parent.liveRulerGeometry, !geometry.coordinates.isEmpty,
                  let coordinate = displayedLiveCoordinate ?? map.userLocation.location?.coordinate,
                  CLLocationCoordinate2DIsValid(coordinate) else { return nil }
            return RulerFitSource(identity: ObjectIdentifier(geometry), coordinates: geometry.coordinates,
                position: Double(geometry.coordinates.count - 1), coordinate: coordinate)
        }

        private func applyRulerPosition(on map: MKMapView) {
            if parent.replayActive { applyPosition(map, animated: false) }
            else { followUser(on: map, animated: false) }
        }

        private func applyRulerScale(_ frame: RulerScaleChannel.Frame, on map: MKMapView) {
            guard parent.scenePhase == .active, parent.pageActive, parent.rulerZoomActive,
                  rulerFollowing, !hasMapContact, var source = rulerFitSource(on: map) else { return }
            let bracket = frame.detents.bracket(at: frame.pointsPerBar)
            let step = min(bracket.upper, max(bracket.lower, frame.pointsPerBar))
            let zoom = frame.detents.zoom(step: step, width: frame.width)
            beginRulerZoom(on: map)
            scaledRuler = zoom
            // Freeze the live fit's anchor for the gesture; live motion still centers the dot every frame.
            if !parent.replayActive, let context = rulerScaleFitContext, context.route == source.identity {
                source.coordinate = CLLocationCoordinate2D(latitude: context.latitude, longitude: context.longitude)
            }
            rulerCoordinate = source.coordinate
            let context = RulerScaleFitContext(route: source.identity, position: source.position,
                latitude: source.coordinate.latitude, longitude: source.coordinate.longitude,
                steps: frame.detents.steps, width: frame.width, base: rulerBaseDistance, pitch: rulerPitch)
            if rulerScaleFitContext != context {
                resetRulerScaleFits()
                rulerScaleFitContext = context
            }
            rulerFitPosition = context.position
            rulerLiveFitID = parent.replayActive ? nil : parent.liveRulerGeometry?.pointIDs.last
            func distance(at step: Double) -> CLLocationDistance? {
                if let distance = rulerScaleDistances[step] { return distance }
                let zoom = frame.detents.zoom(step: step, width: frame.width)
                guard let distance = rulerZoomDistance(zoom, on: map, source: source) else { return nil }
                rulerScaleDistances[step] = distance
                rulerScaleZooms[step] = zoom
                rulerScaleFitCounts[step, default: 0] += 1
                return distance
            }
            guard let lower = distance(at: bracket.lower), let upper = distance(at: bracket.upper) else { return }
            stopCameraTransition()
            stopRulerZoom()
            rulerDistance = bracket.distance(lower: lower, upper: upper)
            applyRulerPosition(on: map)
            alignMarkers(on: map)
        }

        private func beginRulerZoom(on map: MKMapView) {
            guard scaledRuler == nil else { return }
            rulerRestoreGeneration &+= 1
            rulerPitch = Double(map.camera.pitch)
            if parent.replayActive {
                rulerBaseDistance = parent.replayFollowDistance ?? map.camera.centerCoordinateDistance
            } else {
                let base = liveRulerBaseDistance ?? replayLiveDistance
                    ?? (hasInitialCamera ? cameraDestination?.distance ?? map.camera.centerCoordinateDistance : 2_000)
                liveRulerBaseDistance = base
                rulerBaseDistance = base
            }
            rulerDistance = map.camera.centerCoordinateDistance
            rulerFitPosition = nil
            rulerLiveFitID = nil
            rulerZoomWasSuspended = false
            stopCameraTransition()
        }

        private func rulerZoomDistance(_ zoom: ReplayRulerHold, on map: MKMapView,
                                       source supplied: RulerFitSource? = nil) -> CLLocationDistance? {
            guard let source = supplied ?? rulerFitSource(on: map), let base = rulerBaseDistance else { return nil }
            let coordinate = source.coordinate
            if zoom.pointsPerBar <= 1 {
                return ReplayHoldZoom.distance(base: base, pointsPerBar: zoom.pointsPerBar, fitted: nil)
            }
            var fit: CLLocationDistance?
            if let bounds = ReplayHoldZoom.bounds(in: source.coordinates,
                    window: zoom.window(at: source.position, count: source.coordinates.count), anchor: coordinate) {
                fit = ReplayHoldZoom.fittedDistance(bounds: bounds, anchor: coordinate, base: base, on: map,
                    clearRect: NativeMapSurface.replayClearRect(on: map), anchorPoint: NativeMapSurface.visibleCenter(on: map),
                    pitch: rulerPitch, projection: rulerProjection)
            }
            return ReplayHoldZoom.distance(base: base, pointsPerBar: zoom.pointsPerBar, fitted: fit)
        }

        private func cachedRulerScaleDistance(for zoom: ReplayRulerHold, source: RulerFitSource) -> CLLocationDistance? {
            guard let context = rulerScaleFitContext, context.route == source.identity,
                  context.position == source.position,
                  (!parent.replayActive || (context.latitude == source.coordinate.latitude
                    && context.longitude == source.coordinate.longitude)), context.base == rulerBaseDistance,
                  context.pitch == rulerPitch, rulerScaleZooms[zoom.pointsPerBar] == zoom else { return nil }
            return rulerScaleDistances[zoom.pointsPerBar]
        }

        private func rulerScaleCommitIsCurrent(_ frame: RulerScaleChannel.Frame) -> Bool {
            (parent.rulerZoom?.pointsPerBar ?? 1) == frame.detents.nearestStep(to: frame.pointsPerBar)
        }

        private func updateRulerZoom(on map: MKMapView, wasVisible: Bool, liveFlight: Bool = false) -> Bool {
            let visible = parent.scenePhase == .active && parent.pageActive && parent.rulerZoomActive
            let following = rulerFollowing
            if let frame = rulerScaleFrame, visible, following,
               rulerFitSource(on: map) != nil {
                applyRulerScale(frame, on: map)
                return false
            }
            if rulerScalePendingCommit != nil, visible, following, hasMapContact { return false }
            defer {
                rulerScalePendingCommit = nil
                resetRulerScaleFits()
            }
            let source = rulerFitSource(on: map)
            let zoom = visible && following && source != nil ? parent.rulerZoom : nil
            guard let zoom else {
                if !parent.replayActive, parent.rulerZoomActive, parent.rulerZoom == nil, rulerScaleFrame == nil {
                    liveRulerBaseDistance = nil
                }
                guard scaledRuler != nil, let base = rulerBaseDistance else { return false }
                let finishedAtBase = rulerScalePendingCommit.map {
                    let bracket = $0.detents.bracket(at: $0.pointsPerBar)
                    return bracket.lower == 1 && bracket.upper == 1
                        && abs(log(max(1, map.camera.centerCoordinateDistance) / max(1, base))) <= 0.0001
                } ?? false
                stopRulerZoom()
                scaledRuler = nil
                rulerBaseDistance = nil
                let pitch = rulerPitch
                rulerPitch = nil
                rulerRestoreGeneration &+= 1
                rulerDistance = nil
                rulerFitPosition = nil
                rulerLiveFitID = nil
                let coordinate = rulerCoordinate
                rulerCoordinate = nil
                if !visible { rulerZoomWasSuspended = true }
                guard !visible || following, let coordinate else { return false }
                var destination = MapCamera(map.camera)
                destination.centerCoordinate = parent.replayActive ? parent.selected ?? coordinate
                    : displayedLiveCoordinate ?? map.userLocation.location?.coordinate ?? coordinate
                destination.distance = base
                if parent.replayActive { destination.pitch = pitch ?? destination.pitch }
                request = parent.replayActive ? .camera(destination) : .follow
                if finishedAtBase, visible, following {
                    stopCameraTransition()
                } else if !visible {
                    stopCameraTransition()
                    setCamera(destination, on: map, animated: false)
                } else {
                    startCameraTransition(to: destination, on: map, zoom: !parent.replayActive,
                                          keepsCentering: !parent.replayActive)
                }
                reportRulerRestore(destination, base: base)
                return following
            }
            let starting = scaledRuler == nil
            let immediate = starting && (rulerZoomWasSuspended || !wasVisible || liveFlight)
            beginRulerZoom(on: map)
            if scaledRuler != zoom {
                rulerFitPosition = nil
                rulerLiveFitID = nil
                scaledRuler = zoom
            }
            guard let source else { return false }
            rulerCoordinate = source.coordinate
            guard !hasMapContact else { return false }
            if parent.replayActive {
                guard zoom.needsFit(at: source.position, since: rulerFitPosition) else { return false }
            } else if rulerFitPosition != nil, let id = rulerLiveFitID,
                      let previous = parent.liveRulerGeometry?.pointIDs.firstIndex(of: id) {
                guard source.position - Double(previous) > zoom.halfWindow else { return false }
            }
            rulerFitPosition = source.position
            rulerLiveFitID = parent.replayActive ? nil : parent.liveRulerGeometry?.pointIDs.last
            guard let distance = cachedRulerScaleDistance(for: zoom, source: source)
                ?? rulerZoomDistance(zoom, on: map, source: source) else { return false }
            if immediate {
                stopRulerZoom()
                rulerDistance = distance
            } else {
                easeRulerDistance(to: distance, on: map)
            }
            if !parent.replayActive, !liveFlight { followUser(on: map, animated: false) }
            return false
        }

        private func reportRulerRestore(_ camera: MapCamera, base: CLLocationDistance) {
            let generation = rulerRestoreGeneration
            DispatchQueue.main.async { [weak self] in
                guard let self, self.rulerRestoreGeneration == generation, self.scaledRuler == nil else { return }
                var current = camera
                if self.parent.replayActive, self.parent.replayFollowing, !self.parent.replayOverview,
                   let selected = self.parent.selected { current.centerCoordinate = selected }
                else if !self.parent.replayActive, self.parent.position.followsUserLocation,
                        let coordinate = self.displayedLiveCoordinate ?? self.map?.userLocation.location?.coordinate {
                    current.centerCoordinate = coordinate
                }
                self.parent.onRulerCameraRestore(current, base)
            }
        }

        private func easeRulerDistance(to distance: CLLocationDistance, on map: MKMapView) {
            let current = map.camera.centerCoordinateDistance
            stopCameraTransition()
            stopRulerZoom()
            rulerDistance = current
            guard !UIAccessibility.isReduceMotionEnabled, abs(log(max(1, distance) / max(1, current))) > 0.0001 else {
                rulerDistance = distance
                return
            }
            rulerDistanceEase = ReplayHoldDistanceEase(from: current, to: distance, start: CACurrentMediaTime())
            let target = RulerZoomFrameTarget(coordinator: self)
            let link = CADisplayLink(target: target, selector: #selector(RulerZoomFrameTarget.frame(_:)))
            let maximum = Float(map.window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
            link.add(to: .main, forMode: .common)
            rulerZoomLink = link
        }

        func advanceRulerZoom(at time: TimeInterval) {
            guard let map, let ease = rulerDistanceEase, scaledRuler != nil,
                  parent.scenePhase == .active, parent.pageActive, parent.rulerZoomActive,
                  rulerFollowing else { stopRulerZoom(); return }
            guard !hasMapContact else { return }
            rulerDistance = UIAccessibility.isReduceMotionEnabled ? ease.to : ease.distance(at: time)
            applyRulerPosition(on: map)
            alignMarkers(on: map)
            if UIAccessibility.isReduceMotionEnabled || ease.progress(at: time) == 1 { stopRulerZoom() }
        }

        func stopRulerZoom() {
            rulerZoomLink?.invalidate()
            rulerZoomLink = nil
            rulerDistanceEase = nil
            rulerContactTime = nil
        }

        func stopCameraTransition() {
            cameraDisplayLink?.invalidate()
            cameraDisplayLink = nil
            cameraTransition = nil
            cameraClockPending = false
            cameraContactTime = nil
            cameraDestination = nil
            cameraActionAnimating = false
            cameraZooming = false
            cameraFlight = false
            zoomKeepsCentering = false
            endMarkerGlide()
        }

        private func endMarkerGlide() {
            guard markerGlide != nil else { return }
            markerGlide = nil
            guard let selectedPoint else { return }
            if let coordinate = parent.selected { UIView.performWithoutAnimation { selectedPoint.coordinate = coordinate } }
            map?.view(for: selectedPoint)?.layer.sublayerTransform = CATransform3DIdentity
        }

        // Growing out of the live dot, the marker's balloon starts at the dot's size where the dot was. It scales the
        // view's sublayers, leaving the annotation view's own transform to MapKit.
        private func markerTransform(_ view: MKAnnotationView) -> CGAffineTransform {
            guard let glide = markerGlide, glide.live, glide.growth < 1, view.bounds.width > 0 else { return .identity }
            let grown = CGFloat(glide.growth * glide.growth * (3 - 2 * glide.growth))
            let small = min(1, 20 / view.bounds.width)
            let scale = small + (1 - small) * grown
            // The balloon's circle fills the top of the view; the coordinate sits at -centerOffset from its center.
            let balloon = view.bounds.width / 2 - view.bounds.height / 2
            return CGAffineTransform(translationX: -view.centerOffset.x * (1 - grown),
                                     y: (-view.centerOffset.y - small * balloon) * (1 - grown))
                .scaledBy(x: scale, y: scale)
        }

        func zoom(inward: Bool, on map: MKMapView) -> MapZoomResult? {
            let previousGoal = cameraZooming ? cameraDestination?.distance : nil
            return moveCamera(on: map, distance: MapZoom.distance(from: previousGoal ?? map.camera.centerCoordinateDistance,
                                                                  inward: inward), heading: nil)
        }

        func faceNorth(on map: MKMapView) -> MapZoomResult? {
            let goal = cameraZooming ? cameraDestination?.distance : nil
            return moveCamera(on: map, distance: goal ?? map.camera.centerCoordinateDistance, heading: 0)
        }

        private func moveCamera(on map: MKMapView, distance: CLLocationDistance, heading: CLLocationDirection?) -> MapZoomResult? {
            guard parent.sceneVisible, parent.pageActive else { return nil }
            rulerRestoreGeneration &+= 1
            if scaledRuler != nil {
                stopRulerZoom()
                rulerDistance = distance
            }
            let wasInteracting = interacting
            revision += 1
            interacting = false
            if parent.replayActive {
                parent.replayFollowing = !replayDetached && !wasInteracting
                parent.replayOverview = false
                if scaledRuler == nil { parent.replayFollowDistance = distance }
            }
            var destination = MapCamera(map.camera)
            destination.distance = distance
            if let heading { destination.heading = heading }
            let anchor = zoomAnchor(on: map)
            if let anchor { destination.centerCoordinate = anchor }
            if scaledRuler == nil, !parent.position.followsUserLocation { parent.position = .camera(destination) }
            request = parent.position.followsUserLocation ? .follow : .camera(destination)
            let point = anchor.map { map.convert($0, toPointTo: map) }
            let center = NativeMapSurface.visibleCenter(on: map)
            let centered = point.map { hypot($0.x - center.x, $0.y - center.y) < 2 } ?? false
            startCameraTransition(to: destination, on: map, zoom: true, keepsCentering: centered)
            return MapZoomResult(camera: destination, replayFollowing: parent.replayFollowing)
        }

        private func zoomAnchor(on map: MKMapView) -> CLLocationCoordinate2D? {
            if parent.replayActive { return parent.replayFollowing ? parent.selected : nil }
            if parent.position.followsUserLocation {
                return displayedLiveCoordinate ?? map.userLocation.location?.coordinate
            }
            return parent.selected
        }

        private func startCameraTransition(to destination: MapCamera, on map: MKMapView,
                                           zoom: Bool = false, keepsCentering: Bool = false, flight: Bool = false,
                                           clockOnFirstFrame: Bool = false) {
            stopCameraTransition()
            cameraClockPending = clockOnFirstFrame
            anchorCoordinate = nil
            correctionsRemaining = 0
            hasInitialCamera = true
            cameraDestination = destination
            if parent.replayOverview { overviewViewport = (map.bounds, map.safeAreaInsets) }
            cameraZooming = zoom
            cameraFlight = flight
            zoomKeepsCentering = keepsCentering
            let anchored = zoom ? zoomAnchor(on: map) != nil : !replayDetached && !parent.replayOverview
            let start = CACurrentMediaTime()
            let from = MapCamera(map.camera)
            let to = anchored ? MapCamera(anchoredCamera(destination, on: map)) : destination
            if flight, let scale = mapScale(on: map) {
                cameraTransition = .flight(from: from, to: to, start: start, width: scale.pointsPerPoint * Double(map.bounds.width))
            } else {
                cameraTransition = MapCameraTransition(from: from, to: to, start: start,
                                                       length: zoom ? MapZoom.duration : MapCameraTransition.duration)
            }
            if hasMapContact { cameraContactTime = start }
            cameraActionAnimating = true
            if UIAccessibility.isReduceMotionEnabled, let transition = cameraTransition {
                advanceCameraTransition(at: transition.start + transition.length)
                return
            }
            let target = CameraFrameTarget(coordinator: self)
            let link = CADisplayLink(target: target, selector: #selector(CameraFrameTarget.frame(_:)))
            let maximum = Float(map.window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
            link.add(to: .main, forMode: .common)
            cameraDisplayLink = link
        }

        func advanceCameraTransition(at time: TimeInterval) {
            guard let map, var transition = cameraTransition, var destination = cameraDestination,
                  parent.sceneVisible, parent.pageActive, !interacting else {
                stopCameraTransition()
                return
            }
            guard !hasMapContact || UIAccessibility.isReduceMotionEnabled else { return }
            if cameraClockPending, !UIAccessibility.isReduceMotionEnabled {
                cameraClockPending = false
                transition.start = time
                cameraTransition = transition
            }
            // A flight to the live location keeps aiming at it as it moves; one to an opened trip keeps the trip's fit.
            let focusCoordinate = cameraZooming || (cameraFlight && !parent.replayOverview) ? zoomAnchor(on: map) : nil
            if let focusCoordinate {
                destination.centerCoordinate = focusCoordinate
            } else if !cameraZooming, !replayDetached, !parent.replayOverview, let coordinate = parent.selected {
                destination.centerCoordinate = coordinate
            }
            if let heading = followedHeading { destination.heading = heading }
            let anchored = cameraZooming ? focusCoordinate != nil : !replayDetached && !parent.replayOverview
            transition.to = anchored ? MapCamera(anchoredCamera(destination, on: map)) : destination
            cameraTransition = transition
            let end = UIAccessibility.isReduceMotionEnabled ? transition.start + transition.length : time
            var camera = transition.camera(at: end)
            if cameraZooming && zoomKeepsCentering, let focusCoordinate {
                camera.centerCoordinate = focusCoordinate
                camera = MapCamera(anchoredCamera(camera, on: map))
                anchorCoordinate = focusCoordinate
                correctionsRemaining = 6
            }
            revision += 1
            UIView.performWithoutAnimation { map.setCamera(MKMapCamera(camera), animated: false) }
            if var glide = markerGlide, let selectedPoint, let target = parent.selected {
                // The marker covers the same share of its way as the camera's center, so it stays in view.
                let coordinate = ReplayCoordinate(glide.from).interpolated(to: ReplayCoordinate(target),
                                                                           fraction: transition.travel(at: end)).coordinate
                UIView.performWithoutAnimation { selectedPoint.coordinate = coordinate }
                if glide.live { glide.growth = min(1, max(0, (end - transition.start) / 0.45)) }
                markerGlide = glide
            }
            alignMarkers(on: map)
            if transition.progress(at: end) == 1 {
                let overview = parent.replayOverview
                let wasZooming = cameraZooming || cameraFlight
                stopCameraTransition()
                if wasZooming {
                    anchorCoordinate = focusCoordinate
                    correctionsRemaining = focusCoordinate == nil ? 0 : 6
                    alignAnchor(on: map)
                } else if !overview && !replayDetached {
                    anchorCoordinate = destination.centerCoordinate
                }
                if revealedHighlight != parent.replayHighlight { alignMarkers(on: map) }
            }
        }

        fileprivate func replayOverviewCamera(on map: MKMapView) -> MapCamera? {
            guard let route = replayRoute else { return nil }
            let clear = NativeMapSurface.replayClearRect(on: map)
            let highlight = parent.replayFitRange.flatMap { range in
                range.upperBound < route.coordinates.count ? range : nil
            }
            if let fit = overviewFit, fit.route == ObjectIdentifier(route), fit.highlight == highlight, fit.bounds == map.bounds,
               fit.clear == clear, fit.heading == map.camera.heading, fit.pitch == map.camera.pitch,
               fit.type == map.mapType { return fit.camera }
            // An opened trip fits only its own fixes.
            let coordinates = highlight.map { Array(route.coordinates[$0]) } ?? route.coordinates
            guard let camera = ReplayOverviewFit.camera(for: coordinates, on: map, clearRect: clear) else { return nil }
            overviewFit = (ObjectIdentifier(route), highlight, map.bounds, clear, map.camera.heading, map.camera.pitch,
                           map.mapType, camera)
            return camera
        }

        private func highlightCoverage(_ route: MKPolyline) -> ReplayRoutePresentation.Coverage? {
            guard let range = parent.replayHighlight, range.lowerBound >= 0, range.upperBound < route.pointCount else {
                highlightBounds = nil
                return nil
            }
            let id = ObjectIdentifier(route)
            if highlightBounds?.route != id || highlightBounds?.range != range {
                var minX = Double.infinity, minY = Double.infinity, maxX = -Double.infinity, maxY = -Double.infinity
                for index in range {
                    let point = route.points()[index]
                    minX = min(minX, point.x); maxX = max(maxX, point.x)
                    minY = min(minY, point.y); maxY = max(maxY, point.y)
                }
                highlightBounds = (id, range, CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
            }
            return ReplayRoutePresentation.Coverage(start: range.lowerBound, end: range.upperBound, prefix: false,
                                                    marker: false, bounds: highlightBounds?.bounds ?? .zero)
        }

        // Map points per screen point in the middle of the map, and the coordinate there.
        private func mapScale(on map: MKMapView) -> (center: CLLocationCoordinate2D, pointsPerPoint: Double)? {
            let mid = CGPoint(x: map.bounds.midX, y: map.bounds.midY)
            let a = MKMapPoint(map.convert(mid, toCoordinateFrom: map))
            let b = MKMapPoint(map.convert(CGPoint(x: mid.x + 1, y: mid.y), toCoordinateFrom: map))
            var dx = b.x - a.x
            dx -= (dx / MKMapRect.world.width).rounded() * MKMapRect.world.width
            let pointsPerPoint = hypot(dx, b.y - a.y)
            guard pointsPerPoint > 0, pointsPerPoint.isFinite else { return nil }
            return (a.coordinate, pointsPerPoint)
        }

        private func fitReplayRoute(on map: MKMapView, animated: Bool) {
            guard let camera = replayOverviewCamera(on: map) else { return }
            map.setCamera(MKMapCamera(camera), animated: animated)
            overviewViewport = (map.bounds, map.safeAreaInsets)
        }

        private func setCamera(_ camera: MapCamera, on map: MKMapView, animated: Bool) {
            if replayDetached {
                anchorCoordinate = nil
                correctionsRemaining = 0
                hasInitialCamera = true
                map.setCamera(MKMapCamera(camera), animated: animated)
                return
            }
            let center = parent.selected ?? camera.centerCoordinate
            anchorCoordinate = center
            correctionsRemaining = 6
            hasInitialCamera = true
            var target = camera
            target.centerCoordinate = center
            map.setCamera(anchoredCamera(target, on: map), animated: animated)
            if !animated { alignAnchor(on: map) }
        }

        private func anchoredCamera(_ camera: MapCamera, on map: MKMapView) -> MKMapCamera {
            let center = camera.centerCoordinate
            let next = MKMapCamera(lookingAtCenter: center, fromDistance: camera.distance,
                                   pitch: CGFloat(camera.pitch), heading: camera.heading)
            let previous = MapCamera(map.camera)
            if map.bounds.width > 0, map.bounds.height > 0, previous.distance > 1,
               abs(previous.pitch - camera.pitch) < 0.1 {
                let middle = map.convert(NativeMapSurface.cameraCenter(on: map), toCoordinateFrom: map)
                let target = map.convert(NativeMapSurface.visibleCenter(on: map), toCoordinateFrom: map)
                let scale = camera.distance / previous.distance
                    * MKMapPointsPerMeterAtLatitude(center.latitude) / MKMapPointsPerMeterAtLatitude(middle.latitude)
                if CLLocationCoordinate2DIsValid(middle), CLLocationCoordinate2DIsValid(target), scale.isFinite {
                    // Apply the visible-area offset before starting an animation, avoiding a second pan afterward.
                    next.centerCoordinate = MapViewport.anchoredCenter(center, projectionCenter: middle,
                        projectionTarget: target, scale: scale, rotation: (camera.heading - previous.heading) * .pi / 180)
                }
            }
            return next
        }

        func viewportChanged(on map: MKMapView) {
            guard parent.sceneVisible, parent.pageActive, !interacting, !cameraActionAnimating, !hasMapContact else { return }
            if parent.replayOverview {
                if overviewViewport?.bounds != map.bounds || overviewViewport?.safeArea != map.safeAreaInsets {
                    revision += 1
                    fitReplayRoute(on: map, animated: false)
                }
                return
            }
            guard anchorCoordinate != nil else { return }
            revision += 1
            correctionsRemaining = 6
            alignAnchor(on: map)
        }

        private func alignAnchor(on map: MKMapView) {
            guard !aligning, !interacting, !hasMapContact, correctionsRemaining > 0,
                  parent.sceneVisible, parent.pageActive, let anchorCoordinate,
                  let map = map as? AttributionMapView, map.bounds.width > 0, map.bounds.height > 0 else { return }
            let target = map.visibleCenter
            let point = map.convert(anchorCoordinate, toPointTo: map)
            guard point.x.isFinite, point.y.isFinite else { return }
            guard hypot(point.x - target.x, point.y - target.y) > 0.5 else {
                correctionsRemaining = 0
                return
            }
            let projectionCenter = map.convert(NativeMapSurface.cameraCenter(on: map), toCoordinateFrom: map)
            let projectionTarget = map.convert(target, toCoordinateFrom: map)
            guard CLLocationCoordinate2DIsValid(projectionCenter),
                  CLLocationCoordinate2DIsValid(projectionTarget) else { return }
            correctionsRemaining -= 1
            let camera = map.camera.copy() as! MKMapCamera
            // The model camera can lead MapKit's rendered projection. Never add an offset to that camera.
            camera.centerCoordinate = MapViewport.anchoredCenter(anchorCoordinate, projectionCenter: projectionCenter,
                                                                projectionTarget: projectionTarget)
            aligning = true
            map.setCamera(camera, animated: false)
            aligning = false
        }

        private func followUser(on map: MKMapView, animated: Bool) {
            // MapKit can report a fix while `update` runs, before it applies the follow request; that
            // request decides whether to fly there.
            guard parent.sceneVisible, parent.pageActive, !parent.replayOverview, !cameraActionAnimating,
                  parent.position.followsUserLocation, request == .follow, !interacting, !hasMapContact,
                  let coordinate = displayedLiveCoordinate ?? map.userLocation.location?.coordinate,
                  CLLocationCoordinate2DIsValid(coordinate) else { return }
            let heading = followedHeading
            let distance = rulerDistance ?? replayLiveDistance
            replayLiveDistance = nil
            if flyToUser {
                flyToUser = false
                var destination = MapCamera(map.camera)
                destination.centerCoordinate = coordinate
                if let distance { destination.distance = distance }
                if let heading { destination.heading = heading }
                startCameraTransition(to: destination, on: map, flight: true)
                return
            }
            if followingInitialized,
               distance.map({ abs($0 - map.camera.centerCoordinateDistance) < 0.001 }) ?? true,
               heading.map({ abs(remainder($0 - map.camera.heading, 360)) < 0.01 }) ?? true {
                let point = map.convert(coordinate, toPointTo: map)
                let target = NativeMapSurface.visibleCenter(on: map)
                if hypot(point.x - target.x, point.y - target.y) < 0.1 {
                    anchorCoordinate = coordinate
                    correctionsRemaining = 0
                    return
                }
            }
            var camera = MapCamera(map.camera)
            camera.centerCoordinate = coordinate
            if let distance { camera.distance = distance }
            if let heading { camera.heading = heading }
            if !hasInitialCamera { camera.distance = distance ?? 2_000 }
            followingInitialized = true
            revision += 1
            setCamera(camera, on: map, animated: animated)
        }

        func stopLiveMotion() {
            liveDisplayLink?.invalidate()
            liveDisplayLink = nil
            liveMotion = LiveMapMotion()
            displayedLiveCoordinate = nil
            latestLiveTimestamp = nil
        }

        func receiveLiveLocation(_ location: CLLocation, on map: MKMapView) {
            guard parent.sceneVisible, parent.pageActive, map.showsUserLocation else { return }
            if let latestLiveTimestamp, location.timestamp < latestLiveTimestamp { return }
            latestLiveTimestamp = location.timestamp
            if UIAccessibility.isReduceMotionEnabled {
                liveDisplayLink?.invalidate()
                liveDisplayLink = nil
                liveMotion = LiveMapMotion()
                _ = liveMotion.receive(location.coordinate, at: CACurrentMediaTime())
                displayedLiveCoordinate = liveMotion.coordinate
                _ = updateRulerZoom(on: map, wasVisible: true, liveFlight: flyToUser || request != .follow)
                followUser(on: map, animated: false)
                alignMarkers(on: map)
                return
            }
            let first = liveMotion.point == nil
            let moving = liveMotion.receive(location.coordinate, at: CACurrentMediaTime())
            if first {
                displayedLiveCoordinate = location.coordinate
                _ = updateRulerZoom(on: map, wasVisible: true, liveFlight: flyToUser || request != .follow)
                followUser(on: map, animated: false)
            } else if moving, liveDisplayLink == nil {
                let target = CameraFrameTarget(coordinator: self, kind: .live)
                let link = CADisplayLink(target: target, selector: #selector(CameraFrameTarget.frame(_:)))
                let maximum = Float(map.window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
                link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
                link.add(to: .main, forMode: .common)
                liveDisplayLink = link
            }
            alignMarkers(on: map)
        }

        fileprivate func advanceLiveLocation(at time: TimeInterval) {
            guard let map, parent.sceneVisible, parent.pageActive, map.showsUserLocation else {
                stopLiveMotion()
                return
            }
            liveMotion.advance(at: time)
            let tolerance = max(0.001, map.visibleMapRect.width / max(1, Double(map.bounds.width)) * 0.1)
            let finished = UIAccessibility.isReduceMotionEnabled || liveMotion.settled(at: time, tolerance: tolerance)
            if finished { liveMotion.finish() }
            displayedLiveCoordinate = liveMotion.coordinate
            followUser(on: map, animated: false)
            alignMarkers(on: map)
            if finished {
                liveDisplayLink?.invalidate()
                liveDisplayLink = nil
            }
        }

        // Heading mode, as in Find My: while following, the map turns with the direction the phone faces.
        private var headingModeActive: Bool {
            parent.position.followsUserLocation && parent.position.followsUserHeading && parent.trackingEnabled
                && parent.scenePhase == .active
                && parent.pageActive && !parent.replayActive && parent.replayRoute == nil
        }

        private var followedHeading: CLLocationDirection? {
            guard headingModeActive, let angle = mapHeading.angle else { return nil }
            let degrees = (angle * 180 / .pi).truncatingRemainder(dividingBy: 360)
            return degrees < 0 ? degrees + 360 : degrees
        }

        private func updateHeadingMode(on map: MKMapView) {
            let active = headingModeActive
            liveHeading.update(tracking: parent.trackingEnabled, sceneActive: parent.scenePhase == .active,
                               mapVisible: parent.pageActive, showsLiveLocation: map.showsUserLocation,
                               orientation: map.window?.windowScene?.interfaceOrientation ?? .portrait)
            guard active != followingHeading else { return }
            followingHeading = active
            if active {
                if let reading = liveHeading.reading { receiveDeviceHeading(reading.degrees) }
                return
            }
            stopMapHeading()
            // Leaving heading mode while still following turns the map back to north.
            if parent.position.followsUserLocation, !parent.position.followsUserHeading, parent.sceneVisible, parent.pageActive,
               !parent.replayActive, parent.replayRoute == nil, NativeMapSurface.isRotated(heading: map.camera.heading) {
                _ = faceNorth(on: map)
            }
        }

        func stopHeadingMode() {
            liveHeading.stop()
            stopMapHeading()
            followingHeading = false
        }

        private func stopMapHeading() {
            mapHeadingDisplayLink?.invalidate()
            mapHeadingDisplayLink = nil
            mapHeading = HeadingMotion(response: 9)
        }

        func receiveDeviceHeading(_ degrees: CLLocationDirection, at time: TimeInterval = CACurrentMediaTime()) {
            guard let map, headingModeActive, degrees.isFinite else { return }
            // Start from the map's own heading, so entering heading mode turns smoothly.
            if mapHeading.angle == nil { mapHeading.receive(map.camera.heading * .pi / 180, at: time) }
            mapHeading.receive(degrees * .pi / 180, at: time)
            if UIAccessibility.isReduceMotionEnabled {
                mapHeading.finish()
                if !cameraActionAnimating { followUser(on: map, animated: false) }
                return
            }
            guard mapHeadingDisplayLink == nil else { return }
            let target = CameraFrameTarget(coordinator: self, kind: .heading)
            let link = CADisplayLink(target: target, selector: #selector(CameraFrameTarget.frame(_:)))
            let maximum = Float(map.window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
            link.add(to: .main, forMode: .common)
            mapHeadingDisplayLink = link
        }

        func advanceMapHeading(at time: TimeInterval) {
            guard let map, headingModeActive else {
                mapHeadingDisplayLink?.invalidate()
                mapHeadingDisplayLink = nil
                return
            }
            mapHeading.advance(at: time)
            let settled = UIAccessibility.isReduceMotionEnabled || mapHeading.settled
            if settled { mapHeading.finish() }
            // A running flight or zoom applies the heading itself.
            if !cameraActionAnimating { followUser(on: map, animated: false) }
            if settled {
                mapHeadingDisplayLink?.invalidate()
                mapHeadingDisplayLink = nil
            }
        }

        func mapContactChanged(_ active: Bool, at time: TimeInterval = CACurrentMediaTime()) {
            guard hasMapContact != active else { return }
            hasMapContact = active
            if active {
                rulerContactTime = rulerDistanceEase == nil ? nil : time
                cameraContactTime = cameraTransition == nil ? nil : time
            } else if let paused = cameraContactTime, let transition = cameraTransition {
                cameraTransition = MapCameraTransition(from: transition.from, to: transition.to,
                    start: transition.start + max(0, time - paused), length: transition.length,
                    flightWidth: transition.flightWidth)
            }
            if !active {
                if let paused = rulerContactTime, let ease = rulerDistanceEase {
                    rulerDistanceEase = ReplayHoldDistanceEase(from: ease.from, to: ease.to,
                                                               start: ease.start + max(0, time - paused))
                }
                rulerContactTime = nil
                cameraContactTime = nil
            }
            // A tap resumes following; a recognized pan retains its own camera and deferred delegate commit.
            guard !active, !interacting, !cameraActionAnimating, parent.sceneVisible, parent.pageActive,
                  let map else { return }
            if scaledRuler != nil {
                _ = updateRulerZoom(on: map, wasVisible: true)
                applyPosition(map, animated: false)
            } else if parent.position.followsUserLocation { followUser(on: map, animated: false) }
            else { viewportChanged(on: map) }
        }

        func clearMapContact() {
            hasMapContact = false
            cameraContactTime = nil
            rulerContactTime = nil
        }

        func observeGestures(in view: UIView) {
            for gesture in view.gestureRecognizers ?? [] {
                let tap = gesture as? UITapGestureRecognizer
                let changesCamera = gesture is UIPanGestureRecognizer || gesture is UIPinchGestureRecognizer
                    || gesture is UIRotationGestureRecognizer
                    || (tap.map { $0.numberOfTapsRequired > 1 || $0.numberOfTouchesRequired > 1 } ?? false)
                if changesCamera, observedGestures.insert(ObjectIdentifier(gesture)).inserted {
                    gesture.addTarget(self, action: #selector(gestureChanged(_:)))
                }
            }
            for child in view.subviews { observeGestures(in: child) }
        }

        private func hasActiveGesture(in view: UIView) -> Bool {
            if (view.gestureRecognizers ?? []).contains(where: { $0.state == .began || $0.state == .changed }) {
                return true
            }
            return view.subviews.contains { hasActiveGesture(in: $0) }
        }

        @objc func gestureChanged(_ gesture: UIGestureRecognizer) {
            if gesture.state == .began || gesture.state == .changed
                || (gesture is UITapGestureRecognizer && gesture.state == .ended) {
                beginInteraction()
            }
            // MapKit can report the last region while the finger is still down, and nothing after a
            // gesture that stops without decelerating.
            if gesture.state == .ended || gesture.state == .cancelled, let map { commitWhenSettled(map) }
        }

        private func commitWhenSettled(_ map: MKMapView) {
            let displayed = MapCamera(map.camera)
            let currentRevision = revision
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self, weak map] in
                // A map still decelerating reports through regionDidChange when it stops.
                guard let self, let map, self.interacting, self.revision == currentRevision,
                      !self.hasActiveGesture(in: map), MapCamera(map.camera) == displayed else { return }
                self.commitUserCamera(displayed)
            }
        }

        private func commitUserCamera(_ camera: MapCamera) {
            interacting = false
            request = .camera(camera)
            parent.position = .camera(camera)
            parent.onCameraChange(camera, true)
        }

        private func beginInteraction() {
            rulerRestoreGeneration &+= 1
            stopRulerZoom()
            rulerDistance = nil
            stopCameraTransition()
            flyToUser = false
            guard !interacting else { return }
            interacting = true
            anchorCoordinate = nil
            correctionsRemaining = 0
            revision += 1
            let currentRevision = revision
            DispatchQueue.main.async { [weak self] in
                guard let self, self.revision == currentRevision else { return }
                self.parent.onInteraction()
            }
        }

        func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
            observeGestures(in: mapView)
            if hasActiveGesture(in: mapView) { beginInteraction() }
        }

        func mapViewDidChangeVisibleRegion(_ mapView: MKMapView) {
            let camera = MapCamera(mapView.camera)
            if let previous = replayRenderCamera,
               previous.distance != camera.distance || previous.pitch != camera.pitch || previous.heading != camera.heading {
                replayPresentation?.coverDuringCameraChange()
            }
            replayRenderCamera = camera
            alignMarkers(on: mapView)
            // Reported only when it changes, not every frame.
            let rotated = NativeMapSurface.isRotated(heading: mapView.camera.heading)
            guard rotated != mapRotated else { return }
            mapRotated = rotated
            let report = parent.onRotationChange
            DispatchQueue.main.async { report(rotated) }
        }

        func mapViewWillStartRenderingMap(_ mapView: MKMapView) {
            replayPresentation?.renderingBegan()
        }

        func mapViewDidFinishRenderingMap(_ mapView: MKMapView, fullyRendered: Bool) {
            replayPresentation?.renderingFinished(fullyRendered: fullyRendered)
            alignMarkers(on: mapView)
        }

        func mapView(_ mapView: MKMapView, regionDidChangeAnimated animated: Bool) {
            guard !hasActiveGesture(in: mapView) else {
                beginInteraction()
                return
            }
            if cameraActionAnimating || (scaledRuler != nil && !interacting) {
                return
            }
            if !interacting, correctionsRemaining > 0 {
                let before = MapCamera(mapView.camera)
                alignAnchor(on: mapView)
                if MapCamera(mapView.camera) != before { return }
            }
            let byUser = interacting
            let displayed = MapCamera(mapView.camera)
            var camera = displayed
            if !byUser, let anchorCoordinate { camera.centerCoordinate = anchorCoordinate }
            let reported = camera
            let currentRevision = revision
            DispatchQueue.main.async { [weak self, weak mapView] in
                guard let self, let mapView, self.revision == currentRevision,
                      !self.hasActiveGesture(in: mapView), MapCamera(mapView.camera) == displayed else { return }
                if byUser {
                    guard self.interacting else { return }
                    self.commitUserCamera(reported)
                    return
                }
                guard !self.interacting else { return }
                self.parent.onCameraChange(reported, byUser)
            }
        }

        func mapView(_ mapView: MKMapView, didUpdate userLocation: MKUserLocation) {
            if let location = userLocation.location { receiveLiveLocation(location, on: mapView) }
        }

        func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
            if let presentation = replayPresentation, presentation.contains(overlay),
               let renderer = presentation.renderer(for: overlay) { return renderer }
            // A deferred renderer request for a removed replay line must not fall back to blue.
            guard let line = overlay as? MKPolyline, line === tripLine else { return MKOverlayRenderer(overlay: overlay) }
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.lineCap = .round
            renderer.lineJoin = .round
            renderer.strokeColor = .systemBlue
            renderer.lineWidth = ReplayRouteStyle.pastWidth
            return renderer
        }

        func mapView(_ mapView: MKMapView, didAdd views: [MKAnnotationView]) {
            for view in views where view.annotation is MKUserLocation {
                view.accessibilityIdentifier = "wherewolf.map.user-location"
            }
            alignMarkers(on: mapView)
        }

        func mapView(_ mapView: MKMapView, viewFor annotation: any MKAnnotation) -> MKAnnotationView? {
            if annotation is MKUserLocation {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "LiveLocation") as? PresentedUserLocationView
                    ?? PresentedUserLocationView(annotation: annotation, reuseIdentifier: "LiveLocation")
                view.presentedCenter = nil
                view.annotation = annotation
                view.accessibilityIdentifier = "wherewolf.map.user-location"
                return view
            }
            if parent.replayRoute != nil {
                let view = mapView.dequeueReusableAnnotationView(withIdentifier: "ReplayPoint") as? ReplayMarkerView
                    ?? ReplayMarkerView(annotation: annotation, reuseIdentifier: "ReplayPoint")
                view.annotation = annotation
                view.markerTintColor = .systemBlue
                view.glyphTintColor = .white
                updateReplayDirection(view, coordinate: annotation.coordinate, on: mapView)
                view.titleVisibility = .hidden
                view.subtitleVisibility = .hidden
                view.animatesWhenAdded = false
                view.layer.sublayerTransform = CATransform3DMakeAffineTransform(markerTransform(view))
                view.isAccessibilityElement = true
                view.accessibilityLabel = parent.selectedTitle
                view.accessibilityIdentifier = "wherewolf.map.replay-marker"
                view.displayPriority = .required
                view.canShowCallout = false
                return view
            }
            let view = mapView.dequeueReusableAnnotationView(withIdentifier: "SelectedPoint") as? MKMarkerAnnotationView
                ?? MKMarkerAnnotationView(annotation: annotation, reuseIdentifier: "SelectedPoint")
            view.annotation = annotation
            view.markerTintColor = .systemBlue
            view.glyphImage = UIImage(systemName: "mappin.circle.fill")
            view.canShowCallout = false
            return view
        }
    }
}

@MainActor
private final class CameraFrameTarget: NSObject {
    enum Kind { case camera, live, heading }
    private weak var coordinator: NativeMapSurface.Coordinator?
    private let kind: Kind

    init(coordinator: NativeMapSurface.Coordinator, kind: Kind = .camera) {
        self.coordinator = coordinator
        self.kind = kind
    }

    @objc func frame(_ link: CADisplayLink) {
        guard let coordinator else { link.invalidate(); return }
        switch kind {
        case .camera: coordinator.advanceCameraTransition(at: link.timestamp)
        case .live: coordinator.advanceLiveLocation(at: link.timestamp)
        case .heading: coordinator.advanceMapHeading(at: link.timestamp)
        }
    }
}
