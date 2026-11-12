import MapKit

// Replace the snapshot when tracks change. Keys are local day starts; loaded days take precedence.
final class ReplayDayTracks {
    let days: [Date: [MKMapPoint]]
    let segments: [Date: [[MKMapPoint]]]
    let needsSimplification: Bool

    init(days: [Date: [MKMapPoint]]) {
        self.days = days
        segments = days.mapValues { [$0] }
        needsSimplification = false
    }

    init(segments: [Date: [[MKMapPoint]]]) {
        self.segments = segments
        days = segments.mapValues { $0.flatMap { $0 } }
        needsSimplification = true
    }
}

// Camera bounds only; these corners never enter the route or its marker indices.
final class ReplayHistoryFrame {
    let coordinates: [CLLocationCoordinate2D]

    init?(points: [RecordedLocation], tracks: ReplayDayTracks?, range: ClosedRange<Date>, calendar: Calendar) {
        var origin: Double?, minX = Double.infinity, minY = Double.infinity
        var maxX = -Double.infinity, maxY = -Double.infinity
        func include(_ point: MKMapPoint) {
            if origin == nil { origin = point.x }
            let x = point.x - ((point.x - origin!) / MKMapRect.world.width).rounded() * MKMapRect.world.width
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, point.y); maxY = max(maxY, point.y)
        }
        let first = HistoryLandmarks.lowerBound(points.count) { points[$0].timestamp >= range.lowerBound }
        let last = HistoryLandmarks.lowerBound(points.count) { points[$0].timestamp > range.upperBound }
        for point in points[first..<last] { include(MKMapPoint(point.coordinate)) }
        for (day, lines) in tracks?.segments ?? [:]
            where day <= range.upperBound && calendar.date(byAdding: .day, value: 1, to: day)! > range.lowerBound {
            for line in lines { for point in line { include(point) } }
        }
        guard origin != nil else { return nil }
        coordinates = [MKMapPoint(x: minX, y: minY).coordinate, MKMapPoint(x: maxX, y: minY).coordinate,
                       MKMapPoint(x: minX, y: maxY).coordinate, MKMapPoint(x: maxX, y: maxY).coordinate]
    }
}

enum ReplayRouteDetail {
    static let day: TimeInterval = 86_400
    static let maximumSegments = 1_024
    static let maximumLength = 100_000.0

    static func simplified(secondsPerBar: TimeInterval) -> Bool {
        secondsPerBar.isFinite && secondsPerBar >= day
    }

    // Half octaves keep the error between 0.7 and 1 screen point, without rebuilding during zoom.
    static func zoomBucket(mapPointsPerPoint: Double) -> Int {
        guard mapPointsPerPoint.isFinite, mapPointsPerPoint > 0 else { return 0 }
        return Int(min(80, max(-80, floor(log2(mapPointsPerPoint) * 2))))
    }

    static func tolerance(bucket: Int) -> Double { exp2(Double(bucket) / 2) }

    static func distanceSquared(_ point: MKMapPoint, from a: MKMapPoint, to b: MKMapPoint) -> Double {
        let dx = b.x - a.x, dy = b.y - a.y, length = dx * dx + dy * dy
        let fraction = length > 0 ? min(1, max(0, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length)) : 0
        let x = point.x - a.x - fraction * dx, y = point.y - a.y - fraction * dy
        return x * x + y * y
    }

