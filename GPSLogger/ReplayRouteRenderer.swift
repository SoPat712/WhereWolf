import MapKit

enum ReplayRouteStyle {
    static let pastWidth: CGFloat = 2.5
    static let futureWidth: CGFloat = 1.25
    static let cacheStride = 64
}

@MainActor
final class ReplayRoutePresentation {
    struct Section {
        let start: Int
        let end: Int
        let prefix: Int
        let polyline: MKPolyline
    }

    struct OverlayChange {
        var added: [MKOverlay] = []
        var removed: [MKOverlay] = []
    }

    let future: MKPolyline
    let futureRenderer: MKPolylineRenderer
    let sections: [Section]
    private var trails: Set<ObjectIdentifier>
    private(set) var activeIndex = 0
    private(set) var activeTrail: MKPolyline?
    private var retiredTrail: MKPolyline?
    private var anchor = -1
    private static let maximumSegments = 1_024
    private static let maximumLength = 100_000.0

    var overlays: [MKOverlay] {
        [future] + sections[..<min(activeIndex, sections.count)].map(\.polyline) + [retiredTrail, activeTrail].compactMap { $0 }
    }

    init(coordinates: [CLLocationCoordinate2D]) {
        let world = MKMapRect.world.width
        var points: [MKMapPoint] = []
        points.reserveCapacity(coordinates.count)
        for coordinate in coordinates {
            var point = MKMapPoint(coordinate)
            if let previous = points.last {
                point.x -= ((point.x - previous.x) / world).rounded() * world
            }
            points.append(point)
        }
        future = MKPolyline(points: points, count: points.count)
        futureRenderer = MKPolylineRenderer(polyline: future)
        Self.configure(futureRenderer, width: ReplayRouteStyle.futureWidth)
        futureRenderer.strokeColor = UIColor.systemTeal.withAlphaComponent(0.55)
        futureRenderer.lineDashPattern = [1, 5]
        futureRenderer.lineCap = .round

        var sections: [Section] = []
        var start = 0
        while start < points.count {
            var end = min(start + 1, points.count - 1)
            var length = hypot(points[end].x - points[start].x, points[end].y - points[start].y)
            while end + 1 < points.count, end - start < Self.maximumSegments {
                let nextLength = hypot(points[end + 1].x - points[end].x, points[end + 1].y - points[end].y)
                if length + nextLength > Self.maximumLength { break }
                length += nextLength
                end += 1
            }
            var values = Array(points[start...end])
            var prefix = 0
            if start > 0 {
                let previous = points[start - 1], current = points[start]
                let distance = hypot(previous.x - current.x, previous.y - current.y)
                if distance > 0.001 {
                    // A short shared tail preserves joins without importing a preceding GPS jump.
                    let amount = min(1, 100 / distance)
                    values.insert(MKMapPoint(x: current.x + (previous.x - current.x) * amount,
                        y: current.y + (previous.y - current.y) * amount), at: 0)
                    prefix = 1
                }
            }
            let line = MKPolyline(points: values, count: values.count)
            sections.append(Section(start: start, end: end, prefix: prefix, polyline: line))
            if end == points.count - 1 { break }
            start = end
        }
        self.sections = sections
        trails = Set(sections.map { ObjectIdentifier($0.polyline) })
    }

    private static func configure(_ renderer: MKOverlayPathRenderer, width: CGFloat) {
        renderer.lineWidth = width
        renderer.lineCap = .butt
        renderer.lineJoin = .round
    }

    // MKPolylineRenderer is the only overlay MapKit draws as vector geometry, at a constant
    // screen width. Path renderer subclasses become tiles that stretch between zoom levels.
    func updateCachedTrail(position: Double) -> OverlayChange {
        guard position.isFinite, !sections.isEmpty else { return OverlayChange() }
        let value = min(Double(future.pointCount - 1), max(0, position))
        let next = Int(value) / ReplayRouteStyle.cacheStride * ReplayRouteStyle.cacheStride
        guard next != anchor else { return OverlayChange() }
        let forward = next > anchor
        anchor = next
        var lower = 0, upper = sections.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if sections[middle].start <= next { lower = middle + 1 }
            else { upper = middle }
        }
        let nextIndex = max(0, lower - 1)

