import XCTest
import MapKit
@testable import Where

@MainActor
final class ReplayRouteRendererTests: XCTestCase {
    func testUsesNativeVectorRenderersAndThinnerFutureDashes() throws {
        let route = ReplayRoutePresentation(coordinates: coordinates(count: 1_500))
        _ = route.updateCachedTrail(position: 300)
        let trail = try XCTUnwrap(route.activeTrail)
        for line in route.sections.map(\.polyline) + [trail] {
            let renderer = try XCTUnwrap(route.renderer(for: line))
            XCTAssertTrue(type(of: renderer) == MKPolylineRenderer.self)
            XCTAssertFalse(renderer.shouldRasterize)
            XCTAssertEqual(renderer.lineWidth, 2.5)
            XCTAssertEqual(renderer.strokeColor, .systemBlue)
        }
        let ahead = try XCTUnwrap(route.activeFuture)
        for line in route.futureSections + [ahead] {
            let renderer = try XCTUnwrap(route.renderer(for: line))
            XCTAssertTrue(type(of: renderer) == MKPolylineRenderer.self)
            XCTAssertFalse(renderer.shouldRasterize)
            XCTAssertEqual(renderer.lineWidth, 1.25)
            XCTAssertEqual(renderer.lineDashPattern, [1, 5])
            XCTAssertEqual(renderer.lineCap, .round)
        }
    }

    func testEveryVertexSurvivesAndSectionsStayStableAcrossLargeScrubs() throws {
        let values = coordinates(count: 10_000)
        let route = ReplayRoutePresentation(coordinates: values)
        let lines = route.sections.map { ObjectIdentifier($0.polyline) }
        XCTAssertEqual(route.fullRoute.pointCount, values.count)
        for index in values.indices {
            let point = route.fullRoute.points()[index].coordinate
            XCTAssertEqual(point.latitude, values[index].latitude, accuracy: 0.0000001)
            XCTAssertEqual(point.longitude, values[index].longitude, accuracy: 0.0000001)
        }
        for position in [255.9, 256, 511.999, 512, 9_998.38, 1_100, 0, 9_999] {
            _ = route.updateCachedTrail(position: position)
            XCTAssertEqual(route.sections.map { ObjectIdentifier($0.polyline) }, lines)
            let shown = Set(route.overlays.map { ObjectIdentifier($0) })
            for (index, section) in route.sections.enumerated() {
                XCTAssertEqual(shown.contains(ObjectIdentifier(section.polyline)), index < route.activeIndex)
            }
            let anchor = Int(position) / 64 * 64
            if anchor == 0 {
                XCTAssertNil(route.activeTrail)
                continue
            }
            let trail = try XCTUnwrap(route.activeTrail)
            let section = route.sections[route.activeIndex]
            XCTAssertEqual(trail.pointCount, anchor - section.start + section.prefix + 1)
            for offset in section.prefix..<trail.pointCount {
                let point = trail.points()[offset].coordinate
                let expected = values[section.start + offset - section.prefix]
                XCTAssertEqual(point.latitude, expected.latitude, accuracy: 0.0000001)
                XCTAssertEqual(point.longitude, expected.longitude, accuracy: 0.0000001)
            }
        }
    }

    func testFutureDotsStayFineAndSeparatedAcrossZooms() {
        let origin = MKMapPoint(CLLocationCoordinate2D(latitude: 45, longitude: -122))
        let values = [-10_000.0, 0, 10_000].map { MKMapPoint(x: origin.x + $0, y: origin.y).coordinate }
        let route = ReplayRoutePresentation(coordinates: values)
        for scale in [0.02, 1, 4] {
            let renderer = route.renderer(for: route.futureSections[0]) as! MKPolylineRenderer
            let pixels = paint(renderer, centeredAt: origin.coordinate, scale: scale)
            let ink = pixels.filter { $0.a > 40 }
            XCTAssertFalse(ink.isEmpty)
            if let lower = ink.map(\.y).min(), let upper = ink.map(\.y).max() {
                XCTAssertLessThanOrEqual(upper - lower + 1, 3)
            }
            let columns = Set(ink.filter { (20..<108).contains($0.x) }.map(\.x))
            XCTAssertGreaterThan(columns.count, 10)
            XCTAssertLessThan(columns.count, 65)
        }
    }

