import MapKit

enum ReplayRouteStyle {
    static let pastWidth: CGFloat = 2.5
    static let futureWidth: CGFloat = 1.25
    static let futureColor = UIColor.systemTeal.withAlphaComponent(0.55)
}

@MainActor
final class ReplayRoutePresentation {
    struct Section {
        let start: Int
        let end: Int
        let prefix: Int
        let polyline: MKPolyline
        let future: MKPolyline
    }

    struct Coverage: Equatable {
        let start: Int
        let end: Int
        let prefix: Bool
        let marker: Bool
        let bounds: CGRect
    }

    struct OverlayChange {
        var added: [MKOverlay] = []
        var removed: [MKOverlay] = []
        var addedDots: [MKOverlay] = []
        var removedDots: [MKOverlay] = []

        var isEmpty: Bool { added.isEmpty && removed.isEmpty && addedDots.isEmpty && removedDots.isEmpty }

        @MainActor func apply(to map: MKMapView) {
            // Remove obsolete colors before installing their replacements. Dots stay below blue.
            let gone = removed + removedDots
            if !gone.isEmpty { map.removeOverlays(gone) }
            for line in addedDots { map.insertOverlay(line, at: 0, level: .aboveRoads) }
            if !added.isEmpty { map.addOverlays(added, level: .aboveRoads) }
        }
    }

    static let maximumSegments = 1_024
    private static let maximumLength = 100_000.0
    static let renderTimeout: TimeInterval = 2
    private static let cameraCoverageSegments = 4 * maximumSegments
    private(set) var fullRoute = MKPolyline()
    private(set) var sections: [Section] = []
    private(set) var overlays: [MKOverlay] = []
    private(set) var activeIndex = 0
    private(set) var position = 0.0
    private var coordinates: [CLLocationCoordinate2D] = []
    private var pointIDs: [Int64] = []
    private var dots = Set<ObjectIdentifier>()
    private var trails = Set<ObjectIdentifier>()
    private var installed = Set<ObjectIdentifier>()
    private var pending: [ObjectIdentifier: TimeInterval] = [:]
    private var rendering = Set<ObjectIdentifier>()

    var futureSections: [MKPolyline] { sections.map(\.future) }
    var nextCoverageDeadline: TimeInterval? { pending.values.min() }

    init(coordinates: [CLLocationCoordinate2D], pointIDs: [Int64]? = nil,
         position: Double = 0, now: TimeInterval = CACurrentMediaTime()) {
        _ = update(coordinates: coordinates, pointIDs: pointIDs ?? coordinates.indices.map { Int64($0) },
                   position: position, now: now)
    }

    func isDots(_ overlay: MKOverlay) -> Bool { dots.contains(ObjectIdentifier(overlay)) }
    func contains(_ overlay: MKOverlay) -> Bool { installed.contains(ObjectIdentifier(overlay)) }

    // Only reloads inspect the point arrays. Retained section boundaries stay attached to the
    // same records, even when removing the front shifts every presentation index.
    func update(coordinates values: [CLLocationCoordinate2D], pointIDs ids: [Int64],
                position: Double, now: TimeInterval = CACurrentMediaTime()) -> OverlayChange {
        precondition(values.count == ids.count)
        let previous = overlays, previousDots = dots
        var offset: Int?
        if let first = ids.first, let match = pointIDs.firstIndex(of: first) {
            let count = pointIDs.count - match
            if values.count >= count, (0..<count).allSatisfy({ index in
                pointIDs[match + index] == ids[index]
                    && coordinates[match + index].latitude == values[index].latitude
                    && coordinates[match + index].longitude == values[index].longitude
            }) { offset = match }
        }
        if offset == 0 && ids.count == pointIDs.count { return updatePosition(position, now: now) }
        let retainedCount = offset.map { pointIDs.count - $0 } ?? 0
        let oldSections = sections
        var points: [MKMapPoint] = []
        points.reserveCapacity(values.count)
        if let offset {
            points.append(contentsOf: UnsafeBufferPointer(start: fullRoute.points() + offset,
                                                          count: fullRoute.pointCount - offset))
        }
        let world = MKMapRect.world.width
        for coordinate in values.dropFirst(points.count) {
            var point = MKMapPoint(coordinate)
            if let previous = points.last {
                point.x -= ((point.x - previous.x) / world).rounded() * world
            }
            points.append(point)
        }
        fullRoute = MKPolyline(points: points, count: points.count)
        coordinates = values
        pointIDs = ids
        sections = []
        if let offset {
            let appended = values.count > retainedCount
            for (index, section) in oldSections.enumerated() {
                if appended && index == oldSections.count - 1 { break }
                let start = max(0, section.start - offset), end = section.end - offset
                guard end >= start, end > 0 || values.count == 1 else { continue }
                if start == section.start - offset && !(offset > 0 && start == 0 && section.prefix > 0) {
                    sections.append(Section(start: start, end: end, prefix: section.prefix,
                                            polyline: section.polyline, future: section.future))
                } else {
                    let future = start == section.start - offset ? section.future : nil
                    sections.append(Self.section(points: points, start: start, end: end, future: future))
                }
            }
            if appended, let last = oldSections.last {
                appendSections(points: points, from: max(0, last.start - offset), reusing: last, offset: offset)
            }
        } else if !points.isEmpty {
            appendSections(points: points, from: 0)
        }
        dots = Set(sections.map { ObjectIdentifier($0.future) })
        trails = Set(sections.map { ObjectIdentifier($0.polyline) })
        self.position = clamped(position)
        activeIndex = sectionIndex(containing: Int(self.position))
        return reconcile(previous: previous, previousDots: previousDots, now: now)
    }

