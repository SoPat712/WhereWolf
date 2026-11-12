import MapKit

struct TripActivityMapFrame {
    let rect: MKMapRect

    // Snapshotter may adjust options.mapRect. Recover the actual north-up image frame
    // from two interior point(for:) probes rather than assuming the requested rect won.
    init?(first: MKMapPoint, firstPixel: CGPoint, last: MKMapPoint, lastPixel: CGPoint, size: CGSize) {
        let dx = Double(lastPixel.x - firstPixel.x)
        let dy = Double(lastPixel.y - firstPixel.y)
        guard dx > 0, dy > 0, size.width > 0, size.height > 0 else { return nil }
        let xScale = (last.x - first.x) / dx
        let yScale = (last.y - first.y) / dy
        let rect = MKMapRect(x: first.x - Double(firstPixel.x) * xScale,
                             y: first.y - Double(firstPixel.y) * yScale,
                             width: Double(size.width) * xScale, height: Double(size.height) * yScale)
        self.init(rect: rect)
    }

    init?(rect: MKMapRect) {
        guard rect.origin.x.isFinite, rect.origin.y.isFinite,
              rect.size.width.isFinite, rect.size.height.isFinite,
              rect.size.width > 0, rect.size.height > 0,
              rect.size.width < MKMapRect.world.size.width / 2 else { return nil }
        self.rect = rect
    }

    static func point(latitude: Double, longitude: Double) -> MKMapPoint {
        // Keep the same unwrapped longitude as the sketch across the date line.
        let latitude = min(85.05112878, max(-85.05112878, latitude))
        let y = MKMapPoint(CLLocationCoordinate2D(latitude: latitude, longitude: 0)).y
        return MKMapPoint(x: (longitude + 180) / 360 * MKMapRect.world.size.width, y: y)
    }

    func normalized(_ point: MKMapPoint) -> CGPoint {
        let world = MKMapRect.world.size.width
        let x = point.x + ((rect.midX - point.x) / world).rounded() * world
        return CGPoint(x: (x - rect.minX) / rect.size.width, y: (point.y - rect.minY) / rect.size.height)
    }

    func contains(_ point: MKMapPoint, margin: Double = 0) -> Bool {
        let p = normalized(point)
        return p.x >= margin && p.x <= 1 - margin && p.y >= margin && p.y <= 1 - margin
    }

    func quantizationPosition(_ point: MKMapPoint) -> CGPoint {
        let p = normalized(point)
        return CGPoint(x: min(1, max(0, p.x)) * 255, y: min(1, max(0, p.y)) * 255)
    }

    static func enclosing(_ points: [MKMapPoint], size: CGSize) -> TripActivityMapFrame? {
        guard let first = points.first else { return nil }
        let minX = points.map(\.x).min()!
        let maxX = points.map(\.x).max()!
        let minY = points.map(\.y).min()!
        let maxY = points.map(\.y).max()!
        let aspect = Double(size.width / size.height)
        // At least 600 m tall: even the first fix shows a neighborhood, not one street.
        let minimumHeight = 600 * MKMapPointsPerMeterAtLatitude(first.coordinate.latitude)
        let height = max(minimumHeight, (maxY - minY) / 0.56, (maxX - minX) / 0.56 / aspect)
        let width = height * aspect
        return TripActivityMapFrame(rect: MKMapRect(x: (minX + maxX - width) / 2,
            y: (minY + maxY - height) / 2, width: width, height: height))
    }
}

// No ActivityKit, clock, IO or network: requests are driven by committed trip updates.
struct TripActivityMapPolicy {
    static let refreshInterval: TimeInterval = 120
    private(set) var frames: [TripActivityMap.Presentation: TripActivityMapFrame] = [:]
    private(set) var lastRequest: TimeInterval?
    private(set) var inFlight = false

    mutating func begin(newest: MKMapPoint?, now: TimeInterval, enabled: Bool, showsOnLockScreen: Bool) -> Bool {
        let presentations: [TripActivityMap.Presentation] = showsOnLockScreen ? [.island, .lockScreen] : [.island]
        guard enabled, let newest, !inFlight,
              lastRequest.map({ now - $0 >= Self.refreshInterval }) ?? true,
              presentations.contains(where: { frames[$0].map { !$0.contains(newest, margin: 0.20) } ?? true }) else { return false }
        lastRequest = now
        inFlight = true
        return true
    }

    mutating func complete(frames: [TripActivityMap.Presentation: TripActivityMapFrame]?) {
        if let frames { self.frames = frames }
        inFlight = false
    }

    mutating func removeLockScreen() { frames[.lockScreen] = nil }

    func usableFrame(for points: [MKMapPoint], presentation: TripActivityMap.Presentation) -> TripActivityMapFrame? {
        guard !points.isEmpty, let frame = frames[presentation], points.allSatisfy({ frame.contains($0) }) else { return nil }
        return frame
    }
}
