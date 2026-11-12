import Foundation
import XCTest
@testable import WhereWolf

final class TripRouteSketchTests: XCTestCase {
    func testPointEncodingUsesCompactPairsAndRoundTrips() throws {
        let sketch = TripRouteSketch(points: [.init(x: 0, y: 255), .init(x: 128, y: 9)])
        let data = try JSONEncoder().encode(sketch)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: [[Int]]])
        XCTAssertEqual(object, ["points": [[0, 255], [128, 9]]])
        XCTAssertEqual(try JSONDecoder().decode(TripRouteSketch.self, from: data), sketch)
        XCTAssertThrowsError(try JSONDecoder().decode(TripRouteSketch.Point.self, from: Data("[1,2,3]".utf8)))
        XCTAssertThrowsError(try JSONDecoder().decode(TripRouteSketch.Point.self, from: Data("[256,0]".utf8)))
    }

    func testBufferStaysBoundedAcrossManyDecimationsAndKeepsTripEndpoints() {
        var builder = TripRouteSketchBuilder()
        for index in 0..<20_000 {
            builder.add(latitude: 0, longitude: Double(index) / 1_000)
            XCTAssertLessThanOrEqual(builder.bufferedPointCount, TripRouteSketchBuilder.maximumBufferedPoints)
        }
        let sketch = builder.sketch()
        XCTAssertEqual(sketch.points, [.init(x: 0, y: 128), .init(x: 255, y: 128)])
    }

    func testSimplificationCapsComplexShapesAndPreservesEndpoints() throws {
        var builder = TripRouteSketchBuilder()
        for index in 0..<300 {
            builder.add(latitude: index.isMultiple(of: 2) ? 0 : 0.1, longitude: Double(index) / 100)
        }
        let points = builder.sketch().points
        XCTAssertEqual(points.count, TripRouteSketchBuilder.maximumSketchPoints)
        let start = try XCTUnwrap(points.first)
        let end = try XCTUnwrap(points.last)
        XCTAssertEqual(start.x, 0)
        XCTAssertEqual(end.x, 255)
        XCTAssertGreaterThan(start.y, end.y)
        XCTAssertTrue(points.contains { $0.y == start.y })
        XCTAssertTrue(points.contains { $0.y == end.y })
    }

    func testNorthIsUpEastIsRightAndCornersSurvive() {
        var builder = TripRouteSketchBuilder()
        builder.add(latitude: 0, longitude: 0)
        builder.add(latitude: 1, longitude: 0)
        builder.add(latitude: 1, longitude: 1)
        XCTAssertEqual(builder.sketch().points, [.init(x: 0, y: 255), .init(x: 0, y: 0), .init(x: 255, y: 0)])
    }

    func testQuantizationPreservesAspectAndUsesOnlyByteCoordinates() throws {
        var builder = TripRouteSketchBuilder()
        builder.add(latitude: 0, longitude: 0)
        builder.add(latitude: 1, longitude: 0)
        builder.add(latitude: 1, longitude: 2)
        let sketch = builder.sketch()
        XCTAssertEqual(sketch.points, [.init(x: 0, y: 191), .init(x: 0, y: 64), .init(x: 255, y: 64)])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(sketch)) as? [String: [[Int]]])
        for pair in try XCTUnwrap(object["points"]) {
            XCTAssertEqual(pair.count, 2)
            XCTAssertTrue(pair.allSatisfy { (0...255).contains($0) })
        }
    }

    func testFitUsesActualBoundsInTallAndWideViewports() {
        let sketch = TripRouteSketch(points: [.init(x: 10, y: 30), .init(x: 110, y: 80)])
        let tall = sketch.fittedPoints(width: 100, height: 300, inset: 10)
        XCTAssertEqual(tall, [CGPoint(x: 10, y: 130), CGPoint(x: 90, y: 170)])
        let wide = sketch.fittedPoints(width: 300, height: 100, inset: 10)
        XCTAssertEqual(wide, [CGPoint(x: 70, y: 10), CGPoint(x: 230, y: 90)])
        XCTAssertEqual((wide[1].x - wide[0].x) / (wide[1].y - wide[0].y), 2, accuracy: 0.000001)
    }

    func testSingleEmptyAndCoincidentShapesGiveACenteredMarker() {
        for points in [[TripRouteSketch.Point](), [.init(x: 0, y: 255)],
                       [.init(x: 3, y: 4), .init(x: 3, y: 4)]] {
            XCTAssertEqual(TripRouteSketch(points: points).fittedPoints(width: 120, height: 80),
                           [CGPoint(x: 60, y: 40)])
        }
        var builder = TripRouteSketchBuilder()
        XCTAssertTrue(builder.sketch().points.isEmpty)
        builder.add(latitude: 40, longitude: -73)
        XCTAssertEqual(builder.sketch().points, [.init(x: 128, y: 128)])
    }

    func testFitHandlesHorizontalVerticalAndCollapsedViewports() {
        let horizontal = TripRouteSketch(points: [.init(x: 0, y: 128), .init(x: 255, y: 128)])
        XCTAssertEqual(horizontal.fittedPoints(width: 100, height: 50),
                       [CGPoint(x: 8, y: 25), CGPoint(x: 92, y: 25)])
        let vertical = TripRouteSketch(points: [.init(x: 128, y: 0), .init(x: 128, y: 255)])
        XCTAssertEqual(vertical.fittedPoints(width: 100, height: 50),
                       [CGPoint(x: 50, y: 8), CGPoint(x: 50, y: 42)])
        XCTAssertEqual(horizontal.fittedPoints(width: 10, height: 10),
                       [CGPoint(x: 5, y: 5), CGPoint(x: 5, y: 5)])
    }

    func testInvalidCoordinatesDoNotEnterBufferOrAffectUnwrapping() {
        var builder = TripRouteSketchBuilder()
        builder.add(latitude: 0, longitude: 179.9)
        for (latitude, longitude) in [(91.0, 0.0), (-91, 0), (0, 181), (0, -181),
                                      (.nan, 0), (0, .nan), (.infinity, 0), (0, -.infinity)] {
            builder.add(latitude: latitude, longitude: longitude)
        }
        XCTAssertEqual(builder.bufferedPointCount, 1)
        builder.add(latitude: 0, longitude: -179.9)
        XCTAssertEqual(builder.sketch().points, [.init(x: 0, y: 128), .init(x: 255, y: 128)])
    }

    func testResetClearsShapeAndProjectionReference() {
        var builder = TripRouteSketchBuilder()
        builder.add(latitude: 80, longitude: 179)
        builder.add(latitude: 81, longitude: -179)
        builder.reset()
        XCTAssertEqual(builder.bufferedPointCount, 0)
        XCTAssertTrue(builder.sketch().points.isEmpty)
        builder.add(latitude: 0, longitude: 0)
        builder.add(latitude: 1, longitude: 1)
        XCTAssertEqual(builder.sketch().points, [.init(x: 0, y: 255), .init(x: 255, y: 0)])
    }

    func testHighLatitudeProjectionContractsEastWestDistance() throws {
        var builder = TripRouteSketchBuilder()
        builder.add(latitude: 80, longitude: 0)
        builder.add(latitude: 81, longitude: 1)
        let points = builder.sketch().points
        let first = try XCTUnwrap(points.first)
        let last = try XCTUnwrap(points.last)
        XCTAssertEqual(first.y, 255)
        XCTAssertEqual(last.y, 0)
        XCTAssertGreaterThan(last.x, first.x)
        XCTAssertEqual(Double(last.x) - Double(first.x), 255 * cos(80 * .pi / 180), accuracy: 1)
    }

    func testSubnormalValidDisplacementQuantizesWithoutOverflow() {
        var builder = TripRouteSketchBuilder()
        builder.add(latitude: 0, longitude: 0)
        builder.add(latitude: Double.leastNonzeroMagnitude, longitude: 0)
        XCTAssertEqual(builder.sketch().points, [.init(x: 128, y: 255), .init(x: 128, y: 0)])
    }

    func testDatelineCrossingStaysLocalAndKeepsItsCorner() throws {
        var builder = TripRouteSketchBuilder()
        builder.add(latitude: 0, longitude: 179.8)
        builder.add(latitude: 0.2, longitude: -180)
        builder.add(latitude: 0, longitude: -179.8)
        let points = builder.sketch().points
        XCTAssertEqual(points.count, 3)
        let first = try XCTUnwrap(points.first)
        let last = try XCTUnwrap(points.last)
        XCTAssertEqual(first.x, 0)
        XCTAssertEqual(last.x, 255)
        XCTAssertEqual(first.y, last.y)
        XCTAssertEqual(Double(first.y) - Double(points[1].y), 127.5, accuracy: 1)
        XCTAssertEqual(Double(points[1].x), 127.5, accuracy: 1)
    }
}