    private func appendSections(points: [MKMapPoint], from first: Int, reusing old: Section? = nil, offset: Int = 0) {
        var start = first
        while start < points.count {
            var end = min(start + 1, points.count - 1)
            var length = hypot(points[end].x - points[start].x, points[end].y - points[start].y)
            while end + 1 < points.count, end - start < Self.maximumSegments {
                let step = hypot(points[end + 1].x - points[end].x, points[end + 1].y - points[end].y)
                if length + step > Self.maximumLength { break }
                length += step
                end += 1
            }
            if let old, start == old.start - offset, end == old.end - offset,
               !(offset > 0 && start == 0 && old.prefix > 0) {
                sections.append(Section(start: start, end: end, prefix: old.prefix,
                                        polyline: old.polyline, future: old.future))
            } else {
                let future = old.flatMap { start == $0.start - offset && end == $0.end - offset ? $0.future : nil }
                sections.append(Self.section(points: points, start: start, end: end, future: future))
            }
            if end == points.count - 1 { break }
            start = end
        }
    }

    private static func section(points: [MKMapPoint], start: Int, end: Int, future: MKPolyline? = nil) -> Section {
        var values = Array(points[start...end])
        var prefix = 0
        if start > 0, let tail = sharedTail(previous: points[start - 1], current: points[start]) {
            values.insert(tail, at: 0)
            prefix = 1
        }
        let line = MKPolyline(points: values, count: values.count)
        // Each section's far end anchors its dash phase, independently of the marker.
        let dots: MKPolyline
        if let future { dots = future }
        else {
            let reversed = Array(points[start...end].reversed())
            dots = MKPolyline(points: reversed, count: reversed.count)
        }
        return Section(start: start, end: end, prefix: prefix, polyline: line,
                       future: dots)
    }

    static func sharedTail(previous: MKMapPoint, current: MKMapPoint) -> MKMapPoint? {
        let distance = hypot(previous.x - current.x, previous.y - current.y)
        guard distance > 0.001 else { return nil }
        let amount = min(1, 100 / distance)
        return MKMapPoint(x: current.x + (previous.x - current.x) * amount,
                          y: current.y + (previous.y - current.y) * amount)
    }

    private func clamped(_ value: Double) -> Double {
        min(Double(max(0, fullRoute.pointCount - 1)), max(0, value.isFinite ? value : position))
    }

    func updatePosition(_ value: Double, now: TimeInterval = CACurrentMediaTime()) -> OverlayChange {
        guard value.isFinite, !sections.isEmpty else { return OverlayChange() }
        position = clamped(value)
        let index = sectionIndex(containing: Int(position))
        guard index != activeIndex else { return OverlayChange() }
        activeIndex = index
        return reconcile(previous: overlays, previousDots: dots, now: now)
    }