    func testCachedTrailChangesOnlyAtStrideBoundaries() throws {
        let route = ReplayRoutePresentation(coordinates: coordinates(count: 1_500))
        let first = try XCTUnwrap(route.updateCachedTrail(position: 300.1).added.first as? MKPolyline)
        XCTAssertEqual(first.pointCount, 257)
        for position in [300.2, 305.7, 319.99] {
            let change = route.updateCachedTrail(position: position)
            XCTAssertTrue(change.added.isEmpty)
            XCTAssertTrue(change.removed.isEmpty)
            XCTAssertTrue(route.activeTrail === first)
        }
        let second = route.updateCachedTrail(position: 320)
        XCTAssertEqual(second.added.count, 1)
        XCTAssertTrue(second.removed.isEmpty, "The previous trail covers its replacement until the next boundary")
        XCTAssertTrue(route.overlays.contains { $0 === first })
        XCTAssertNotNil(route.renderer(for: first))
        XCTAssertNil(route.renderer(for: MKPolyline()))
        let third = route.updateCachedTrail(position: 384)
        XCTAssertTrue(third.removed.first === first)
        XCTAssertNil(route.renderer(for: first))
    }

    func testScrubbingBackRemovesEveryLaterTrailAtOnce() throws {
        let route = ReplayRoutePresentation(coordinates: coordinates(count: 1_500))
        let older = try XCTUnwrap(route.updateCachedTrail(position: 320).added.first)
        let newer = try XCTUnwrap(route.updateCachedTrail(position: 384).added.first)
        let change = route.updateCachedTrail(position: 128)
        XCTAssertEqual(Set(change.removed.map { ObjectIdentifier($0) }),
            Set([older, newer].map { ObjectIdentifier($0) }))
        XCTAssertEqual(route.activeTrail?.pointCount, 129)
        XCTAssertEqual(route.overlays.filter { !route.isDots($0) }.count, 1)
    }

    func testCrossingSectionsShowsOnlyCompletedSections() throws {
        let route = ReplayRoutePresentation(coordinates: coordinates(count: 3_000))
        XCTAssertGreaterThan(route.sections.count, 2)
        let forward = route.updateCachedTrail(position: 2_100)
        XCTAssertEqual(route.activeIndex, 2)
        XCTAssertTrue(forward.added.contains { $0 === route.sections[0].polyline })
        XCTAssertTrue(forward.added.contains { $0 === route.sections[1].polyline })
        XCTAssertFalse(forward.added.contains { $0 === route.sections[2].polyline })
        let back = route.updateCachedTrail(position: 10)
        XCTAssertEqual(route.activeIndex, 0)
        XCTAssertTrue(back.removed.contains { $0 === route.sections[0].polyline })
        XCTAssertTrue(back.removed.contains { $0 === route.sections[1].polyline })
        XCTAssertNil(route.activeTrail)
        XCTAssertTrue(route.overlays.allSatisfy { route.isDots($0) })
    }

    func testDotsBehindTheMarkerAreRemovedNotCovered() {
        let values = coordinates(count: 3_000)
        let route = ReplayRoutePresentation(coordinates: values)
        XCTAssertGreaterThan(route.sections.count, 2)
        var fixAt: [Double: Int] = [:]
        for index in values.indices { fixAt[route.fullRoute.points()[index].x] = index }
        func covered() -> Set<Int> {
            var fixes = Set<Int>()
            for dot in route.overlays.filter({ route.isDots($0) }).compactMap({ $0 as? MKPolyline }) {
                for offset in 0..<dot.pointCount {
                    if let fix = fixAt[dot.points()[offset].x] { fixes.insert(fix) }
                }
            }
            return fixes
        }
        func check(_ position: Double, line: UInt = #line) {
            _ = route.updateCachedTrail(position: position)
            let shown = covered(), fix = Int(position)
            XCTAssertGreaterThan(route.futureCut, fix, "The map's dots must start ahead of \(position)", line: line)
            XCTAssertLessThanOrEqual(route.futureCut - fix, 33, line: line)
            // Past the last step, the foreground layer draws everything that remains.
            guard route.futureCut < values.count - 1 else {
                XCTAssertTrue(shown.isEmpty, "Dots left near the end at \(position)", line: line)
                return
            }
            // Not one dotted point at or behind the marker, whatever the spacing between points.
            XCTAssertEqual(shown.min(), route.futureCut, "Dots behind \(position)", line: line)
            let missing = (route.futureCut..<values.count).filter { !shown.contains($0) }
            XCTAssertEqual(missing, [], "Dots missing ahead of \(position)", line: line)
        }
        // Single steps, then jumps, then scrubbing back, which restores what was removed.
        for position in stride(from: 0.0, through: 200, by: 7.5) { check(position) }
        for position in [1_024.0, 1_500.5, 2_100, 2_990, 1_200, 30] { check(position) }
    }