    // Iterative Douglas–Peucker; long jumps and the opened trip cannot be shortcut away.
    static func retainedIndices(_ points: [MKMapPoint], tolerance: Double,
                                preserving: ClosedRange<Int>? = nil) -> [Int] {
        guard points.count > 2 else { return Array(points.indices) }
        var kept = IndexSet([0, points.count - 1])
        if let preserving {
            let lower = max(0, preserving.lowerBound), upper = min(points.count - 1, preserving.upperBound)
            if lower <= upper { kept.insert(integersIn: lower..<(upper + 1)) }
        }
        for index in 1..<points.count where hypot(points[index].x - points[index - 1].x,
                                                points[index].y - points[index - 1].y) > maximumLength {
            kept.insert(index - 1); kept.insert(index)
        }
        var work = Array(zip(kept, kept.dropFirst()))
        let squared = max(0, tolerance.isFinite ? tolerance : 0) * max(0, tolerance.isFinite ? tolerance : 0)
        while let (first, last) = work.popLast() {
            guard last > first + 1 else { continue }
            var furthest = first, distance = squared
            for index in (first + 1)..<last {
                let value = distanceSquared(points[index], from: points[first], to: points[last])
                if value > distance { furthest = index; distance = value }
            }
            if furthest != first {
                kept.insert(furthest)
                work.append((first, furthest)); work.append((furthest, last))
            }
        }
        return Array(kept)
    }
}

struct ReplayDayGeometry {
    let points: [MKMapPoint]
    let spans: [ClosedRange<Int>]
    let sourceIndices: [Int]
    let renderedIndices: [Int]
    var sourceIDs: [Int64] = []

    func rebased(to ids: [Int64]) -> ReplayDayGeometry? {
        guard sourceIDs.count == renderedIndices.count else { return nil }
        var offsets: [Int64: Int] = [:]
        for (index, id) in ids.enumerated() { offsets[id] = index }
        var shift: Int?
        for (index, id) in sourceIDs.enumerated() {
            guard let offset = offsets[id] else { continue }
            let delta = offset - sourceIndices[index]
            if let shift, shift != delta { return nil }
            shift = delta
        }
        guard let shift else { return nil }
        // Retain the outgoing anchor just before the new first point, for its fractional split.
        return ReplayDayGeometry(points: points, spans: spans, sourceIndices: sourceIndices.map { $0 + shift },
                                 renderedIndices: renderedIndices, sourceIDs: sourceIDs)
    }

    func position(for source: Double) -> Double {
        guard source.isFinite, let first = sourceIndices.first, let last = sourceIndices.last else { return 0 }
        if source <= Double(first) { return Double(renderedIndices[0]) }
        if source >= Double(last) { return Double(renderedIndices[renderedIndices.count - 1]) }
        var lower = 0, upper = sourceIndices.count - 1
        while upper - lower > 1 {
            let middle = (lower + upper) / 2
            if Double(sourceIndices[middle]) <= source { lower = middle } else { upper = middle }
        }
        let fraction = (source - Double(sourceIndices[lower])) / Double(sourceIndices[upper] - sourceIndices[lower])
        return Double(renderedIndices[lower]) + fraction * Double(renderedIndices[upper] - renderedIndices[lower])
    }

    func range(for source: ClosedRange<Int>) -> ClosedRange<Int> {
        Int(position(for: Double(source.lowerBound)))...Int(position(for: Double(source.upperBound)))
    }
}

// Confined to the cache's utility queue. Reloads compare each day's contents, never just its endpoints.
struct ReplayDayRouteBuilder {
    private struct Source {
        let points: [MKMapPoint]
        let ids: [Int64]
        let dates: [Date]
        let offset: Int?
        let preserving: ClosedRange<Int>?
        var breaks = IndexSet()
        var simplify = false

        func matches(_ other: Source) -> Bool {
            ids == other.ids && dates == other.dates && preserving == other.preserving && breaks == other.breaks
                && simplify == other.simplify
                && (offset == nil) == (other.offset == nil) && points.count == other.points.count
                && zip(points, other.points).allSatisfy { pair in pair.0.x == pair.1.x && pair.0.y == pair.1.y }
        }
    }
    private struct Entry {
        let source: Source
        var buckets: [Int: [Int]] = [:]
    }
    private var entries: [Date: Entry] = [:]
    private var calendar: Calendar?
    private(set) var simplificationCount = 0
    var cachedDays: Set<Date> { Set(entries.keys) }