    private func reconcile(previous: [MKOverlay], previousDots: Set<ObjectIdentifier>, now: TimeInterval) -> OverlayChange {
        overlays = sections.indices.filter { $0 > activeIndex }.map { sections[$0].future as MKOverlay }
            + sections.indices.filter { $0 < activeIndex }.map { sections[$0].polyline as MKOverlay }
        let old = installed
        let next = Set(overlays.map { ObjectIdentifier($0) })
        installed = next
        var change = OverlayChange()
        for line in previous where !next.contains(ObjectIdentifier(line)) {
            if previousDots.contains(ObjectIdentifier(line)) { change.removedDots.append(line) }
            else { change.removed.append(line) }
        }
        for line in overlays where !old.contains(ObjectIdentifier(line)) {
            if isDots(line) { change.addedDots.append(line) }
            else { change.added.append(line) }
            pending[ObjectIdentifier(line)] = now + Self.renderTimeout
        }
        pending = pending.filter { next.contains($0.key) }
        rendering.formIntersection(next)
        return change
    }

    private func sectionIndex(containing fix: Int) -> Int {
        var lower = 0, upper = sections.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if sections[middle].start <= fix { lower = middle + 1 }
            else { upper = middle }
        }
        return max(0, lower - 1)
    }

    // A finish callback for a render already in flight cannot confirm a later overlay addition.
    func renderingBegan() { rendering = Set(pending.keys) }

    func renderingFinished(fullyRendered: Bool) {
        guard fullyRendered else { return }
        for id in rendering { pending.removeValue(forKey: id) }
        rendering.removeAll()
    }

    // A zoom leaves MapKit's tiles stale for a while. Only the blue nearest the marker is covered:
    // redrawing a week of visible route and dots every frame would cost more than it hides.
    func coverDuringCameraChange(now: TimeInterval = CACurrentMediaTime()) {
        expireCoverage(now: now)
        var budget = Self.cameraCoverageSegments
        for section in sections[..<min(activeIndex, sections.count)].reversed() {
            budget -= section.end - section.start
            guard budget >= 0 else { break }
            let id = ObjectIdentifier(section.polyline)
            if installed.contains(id), pending[id] == nil { pending[id] = now + Self.renderTimeout }
        }
    }

    func expireCoverage(now: TimeInterval = CACurrentMediaTime()) {
        guard pending.values.contains(where: { $0 <= now }) else { return }
        pending = pending.filter { $0.value > now }
        rendering.formIntersection(pending.keys)
    }

    func layerCoverage(future: Bool, now: TimeInterval = CACurrentMediaTime()) -> [Coverage] {
        expireCoverage(now: now)
        var result: [Coverage] = []
        if !pending.isEmpty {
            for (index, section) in sections.enumerated() {
                guard future ? index > activeIndex : index < activeIndex else { continue }
                let line = future ? section.future : section.polyline
                guard pending[ObjectIdentifier(line)] != nil else { continue }
                result.append(coverage(section, future: future, marker: false))
            }
        }
        if !sections.isEmpty {
            let section = sections[activeIndex]
            if future ? position < Double(section.end) : position > Double(section.start) {
                result.append(coverage(section, future: future, marker: true))
            }
        }
        return result
    }

    private func coverage(_ section: Section, future: Bool, marker: Bool) -> Coverage {
        let rect = section.polyline.boundingMapRect
        return Coverage(start: section.start, end: section.end, prefix: !future && section.prefix > 0,
                        marker: marker, bounds: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
    }

    // Keep plain MKPolylineRenderer: path renderer subclasses become upscaled bitmap tiles.
    func renderer(for overlay: MKOverlay) -> MKOverlayPathRenderer? {
        let id = ObjectIdentifier(overlay)
        guard let line = overlay as? MKPolyline, dots.contains(id) || trails.contains(id) else { return nil }
        let renderer = MKPolylineRenderer(polyline: line)
        renderer.lineJoin = .round
        if dots.contains(id) {
            renderer.lineWidth = ReplayRouteStyle.futureWidth
            renderer.strokeColor = ReplayRouteStyle.futureColor
            renderer.lineDashPattern = [1, 5]
            renderer.lineCap = .round
        } else {
            renderer.lineWidth = ReplayRouteStyle.pastWidth
            renderer.strokeColor = .systemBlue
            renderer.lineCap = .butt
        }
        return renderer
    }

#if targetEnvironment(simulator)
    var auditValues: [String: Double] {
        ["nativeSectionCount": Double(sections.count),
         "nativeSectionStart": Double(sections.isEmpty ? 0 : sections[activeIndex].start)]
    }
#endif
}

// A flat Mercator map projects through one homography, including camera pitch. Validate the
// fit independently and at each covered section; globe/terrain or horizon cases use MapKit.
@MainActor
struct ReplayScreenProjection {
    let samples: [CGPoint]
    private let origin: MKMapPoint
    private let unit: Double
    private let matrix: [Double]?
    private let map: MKMapView
    private let container: UIView

