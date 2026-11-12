import Foundation

/// A north-up trip shape, with no geographic coordinates or scale in its payload.
struct TripRouteSketch: Codable, Hashable {
    struct Point: Codable, Hashable {
        var x: UInt8
        var y: UInt8

        init(x: UInt8, y: UInt8) {
            self.x = x
            self.y = y
        }

        init(from decoder: Decoder) throws {
            var values = try decoder.unkeyedContainer()
            x = try values.decode(UInt8.self)
            y = try values.decode(UInt8.self)
            guard values.isAtEnd else {
                throw DecodingError.dataCorruptedError(in: values, debugDescription: "Expected an x/y pair")
            }
        }

        func encode(to encoder: Encoder) throws {
            var values = encoder.unkeyedContainer()
            try values.encode(x)
            try values.encode(y)
        }
    }

    var points: [Point]

    func imagePoints(width: Double, height: Double) -> [CGPoint] {
        points.map { CGPoint(x: Double($0.x) / 255 * width, y: Double($0.y) / 255 * height) }
    }

    func displayPoints(size: CGSize, imageRoute: TripRouteSketch?, hasImage: Bool) -> [CGPoint] {
        if hasImage, let imageRoute { return imageRoute.imagePoints(width: size.width, height: size.height) }
        return fittedPoints(width: size.width, height: size.height, inset: 12)
    }

    /// Fit the stored shape's actual bounds, including any rounding from quantization.
    func fittedPoints(width: Double, height: Double, inset: Double = 8) -> [CGPoint] {
        let width = width.isFinite ? max(0, width) : 0
        let height = height.isFinite ? max(0, height) : 0
        let inset = inset.isFinite ? max(0, inset) : 0
        let center = CGPoint(x: width / 2, y: height / 2)
        guard points.count >= 2 else { return [center] }

        let minX = Double(points.map(\.x).min()!)
        let maxX = Double(points.map(\.x).max()!)
        let minY = Double(points.map(\.y).min()!)
        let maxY = Double(points.map(\.y).max()!)
        let spanX = maxX - minX
        let spanY = maxY - minY
        guard spanX > 0 || spanY > 0 else { return [center] }

        let availableWidth = max(0, width - 2 * inset)
        let availableHeight = max(0, height - 2 * inset)
        let scale = min(spanX > 0 ? availableWidth / spanX : .infinity,
                        spanY > 0 ? availableHeight / spanY : .infinity)
        let midX = (minX + maxX) / 2
        let midY = (minY + maxY) / 2
        return points.map {
            CGPoint(x: width / 2 + (Double($0.x) - midX) * scale,
                    y: height / 2 + (Double($0.y) - midY) * scale)
        }
    }
}

/// Collects a bounded, increasingly coarse sample; simplification happens only on publication.
struct TripRouteSketchBuilder {
    static let maximumBufferedPoints = 384
    static let maximumSketchPoints = 48

    var bufferedPointCount: Int { bufferedPoints.count }

    private struct Coordinate {
        let latitude: Double
        let longitude: Double
    }

    private struct ProjectedPoint {
        let x: Double
        let y: Double
    }

    private struct Segment {
        let first: Int
        let last: Int
        let split: Int
        let errorSquared: Double
    }

    private var bufferedPoints: [Coordinate] = []
    private var previousLongitude: Double?
    private var unwrappedLongitude: Double = 0
    private(set) var bounds: (south: Double, north: Double, west: Double, east: Double)?

    var coordinates: [(latitude: Double, longitude: Double)] {
        bufferedPoints.map { ($0.latitude, $0.longitude) }
    }

    mutating func add(latitude: Double, longitude: Double) {
        guard latitude.isFinite, longitude.isFinite,
              (-90...90).contains(latitude), (-180...180).contains(longitude) else { return }

        if let previousLongitude {
            var delta = longitude - previousLongitude
            if delta > 180 { delta -= 360 }
            if delta < -180 { delta += 360 }
            unwrappedLongitude += delta
        } else {
            unwrappedLongitude = longitude
        }
        previousLongitude = longitude
        if let bounds {
            self.bounds = (min(bounds.south, latitude), max(bounds.north, latitude),
                           min(bounds.west, unwrappedLongitude), max(bounds.east, unwrappedLongitude))
        } else {
            bounds = (latitude, latitude, unwrappedLongitude, unwrappedLongitude)
        }

        if bufferedPoints.count == Self.maximumBufferedPoints {
            // Thin in place, keeping the trip's first fix and the most recent buffered fix.
            var writeIndex = 1
            for readIndex in stride(from: 2, to: bufferedPoints.count - 1, by: 2) {
                bufferedPoints[writeIndex] = bufferedPoints[readIndex]
                writeIndex += 1
            }
            bufferedPoints[writeIndex] = bufferedPoints[bufferedPoints.count - 1]
            writeIndex += 1
            bufferedPoints.removeSubrange(writeIndex..<bufferedPoints.count)
        }
        bufferedPoints.append(Coordinate(latitude: latitude, longitude: unwrappedLongitude))
    }