        var change = OverlayChange()
        // A live strokeColor change can take over a second to appear; adding a line does not.
        if nextIndex > activeIndex {
            change.added += sections[activeIndex..<nextIndex].map(\.polyline)
        } else if nextIndex < activeIndex {
            change.removed += sections[nextIndex..<activeIndex].map(\.polyline)
        }
        activeIndex = nextIndex
        func remove(_ line: MKPolyline?) {
            guard let line else { return }
            change.removed.append(line)
            trails.remove(ObjectIdentifier(line))
        }
        remove(retiredTrail)
        retiredTrail = nil
        // Going forward, the previous trail stays beneath its replacement until the next
        // boundary so MapKit never shows a gap while it prepares the new geometry.
        if forward { retiredTrail = activeTrail } else { remove(activeTrail) }
        activeTrail = nil
        let section = sections[nextIndex]
        let count = next - section.start + section.prefix + 1
        if count > 1 {
            let line = MKPolyline(points: section.polyline.points(), count: count)
            trails.insert(ObjectIdentifier(line))
            activeTrail = line
            change.added.append(line)
        }
        return change
    }

    func renderer(for overlay: MKOverlay) -> MKOverlayPathRenderer? {
        if overlay === future { return futureRenderer }
        guard trails.contains(ObjectIdentifier(overlay)), let line = overlay as? MKPolyline else { return nil }
        let renderer = MKPolylineRenderer(polyline: line)
        Self.configure(renderer, width: ReplayRouteStyle.pastWidth)
        renderer.strokeColor = .systemBlue
        return renderer
    }

#if targetEnvironment(simulator)
    var auditValues: [String: Double] {
        ["nativeSectionCount": Double(sections.count),
         "nativeSectionStart": Double(sections.isEmpty ? 0 : sections[activeIndex].start)]
    }
#endif
}

@MainActor
final class ReplayTrailLayer: CAShapeLayer {
    private static let maximumSegments = ReplayRouteStyle.cacheStride * 2
    private(set) var coordinate: CLLocationCoordinate2D?
    private struct Projection: Equatable {
        let route: ObjectIdentifier
        let position: Double
        let coordinate: ReplayCoordinate
        let center: CGPoint
        let east: CGPoint
        let north: CGPoint
        let bounds: CGRect
        let scale: CGFloat
        let appearance: UIUserInterfaceStyle
    }
    private var projection: Projection?

