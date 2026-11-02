import MapKit

struct ReplayCoordinate: Equatable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func interpolated(to other: ReplayCoordinate, fraction: Double) -> ReplayCoordinate {
        let start = MKMapPoint(coordinate)
        let end = MKMapPoint(other.coordinate)
        let worldWidth = MKMapRect.world.size.width
        var deltaX = end.x - start.x
        if deltaX > worldWidth / 2 { deltaX -= worldWidth }
        if deltaX < -worldWidth / 2 { deltaX += worldWidth }
        var x = start.x + deltaX * fraction
        if x < 0 { x += worldWidth }
        if x >= worldWidth { x -= worldWidth }
        return ReplayCoordinate(MKMapPoint(x: x, y: start.y + (end.y - start.y) * fraction).coordinate)
    }
}

struct ReplayPose: Equatable {
    let position: Double
    let coordinate: ReplayCoordinate
}

enum ReplayPacing {
    static let rates: [Double] = [0.25, 0.5, 1, 2, 5, 10, 25, 50]
    // Map speed grows with the square root of real speed, so walks stop crawling and highways
    // stop blurring: 1.4 m/s plays at about 21 m/s, and 30 m/s plays at about 99 m/s.
    private static let mapSpeedScale = 18.0
    private static let slowestMapSpeed = 20.0
    private static let longestWait: TimeInterval = 2

    static func segmentDuration(recordedInterval: TimeInterval, distance: CLLocationDistance, rate: Double) -> TimeInterval {
        baseDuration(recordedInterval: recordedInterval, distance: distance) / speed(rate)
    }

    // Duration = distance / (scale * sqrt(distance / interval)), never slower than a walk on the map.
    // Time keeps a small share so a brief stop still passes visibly, and a phone that logs only when
    // it moves leaves long silent gaps, so that share stays brief.
    static func baseDuration(recordedInterval: TimeInterval, distance: CLLocationDistance) -> TimeInterval {
        guard recordedInterval.isFinite, recordedInterval > 0 else { return 0.2 }
        let moved = distance.isFinite && distance > 0 ? distance : 0
        let travel = min(sqrt(moved * recordedInterval) / mapSpeedScale, moved / slowestMapSpeed)
        return min(16, max(1.0 / 240, travel, min(longestWait, recordedInterval / 300)))
    }

    // Being somewhere is part of the day, so a longer stay holds longer, up to seven hours.
    static func stayDuration(span: TimeInterval) -> TimeInterval {
        min(3, 1.25 + max(0, span) / 3_600 * 0.25)
    }

    // Faster rates shorten a stay only this far, or it would vanish between frames.
    static let shortestStay: TimeInterval = 1

    static func speed(_ rate: Double) -> Double {
        rate.isFinite && rate > 0 ? min(50, max(0.25, rate)) : 1
    }

