import MapKit
import SwiftUI

extension MKMapCamera {
    convenience init(_ camera: MapCamera) {
        self.init(lookingAtCenter: camera.centerCoordinate, fromDistance: camera.distance,
                  pitch: CGFloat(camera.pitch), heading: camera.heading)
    }
}

enum MapViewport {
    static func visibleRect(in bounds: CGRect, safeTop: CGFloat, drawerTop: CGFloat?) -> CGRect {
        let top = min(bounds.maxY, max(bounds.minY, safeTop))
        let bottom = min(bounds.maxY, max(top, drawerTop ?? bounds.maxY))
        return CGRect(x: bounds.minX, y: top, width: bounds.width, height: bottom - top)
    }

    static func center(in bounds: CGRect, safeTop: CGFloat, drawerTop: CGFloat?) -> CGPoint {
        let rect = visibleRect(in: bounds, safeTop: safeTop, drawerTop: drawerTop)
        return CGPoint(x: rect.midX, y: rect.midY)
    }

    // Like Find My, moving the drawer leaves the map where it is. The target stays centered above the
    // closed drawer, and shifts only when an open drawer would otherwise cover it.
    static let drawerClearance: CGFloat = 48

    static func restingCenter(in bounds: CGRect, safeTop: CGFloat, closedDrawerTop: CGFloat?, drawerTop: CGFloat?) -> CGPoint {
        guard let closedDrawerTop else { return center(in: bounds, safeTop: safeTop, drawerTop: drawerTop) }
        let resting = center(in: bounds, safeTop: safeTop, drawerTop: closedDrawerTop)
        guard let drawerTop else { return resting }
        let visible = visibleRect(in: bounds, safeTop: safeTop, drawerTop: drawerTop)
        return CGPoint(x: resting.x, y: min(resting.y, max(visible.midY, drawerTop - drawerClearance)))
    }

    // `rotation` is the change in camera heading, in radians. The camera turns about its own center, so
    // the offset to the visible center turns with it.
    static func anchoredCenter(_ anchor: CLLocationCoordinate2D, projectionCenter: CLLocationCoordinate2D,
                               projectionTarget: CLLocationCoordinate2D, scale: Double = 1,
                               rotation: Double = 0) -> CLLocationCoordinate2D {
        let origin = MKMapPoint(anchor)
        let center = MKMapPoint(projectionCenter)
        let target = MKMapPoint(projectionTarget)
        let width = MKMapRect.world.width
        var dx = center.x - target.x
        if dx > width / 2 { dx -= width }
        if dx < -width / 2 { dx += width }
        let dy = center.y - target.y
        var x = (origin.x + (dx * cos(rotation) - dy * sin(rotation)) * scale).truncatingRemainder(dividingBy: width)
        if x < 0 { x += width }
        let y = min(MKMapRect.world.maxY, max(0, origin.y + (dx * sin(rotation) + dy * cos(rotation)) * scale))
        return MKMapPoint(x: x, y: y).coordinate
    }
}

enum ReplayOverviewFit {
    // Preserve a useful neighborhood for a single fix or a trail only a few meters long.
    static let minimumSpan: CLLocationDistance = 150