    mutating func reset() {
        bufferedPoints.removeAll(keepingCapacity: true)
        previousLongitude = nil
        unwrappedLongitude = 0
        bounds = nil
    }

    func sketch() -> TripRouteSketch {
        guard let first = bufferedPoints.first else { return TripRouteSketch(points: []) }
        // A fixed reference avoids changing the projection as more fixes arrive.
        let longitudeScale = cos(first.latitude * .pi / 180)
        let projected = bufferedPoints.map {
            ProjectedPoint(x: $0.longitude * longitudeScale, y: -$0.latitude)
        }
        let minX = projected.map(\.x).min()!
        let maxX = projected.map(\.x).max()!
        let minY = projected.map(\.y).min()!
        let maxY = projected.map(\.y).max()!
        let span = max(maxX - minX, maxY - minY)
        guard span > 0 else { return TripRouteSketch(points: [.init(x: 128, y: 128)]) }

        let offsetX = (255 - (maxX - minX) / span * 255) / 2
        let offsetY = (255 - (maxY - minY) / span * 255) / 2
        let normalized = projected.map {
            // Divide first so even a subnormal valid displacement cannot overflow a scale.
            ProjectedPoint(x: ($0.x - minX) / span * 255 + offsetX,
                           y: ($0.y - minY) / span * 255 + offsetY)
        }
        return Self.quantized(normalized)
    }

    func sketch(project: (Double, Double) -> CGPoint) -> TripRouteSketch {
        Self.quantized(bufferedPoints.map {
            let point = project($0.latitude, $0.longitude)
            return ProjectedPoint(x: point.x, y: point.y)
        })
    }

    private static func quantized(_ normalized: [ProjectedPoint]) -> TripRouteSketch {
        let indices = simplifiedIndices(normalized)
        return TripRouteSketch(points: indices.map {
            let point = normalized[$0]
            return .init(x: UInt8(clamping: Int(point.x.rounded())),
                         y: UInt8(clamping: Int(point.y.rounded())))
        })
    }

    private static func simplifiedIndices(_ points: [ProjectedPoint]) -> [Int] {
        guard points.count > 2 else { return Array(points.indices) }
        var selected = [0, points.count - 1]
        var segments: [Segment] = []
        if let segment = segment(first: 0, last: points.count - 1, points: points) {
            segments.append(segment)
        }

        // Best-first Douglas-Peucker: resolve the largest remaining error, bounded by
        // both the buffer and payload limits. Half a quantization unit needs no split.
        while selected.count < maximumSketchPoints,
              let best = segments.indices.max(by: { segments[$0].errorSquared < segments[$1].errorSquared }) {
            let current = segments.remove(at: best)
            guard current.errorSquared > 0.25 else { break }
            selected.append(current.split)
            if let left = segment(first: current.first, last: current.split, points: points) {
                segments.append(left)
            }
            if let right = segment(first: current.split, last: current.last, points: points) {
                segments.append(right)
            }
        }
        return selected.sorted()
    }

    private static func segment(first: Int, last: Int, points: [ProjectedPoint]) -> Segment? {
        guard last - first > 1 else { return nil }
        let start = points[first]
        let end = points[last]
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        var split = first + 1
        var largestError = 0.0
        for index in (first + 1)..<last {
            let point = points[index]
            let fraction = lengthSquared > 0
                ? min(1, max(0, ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared)) : 0
            let offsetX = point.x - (start.x + fraction * dx)
            let offsetY = point.y - (start.y + fraction * dy)
            let error = offsetX * offsetX + offsetY * offsetY
            if error > largestError {
                largestError = error
                split = index
            }
        }
        return Segment(first: first, last: last, split: split, errorSquared: largestError)
    }
}