    override init() {
        super.init()
        fillColor = nil
        lineWidth = ReplayRouteStyle.pastWidth
        lineCap = .butt
        lineJoin = .round
        actions = ["path": NSNull(), "position": NSNull(), "bounds": NSNull(),
                   "strokeColor": NSNull(), "contentsScale": NSNull()]
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    func hide() {
        projection = nil
        coordinate = nil
        path = nil
        removeFromSuperlayer()
    }

    func update(route: MKPolyline, position: Double, coordinate: CLLocationCoordinate2D,
                on map: MKMapView, below marker: MKAnnotationView) {
        guard position.isFinite, route.pointCount > 0, CLLocationCoordinate2DIsValid(coordinate),
              let container = marker.superview else { hide(); return }
        let end = Int(min(Double(route.pointCount - 1), max(0, position)))
        let start = max(0, end - Self.maximumSegments)
        func project(_ coordinate: CLLocationCoordinate2D) -> CGPoint {
            let point = map.convert(coordinate, toPointTo: container)
            return CGPoint(x: point.x - container.bounds.minX, y: point.y - container.bounds.minY)
        }
        func project(_ point: MKMapPoint) -> CGPoint {
            var x = point.x.truncatingRemainder(dividingBy: MKMapRect.world.width)
            if x < 0 { x += MKMapRect.world.width }
            return project(MKMapPoint(x: x, y: point.y).coordinate)
        }
        let origin = MKMapPoint(coordinate)
        let endpoint = project(coordinate)
        let next = Projection(route: ObjectIdentifier(route), position: position,
            coordinate: ReplayCoordinate(coordinate), center: endpoint,
            east: project(MKMapPoint(x: origin.x + 1_000, y: origin.y)),
            north: project(MKMapPoint(x: origin.x, y: max(0, origin.y - 1_000))),
            bounds: container.bounds, scale: map.traitCollection.displayScale,
            appearance: map.traitCollection.userInterfaceStyle)
        guard projection != next || superlayer !== container.layer else { return }
        let path = CGMutablePath()
        for index in start...end {
            let projected = project(route.points()[index])
            guard projected.x.isFinite, projected.y.isFinite else { hide(); return }
            if index == start { path.move(to: projected) }
            else { path.addLine(to: projected) }
        }
        guard endpoint.x.isFinite, endpoint.y.isFinite else { hide(); return }
        path.addLine(to: endpoint)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if superlayer !== container.layer { container.layer.insertSublayer(self, below: marker.layer) }
        frame = container.bounds
        contentsScale = map.traitCollection.displayScale
        strokeColor = UIColor.systemBlue.resolvedColor(with: map.traitCollection).cgColor
        // This short tail shares the marker's transaction while MapKit redraws the cached route.
        self.path = path
        self.coordinate = coordinate
        CATransaction.commit()
        projection = next
    }
}

@MainActor
final class ReplayAccuracyLayer: CAShapeLayer {
    private struct Projection: Equatable {
        let coordinate: ReplayCoordinate
        let accuracy: Double
        let center: CGPoint
        let east: CGPoint
        let north: CGPoint
        let bounds: CGRect
        let appearance: UIUserInterfaceStyle
    }
    private var projection: Projection?

    override init() {
        super.init()
        lineWidth = 1
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    func hide() {
        projection = nil
        removeFromSuperlayer()
    }

    func update(coordinate: CLLocationCoordinate2D, accuracy: CLLocationAccuracy?,
                on map: MKMapView, below marker: MKAnnotationView) {
        guard let accuracy, accuracy.isFinite, accuracy > 0,
              CLLocationCoordinate2DIsValid(coordinate), let container = marker.superview else {
            hide()
            return
        }
        let world = MKMapRect.world
        let origin = MKMapPoint(coordinate)
        let radius = min(world.width, accuracy * MKMapPointsPerMeterAtLatitude(coordinate.latitude))
        func point(_ angle: Double) -> CGPoint {
            var x = (origin.x + cos(angle) * radius).truncatingRemainder(dividingBy: world.width)
            if x < 0 { x += world.width }
            let y = min(world.maxY, max(0, origin.y + sin(angle) * radius))
            let point = map.convert(MKMapPoint(x: x, y: y).coordinate, toPointTo: container)
            return CGPoint(x: point.x - container.bounds.minX, y: point.y - container.bounds.minY)
        }
        let center = map.convert(coordinate, toPointTo: container)
        let next = Projection(coordinate: ReplayCoordinate(coordinate), accuracy: accuracy,
            center: center, east: point(0), north: point(.pi / 2), bounds: container.bounds,
            appearance: map.traitCollection.userInterfaceStyle)
        guard next.center.x.isFinite, next.center.y.isFinite, next.east.x.isFinite,
              next.east.y.isFinite, next.north.x.isFinite, next.north.y.isFinite else {
            hide()
            return
        }
        guard projection != next || superlayer !== container.layer else { return }
        let path = CGMutablePath()
        for index in 0..<64 {
            let position = point(Double(index) / 64 * .pi * 2)
            guard position.x.isFinite, position.y.isFinite else { hide(); return }
            if index == 0 { path.move(to: position) }
            else { path.addLine(to: position) }
        }
        path.closeSubpath()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if superlayer !== container.layer { container.layer.insertSublayer(self, below: marker.layer) }
        frame = container.bounds
        self.path = path
        let blue = UIColor.systemBlue.resolvedColor(with: map.traitCollection)
        fillColor = blue.withAlphaComponent(0.12).cgColor
        strokeColor = blue.withAlphaComponent(0.25).cgColor
        CATransaction.commit()
        projection = next
    }
}