    @MainActor static func camera(for coordinates: [CLLocationCoordinate2D], on map: MKMapView,
                                  clearRect: CGRect) -> MapCamera? {
        guard !coordinates.isEmpty, clearRect.width > 1, clearRect.height > 1,
              map.bounds.width > 0, map.bounds.height > 0 else { return nil }
        let points = coordinates.map(MKMapPoint.init)
        guard points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let minX = points.map(\.x).min()!, maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!, maxY = points.map(\.y).max()!
        let center = MKMapPoint(x: (minX + maxX) / 2, y: (minY + maxY) / 2)
        let span = minimumSpan * MKMapPointsPerMeterAtLatitude(center.coordinate.latitude)
        let rect = MKMapRect(x: center.x - max(span, maxX - minX) / 2,
                             y: center.y - max(span, maxY - minY) / 2,
                             width: max(span, maxX - minX), height: max(span, maxY - minY))
        // An unattached map supplies MapKit's perspective projection without changing the displayed
        // camera. A north-up rectangle is only the initial scale; the fit uses the actual vertices.
        let projection = MKMapView(frame: CGRect(origin: .zero, size: map.bounds.size))
        projection.insetsLayoutMarginsFromSafeArea = false
        projection.layoutMargins = .zero
        projection.mapType = map.mapType
        projection.layoutIfNeeded()
        let target = clearRect.offsetBy(dx: -map.bounds.minX, dy: -map.bounds.minY).insetBy(dx: 0.5, dy: 0.5)
        let padding = UIEdgeInsets(top: target.minY, left: target.minX,
                                  bottom: projection.bounds.maxY - target.maxY,
                                  right: projection.bounds.maxX - target.maxX)
        projection.setVisibleMapRect(MKMapRect(x: center.x - span / 2, y: center.y - span / 2,
                                              width: span, height: span), edgePadding: padding, animated: false)
        let minimumDistance = max(MapZoom.minimumDistance, projection.camera.centerCoordinateDistance)
        projection.setVisibleMapRect(rect, edgePadding: padding, animated: false)
        let requestedPitch = Double(map.camera.pitch)
        var camera = MapCamera(centerCoordinate: center.coordinate,
                               distance: projection.camera.centerCoordinateDistance,
                               heading: map.camera.heading, pitch: requestedPitch)
        var fitted: MapCamera?
        for _ in 0..<24 {
            // MapKit limits pitch by scale. Retry the original pitch at each scale, then fit and
            // return the applied camera, including any clamp.
            camera.pitch = requestedPitch
            projection.setCamera(MKMapCamera(camera), animated: false)
            camera = MapCamera(projection.camera)
            guard let bounds = projectedBounds(coordinates.map { projection.convert($0, toPointTo: projection) }) else { return nil }
            let ratio = max(bounds.width / target.width, bounds.height / target.height)
            let offset = hypot(bounds.midX - target.midX, bounds.midY - target.midY)
            if bounds.minX >= target.minX - 0.25, bounds.maxX <= target.maxX + 0.25,
               bounds.minY >= target.minY - 0.25, bounds.maxY <= target.maxY + 0.25 {
                fitted = camera
                if offset < 0.25, ratio > 0.995 || camera.distance <= minimumDistance * 1.000001 { return camera }
            }
            let scale = min(MapZoom.maximumDistance / camera.distance,
                            max(minimumDistance / camera.distance, min(4, max(0.25, ratio))))
            let anchor = projection.convert(CGPoint(x: bounds.midX, y: bounds.midY), toCoordinateFrom: projection)
            let middle = projection.convert(CGPoint(x: projection.bounds.midX, y: projection.bounds.midY),
                                            toCoordinateFrom: projection)
            let destination = projection.convert(CGPoint(x: target.midX, y: target.midY), toCoordinateFrom: projection)
            let nextCenter = MapViewport.anchoredCenter(anchor, projectionCenter: middle,
                                                       projectionTarget: destination, scale: scale)
            let distance = camera.distance * scale
                * MKMapPointsPerMeterAtLatitude(camera.centerCoordinate.latitude)
                / MKMapPointsPerMeterAtLatitude(nextCenter.latitude)
            guard CLLocationCoordinate2DIsValid(nextCenter), distance.isFinite, distance > 0 else { return fitted }
            camera.centerCoordinate = nextCenter
            camera.distance = min(MapZoom.maximumDistance, max(minimumDistance, distance))
        }
        return fitted
    }