    static func label(for rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

struct ReplayStay: Equatable {
    let start: Int
    let end: Int
    let span: TimeInterval
}

enum ReplayActivity: Equatable {
    case stayed(TimeInterval)
    case stopped
    case walking
    case running
    case cycling
    case driving
    case flying
    case moving

    var title: String {
        switch self {
        case .stayed(let span): return "Stayed \(Self.format(span))"
        case .stopped: return "Stopped"
        case .walking: return "Walking"
        case .running: return "Running"
        case .cycling: return "Cycling"
        case .driving: return "Driving"
        case .flying: return "Flying"
        case .moving: return "Moving"
        }
    }

    var symbol: String {
        switch self {
        case .stayed: return "mappin.and.ellipse"
        case .stopped: return "pause.circle"
        case .walking: return "figure.walk"
        case .running: return "figure.run"
        case .cycling: return "bicycle"
        case .driving: return "car.fill"
        case .flying: return "airplane"
        case .moving: return "location.north.line"
        }
    }

    static func format(_ span: TimeInterval) -> String {
        let minutes = Int((max(0, span) / 60).rounded())
        if minutes < 60 { return "\(minutes)m" }
        if minutes < 24 * 60 { return minutes % 60 == 0 ? "\(minutes / 60)h" : "\(minutes / 60)h \(minutes % 60)m" }
        return "\(minutes / (24 * 60))d \(minutes / 60 % 24)h"
    }

    static let stoppedSpeed = 0.5

    static func inferred(speed: Double) -> ReplayActivity {
        switch speed {
        case ..<stoppedSpeed: return .stopped
        case ..<2.7: return .walking
        case ..<5: return .running
        case ..<9: return .moving
        case ..<75: return .driving
        default: return .flying
        }
    }

    // Motion & Fitness knows a car at a red light is still driving. Location speed knows a phone
    // resting on a seat is not stationary, and that nothing on the ground moves this fast.
    static func resolved(recorded motion: [String], inferred: ReplayActivity) -> ReplayActivity {
        if inferred == .flying { return .flying }
        if motion.contains("driving") { return .driving }
        if motion.contains("cycling") { return .cycling }
        if motion.contains("running") { return .running }
        if motion.contains("walking") { return .walking }
        return inferred
    }
}

struct ReplayStatus: Equatable {
    let activity: ReplayActivity
    let minute: Int
    let altitude: Double?
    let altitudeTrend: Int
    let legDistance: Double?

    var time: Date { Date(timeIntervalSince1970: TimeInterval(minute) * 60) }

    static func altitudeText(_ meters: Double, metric: Bool) -> String {
        metric ? "\(Int((meters / 5).rounded()) * 5) m" : "\(Int((meters * 3.28084 / 10).rounded()) * 10) ft"
    }

    static func distanceText(_ meters: Double, metric: Bool) -> String {
        let value = metric ? meters / 1_000 : meters / 1_609.344
        return String(format: metric ? "%.1f km" : "%.1f mi", value)
    }

    static func trend(_ altitudes: [Double]) -> Int {
        guard altitudes.count >= 10 else { return 0 }
        let older = altitudes.prefix(5).reduce(0, +) / 5
        let newer = altitudes.suffix(5).reduce(0, +) / 5
        if newer - older > 6 { return 1 }
        return newer - older < -6 ? -1 : 0
    }
}

final class ReplayTimeline {
    let stays: [ReplayStay]
    private let durations: [TimeInterval]
    private let shortestDurations: [TimeInterval]
    private let legDistances: [Double]
    private let inferredActivities: [ReplayActivity]
    // Playback does not follow the route inside a stay, so a stay must be too small for that to show.
    private static let stayWidth = 60.0
    private static let stayMinimum: TimeInterval = 5 * 60
    private static let staySilence: TimeInterval = 60
    private static let stillStep = 25.0
    private static let jumpDistance = 100.0
    private static let activityWindow: TimeInterval = 30
    private static let earthRadius = 6_371_008.8

    init(points: [RecordedLocation]) {
        let speeds = Self.netSpeeds(points)
        let stays = Self.detectStays(in: points, netSpeeds: speeds)
        var durations = [TimeInterval](repeating: 0, count: max(0, points.count - 1))
        var legDistances = [Double](repeating: 0, count: points.count)
        for index in durations.indices {
            let distance = Self.distance(points[index], points[index + 1])
            // Fixes wandering during a shorter stop are not progress. The marker still visits each one.
            let still = distance <= Self.stillStep && (speeds[index] ?? .infinity) < ReplayActivity.stoppedSpeed
                && (speeds[index + 1] ?? .infinity) < ReplayActivity.stoppedSpeed
            durations[index] = ReplayPacing.baseDuration(
                recordedInterval: points[index + 1].timestamp.timeIntervalSince(points[index].timestamp),
                distance: still ? 0 : distance)
            // A jump counts as the direct distance across it, once the fix after it arrives.
            let travelled = still || Self.isJump(points, at: index + 1) ? 0
                : index > 0 && Self.isJump(points, at: index) ? Self.distance(points[index - 1], points[index + 1])
                : distance
            legDistances[index + 1] = legDistances[index] + travelled
        }
        var shortestDurations = [TimeInterval](repeating: 0, count: durations.count)
        for stay in stays where stay.end > stay.start {
            let count = Double(stay.end - stay.start)
            for index in stay.start..<stay.end {
                durations[index] = ReplayPacing.stayDuration(span: stay.span) / count
                shortestDurations[index] = ReplayPacing.shortestStay / count
            }
        }
        var previous = 0
        var offset = 0.0
        for stay in stays + [ReplayStay(start: points.count, end: points.count, span: 0)] {
            if previous < points.count {
                for index in previous..<min(stay.start + 1, points.count) { legDistances[index] -= offset }
            }
            guard stay.end < points.count else { break }
            offset = legDistances[stay.end]
            previous = stay.end
        }
        self.stays = stays
        self.durations = durations
        self.shortestDurations = shortestDurations
        self.legDistances = legDistances
        inferredActivities = speeds.map { $0.map(ReplayActivity.inferred(speed:)) ?? .moving }
    }

    func duration(segment: Int, rate: Double) -> TimeInterval {
        max(shortestDurations[segment], durations[segment] / ReplayPacing.speed(rate))
    }

    func stay(containing index: Int) -> ReplayStay? {
        let stay = firstStay(endingAfter: index - 1)
        return stay.map { $0.start <= index } == true ? stay : nil
    }

    // Consecutive stays share a fix, so a segment needs the stay that continues past it.
    func stay(during segment: Int) -> ReplayStay? {
        let stay = firstStay(endingAfter: segment)
        return stay.map { $0.start <= segment } == true ? stay : nil
    }

    private func firstStay(endingAfter index: Int) -> ReplayStay? {
        var lower = 0, upper = stays.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if stays[middle].end <= index { lower = middle + 1 }
            else { upper = middle }
        }
        return stays.indices.contains(lower) ? stays[lower] : nil
    }

    func legDistance(at index: Int) -> Double? {
        guard legDistances.indices.contains(index), stay(containing: index) == nil else { return nil }
        return legDistances[index]
    }

    func inferredActivity(at index: Int) -> ReplayActivity {
        inferredActivities.indices.contains(index) ? inferredActivities[index] : .moving
    }

    static func distance(_ lhs: RecordedLocation, _ rhs: RecordedLocation) -> Double {
        let delta = offset(of: rhs, from: lhs)
        return hypot(delta.x, delta.y)
    }

    private static func offset(of point: RecordedLocation, from origin: RecordedLocation) -> (x: Double, y: Double) {
        var longitude = point.longitude - origin.longitude
        longitude -= (longitude / 360).rounded() * 360
        let radians = Double.pi / 180
        return (longitude * radians * cos(origin.latitude * radians) * earthRadius,
                (point.latitude - origin.latitude) * radians * earthRadius)
    }

    // A fix far out and straight back looks like a U-turn, except that the travel on either side is
    // much slower than the jump. A real U-turn keeps the speed it arrived with.
    private static func isJump(_ points: [RecordedLocation], at index: Int) -> Bool {
        guard index > 0, index + 1 < points.count else { return false }
        let before = points[index - 1], fix = points[index], after = points[index + 1]
        let out = distance(before, fix), back = distance(fix, after)
        guard min(out, back) > jumpDistance, distance(before, after) < min(out, back) / 4 else { return false }
        func speed(_ from: RecordedLocation, _ to: RecordedLocation) -> Double {
            distance(from, to) / max(1, to.timestamp.timeIntervalSince(from.timestamp))
        }
        let around = max(index > 1 ? speed(points[index - 2], before) : 0,
                         index + 2 < points.count ? speed(after, points[index + 2]) : 0)
        return min(speed(before, fix), speed(fix, after)) > max(10, around * 3)
    }

    // GPS wanders while a phone sits still, so a stay is five minutes of fixes that all fit in one
    // small box. The box cannot drift along with slow movement, and any fix outside it ends the stay,
    // because nothing here can tell a stray fix from a trip that turned around.
    private static func detectStays(in points: [RecordedLocation], netSpeeds: [Double?]) -> [ReplayStay] {
        var stays: [ReplayStay] = []
        var start = 0
        while start + 1 < points.count {
            let origin = points[start]
            var minX = 0.0, maxX = 0.0, minY = 0.0, maxY = 0.0
            var end = start
            for index in (start + 1)..<points.count {
                let delta = offset(of: points[index], from: origin)
                let lowX = min(minX, delta.x), highX = max(maxX, delta.x)
                let lowY = min(minY, delta.y), highY = max(maxY, delta.y)
                guard hypot(highX - lowX, highY - lowY) <= stayWidth else { break }
                (minX, maxX, minY, maxY) = (lowX, highX, lowY, highY)
                end = index
            }
            guard end > start, points[end].timestamp.timeIntervalSince(origin.timestamp) >= stayMinimum else {
                start += 1
                continue
            }
            // The box also catches the end of arriving and the start of leaving, which should play.
            // A phone that logs only when it moves goes silent once parked, so silence ends the trim.
            var first = start, last = end
            while first < last, (netSpeeds[first] ?? 0) >= ReplayActivity.stoppedSpeed,
                  points[first + 1].timestamp.timeIntervalSince(points[first].timestamp) <= staySilence { first += 1 }
            while first < last, (netSpeeds[last] ?? 0) >= ReplayActivity.stoppedSpeed,
                  points[last].timestamp.timeIntervalSince(points[last - 1].timestamp) <= staySilence { last -= 1 }
            let span = points[last].timestamp.timeIntervalSince(points[first].timestamp)
            if span >= stayMinimum { stays.append(ReplayStay(start: first, end: last, span: span)) }
            start = end
        }
        return stays
    }

    // Net speed across the surrounding minute: noise cancels out where real movement adds up.
    // Unknown across a gap too long to say anything about what happened in it.
    private static func netSpeeds(_ points: [RecordedLocation]) -> [Double?] {
        var result = [Double?](repeating: nil, count: points.count)
        guard points.count > 1 else { return result }
        var lower = 0, upper = 0
        for index in points.indices {
            let time = points[index].timestamp
            while time.timeIntervalSince(points[lower].timestamp) > activityWindow { lower += 1 }
            upper = max(upper, index)
            while upper + 1 < points.count, points[upper + 1].timestamp.timeIntervalSince(time) <= activityWindow { upper += 1 }
            var first = lower, last = upper
            if first == last {
                first = max(0, index - 1)
                last = min(points.count - 1, index + 1)
            }
            let elapsed = points[last].timestamp.timeIntervalSince(points[first].timestamp)
            guard elapsed > 0, elapsed <= 600 else { continue }
            result[index] = distance(points[first], points[last]) / elapsed
        }
        return result
    }
}

enum ReplayCameraFocus: Equatable {
    case point
    case trail