    func testForegroundDotsCoverOnlyTheStretchFromTheMarkerToTheMapsDots() throws {
        let values = coordinates(count: 400)
        let route = ReplayRoutePresentation(coordinates: values)
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        map.region = MKCoordinateRegion(center: values[110], latitudinalMeters: 300, longitudinalMeters: 300)
        let marker = MKAnnotationView()
        map.addSubview(marker)
        let layer = ReplayTrailLayer(future: true)
        _ = route.updateCachedTrail(position: 100.5)
        let cut = route.futureCut
        XCTAssertGreaterThan(cut, 100)
        let here = values[100]
        layer.update(route: route.fullRoute, position: 100.5, coordinate: here, on: map, below: marker, ahead: cut)
        let box = try XCTUnwrap(layer.path).boundingBox
        let start = map.convert(here, toPointTo: map), end = map.convert(values[cut], toPointTo: map)
        XCTAssertEqual(box.minX, min(start.x, end.x), accuracy: 0.5)
        XCTAssertEqual(box.maxX, max(start.x, end.x), accuracy: 0.5)
        XCTAssertEqual(layer.lineDashPattern, [1, 5])
        XCTAssertEqual(layer.lineCap, .round)
        // At the end of the route there is nothing left to draw.
        layer.update(route: route.fullRoute, position: 399, coordinate: values[399], on: map, below: marker, ahead: 399)
        XCTAssertTrue(layer.path?.isEmpty ?? true)
    }

    func testFinishingLeavesNoDots() {
        let route = ReplayRoutePresentation(coordinates: coordinates(count: 500))
        XCTAssertTrue(route.overlays.contains { route.isDots($0) })
        _ = route.updateCachedTrail(position: 250)
        _ = route.updateCachedTrail(position: 499)
        XCTAssertFalse(route.overlays.contains { route.isDots($0) })
        _ = route.updateCachedTrail(position: 100)
        XCTAssertTrue(route.overlays.contains { route.isDots($0) })
    }

    func testDotsStayInPlaceAsTheLineShortens() throws {
        let route = ReplayRoutePresentation(coordinates: coordinates(count: 800))
        let section = route.sections[0]
        let end = route.fullRoute.points()[section.end]
        for position in stride(from: 0.0, to: Double(section.end - 1), by: 37.5) {
            _ = route.updateCachedTrail(position: position)
            guard let line = route.activeFuture else { continue }
            // The dash pattern starts at a line's first point, which must never move.
            XCTAssertEqual(line.points()[0].x, end.x)
            XCTAssertEqual(line.points()[0].y, end.y)
        }
    }

    func testShortenedLinesReplaceEachOtherWithoutLeaks() throws {
        let route = ReplayRoutePresentation(coordinates: coordinates(count: 3_000))
        var shown = Set(route.overlays.map { ObjectIdentifier($0) })
        func step(_ position: Double, line: UInt = #line) {
            let change = route.updateCachedTrail(position: position)
            for overlay in change.added + change.addedDots {
                XCTAssertTrue(shown.insert(ObjectIdentifier(overlay)).inserted, "Added twice at \(position)", line: line)
            }
            for overlay in change.removed + change.removedDots {
                XCTAssertNotNil(shown.remove(ObjectIdentifier(overlay)), "Removed but not shown at \(position)", line: line)
            }
            XCTAssertEqual(shown, Set(route.overlays.map { ObjectIdentifier($0) }), "At \(position)", line: line)
        }
        for position in stride(from: 0.0, through: 2_999, by: 3.7) { step(position) }
        for position in [2_999.0, 2_990, 1_500, 1_501, 1_024, 1_023, 0, 2_100, 0, 5, 1_030, 1_024, 2_999, 0] { step(position) }
    }

    func testRealMapKeepsDotsBeneathTheRoute() throws {
        let route = ReplayRoutePresentation(coordinates: coordinates(count: 3_000))
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        map.addOverlays(route.overlays, level: .aboveRoads)
        for position in [300.0, 1_500, 2_500, 900, 2_000, 10] {
            route.updateCachedTrail(position: position).apply(to: map)
            let drawn = map.overlays(in: .aboveRoads)
            XCTAssertEqual(Set(drawn.map { ObjectIdentifier($0) }), Set(route.overlays.map { ObjectIdentifier($0) }), "At \(position)")
            let lastDots = drawn.lastIndex { route.isDots($0) } ?? -1
            let firstRoute = drawn.firstIndex { !route.isDots($0) } ?? .max
            XCTAssertLessThan(lastDots, firstRoute, "At \(position)")
        }
    }