    static func projectedBounds(_ points: [CGPoint]) -> CGRect? {
        guard let first = points.first, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
        for point in points.dropFirst() {
            minX = min(minX, point.x); maxX = max(maxX, point.x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }
}

struct ReplayRulerHold: Equatable {
    let pointsPerBar: Double
    let visibleBars: Double

    var halfWindow: Double { max(0, visibleBars * pointsPerBar / 2) }

    func window(at position: Double, count: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let lower = min(count - 1, max(0, Int(ceil(position - halfWindow))))
        let upper = min(count, max(lower + 1, Int(floor(position + halfWindow)) + 1))
        return lower..<upper
    }

    func needsFit(at position: Double, since previous: Double?) -> Bool {
        guard let previous else { return true }
        return abs(position - previous) > halfWindow
    }
}

struct ReplayHoldDistanceEase {
    let from: CLLocationDistance
    let to: CLLocationDistance
    let start: TimeInterval
    static let duration: TimeInterval = 0.3

    func progress(at time: TimeInterval) -> Double {
        min(1, max(0, (time - start) / Self.duration))
    }

    func distance(at time: TimeInterval) -> CLLocationDistance {
        let progress = progress(at: time)
        if progress == 0 { return from }
        if progress == 1 { return to }
        let eased = progress * progress * (3 - 2 * progress)
        return exp(log(max(1, from)) + (log(max(1, to)) - log(max(1, from))) * eased)
    }
}

enum ReplayHoldZoom {
    static func distance(base: CLLocationDistance, pointsPerBar: Double,
                         fitted: CLLocationDistance?) -> CLLocationDistance {
        let base = min(MapZoom.maximumDistance, max(MapZoom.minimumDistance, base))
        guard pointsPerBar > 1, let fitted, fitted.isFinite else { return base }
        return min(MapZoom.maximumDistance, max(base, fitted))
    }

    static func bounds(in coordinates: [CLLocationCoordinate2D], window: Range<Int>,
                       anchor: CLLocationCoordinate2D) -> MKMapRect? {
        guard !window.isEmpty, window.lowerBound >= 0, window.upperBound <= coordinates.count else { return nil }
        let origin = MKMapPoint(anchor)
        let world = MKMapRect.world.width
        var minX = origin.x, maxX = origin.x, minY = origin.y, maxY = origin.y
        for index in window {
            let point = MKMapPoint(coordinates[index])
            guard point.x.isFinite, point.y.isFinite else { return nil }
            var dx = point.x - origin.x
            dx -= (dx / world).rounded() * world
            minX = min(minX, origin.x + dx); maxX = max(maxX, origin.x + dx)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        return MKMapRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    // The pose remains at the map's usual visible center, rather than at the route box's midpoint.
    static func requiredScale(bounds: CGRect, anchor: CGPoint, clear: CGRect) -> Double {
        guard clear.contains(anchor) else { return 1 }
        let horizontal = max((anchor.x - bounds.minX) / max(1, anchor.x - clear.minX),
                             (bounds.maxX - anchor.x) / max(1, clear.maxX - anchor.x))
        let vertical = max((anchor.y - bounds.minY) / max(1, anchor.y - clear.minY),
                           (bounds.maxY - anchor.y) / max(1, clear.maxY - anchor.y))
        return Double(max(0, max(horizontal, vertical)))
    }

    @MainActor static func fittedDistance(bounds: MKMapRect, anchor: CLLocationCoordinate2D,
                                          base: CLLocationDistance, on map: MKMapView,
                                          clearRect: CGRect, anchorPoint: CGPoint,
                                          pitch requestedPitch: Double? = nil,
                                          projection reused: MKMapView? = nil) -> CLLocationDistance? {
        guard clearRect.width > 1, clearRect.height > 1, map.bounds.width > 1, map.bounds.height > 1 else { return nil }
        let corners = [MKMapPoint(x: bounds.minX, y: bounds.minY), MKMapPoint(x: bounds.maxX, y: bounds.minY),
                       MKMapPoint(x: bounds.maxX, y: bounds.maxY), MKMapPoint(x: bounds.minX, y: bounds.maxY)]
            .map { point -> CLLocationCoordinate2D in
                let world = MKMapRect.world.width
                let x = (point.x.truncatingRemainder(dividingBy: world) + world).truncatingRemainder(dividingBy: world)
                return MKMapPoint(x: x, y: point.y).coordinate
            }
        // Creating a map view costs more than the fit, and holds refit on every detent change.
        let projection = reused ?? MKMapView()
        if projection.frame.size != map.bounds.size { projection.frame = CGRect(origin: .zero, size: map.bounds.size) }
        projection.insetsLayoutMarginsFromSafeArea = false
        projection.layoutMargins = .zero
        if projection.mapType != map.mapType { projection.mapType = map.mapType }
        projection.layoutIfNeeded()
        let target = clearRect.offsetBy(dx: -map.bounds.minX, dy: -map.bounds.minY).insetBy(dx: 1, dy: 1)
        let point = CGPoint(x: anchorPoint.x - map.bounds.minX, y: anchorPoint.y - map.bounds.minY)
        let pitch = requestedPitch ?? Double(map.camera.pitch)
        // Start near the box's scale so distant corners do not project behind a pitched horizon.
        let seed = MKMapRect(x: bounds.minX, y: bounds.minY,
                             width: max(1, bounds.width), height: max(1, bounds.height))
        projection.setVisibleMapRect(seed, edgePadding: UIEdgeInsets(top: target.minY, left: target.minX,
            bottom: projection.bounds.maxY - target.maxY, right: projection.bounds.maxX - target.maxX), animated: false)
        var distance = ReplayHoldZoom.distance(base: base, pointsPerBar: 2,
                                               fitted: projection.camera.centerCoordinateDistance)
        for _ in 0..<24 {
            var camera = MapCamera(centerCoordinate: anchor, distance: distance,
                                   heading: map.camera.heading, pitch: pitch)
            projection.setCamera(MKMapCamera(camera), animated: false)
            for _ in 0..<4 {
                camera = MapCamera(projection.camera)
                camera.centerCoordinate = MapViewport.anchoredCenter(anchor,
                    projectionCenter: projection.convert(CGPoint(x: projection.bounds.midX, y: projection.bounds.midY),
                                                          toCoordinateFrom: projection),
                    projectionTarget: projection.convert(point, toCoordinateFrom: projection))
                projection.setCamera(MKMapCamera(camera), animated: false)
            }
            guard let projected = ReplayOverviewFit.projectedBounds(corners.map { projection.convert($0, toPointTo: projection) }) else { return nil }
            let applied = projection.camera.centerCoordinateDistance
            let ratio = requiredScale(bounds: projected, anchor: point, clear: target)
            if ratio <= 1 || applied >= MapZoom.maximumDistance { return applied }
            let next = min(MapZoom.maximumDistance, max(distance, applied) * max(1.01, ratio * 1.02))
            if next <= distance { return applied }
            distance = next
        }
        return projection.camera.centerCoordinateDistance
    }
}

struct MapCameraTransition {
    let from: MapCamera
    var to: MapCamera
    let start: TimeInterval
    var length: TimeInterval = Self.duration
    // The starting view's width in map points. A transition with one follows `MapFlight`.
    var flightWidth: Double?
    static let duration: TimeInterval = 1

    static func flight(from: MapCamera, to: MapCamera, start: TimeInterval, width: Double) -> Self {
        let path = MapFlight(from: from, to: to, width: width)
        return Self(from: from, to: to, start: start, length: MapFlight.duration(for: path.length), flightWidth: width)
    }

    func progress(at time: TimeInterval) -> Double {
        let duration = max(0.001, length)
        if time >= start + duration { return 1 }
        return min(1, max(0, (time - start) / duration))
    }

    func camera(at time: TimeInterval) -> MapCamera {
        let progress = progress(at: time)
        if progress == 0 { return from }
        if progress == 1 { return to }
        let amount = progress * progress * progress * (progress * (progress * 6 - 15) + 10)
        if let flightWidth {
            return MapFlight(from: from, to: to, width: flightWidth).camera(at: amount, from: from, to: to)
        }
        let distance = exp(log(max(1, from.distance))
            + (log(max(1, to.distance)) - log(max(1, from.distance))) * amount)
        // Keep the focus in view as the scale changes, including very large zooms.
        let centerAmount = abs(to.distance - from.distance) > 1
            ? min(1, max(0, (distance - from.distance) / (to.distance - from.distance))) : amount
        let center = ReplayCoordinate(from.centerCoordinate)
            .interpolated(to: ReplayCoordinate(to.centerCoordinate), fraction: centerAmount).coordinate
        var heading = to.heading - from.heading
        heading -= (heading / 360).rounded() * 360
        return MapCamera(centerCoordinate: center,
                         distance: distance,
                         heading: from.heading + heading * amount,
                         pitch: from.pitch + (to.pitch - from.pitch) * amount)
    }
}

// van Wijk and Nuij's smooth zoom and pan, the path Mapbox's flyTo also uses. A long move zooms out on
// the way and back in, so the map never sweeps past faster than the eye can follow; a short move is
// nearly a plain pan. Widths and travel are in map points.
struct MapFlight {
    private static let rho = 1.42
    private let start: MKMapPoint
    private let delta: (x: Double, y: Double)
    private let travel: Double
    private let startWidth: Double
    private let endWidth: Double
    private let r0: Double
    // The path length in van Wijk's units, which grows with the logarithm of the move in screen widths.
    let length: Double

    init(from: MapCamera, to: MapCamera, width: Double) {
        start = MKMapPoint(from.centerCoordinate)
        let end = MKMapPoint(to.centerCoordinate)
        let world = MKMapRect.world.width
        var dx = end.x - start.x
        dx -= (dx / world).rounded() * world
        delta = (dx, end.y - start.y)
        travel = hypot(dx, end.y - start.y)
        startWidth = max(1e-9, width.isFinite ? width : 1)
        let ratio = Self.scale(of: to) / Self.scale(of: from)
        endWidth = startWidth * (ratio.isFinite && ratio > 0 ? ratio : 1)
        let rho2 = Self.rho * Self.rho
        if travel < startWidth * 1e-6 {
            r0 = 0
            length = abs(log(endWidth / startWidth)) / Self.rho
        } else {
            let pan = rho2 * rho2 * travel * travel
            let b0 = (endWidth * endWidth - startWidth * startWidth + pan) / (2 * startWidth * rho2 * travel)
            let b1 = (endWidth * endWidth - startWidth * startWidth - pan) / (2 * endWidth * rho2 * travel)
            r0 = asinh(-b0)
            length = (asinh(-b1) - r0) / Self.rho
        }
    }

    // About half a second for a short hop, up to two seconds for the other side of the world.
    static func duration(for length: Double) -> TimeInterval {
        min(2, max(0.6, 0.55 + 0.15 * length))
    }

    // `amount` is the eased progress, 0 to 1.
    func camera(at amount: Double, from: MapCamera, to: MapCamera) -> MapCamera {
        let s = amount * length
        let fraction: Double
        let width: Double
        if travel < startWidth * 1e-6 {
            fraction = amount
            width = startWidth * exp((endWidth >= startWidth ? 1 : -1) * Self.rho * s)
        } else {
            let rho2 = Self.rho * Self.rho
            fraction = min(1, max(0, startWidth / rho2 * (cosh(r0) * tanh(Self.rho * s + r0) - sinh(r0)) / travel))
            width = startWidth * cosh(r0) / cosh(Self.rho * s + r0)
        }
        let worldWidth = MKMapRect.world.width
        var x = (start.x + delta.x * fraction).truncatingRemainder(dividingBy: worldWidth)
        if x < 0 { x += worldWidth }
        let center = MKMapPoint(x: x, y: min(MKMapRect.world.maxY, max(0, start.y + delta.y * fraction))).coordinate
        let distance = from.distance * width / startWidth
            * MKMapPointsPerMeterAtLatitude(from.centerCoordinate.latitude) / MKMapPointsPerMeterAtLatitude(center.latitude)
        var heading = to.heading - from.heading
        heading -= (heading / 360).rounded() * 360
        return MapCamera(centerCoordinate: center,
                         distance: min(MapZoom.maximumDistance, max(1, distance.isFinite ? distance : to.distance)),
                         heading: from.heading + heading * amount,
                         pitch: from.pitch + (to.pitch - from.pitch) * amount)
    }

    private static func scale(of camera: MapCamera) -> Double {
        camera.distance * MKMapPointsPerMeterAtLatitude(camera.centerCoordinate.latitude)
    }
}

enum MapZoom {
    static let minimumDistance: CLLocationDistance = 50
    static let maximumDistance: CLLocationDistance = 40_000_000
    static let duration: TimeInterval = 0.32

    static func distance(from current: CLLocationDistance, inward: Bool) -> CLLocationDistance {
        let start = current.isFinite && current > 0 ? current : 2_000
        return min(maximumDistance, max(minimumDistance, start * (inward ? 0.5 : 2)))
    }
}

struct MapZoomResult {
    let camera: MapCamera
    let replayFollowing: Bool
}

struct LiveMapMotion {
    private(set) var point: MKMapPoint?
    private(set) var target: MKMapPoint?
    private(set) var velocity = CGVector.zero
    private var lastFrame: TimeInterval?
    private var lastFix: TimeInterval = 0
    private static let response = 6.0

    var coordinate: CLLocationCoordinate2D? {
        guard let point else { return nil }
        let world = MKMapRect.world.width
        var x = point.x.truncatingRemainder(dividingBy: world)
        if x < 0 { x += world }
        return MKMapPoint(x: x, y: point.y).coordinate
    }

    mutating func receive(_ coordinate: CLLocationCoordinate2D, at time: TimeInterval) -> Bool {
        guard CLLocationCoordinate2DIsValid(coordinate) else { return false }
        var next = MKMapPoint(coordinate)
        guard next.x.isFinite, next.y.isFinite else { return false }
        guard let point else {
            self.point = next
            target = next
            lastFrame = time
            lastFix = time
            return false
        }
        next.x -= ((next.x - point.x) / MKMapRect.world.width).rounded() * MKMapRect.world.width
        if let target, hypot(next.x - target.x, next.y - target.y) < 0.001 { return false }
        advance(at: time)
        target = next
        lastFix = time
        return true
    }

    mutating func advance(at time: TimeInterval) {
        guard let point, let target, let lastFrame, time > lastFrame else { return }
        let elapsed = min(0.1, time - lastFrame)
        self.lastFrame = time
        let decay = exp(-Self.response * elapsed)
        func axis(_ position: Double, _ goal: Double, _ speed: Double) -> (Double, Double) {
            let error = position - goal
            let combined = speed + Self.response * error
            return (goal + (error + combined * elapsed) * decay,
                    (speed - Self.response * combined * elapsed) * decay)
        }
        let x = axis(point.x, target.x, velocity.dx)
        let y = axis(point.y, target.y, velocity.dy)
        self.point = MKMapPoint(x: x.0, y: y.0)
        velocity = CGVector(dx: x.1, dy: y.1)
    }

    func settled(at time: TimeInterval, tolerance: Double) -> Bool {
        guard let point, let target else { return true }
        return time - lastFix >= 1.25
            && hypot(point.x - target.x, point.y - target.y) < tolerance
            && hypot(velocity.dx, velocity.dy) < tolerance * Self.response
    }

    mutating func finish() {
        point = target
        velocity = .zero
    }
}

// A critically damped turn toward the latest heading, in radians, over the shortest arc.
struct HeadingMotion {
    private(set) var angle: Double?
    private var target: Double?
    private var velocity = 0.0
    private var lastFrame: TimeInterval?
    private let response: Double

    init(response: Double = 26) {
        self.response = response
    }

    mutating func receive(_ next: Double, at time: TimeInterval) {
        guard next.isFinite else { return }
        guard angle != nil else {
            angle = next
            target = next
            lastFrame = time
            return
        }
        advance(at: time)
        guard let angle else { return }
        // Unwrap around the displayed heading so crossing north never adds a full turn.
        let delta = atan2(sin(next - angle), cos(next - angle))
        target = angle + delta
    }

    mutating func advance(at time: TimeInterval) {
        guard let angle, let target, let lastFrame, time > lastFrame else { return }
        let elapsed = min(0.1, time - lastFrame)
        self.lastFrame = time
        let error = angle - target
        let combined = velocity + response * error
        let decay = exp(-response * elapsed)
        self.angle = target + (error + combined * elapsed) * decay
        velocity = (velocity - response * combined * elapsed) * decay
    }

    var settled: Bool {
        guard let angle, let target else { return true }
        return abs(angle - target) < .pi / 720 && abs(velocity) < .pi / 180
    }

    mutating func finish() {
        angle = target
        velocity = 0
    }
}