    mutating func build(points: [MKMapPoint], ids: [Int64], dates: [Date], tracks: ReplayDayTracks?,
                        calendar: Calendar, bucket: Int, highlight: ClosedRange<Int>?) -> ReplayDayGeometry {
        precondition(points.count == ids.count && points.count == dates.count)
        if self.calendar != calendar { entries.removeAll(); self.calendar = calendar }
        var sources: [Date: Source] = [:]
        var first = 0
        while first < dates.count {
            let day = calendar.startOfDay(for: dates[first])
            let end = calendar.date(byAdding: .day, value: 1, to: day)!
            var last = first + 1
            while last < dates.count, dates[last] < end { last += 1 }
            // Join consecutive loaded days, but never bridge missing days or an external track.
            let previousDay = calendar.date(byAdding: .day, value: -1, to: day)!
            let start = first > 0 && dates[first - 1] >= previousDay ? first - 1 : first
            let preserved = highlight.flatMap { range -> ClosedRange<Int>? in
                let lower = max(start, range.lowerBound), upper = min(last - 1, range.upperBound)
                return lower <= upper ? (lower - start)...(upper - start) : nil
            }
            sources[day] = Source(points: Array(points[start..<last]), ids: Array(ids[start..<last]),
                dates: Array(dates[start..<last]), offset: start, preserving: preserved)
            first = last
        }
        for (day, lines) in tracks?.segments ?? [:] where sources[day] == nil {
            var values: [MKMapPoint] = [], breaks = IndexSet()
            for line in lines where !line.isEmpty && line.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) {
                var unwrapped = line
                for index in unwrapped.indices.dropFirst() {
                    unwrapped[index].x -= ((unwrapped[index].x - unwrapped[index - 1].x) / MKMapRect.world.width).rounded()
                        * MKMapRect.world.width
                }
                breaks.insert(values.count)
                values += unwrapped
            }
            guard !values.isEmpty else { continue }
            sources[day] = Source(points: values, ids: [], dates: [], offset: nil, preserving: nil, breaks: breaks,
                                  simplify: tracks?.needsSimplification ?? false)
        }
        entries = entries.filter { sources[$0.key] != nil }
        var output: [MKMapPoint] = [], spans: [ClosedRange<Int>] = [], sourceIndices: [Int] = [], renderedIndices: [Int] = []
        for day in sources.keys.sorted() {
            let source = sources[day]!
            var entry = entries[day].flatMap { $0.source.matches(source) ? $0 : nil } ?? Entry(source: source)
            let indices: [Int]
            if let cached = entry.buckets[bucket] { indices = cached }
            else {
                if source.offset == nil, !source.simplify { indices = Array(source.points.indices) }
                else if source.offset == nil {
                    let starts = Array(source.breaks) + [source.points.count]
                    indices = zip(starts, starts.dropFirst()).flatMap { first, end in
                        ReplayRouteDetail.retainedIndices(Array(source.points[first..<end]),
                            tolerance: ReplayRouteDetail.tolerance(bucket: bucket)).map { $0 + first }
                    }
                }
                else {
                    indices = ReplayRouteDetail.retainedIndices(source.points,
                        tolerance: ReplayRouteDetail.tolerance(bucket: bucket), preserving: source.preserving)
                    simplificationCount += 1
                }
                // Bound zoom variants; days no longer in the input are evicted above.
                if entry.buckets.count >= 4, let oldest = entry.buckets.keys.max(by: { abs($0 - bucket) < abs($1 - bucket) }) {
                    entry.buckets.removeValue(forKey: oldest)
                }
                entry.buckets[bucket] = indices
            }
            entries[day] = entry
            var start = output.count
            for index in indices {
                if source.breaks.contains(index), start < output.count {
                    spans.append(start...(output.count - 1))
                    start = output.count
                }
                let sourceIndex = source.offset.map { $0 + index }
                if let sourceIndex, sourceIndices.last == sourceIndex, renderedIndices.last == output.count - 1 {
                    start = output.count - 1
                    continue
                }
                if let sourceIndex { sourceIndices.append(sourceIndex); renderedIndices.append(output.count) }
                output.append(source.points[index])
            }
            if start < output.count { spans.append(start...(output.count - 1)) }
        }
        return ReplayDayGeometry(points: output, spans: spans, sourceIndices: sourceIndices,
                                 renderedIndices: renderedIndices, sourceIDs: sourceIndices.map { ids[$0] })
    }
}