    init(map: MKMapView, container: UIView) {
        self.map = map
        self.container = container
        origin = MKMapPoint(map.camera.centerCoordinate)
        unit = max(1, map.visibleMapRect.width)
        var source: [CGPoint] = [], target: [CGPoint] = []
        for (x, y) in [(0.2, 0.25), (0.8, 0.25), (0.8, 0.75), (0.2, 0.75)] {
            let screen = CGPoint(x: map.bounds.minX + map.bounds.width * x, y: map.bounds.minY + map.bounds.height * y)
            let point = MKMapPoint(map.convert(screen, toCoordinateFrom: map))
            source.append(Self.normalized(point, origin: origin, unit: unit))
            let converted = map.convert(Self.wrapped(point).coordinate, toPointTo: container)
            target.append(CGPoint(x: converted.x - container.bounds.minX, y: converted.y - container.bounds.minY))
        }
        let candidate = map.camera.centerCoordinateDistance < 2_000_000 ? Self.fit(source, target) : nil
        var valid = candidate != nil
        if let candidate {
            for (x, y) in [(0.05, 0.05), (0.95, 0.05), (0.5, 0.5), (0.05, 0.95), (0.95, 0.95)] {
                let screen = CGPoint(x: map.bounds.minX + map.bounds.width * x, y: map.bounds.minY + map.bounds.height * y)
                let point = MKMapPoint(map.convert(screen, toCoordinateFrom: map))
                let expected = map.convert(Self.wrapped(point).coordinate, toPointTo: container)
                let actual = Self.project(Self.normalized(point, origin: origin, unit: unit), matrix: candidate)
                if !Self.close(actual, CGPoint(x: expected.x - container.bounds.minX, y: expected.y - container.bounds.minY)) { valid = false; break }
            }
        }
        matrix = valid ? candidate : nil
        samples = target + source + [CGPoint(x: origin.x, y: origin.y), CGPoint(x: unit, y: valid ? 1 : 0)]
    }

    private static func wrapped(_ point: MKMapPoint) -> MKMapPoint {
        let world = MKMapRect.world.width
        var x = point.x.truncatingRemainder(dividingBy: world)
        if x < 0 { x += world }
        return MKMapPoint(x: x, y: point.y)
    }

    private static func normalized(_ point: MKMapPoint, origin: MKMapPoint, unit: Double) -> CGPoint {
        let world = MKMapRect.world.width
        var dx = point.x - origin.x
        dx -= (dx / world).rounded() * world
        return CGPoint(x: dx / unit, y: (point.y - origin.y) / unit)
    }

    private static func close(_ a: CGPoint?, _ b: CGPoint) -> Bool {
        guard let a, a.x.isFinite, a.y.isFinite, b.x.isFinite, b.y.isFinite else { return false }
        return hypot(a.x - b.x, a.y - b.y) <= 0.2
    }

    func direct(_ point: MKMapPoint) -> CGPoint {
        let value = map.convert(Self.wrapped(point).coordinate, toPointTo: container)
        return CGPoint(x: value.x - container.bounds.minX, y: value.y - container.bounds.minY)
    }

    func point(_ point: MKMapPoint, fast: Bool = true) -> CGPoint {
        if fast, let matrix, let value = Self.project(Self.normalized(point, origin: origin, unit: unit), matrix: matrix) { return value }
        return direct(point)
    }

    func canProject(_ route: MKPolyline, start: Int, end: Int) -> Bool {
        guard matrix != nil else { return false }
        for part in 0...4 {
            let point = route.points()[start + (end - start) * part / 4]
            if !Self.close(self.point(point), direct(point)) { return false }
        }
        return true
    }