    func testInvalidAndOutOfRangePositionsKeepTheTrailValid() throws {
        let route = ReplayRoutePresentation(coordinates: coordinates(count: 200))
        _ = route.updateCachedTrail(position: 70)
        let trail = try XCTUnwrap(route.activeTrail)
        for invalid in [Double.nan, .infinity, -.infinity] {
            let change = route.updateCachedTrail(position: invalid)
            XCTAssertTrue(change.added.isEmpty)
            XCTAssertTrue(change.removed.isEmpty)
            XCTAssertTrue(route.activeTrail === trail)
        }
        _ = route.updateCachedTrail(position: -1)
        XCTAssertNil(route.activeTrail)
        _ = route.updateCachedTrail(position: 1_000)
        XCTAssertEqual(route.activeTrail?.pointCount, 193)
    }

    func testDensePointsStayPreciseEvenWhenTheRouteContainsLongJumps() throws {
        let origin = MKMapPoint(CLLocationCoordinate2D(latitude: 45, longitude: -122))
        var values = (0..<12_000).map { MKMapPoint(x: origin.x + Double($0) * 6, y: origin.y).coordinate }
        values.insert(CLLocationCoordinate2D(latitude: 0, longitude: 0), at: 0)
        values.append(CLLocationCoordinate2D(latitude: 0, longitude: 0))
        let route = ReplayRoutePresentation(coordinates: values)
        for position in stride(from: 128.0, through: 11_900, by: 640.25) {
            _ = route.updateCachedTrail(position: position)
            let trail = try XCTUnwrap(route.activeTrail)
            let last = trail.points()[trail.pointCount - 1]
            let anchor = Int(position) / 64 * 64
            XCTAssertEqual(last.x, origin.x + Double(anchor - 1) * 6, accuracy: 0.001)
            XCTAssertEqual(last.y, origin.y, accuracy: 0.001)
            XCTAssertLessThanOrEqual(Double(anchor), position)
        }
    }

    func testDatelineUsesShortSegmentsAndStationaryRoutesStayFinite() {
        let route = ReplayRoutePresentation(coordinates: [179.9, -179.9, -179.8].map {
            CLLocationCoordinate2D(latitude: 0, longitude: $0)
        })
        XCTAssertLessThan(route.fullRoute.boundingMapRect.width, MKMapRect.world.width / 100)
        XCTAssertLessThan(route.sections[0].polyline.boundingMapRect.width, MKMapRect.world.width / 100)
        let point = CLLocationCoordinate2D(latitude: 45, longitude: -122)
        for count in [0, 1, 10] {
            let still = ReplayRoutePresentation(coordinates: Array(repeating: point, count: count))
            _ = still.updateCachedTrail(position: 2.5)
            XCTAssertNil(still.activeTrail)
            for section in still.sections {
                XCTAssertTrue(still.renderer(for: section.polyline).map { type(of: $0) == MKPolylineRenderer.self } ?? false)
            }
        }
    }

    private func coordinates(count: Int) -> [CLLocationCoordinate2D] {
        let origin = MKMapPoint(CLLocationCoordinate2D(latitude: 45, longitude: -122))
        return (0..<count).map { index in
            MKMapPoint(x: origin.x + Double(index) * 2,
                       y: origin.y + sin(Double(index) * 0.2) * 20).coordinate
        }
    }

    private struct Pixel {
        let x: Int
        let y: Int
        let r: UInt8
        let g: UInt8
        let b: UInt8
        let a: UInt8
        var blue: Bool { b > 150 && r < 100 && a > 180 }
    }

    private func paint(_ renderer: MKOverlayPathRenderer, centeredAt coordinate: CLLocationCoordinate2D,
                        scale: Double) -> [Pixel] {
        renderer.createPath()
        let size = 128
        var bytes = [UInt8](repeating: 0, count: size * size * 4)
        let endpoint = MKMapPoint(coordinate)
        let center = renderer.point(for: endpoint)
        return bytes.withUnsafeMutableBytes { raw in
            let context = CGContext(data: raw.baseAddress, width: size, height: size, bitsPerComponent: 8,
                                    bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.translateBy(x: 64 - center.x * scale, y: 64 - center.y * scale)
            context.scaleBy(x: scale, y: scale)
            renderer.draw(MKMapRect(x: endpoint.x - 64 / scale, y: endpoint.y - 64 / scale,
                                     width: 128 / scale, height: 128 / scale), zoomScale: scale, in: context)
            context.flush()
            let data = raw.bindMemory(to: UInt8.self)
            return (0..<(size * size)).map { index in
                Pixel(x: index % size, y: index / size, r: data[index * 4], g: data[index * 4 + 1],
                      b: data[index * 4 + 2], a: data[index * 4 + 3])
            }
        }
    }
}