final class ReplayDayRouteCache {
    private let queue = DispatchQueue(label: "me.joshpatra.WhereWolf.replay-days", qos: .utility)
    private var builder = ReplayDayRouteBuilder()

    func request(route: MKPolyline, ids: [Int64], dates: [Date], tracks: ReplayDayTracks?, calendar: Calendar,
                 bucket: Int, highlight: ClosedRange<Int>?, completion: @escaping (ReplayDayGeometry) -> Void) {
        queue.async { [self] in
            let points = Array(UnsafeBufferPointer(start: route.points(), count: route.pointCount))
            let geometry = builder.build(points: points, ids: ids, dates: dates, tracks: tracks,
                calendar: calendar, bucket: bucket, highlight: highlight)
            DispatchQueue.main.async { completion(geometry) }
        }
    }
}

enum ReplayRouteStyle {
    static let pastWidth: CGFloat = 2.5
    static let futureWidth: CGFloat = 1.25
    static let futureColor = UIColor.systemTeal.withAlphaComponent(0.55)
    // Wider than blue so an opened trip covers its own blue and dots completely.
    static let highlightWidth: CGFloat = 4
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
        var addedHighlight: [MKOverlay] = []
        // An opened trip's red, already on the map, that new blue must stay beneath.
        var ceiling: MKOverlay?

        var isEmpty: Bool {
            added.isEmpty && removed.isEmpty && addedDots.isEmpty && removedDots.isEmpty && addedHighlight.isEmpty
        }

        mutating func append(_ other: Self) {
            added += other.added; removed += other.removed
            addedDots += other.addedDots; removedDots += other.removedDots
            addedHighlight += other.addedHighlight
            ceiling = other.ceiling ?? ceiling
        }