    func isVisible(_ bounds: CGRect) -> Bool {
        let rect = map.visibleMapRect
        guard rect.width < MKMapRect.world.width / 2 else { return true }
        let world = MKMapRect.world.width
        let shift = ((Double(bounds.midX) - rect.midX) / world).rounded() * world
        let shifted = bounds.offsetBy(dx: -shift, dy: 0)
        let visible = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height)
        return visible.insetBy(dx: -unit * 0.05, dy: -unit * 0.05).intersects(shifted.insetBy(dx: -1, dy: -1))
    }

    private static func project(_ p: CGPoint, matrix m: [Double]) -> CGPoint? {
        let x = Double(p.x), y = Double(p.y), w = m[6] * x + m[7] * y + 1
        guard w.isFinite, w > 0.000001 else { return nil }
        return CGPoint(x: (m[0] * x + m[1] * y + m[2]) / w, y: (m[3] * x + m[4] * y + m[5]) / w)
    }

    private static func fit(_ source: [CGPoint], _ target: [CGPoint]) -> [Double]? {
        var rows: [[Double]] = []
        for (p, q) in zip(source, target) {
            let x = Double(p.x), y = Double(p.y), u = Double(q.x), v = Double(q.y)
            rows.append([x, y, 1, 0, 0, 0, -u * x, -u * y, u])
            rows.append([0, 0, 0, x, y, 1, -v * x, -v * y, v])
        }
        for column in 0..<8 {
            guard let pivot = (column..<8).max(by: { abs(rows[$0][column]) < abs(rows[$1][column]) }),
                  abs(rows[pivot][column]) > 1e-12 else { return nil }
            rows.swapAt(column, pivot)
            let divisor = rows[column][column]
            for j in column...8 { rows[column][j] /= divisor }
            for i in 0..<8 where i != column {
                let amount = rows[i][column]
                for j in column...8 { rows[i][j] -= amount * rows[column][j] }
            }
        }
        let result = rows.map { $0[8] }
        return result.allSatisfy(\.isFinite) ? result : nil
    }
}

@MainActor
final class ReplayTrailLayer: CAShapeLayer {
    private(set) var coordinate: CLLocationCoordinate2D?
    private(set) var showsFuture = false
    private struct Projection: Equatable {
        let route: ObjectIdentifier
        let position: Double
        let coverage: [ReplayRoutePresentation.Coverage]
        let coordinate: ReplayCoordinate
        let samples: [CGPoint]
        let center: CGPoint
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

    convenience init(future: Bool) {
        self.init()
        guard future else { return }
        showsFuture = true
        lineWidth = ReplayRouteStyle.futureWidth
        lineCap = .round
        lineDashPattern = [1, 5]
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
                coverage: [ReplayRoutePresentation.Coverage], projection screen: ReplayScreenProjection,
                on map: MKMapView, below marker: MKAnnotationView) {
        guard position.isFinite, route.pointCount > 0, CLLocationCoordinate2DIsValid(coordinate),
              let container = marker.superview else { hide(); return }
        let value = min(Double(route.pointCount - 1), max(0, position)), fix = Int(value)
        let endpoint = screen.direct(MKMapPoint(coordinate))
        let next = Projection(route: ObjectIdentifier(route), position: value, coverage: coverage,
            coordinate: ReplayCoordinate(coordinate), samples: screen.samples, center: endpoint,
            bounds: container.bounds, scale: map.traitCollection.displayScale,
            appearance: map.traitCollection.userInterfaceStyle)
        guard projection != next || superlayer !== container.layer else { return }
        let path = CGMutablePath()
        for span in coverage {
            guard span.start >= 0, span.end < route.pointCount, span.end >= span.start else { continue }
            guard screen.isVisible(span.bounds) else { continue }
            let start = span.marker && showsFuture ? fix + 1 : span.start
            let end = span.marker && !showsFuture ? fix : span.end
            guard end >= start else { continue }
            let fast = screen.canProject(route, start: start, end: end)
            var began = false
            func add(_ point: CGPoint) -> Bool {
                guard point.x.isFinite, point.y.isFinite else { return false }
                if !began { path.move(to: point); began = true }
                else { path.addLine(to: point) }
                return true
            }
            if !showsFuture, span.prefix, start > 0,
               let tail = ReplayRoutePresentation.sharedTail(previous: route.points()[start - 1], current: route.points()[start]) {
                guard add(screen.point(tail, fast: fast)) else { hide(); return }
            }
            if showsFuture {
                for index in stride(from: end, through: start, by: -1) {
                    guard add(screen.point(route.points()[index], fast: fast)) else { hide(); return }
                }
            } else {
                for index in start...end {
                    guard add(screen.point(route.points()[index], fast: fast)) else { hide(); return }
                }
            }
            if span.marker {
                guard add(endpoint) else { hide(); return }
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if superlayer !== container.layer { container.layer.insertSublayer(self, below: marker.layer) }
        frame = container.bounds
        contentsScale = map.traitCollection.displayScale
        strokeColor = (showsFuture ? ReplayRouteStyle.futureColor : UIColor.systemBlue)
            .resolvedColor(with: map.traitCollection).cgColor
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
