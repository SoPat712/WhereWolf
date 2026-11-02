import MapKit
import SwiftUI

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

    static func anchoredCenter(_ anchor: CLLocationCoordinate2D, projectionCenter: CLLocationCoordinate2D,
                               projectionTarget: CLLocationCoordinate2D, scale: Double = 1) -> CLLocationCoordinate2D {
        let origin = MKMapPoint(anchor)
        let center = MKMapPoint(projectionCenter)
        let target = MKMapPoint(projectionTarget)
        let width = MKMapRect.world.width
        var dx = center.x - target.x
        if dx > width / 2 { dx -= width }
        if dx < -width / 2 { dx += width }
        var x = (origin.x + dx * scale).truncatingRemainder(dividingBy: width)
        if x < 0 { x += width }
        let y = min(MKMapRect.world.maxY, max(0, origin.y + (center.y - target.y) * scale))
        return MKMapPoint(x: x, y: y).coordinate
    }
}

struct MapCameraTransition {
    let from: MapCamera
    var to: MapCamera
    let start: TimeInterval
    var length: TimeInterval = Self.duration
    static let duration: TimeInterval = 1

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

struct ReplayHeadingMotion {
    private(set) var angle: Double?
    private var target: Double?
    private var velocity = 0.0
    private var lastFrame: TimeInterval?
    private static let response = 26.0

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
        let combined = velocity + Self.response * error
        let decay = exp(-Self.response * elapsed)
        self.angle = target + (error + combined * elapsed) * decay
        velocity = (velocity - Self.response * combined * elapsed) * decay
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