    static func nearest(current: Double, point: Double, trail: Double) -> Self {
        guard current.isFinite, point.isFinite, trail.isFinite,
              current > 0, point > 0, trail > 0 else { return .point }
        return abs(log(current / trail)) < abs(log(current / point)) ? .trail : .point
    }
}

final class ReplayRouteGeometry {
    let coordinates: [CLLocationCoordinate2D]
    private let directions: [CGVector?]

    init(points: [RecordedLocation], stays: [ReplayStay] = []) {
        coordinates = points.map(\.coordinate)
        var directions = [CGVector?](repeating: nil, count: coordinates.count)
        let world = MKMapRect.world.width
        for index in coordinates.indices.dropFirst() {
            let start = MKMapPoint(coordinates[index - 1])
            let end = MKMapPoint(coordinates[index])
            var dx = end.x - start.x
            dx -= (dx / world).rounded() * world
            let dy = end.y - start.y
            let length = hypot(dx, dy)
            if length > 0.001 {
                directions[index - 1] = CGVector(dx: dx / length, dy: dy / length)
            }
        }
        // GPS wander during a stay is not a heading.
        for stay in stays where stay.end > stay.start {
            for index in stay.start..<stay.end { directions[index] = nil }
        }
        // Stationary fixes retain the previous direction; leading duplicates use the first movement.
        var previous = directions.lazy.compactMap { $0 }.first
        for index in directions.indices {
            if let direction = directions[index] { previous = direction }
            else { directions[index] = previous }
        }
        self.directions = directions
    }

    func direction(at position: Double) -> CGVector? {
        guard position.isFinite, !directions.isEmpty else { return nil }
        let index = Int(min(Double(directions.count - 1), max(0, position)))
        return directions[index]
    }
}
