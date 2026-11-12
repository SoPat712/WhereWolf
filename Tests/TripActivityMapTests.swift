import MapKit
import UIKit
import XCTest
@testable import WhereWolf

final class TripActivityMapTests: XCTestCase {
    private func frame() throws -> TripActivityMapFrame {
        let center = MKMapPoint(CLLocationCoordinate2D(latitude: 45.5152, longitude: -122.6784))
        return try XCTUnwrap(TripActivityMapFrame(rect: MKMapRect(
            x: center.x - 1_000, y: center.y - 500, width: 2_000, height: 1_000)))
    }

    func testMercatorCornersCentreAndOutsideClamp() throws {
        let frame = try frame()
        let rect = frame.rect
        let cases: [(MKMapPoint, CGPoint)] = [
            (MKMapPoint(x: rect.minX, y: rect.minY), .zero),
            (MKMapPoint(x: rect.maxX, y: rect.minY), CGPoint(x: 255, y: 0)),
            (MKMapPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: 255, y: 255)),
            (MKMapPoint(x: rect.minX, y: rect.maxY), CGPoint(x: 0, y: 255)),
            (MKMapPoint(x: rect.midX, y: rect.midY), CGPoint(x: 127.5, y: 127.5)),
            (MKMapPoint(x: rect.minX - 10, y: rect.maxY + 10), CGPoint(x: 0, y: 255))
        ]
        for (point, expected) in cases {
            XCTAssertEqual(frame.quantizationPosition(point), expected)
        }
        let outside = cases.last!.0
        XCTAssertFalse(frame.contains(outside))
        let point = cases[2].0.coordinate
        let mercator = TripActivityMapFrame.point(latitude: point.latitude, longitude: point.longitude)
        XCTAssertEqual(mercator.x, cases[2].0.x, accuracy: 0.000001)
        XCTAssertEqual(mercator.y, cases[2].0.y, accuracy: 0.000001)
    }

    func testSnapshotProbesRecoverActualFrame() throws {
        let frame = try XCTUnwrap(TripActivityMapFrame(
            first: MKMapPoint(x: 1_080, y: 2_100), firstPixel: CGPoint(x: 20, y: 13),
            last: MKMapPoint(x: 1_720, y: 2_300), lastPixel: CGPoint(x: 180, y: 39),
            size: CGSize(width: 200, height: 52)))
        XCTAssertEqual(frame.rect.minX, 1_000, accuracy: 0.000001)
        XCTAssertEqual(frame.rect.minY, 2_000, accuracy: 0.000001)
        XCTAssertEqual(frame.rect.size.width, 800, accuracy: 0.000001)
        XCTAssertEqual(frame.rect.size.height, 400, accuracy: 0.000001)
        XCTAssertNil(TripActivityMapFrame(first: MKMapPoint(x: 1, y: 1), firstPixel: .zero,
            last: MKMapPoint(x: 2, y: 2), lastPixel: .zero, size: CGSize(width: 200, height: 52)))
        XCTAssertNil(TripActivityMapFrame(rect: MKMapRect(x: 0, y: 0, width: .nan, height: 1)))
    }

    func testBothPresentationsPadBoundsAndKeepNeighborhoodMinimum() throws {
        let center = MKMapPoint(CLLocationCoordinate2D(latitude: 45.5152, longitude: -122.6784))
        for presentation in TripActivityMap.Presentation.allCases {
            let size = presentation.size
            let frame = try XCTUnwrap(TripActivityMapFrame.enclosing([center], size: size))
            XCTAssertEqual(frame.rect.size.width / frame.rect.size.height, Double(size.width / size.height), accuracy: 0.000001)
            XCTAssertEqual(frame.rect.size.height / MKMapPointsPerMeterAtLatitude(45.5152), 600, accuracy: 0.001)
            XCTAssertTrue(frame.contains(center, margin: 0.20))
            let points = [center, MKMapPoint(x: center.x + 40_000, y: center.y - 20_000)]
            let expanded = try XCTUnwrap(TripActivityMapFrame.enclosing(points, size: size))
            XCTAssertTrue(points.allSatisfy { expanded.contains($0, margin: 0.20) })
        }
    }

    func testStatsQuantizeInEachMapFrameWithoutRefitting() throws {
        let frame = try frame()
        let stats = TripStatsAccumulator()
        for point in [MKMapPoint(x: frame.rect.minX, y: frame.rect.minY),
                      MKMapPoint(x: frame.rect.maxX, y: frame.rect.minY),
                      MKMapPoint(x: frame.rect.maxX, y: frame.rect.maxY)] {
            let c = point.coordinate
            stats.add(speed: 1, speedAccuracy: 1, altitude: 0, verticalAccuracy: 1,
                      latitude: c.latitude, longitude: c.longitude)
        }
        XCTAssertEqual(stats.routeSketch(in: frame).points, [.init(x: 0, y: 0), .init(x: 255, y: 0), .init(x: 255, y: 255)])
        let single = TripRouteSketch(points: [.init(x: 51, y: 102)])
        let islandPoint = single.imagePoints(width: 200, height: 52)[0]
        let lockPoint = single.imagePoints(width: 188, height: 68)[0]
        XCTAssertEqual(islandPoint.x, 40, accuracy: 0.000001)
        XCTAssertEqual(islandPoint.y, 20.8, accuracy: 0.000001)
        XCTAssertEqual(lockPoint.x, 37.6, accuracy: 0.000001)
        XCTAssertEqual(lockPoint.y, 27.2, accuracy: 0.000001)
        XCTAssertEqual(single.fittedPoints(width: 200, height: 52), [CGPoint(x: 100, y: 26)])
        stats.reset()
        XCTAssertTrue(stats.routeMapPoints.isEmpty)
    }

    func testBoundsSurviveShapeDecimation() {
        var builder = TripRouteSketchBuilder()
        builder.add(latitude: 45, longitude: -122)
        builder.add(latitude: 46, longitude: -121)
        for _ in 0..<1_000 { builder.add(latitude: 45, longitude: -122) }
        XCTAssertEqual(builder.bounds?.north, 46)
        XCTAssertEqual(builder.bounds?.east, -121)
        XCTAssertLessThanOrEqual(builder.bufferedPointCount, TripRouteSketchBuilder.maximumBufferedPoints)
        builder.reset()
        XCTAssertNil(builder.bounds)
    }

    func testDatelineCrossingUsesOneLocalMercatorFrame() throws {
        var builder = TripRouteSketchBuilder()
        builder.add(latitude: 0, longitude: 179.99)
        builder.add(latitude: 0.001, longitude: -179.99)
        let points = builder.coordinates.map { TripActivityMapFrame.point(latitude: $0.latitude, longitude: $0.longitude) }
        let frame = try XCTUnwrap(TripActivityMapFrame.enclosing(points, size: TripActivityMap.Presentation.island.size))
        XCTAssertLessThan(frame.rect.size.width, MKMapRect.world.size.width / 1_000)
        XCTAssertTrue(points.allSatisfy { frame.contains($0, margin: 0.20) })
        let wrapped = MKMapPoint(CLLocationCoordinate2D(latitude: 0.001, longitude: -179.99))
        XCTAssertEqual(frame.quantizationPosition(wrapped).x, frame.quantizationPosition(points[1]).x, accuracy: 0.000001)
    }

    func testRefreshStartMarginTwoMinuteLimitInFlightAndFailureFallback() throws {
        let frame = try XCTUnwrap(TripActivityMapFrame(rect: MKMapRect(x: 0, y: 0, width: 100, height: 100)))
        let center = MKMapPoint(x: 50, y: 50), margin = MKMapPoint(x: 85, y: 50), outside = MKMapPoint(x: 101, y: 50)
        var policy = TripActivityMapPolicy()
        XCTAssertFalse(policy.begin(newest: center, now: 0, enabled: false, showsOnLockScreen: true))
        XCTAssertFalse(policy.begin(newest: nil, now: 0, enabled: true, showsOnLockScreen: true))
        XCTAssertTrue(policy.begin(newest: center, now: 0, enabled: true, showsOnLockScreen: true))
        XCTAssertFalse(policy.begin(newest: margin, now: 120, enabled: true, showsOnLockScreen: true))
        policy.complete(frames: [.island: frame, .lockScreen: frame])
        XCTAssertFalse(policy.begin(newest: center, now: 120, enabled: true, showsOnLockScreen: true))
        XCTAssertFalse(policy.begin(newest: margin, now: 119.99, enabled: true, showsOnLockScreen: true))
        XCTAssertTrue(policy.begin(newest: margin, now: 120, enabled: true, showsOnLockScreen: true))
        policy.complete(frames: nil)
        for presentation in TripActivityMap.Presentation.allCases {
            XCTAssertNotNil(policy.usableFrame(for: [center, margin], presentation: presentation))
            XCTAssertNil(policy.usableFrame(for: [center, outside], presentation: presentation))
        }
        XCTAssertFalse(policy.begin(newest: outside, now: 239, enabled: true, showsOnLockScreen: true))
        XCTAssertTrue(policy.begin(newest: outside, now: 240, enabled: true, showsOnLockScreen: true))
    }

    func testLockScreenFrameTriggersSharedRefreshOnlyWhenEnabled() throws {
        let island = try XCTUnwrap(TripActivityMapFrame(rect: MKMapRect(x: 0, y: 0, width: 200, height: 100)))
        let lock = try XCTUnwrap(TripActivityMapFrame(rect: MKMapRect(x: 50, y: 0, width: 100, height: 100)))
        let point = MKMapPoint(x: 55, y: 50)
        var policy = TripActivityMapPolicy()
        XCTAssertTrue(policy.begin(newest: point, now: 0, enabled: true, showsOnLockScreen: true))
        policy.complete(frames: [.island: island, .lockScreen: lock])
        XCTAssertFalse(policy.begin(newest: point, now: 120, enabled: true, showsOnLockScreen: false))
        XCTAssertTrue(policy.begin(newest: point, now: 120, enabled: true, showsOnLockScreen: true))
        policy.complete(frames: nil)
        policy.removeLockScreen()
        XCTAssertNil(policy.usableFrame(for: [point], presentation: .lockScreen))
        XCTAssertFalse(policy.begin(newest: point, now: 239, enabled: true, showsOnLockScreen: true))
        XCTAssertTrue(policy.begin(newest: point, now: 240, enabled: true, showsOnLockScreen: true))
    }

    func testLockScreenMapOrPlainSelectionKeepsIslandMap() throws {
        let route = TripRouteSketch(points: [.init(x: 51, y: 102)])
        let fallback = TripRouteSketch(points: [.init(x: 128, y: 128)])
        let size = TripActivityMap.Presentation.lockScreen.size
        var map = TripActivityMap(token: UUID().uuidString, routeInMapFrame: route, lockScreenRouteInMapFrame: route)
        XCTAssertEqual(map.route(for: .lockScreen), route)
        XCTAssertEqual(fallback.displayPoints(size: size, imageRoute: map.route(for: .lockScreen), hasImage: true),
                       route.imagePoints(width: size.width, height: size.height))
        XCTAssertEqual(fallback.displayPoints(size: size, imageRoute: map.route(for: .lockScreen), hasImage: false),
                       [CGPoint(x: size.width / 2, y: size.height / 2)])
        map.lockScreenRouteInMapFrame = nil
        XCTAssertNil(map.route(for: .lockScreen))
        XCTAssertEqual(fallback.displayPoints(size: size, imageRoute: map.route(for: .lockScreen), hasImage: true),
                       [CGPoint(x: size.width / 2, y: size.height / 2)])
        XCTAssertEqual(map.route(for: .island), route)
        XCTAssertNil(try JSONDecoder().decode(TripActivityMap.self, from: JSONEncoder().encode(map)).route(for: .lockScreen))
    }

    func testSnapshotOptionsUseExactPanelSizeDarkMutedMapWithoutPOIsOrBuildings() {
        for presentation in TripActivityMap.Presentation.allCases {
            let frame = TripActivityMapFrame(rect: MKMapRect(x: 1_000, y: 1_000, width: 1_000, height: 1_000))!
            let options = TripActivityMapRenderer.options(frame: frame, size: presentation.size)
            XCTAssertEqual(options.size, presentation.size)
            XCTAssertEqual(options.traitCollection.userInterfaceStyle, .dark)
            XCTAssertEqual(options.traitCollection.displayScale, 2)
            let configuration = options.preferredConfiguration as? MKStandardMapConfiguration
            XCTAssertEqual(configuration?.emphasisStyle, .muted)
            XCTAssertEqual(configuration?.elevationStyle, .flat)
            XCTAssertEqual(configuration?.pointOfInterestFilter, .excludingAll)
        }
    }

    func testAtomicFilesKeepTwoGenerationsAndExcludeBackups() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = TripActivityMapFiles(directory: directory)
        defer { files.removeAll() }
        var tokens: [String] = []
        for value in 0..<3 {
            tokens.append(try files.write(Data([UInt8(value)]), lockScreen: Data([UInt8(value + 10)])))
        }
        XCTAssertEqual(files.currentToken, tokens[2])
        XCTAssertEqual(files.previousToken, tokens[1])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 4)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        for presentation in TripActivityMap.Presentation.allCases {
            XCTAssertFalse(FileManager.default.fileExists(atPath: files.url(for: tokens[0], presentation: presentation)!.path))
            let url = try XCTUnwrap(files.url(for: tokens[2], presentation: presentation))
            XCTAssertEqual(try Data(contentsOf: url), Data([presentation == .island ? 2 : 12]))
            XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        }
        files.removeLockScreenImages()
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
        XCTAssertNil(files.url(for: "../private"))
        XCTAssertThrowsError(try TripActivityMapFiles(directory: nil).write(Data([1])))
    }

    @MainActor func testTripOrActivityEndResetDeletesBothGenerationsAndDisabledDoesNoWork() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let files = TripActivityMapFiles(directory: directory)
        defer { files.removeAll() }
        let controller = TripActivityMapController(files: files)
        for _ in 0..<2 { _ = try files.write(Data([1]), lockScreen: Data([2])) }
        controller.reset()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertNil(files.currentToken)
        XCTAssertNil(files.previousToken)
        _ = try files.write(Data([1]), lockScreen: Data([2]))
        controller.update(points: [MKMapPoint(x: 1, y: 1)], enabled: false, showsOnLockScreen: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }
}