        @MainActor func apply(to map: MKMapView) {
            // Remove obsolete colors before installing their replacements. Dots stay below blue, blue below red.
            let gone = removed + removedDots
            if !gone.isEmpty { map.removeOverlays(gone) }
            for line in addedDots { map.insertOverlay(line, at: 0, level: .aboveRoads) }
            if let ceiling { for line in added { map.insertOverlay(line, below: ceiling) } }
            else if !added.isEmpty { map.addOverlays(added, level: .aboveRoads) }
            if !addedHighlight.isEmpty { map.addOverlays(addedHighlight, level: .aboveRoads) }
        }
    }

    static let maximumSegments = ReplayRouteDetail.maximumSegments
    private static let maximumLength = ReplayRouteDetail.maximumLength
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
    private var unrendered = Set<ObjectIdentifier>()
    private(set) var highlightOverlays: [MKOverlay] = []
    private var reds = Set<ObjectIdentifier>()
    private var highlightKey: (range: ClosedRange<Int>, first: MKMapPoint, last: MKMapPoint)?

    var futureSections: [MKPolyline] { sections.map(\.future) }
    var nextCoverageDeadline: TimeInterval? { pending.values.min() }

    init(coordinates: [CLLocationCoordinate2D], pointIDs: [Int64]? = nil,
         position: Double = 0, now: TimeInterval = CACurrentMediaTime()) {
        _ = update(coordinates: coordinates, pointIDs: pointIDs ?? coordinates.indices.map { Int64($0) },
                   position: position, now: now)
    }

    init(dayGeometry geometry: ReplayDayGeometry, position: Double, now: TimeInterval = CACurrentMediaTime()) {
        let points = geometry.points
        fullRoute = MKPolyline(points: points, count: points.count)
        for span in geometry.spans {
            var start = span.lowerBound
            while start < span.upperBound {
                var end = start + 1
                var length = hypot(points[end].x - points[start].x, points[end].y - points[start].y)
                let tail = start > span.lowerBound && length <= Self.maximumLength - 100
                    ? Self.sharedTail(previous: points[start - 1], current: points[start]) : nil
                let prefix = tail == nil ? 0 : 1
                if let tail { length += hypot(tail.x - points[start].x, tail.y - points[start].y) }
                while end < span.upperBound, end - start + prefix < Self.maximumSegments {
                    let step = hypot(points[end + 1].x - points[end].x, points[end + 1].y - points[end].y)
                    if length + step > Self.maximumLength { break }
                    length += step; end += 1
                }
                var values = Array(points[start...end])
                if let tail { values.insert(tail, at: 0) }
                let reversed = Array(points[start...end].reversed())
                sections.append(Section(start: start, end: end, prefix: prefix,
                    polyline: MKPolyline(points: values, count: values.count),
                    future: MKPolyline(points: reversed, count: reversed.count)))
                start = end
            }
            if span.lowerBound == span.upperBound {
                let values = [points[span.lowerBound]]
                sections.append(Section(start: span.lowerBound, end: span.upperBound, prefix: 0,
                    polyline: MKPolyline(points: values, count: 1), future: MKPolyline(points: values, count: 1)))
            }
        }
        dots = Set(sections.map { ObjectIdentifier($0.future) })
        trails = Set(sections.map { ObjectIdentifier($0.polyline) })
        self.position = clamped(geometry.position(for: position))
        activeIndex = sectionIndex(containing: Int(self.position))
        _ = reconcile(previous: [], previousDots: [], now: now)
    }

    // Handoffs need a real render begun after installation; coverage's timeout is not evidence of one.
    var readyForHandoff: Bool { unrendered.isEmpty }

    func prepareForDisplay(ceiling: MKOverlay?, now: TimeInterval = CACurrentMediaTime()) -> OverlayChange {
        rendering.removeAll()
        for overlay in overlays {
            let id = ObjectIdentifier(overlay)
            unrendered.insert(id)
            pending[id] = now + Self.renderTimeout
        }
        return OverlayChange(added: overlays.filter { !isDots($0) }, addedDots: overlays.filter { isDots($0) }, ceiling: ceiling)
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
        installed = next.union(reds)
        var change = OverlayChange(ceiling: highlightOverlays.first)
        for line in previous where !next.contains(ObjectIdentifier(line)) {
            if previousDots.contains(ObjectIdentifier(line)) { change.removedDots.append(line) }
            else { change.removed.append(line) }
        }
        for line in overlays where !old.contains(ObjectIdentifier(line)) {
            if isDots(line) { change.addedDots.append(line) }
            else { change.added.append(line) }
            pending[ObjectIdentifier(line)] = now + Self.renderTimeout
            unrendered.insert(ObjectIdentifier(line))
        }
        pending = pending.filter { installed.contains($0.key) }
        unrendered.formIntersection(next)
        rendering.formIntersection(installed)
        return change
    }

    // An opened trip draws as MapKit overlays, sectioned like the blue, so it moves with the map itself.
    func highlight(_ range: ClosedRange<Int>?, now: TimeInterval = CACurrentMediaTime()) -> OverlayChange {
        let points = fullRoute.points()
        let wanted = range.flatMap { $0.lowerBound >= 0 && $0.upperBound < fullRoute.pointCount ? $0 : nil }
        if let wanted, let key = highlightKey, key.range == wanted,
           Self.same(key.first, points[wanted.lowerBound]), Self.same(key.last, points[wanted.upperBound]) {
            return OverlayChange()
        }
        var change = OverlayChange(removed: highlightOverlays)
        for id in reds { pending.removeValue(forKey: id); rendering.remove(id); installed.remove(id) }
        highlightOverlays = []
        reds = []
        highlightKey = nil
        guard let wanted else { return change }
        highlightKey = (wanted, points[wanted.lowerBound], points[wanted.upperBound])
        var start = wanted.lowerBound
        while start < wanted.upperBound {
            var end = start + 1
            var length = hypot(points[end].x - points[start].x, points[end].y - points[start].y)
            while end < wanted.upperBound, end - start < Self.maximumSegments {
                let step = hypot(points[end + 1].x - points[end].x, points[end + 1].y - points[end].y)
                if length + step > Self.maximumLength { break }
                length += step
                end += 1
            }
            highlightOverlays.append(MKPolyline(points: points + start, count: end - start + 1))
            start = end
        }
        reds = Set(highlightOverlays.map { ObjectIdentifier($0) })
        installed.formUnion(reds)
        for id in reds { pending[id] = now + Self.renderTimeout }
        change.addedHighlight = highlightOverlays
        return change
    }

    // True once MapKit has drawn every red section, so the layer that drew the trip in can go.
    func highlightRendered(now: TimeInterval = CACurrentMediaTime()) -> Bool {
        expireCoverage(now: now)
        return highlightKey != nil && reds.allSatisfy { pending[$0] == nil }
    }

    private static func same(_ a: MKMapPoint, _ b: MKMapPoint) -> Bool { a.x == b.x && a.y == b.y }

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
    func renderingBegan() { rendering = Set(pending.keys).union(unrendered) }

    func renderingFinished(fullyRendered: Bool) {
        guard fullyRendered else { return }
        for id in rendering { pending.removeValue(forKey: id) }
        unrendered.subtract(rendering)
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
        rendering.formIntersection(Set(pending.keys).union(unrendered))
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
        guard let line = overlay as? MKPolyline, dots.contains(id) || trails.contains(id) || reds.contains(id) else { return nil }
        let renderer = MKPolylineRenderer(polyline: line)
        renderer.lineJoin = .round
        if reds.contains(id) {
            renderer.lineWidth = ReplayRouteStyle.highlightWidth
            renderer.strokeColor = .systemRed
            renderer.lineCap = .round
        } else if dots.contains(id) {
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

@MainActor
final class ReplayRouteDisplay {
    private final class Variant {
        let presentation: ReplayRoutePresentation
        var geometry: ReplayDayGeometry?

        init(_ presentation: ReplayRoutePresentation, geometry: ReplayDayGeometry? = nil) {
            self.presentation = presentation; self.geometry = geometry
        }

        func position(_ source: Double) -> Double { geometry?.position(for: source) ?? source }
    }

    let fine: ReplayRoutePresentation
    private let original: Variant
    private var current: Variant
    private var incoming: Variant?

    init(_ fine: ReplayRoutePresentation) {
        self.fine = fine
        original = Variant(fine)
        current = original
    }

    var presentation: ReplayRoutePresentation { current.presentation }
    var isSimplified: Bool { current.geometry != nil }
    var isSwitching: Bool { incoming != nil }
    var wantsSimplified: Bool { (incoming ?? current).geometry != nil }
    var overlays: [MKOverlay] { current.presentation.overlays + (incoming?.presentation.overlays ?? []) + fine.highlightOverlays }
    var nextCoverageDeadline: TimeInterval? {
        [current.presentation.nextCoverageDeadline, incoming?.presentation.nextCoverageDeadline,
         fine.nextCoverageDeadline].compactMap { $0 }.min()
    }

    func position(_ source: Double) -> Double { current.position(source) }
    func range(_ source: ClosedRange<Int>) -> ClosedRange<Int> { current.geometry?.range(for: source) ?? source }

    func updatePosition(_ source: Double, now: TimeInterval = CACurrentMediaTime()) -> ReplayRoutePresentation.OverlayChange {
        if current === original, incoming == nil { return fine.updatePosition(source, now: now) }
        var change = ReplayRoutePresentation.OverlayChange()
        if current === original || incoming === original { change = fine.updatePosition(source, now: now) }
        for variant in [current, incoming].compactMap({ $0 }) where variant !== original {
            change.append(variant.presentation.updatePosition(variant.position(source), now: now))
        }
        change.ceiling = fine.highlightOverlays.first
        return change
    }

    // Keep the outgoing days while replacements build, rebasing the marker by record ID. Presenting all
    // fine layers during a coarse reload would project months of raw points on each frame.
    func reload(coordinates: [CLLocationCoordinate2D], ids: [Int64], position: Double) -> ReplayRoutePresentation.OverlayChange {
        if let rebased = current.geometry?.rebased(to: ids) {
            var change = ReplayRoutePresentation.OverlayChange(removed: incoming?.presentation.overlays ?? [])
            incoming = nil
            _ = fine.update(coordinates: coordinates, pointIDs: ids, position: position)
            current.geometry = rebased
            change.append(current.presentation.updatePosition(rebased.position(for: position)))
            change.ceiling = fine.highlightOverlays.first
            return change
        }
        let fineShown = current === original || incoming === original
        var change = fine.update(coordinates: coordinates, pointIDs: ids, position: position)
        if !fineShown { change = fine.prepareForDisplay(ceiling: fine.highlightOverlays.first) }
        for variant in [current, incoming].compactMap({ $0 }) where variant !== original {
            change.removed += variant.presentation.overlays
        }
        current = original; incoming = nil
        return change
    }

    func stage(_ geometry: ReplayDayGeometry?, position: Double,
               now: TimeInterval = CACurrentMediaTime()) -> ReplayRoutePresentation.OverlayChange {
        var change = ReplayRoutePresentation.OverlayChange()
        if let incoming { change.removed += incoming.presentation.overlays }
        incoming = nil
        guard geometry != nil || current !== original else { return change }
        let next = geometry.map {
            Variant(ReplayRoutePresentation(dayGeometry: $0, position: position, now: now), geometry: $0)
        } ?? original
        _ = next.presentation.updatePosition(next.position(position), now: now)
        incoming = next
        change.append(next.presentation.prepareForDisplay(ceiling: fine.highlightOverlays.first, now: now))
        return change
    }

    func finishHandoff() -> ReplayRoutePresentation.OverlayChange {
        guard let incoming, incoming.presentation.readyForHandoff else { return .init() }
        let change = ReplayRoutePresentation.OverlayChange(removed: current.presentation.overlays)
        current = incoming; self.incoming = nil
        return change
    }

    func renderingBegan() {
        fine.renderingBegan()
        for variant in [current, incoming].compactMap({ $0 }) where variant !== original { variant.presentation.renderingBegan() }
    }

    func renderingFinished(fullyRendered: Bool) {
        fine.renderingFinished(fullyRendered: fullyRendered)
        for variant in [current, incoming].compactMap({ $0 }) where variant !== original {
            variant.presentation.renderingFinished(fullyRendered: fullyRendered)
        }
    }

    func expireCoverage() {
        fine.expireCoverage()
        current.presentation.expireCoverage()
        incoming?.presentation.expireCoverage()
    }

    func renderer(for overlay: MKOverlay) -> MKOverlayPathRenderer? {
        if current === original, incoming == nil { return fine.contains(overlay) ? fine.renderer(for: overlay) : nil }
        if fine.highlightOverlays.contains(where: { $0 === overlay }) { return fine.renderer(for: overlay) }
        for variant in [current, incoming].compactMap({ $0 }) where variant.presentation.contains(overlay) {
            return variant.presentation.renderer(for: overlay)
        }
        return nil
    }
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
    private var tint: UIColor?
    private struct Projection: Equatable {
        let route: ObjectIdentifier
        let position: Double
        let coverage: [ReplayRoutePresentation.Coverage]
        let hiding: ClosedRange<Int>?
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
                   "strokeColor": NSNull(), "contentsScale": NSNull(), "strokeEnd": NSNull()]
    }

    convenience init(future: Bool) {
        self.init()
        guard future else { return }
        showsFuture = true
        lineWidth = ReplayRouteStyle.futureWidth
        lineCap = .round
        lineDashPattern = [1, 5]
    }

    convenience init(highlight: Bool) {
        self.init()
        guard highlight else { return }
        tint = .systemRed
        lineWidth = ReplayRouteStyle.highlightWidth
        lineCap = .round
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    func hide() {
        projection = nil
        coordinate = nil
        path = nil
        removeFromSuperlayer()
    }

    static let revealDuration: TimeInterval = 1.2

    // An opened trip draws itself from its start to its end once the camera arrives.
    func conceal() {
        removeAnimation(forKey: "reveal")
        strokeEnd = 0
    }

    func reveal(animated: Bool) {
        removeAnimation(forKey: "reveal")
        strokeEnd = 1
        guard animated else { return }
        let animation = CABasicAnimation(keyPath: "strokeEnd")
        animation.fromValue = 0
        animation.toValue = 1
        animation.duration = Self.revealDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        add(animation, forKey: "reveal")
    }

    // `hiding` leaves out the segments between those fixes, which an opened trip's red overlays draw instead:
    // every layer sits above every overlay.
    func update(route: MKPolyline, position: Double, coordinate: CLLocationCoordinate2D,
                coverage: [ReplayRoutePresentation.Coverage], hiding: ClosedRange<Int>? = nil,
                projection screen: ReplayScreenProjection, on map: MKMapView, below marker: MKAnnotationView) {
        guard position.isFinite, route.pointCount > 0, CLLocationCoordinate2DIsValid(coordinate),
              let container = marker.superview else { hide(); return }
        let value = min(Double(route.pointCount - 1), max(0, position)), fix = Int(value)
        let endpoint = screen.direct(MKMapPoint(coordinate))
        let next = Projection(route: ObjectIdentifier(route), position: value, coverage: coverage, hiding: hiding,
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
            // A point joins the path unless the segment leading to it, between fixes `from` and `to`, is hidden.
            func add(_ point: CGPoint, from: Int, to: Int) -> Bool {
                guard point.x.isFinite, point.y.isFinite else { return false }
                if !began || hiding.map({ min(from, to) >= $0.lowerBound && max(from, to) <= $0.upperBound }) == true {
                    path.move(to: point); began = true
                } else { path.addLine(to: point) }
                return true
            }
            if !showsFuture, span.prefix, start > 0,
               let tail = ReplayRoutePresentation.sharedTail(previous: route.points()[start - 1], current: route.points()[start]) {
                guard add(screen.point(tail, fast: fast), from: start - 1, to: start) else { hide(); return }
            }
            if showsFuture {
                for index in stride(from: end, through: start, by: -1) {
                    guard add(screen.point(route.points()[index], fast: fast), from: index + 1, to: index) else { hide(); return }
                }
            } else {
                for index in start...end {
                    guard add(screen.point(route.points()[index], fast: fast), from: index - 1, to: index) else { hide(); return }
                }
            }
            if span.marker {
                guard add(endpoint, from: fix, to: fix + 1) else { hide(); return }
            }
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if superlayer !== container.layer { container.layer.insertSublayer(self, below: marker.layer) }
        frame = container.bounds
        contentsScale = map.traitCollection.displayScale
        strokeColor = (tint ?? (showsFuture ? ReplayRouteStyle.futureColor : UIColor.systemBlue))
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
