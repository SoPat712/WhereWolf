import XCTest
import MapKit
@testable import Overland

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
        XCTAssertTrue(type(of: route.futureRenderer) == MKPolylineRenderer.self)
        XCTAssertFalse(route.futureRenderer.shouldRasterize)
        XCTAssertEqual(route.futureRenderer.lineWidth, 1.25)
        XCTAssertEqual(route.futureRenderer.lineDashPattern, [1, 5])
        XCTAssertEqual(route.futureRenderer.lineCap, .round)
    }

    func testEveryVertexSurvivesAndSectionsStayStableAcrossLargeScrubs() throws {
        let values = coordinates(count: 10_000)
        let route = ReplayRoutePresentation(coordinates: values)
        let lines = route.sections.map { ObjectIdentifier($0.polyline) }
        XCTAssertEqual(route.future.pointCount, values.count)
        for index in values.indices {
            let point = route.future.points()[index].coordinate
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
            let pixels = paint(route.futureRenderer, centeredAt: origin.coordinate, scale: scale)
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
        XCTAssertEqual(route.overlays.count, 2)
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
        XCTAssertEqual(route.overlays.count, 1)
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
        XCTAssertLessThan(route.future.boundingMapRect.width, MKMapRect.world.width / 100)
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
