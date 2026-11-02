import MapKit
import SwiftUI
import XCTest
@testable import Overland

@MainActor
final class MapChromeTests: XCTestCase {
    func testLegalTouchTargetStaysAboveMapControls() async throws {
        try await withMap { _, _, map in
            func findLegalControl(in view: UIView) -> UIView? {
                if view.accessibilityIdentifier == "overland.map.legal" { return view }
                return view.subviews.lazy.compactMap { findLegalControl(in: $0) }.first
            }
            let legal = try XCTUnwrap(findLegalControl(in: map))
            let frame = legal.convert(legal.bounds, to: map)
            XCTAssertTrue(legal.transform.isIdentity)
            XCTAssertGreaterThanOrEqual(frame.width, 44)
            XCTAssertGreaterThanOrEqual(frame.height, 44)
            let top = MapChrome.attributionTop(safeTop: map.safeAreaInsets.top)
            XCTAssertGreaterThanOrEqual(frame.minY, 0)
            XCTAssertGreaterThanOrEqual(frame.midY, top)
            XCTAssertLessThanOrEqual(frame.midY, top + MapChrome.attributionHeight / 2)
            XCTAssertGreaterThanOrEqual(frame.minX, 0)
            XCTAssertLessThan(frame.maxX, map.bounds.midX)
        }
    }

    func testAttributionRisesOnlyWhereTheStatusAreaHasRoom() {
        XCTAssertEqual(MapChrome.attributionTop(safeTop: 62), 48)
        XCTAssertEqual(MapChrome.attributionTop(safeTop: 47), 33)
        XCTAssertEqual(MapChrome.attributionTop(safeTop: 20), 20 + MapChrome.topInset)
    }

    func testTripRouteUsesTheReplayRouteWidth() async throws {
        try await withMap { _, coordinator, map in
            let line = MKPolyline(coordinates: [CLLocationCoordinate2D(latitude: 45, longitude: -122),
                                                CLLocationCoordinate2D(latitude: 45.001, longitude: -122)], count: 2)
            let renderer = try XCTUnwrap(coordinator.mapView(map, rendererFor: line) as? MKPolylineRenderer)
            XCTAssertEqual(renderer.lineWidth, ReplayRouteStyle.pastWidth)
        }
    }

    func testZoomStepsHaveFiniteBounds() {
        XCTAssertEqual(MapZoom.distance(from: 2_000, inward: true), 1_000)
        XCTAssertEqual(MapZoom.distance(from: 2_000, inward: false), 4_000)
        XCTAssertEqual(MapZoom.distance(from: 1, inward: true), MapZoom.minimumDistance)
        XCTAssertEqual(MapZoom.distance(from: .greatestFiniteMagnitude, inward: false), MapZoom.maximumDistance)
        for invalid in [0.0, -.infinity, .infinity, .nan] {
            XCTAssertEqual(MapZoom.distance(from: invalid, inward: true), 1_000)
        }
    }

    func testZoomTransitionFinishesQuicklyAtAnyScale() {
        for initial in [100.0, 2_000, 1_000_000, 20_000_000] {
            let from = MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: 45, longitude: -122), distance: initial)
            var to = from
            to.distance = MapZoom.distance(from: initial, inward: false)
            let transition = MapCameraTransition(from: from, to: to, start: 100, length: MapZoom.duration)
            XCTAssertEqual(transition.camera(at: 100), from)
            XCTAssertEqual(transition.camera(at: 100 + MapZoom.duration), to)
            let midpoint = transition.camera(at: 100 + MapZoom.duration / 2)
            XCTAssertGreaterThan(midpoint.distance, from.distance)
            XCTAssertLessThan(midpoint.distance, to.distance)
        }
    }

    func testReplayMarkerStaysCenteredWhileZoomingAndMoving() async throws {
        try await withMap { surface, coordinator, map in
            var surface = surface
            map.setCamera(MKMapCamera(lookingAtCenter: surface.selected!, fromDistance: 2_000, pitch: 25, heading: 37), animated: false)
            coordinator.update(surface, animated: false)
            try await Task.sleep(for: .milliseconds(150))
            self.assertCentered(surface.selected!, on: map, tolerance: 2)
            let overlays = map.overlays.map(ObjectIdentifier.init)
            var interactions = 0
            surface.onInteraction = { interactions += 1 }
            coordinator.update(surface, animated: false)

            for inward in [true, false] {
                let start = CACurrentMediaTime()
                let result = try XCTUnwrap(NativeMapSurface.zoom(inward: inward, on: map))
                XCTAssertTrue(result.replayFollowing)
                surface.replayFollowDistance = result.camera.distance
                surface.position = .camera(result.camera)
                for frame in 1...24 {
                    surface.selected = CLLocationCoordinate2D(latitude: 45 + Double(frame) * 0.00001,
                                                              longitude: -122 + Double(frame) * 0.000015)
                    surface.replayPosition = Double(frame) / 24
                    coordinator.update(surface, animated: false)
                    self.assertCentered(surface.selected!, on: map, tolerance: 2)
                    coordinator.advanceCameraTransition(at: start + Double(frame) / 60)
                    map.layoutIfNeeded()
                    self.assertCentered(surface.selected!, on: map, tolerance: 2)
                }
                XCTAssertEqual(map.camera.centerCoordinateDistance, result.camera.distance, accuracy: 1)
                XCTAssertEqual(map.camera.heading, 37, accuracy: 0.1)
                XCTAssertEqual(map.camera.pitch, 25, accuracy: 0.1)
                XCTAssertEqual(map.overlays.map(ObjectIdentifier.init), overlays)
                XCTAssertTrue(coordinator.parent.replayFollowing)
            }
            XCTAssertEqual(interactions, 0)
        }
    }

    func testRapidZoomTapsCompoundTheRequestedDistance() async throws {
        try await withMap { _, coordinator, map in
            let initial = map.camera.centerCoordinateDistance
            let start = CACurrentMediaTime()
            let first = try XCTUnwrap(NativeMapSurface.zoom(inward: true, on: map))
            let second = try XCTUnwrap(NativeMapSurface.zoom(inward: true, on: map))
            let third = try XCTUnwrap(NativeMapSurface.zoom(inward: true, on: map))
            XCTAssertEqual(first.camera.distance, initial / 2, accuracy: 1)
            XCTAssertEqual(second.camera.distance, initial / 4, accuracy: 1)
            XCTAssertEqual(third.camera.distance, initial / 8, accuracy: 1)
            coordinator.advanceCameraTransition(at: start + 1)
            XCTAssertEqual(map.camera.centerCoordinateDistance, third.camera.distance, accuracy: 1)
            self.assertCentered(coordinator.parent.selected!, on: map, tolerance: 2)
        }
    }

    func testZoomingADetachedReplayKeepsItsCameraFree() async throws {
        try await withMap { surface, coordinator, map in
            var surface = surface
            surface.replayFollowing = false
            let center = CLLocationCoordinate2D(latitude: 45.1, longitude: -122.1)
            surface.position = .camera(MapCamera(centerCoordinate: center, distance: 4_000))
            coordinator.update(surface, animated: false)
            let start = CACurrentMediaTime()
            let result = try XCTUnwrap(NativeMapSurface.zoom(inward: true, on: map))
            XCTAssertFalse(result.replayFollowing)
            coordinator.advanceCameraTransition(at: start + 1)
            XCTAssertEqual(map.camera.centerCoordinate.latitude, center.latitude, accuracy: 0.000001)
            XCTAssertEqual(map.camera.centerCoordinate.longitude, center.longitude, accuracy: 0.000001)
            XCTAssertFalse(coordinator.parent.replayFollowing)
        }
    }

    func testZoomingFromOverviewReturnsToFollowingTheSelectedPoint() async throws {
        try await withMap { surface, coordinator, map in
            var surface = surface
            surface.replayOverview = true
            coordinator.update(surface, animated: false)
            let start = CACurrentMediaTime()
            let result = try XCTUnwrap(NativeMapSurface.zoom(inward: true, on: map))
            XCTAssertTrue(result.replayFollowing)
            XCTAssertFalse(coordinator.parent.replayOverview)
            coordinator.advanceCameraTransition(at: start + 1)
            map.layoutIfNeeded()
            self.assertCentered(surface.selected!, on: map, tolerance: 2)
        }
    }

    func testOverviewFitsEveryPointWhenTheDrawerResizes() async throws {
        try await withMap { surface, coordinator, map in
            var surface = surface
            let records = (0..<3).map { index in
                RecordedLocation(id: Int64(index), timestamp: Date().addingTimeInterval(Double(index)),
                    latitude: 45 + Double(index) * 0.2, longitude: -122 + Double(index) * 0.2)
            }
            surface.replayRoute = ReplayRouteGeometry(points: records)
            surface.replayOverview = true
            surface.replayFollowing = false
            coordinator.update(surface, animated: false)
            for bottom in [240.0, 360] {
                NativeMapSurface.setDrawerTop(map.bounds.height - bottom, on: map)
                map.layoutIfNeeded()
                coordinator.viewportChanged(on: map)
                try await Task.sleep(for: .milliseconds(150))
                let visible = MapViewport.visibleRect(in: map.bounds, safeTop: map.safeAreaInsets.top,
                    drawerTop: map.bounds.height - bottom).insetBy(dx: 16, dy: 16)
                for coordinate in surface.replayRoute!.coordinates {
                    let point = map.convert(coordinate, toPointTo: map)
                    XCTAssertTrue(visible.contains(point), "Route point \(point) is outside \(visible)")
                }
            }
        }
    }

    func testAHiddenMapDoesNotStartZooming() async throws {
        try await withMap { surface, coordinator, map in
            var surface = surface
            surface.pageActive = false
            coordinator.update(surface, animated: false)
            XCTAssertNil(NativeMapSurface.zoom(inward: true, on: map))
        }
    }

    func testMapContactDefersCameraCorrectionsAndPreservesTapAndZoomIntent() async throws {
        try await withMap { surface, coordinator, map in
            var surface = surface
            surface.replayRoute = nil
            surface.replayActive = false
            surface.selected = nil
            surface.position = .userLocation(fallback: .automatic)
            coordinator.update(surface, animated: false)
            coordinator.stopLiveMotion()
            let location = FixedUserLocation(coordinate: CLLocationCoordinate2D(latitude: 45, longitude: -122))
            coordinator.mapView(map, didUpdate: location)
            self.assertCentered(location.location!.coordinate, on: map, tolerance: 2)

            coordinator.mapContactChanged(true)
            let camera = MapCamera(map.camera)
            NativeMapSurface.setDrawerTop(map.bounds.height - 340, on: map)
            map.layoutIfNeeded()
            coordinator.update(surface, animated: false)
            XCTAssertEqual(MapCamera(map.camera), camera)
            let held = map.convert(location.location!.coordinate, toPointTo: map)
            XCTAssertGreaterThan(abs(held.y - NativeMapSurface.visibleCenter(on: map).y), 20)

            coordinator.mapContactChanged(false)
            self.assertCentered(location.location!.coordinate, on: map, tolerance: 2)
            XCTAssertTrue(coordinator.parent.position.followsUserLocation)
            XCTAssertEqual(map.camera.centerCoordinateDistance, camera.distance, accuracy: 1)

            let start = CACurrentMediaTime()
            let zoom = try XCTUnwrap(NativeMapSurface.zoom(inward: true, on: map))
            let initialDistance = map.camera.centerCoordinateDistance
            coordinator.mapContactChanged(true, at: start + 0.05)
            coordinator.advanceCameraTransition(at: start + 10)
            XCTAssertEqual(map.camera.centerCoordinateDistance, initialDistance, accuracy: 1)
            coordinator.mapContactChanged(false, at: start + 10.05)
            coordinator.advanceCameraTransition(at: start + 10.1)
            XCTAssertLessThan(map.camera.centerCoordinateDistance, initialDistance)
            XCTAssertGreaterThan(map.camera.centerCoordinateDistance, zoom.camera.distance)
            coordinator.advanceCameraTransition(at: start + 11)
            XCTAssertEqual(map.camera.centerCoordinateDistance, zoom.camera.distance, accuracy: 1)
            self.assertCentered(location.location!.coordinate, on: map, tolerance: 2)
        }
    }

    func testLiveRecenterReappliesAnUnchangedFollowRequest() async throws {
        try await withMap { surface, coordinator, map in
            var surface = surface
            surface.replayRoute = nil
            surface.replayActive = false
            surface.selected = nil
            surface.position = .userLocation(fallback: .automatic)
            coordinator.update(surface, animated: false)
            coordinator.stopLiveMotion()
            let location = FixedUserLocation(coordinate: CLLocationCoordinate2D(latitude: 45, longitude: -122))
            coordinator.mapView(map, didUpdate: location)
            self.assertCentered(location.location!.coordinate, on: map, tolerance: 2)

            let displaced = map.camera.copy() as! MKMapCamera
            displaced.centerCoordinate.latitude += 0.002
            map.setCamera(displaced, animated: false)
            let point = map.convert(location.location!.coordinate, toPointTo: map)
            XCTAssertGreaterThan(abs(point.y - NativeMapSurface.visibleCenter(on: map).y), 20)
            let distance = map.camera.centerCoordinateDistance

            surface.recenterAction += 1
            coordinator.update(surface, animated: false)
            self.assertCentered(location.location!.coordinate, on: map, tolerance: 2)
            XCTAssertEqual(map.camera.centerCoordinateDistance, distance, accuracy: 1)
            XCTAssertTrue(coordinator.parent.position.followsUserLocation)
        }
    }

    func testNativeTrailAndMarkerStayTogetherDuringFastReplayAndZoom() async throws {
        try await withMap { surface, coordinator, map in
            let origin = MKMapPoint(CLLocationCoordinate2D(latitude: 45, longitude: -122))
            let records = (0..<2_000).map { index in
                let coordinate = MKMapPoint(x: origin.x + Double(index) * 4,
                    y: origin.y + sin(Double(index) * 0.03) * 80).coordinate
                return RecordedLocation(id: Int64(index + 1), timestamp: Date().addingTimeInterval(Double(index) * 5),
                    latitude: coordinate.latitude, longitude: coordinate.longitude)
            }
            var surface = surface
            surface.replayRoute = ReplayRouteGeometry(points: records)
            surface.replayAccuracy = 20
            map.setCamera(MKMapCamera(lookingAtCenter: records[0].coordinate,
                fromDistance: 2_000, pitch: 25, heading: 37), animated: false)
            for rate in [25.0, 50] {
                let model = HistoryPlaybackModel(pointLoader: { after, completion in completion(records.filter { $0.id > after }) },
                    payloadLoader: { _, completion in completion([:]) })
                model.setConsumerActive(true)
                model.reload()
                XCTAssertEqual(model.points.count, records.count)
                model.select(950)
                model.playbackRate = rate
                model.togglePlayback()
                defer { model.pause() }
                for frame in 0..<120 {
                    model.advancePlayback(by: 1.0 / 60)
                    let pose = try XCTUnwrap(model.renderPose)
                    surface.replayPosition = pose.position
                    surface.selected = pose.coordinate.coordinate
                    coordinator.update(surface, animated: false)
                    let cachedIndex = Int(pose.position) / 64 * 64
                    let cachedExpected = MKMapPoint(records[cachedIndex].coordinate)
                    let lines = map.overlays.compactMap { $0 as? MKPolyline }
                    XCTAssertTrue(lines.allSatisfy { line in
                        map.renderer(for: line).map { type(of: $0) == MKPolylineRenderer.self } ?? false
                    })
                    XCTAssertTrue(lines.contains { line in
                        let last = line.points()[line.pointCount - 1]
                        return abs(last.x - cachedExpected.x) < 0.001 && abs(last.y - cachedExpected.y) < 0.001
                    })
                    let endpoint = MKMapPoint(try XCTUnwrap(NativeMapSurface.displayedTrailCoordinate(on: map)))
                    let expected = MKMapPoint(pose.coordinate.coordinate)
                    XCTAssertEqual(endpoint.x, expected.x, accuracy: 0.001)
                    XCTAssertEqual(endpoint.y, expected.y, accuracy: 0.001)
                    let marker = try XCTUnwrap(map.annotations.compactMap { map.view(for: $0) }.first)
                    let tail = try XCTUnwrap(marker.superview?.layer.sublayers?.compactMap { $0 as? ReplayTrailLayer }.first)
                    let path = try XCTUnwrap(tail.path)
                    let projected = map.convert(pose.coordinate.coordinate, toPointTo: marker.superview)
                    XCTAssertEqual(path.currentPoint.x + tail.frame.minX, projected.x, accuracy: 0.01)
                    XCTAssertEqual(path.currentPoint.y + tail.frame.minY, projected.y, accuracy: 0.01)
                    XCTAssertEqual(tail.animationKeys() ?? [], [])
                    var vertices = 0
                    path.applyWithBlock { _ in vertices += 1 }
                    XCTAssertLessThanOrEqual(vertices, 130)
                    self.assertCentered(pose.coordinate.coordinate, on: map, tolerance: 2)
                    if frame == 30 || frame == 60 {
                        let result = try XCTUnwrap(NativeMapSurface.zoom(inward: frame == 30, on: map))
                        surface.replayFollowDistance = result.camera.distance
                        surface.position = .camera(result.camera)
                        coordinator.advanceCameraTransition(at: CACurrentMediaTime() + 1)
                    }
                }
            }
            let marker = try XCTUnwrap(map.annotations.compactMap { map.view(for: $0) }.first)
            let halo = try XCTUnwrap(marker.superview?.layer.sublayers?.compactMap { $0 as? ReplayAccuracyLayer }.first)
            let bounds = try XCTUnwrap(halo.path?.boundingBoxOfPath)
            let center = map.convert(surface.selected!, toPointTo: marker.superview)
            XCTAssertEqual(bounds.midX, center.x, accuracy: 1)
            XCTAssertEqual(bounds.midY, center.y, accuracy: 1)
            surface.replayAccuracy = nil
            coordinator.update(surface, animated: false)
            XCTAssertNil(halo.superlayer)
            let tail = try XCTUnwrap(marker.superview?.layer.sublayers?.compactMap { $0 as? ReplayTrailLayer }.first)
            surface.scenePhase = .background
            coordinator.update(surface, animated: false)
            XCTAssertNil(tail.superlayer)
            XCTAssertNil(tail.path)
        }
    }

    func testInactiveSceneKeepsMapMarkersUntilBackground() async throws {
        try await withMap { surface, coordinator, map in
            var surface = surface
            surface.replayPosition = 1.5
            let coordinates = surface.replayRoute!.coordinates
            surface.selected = ReplayCoordinate(coordinates[1]).interpolated(to: ReplayCoordinate(coordinates[2]), fraction: 0.5).coordinate
            coordinator.update(surface, animated: false)
            let marker = try XCTUnwrap(map.annotations.compactMap { map.view(for: $0) }.first)
            let tail = try XCTUnwrap(marker.superview?.layer.sublayers?.compactMap { $0 as? ReplayTrailLayer }.first)
            surface.scenePhase = .inactive
            coordinator.update(surface, animated: false)
            XCTAssertNotNil(tail.superlayer)
            XCTAssertNotNil(tail.path)

            surface.replayRoute = nil
            surface.replayActive = false
            surface.selected = nil
            surface.scenePhase = .active
            coordinator.update(surface, animated: false)
            XCTAssertTrue(map.showsUserLocation)
            surface.scenePhase = .inactive
            coordinator.update(surface, animated: false)
            XCTAssertTrue(map.showsUserLocation)
            surface.scenePhase = .background
            coordinator.update(surface, animated: false)
            XCTAssertFalse(map.showsUserLocation)
            surface.scenePhase = .inactive
            coordinator.update(surface, animated: false)
            XCTAssertTrue(map.showsUserLocation)
        }
    }

    func testReplayProgressDoesNotInheritUIKitCameraAnimations() async throws {
        try await withMap { surface, coordinator, map in
            var surface = surface
            surface.replayPosition = 1.5
            let coordinates = surface.replayRoute!.coordinates
            surface.selected = ReplayCoordinate(coordinates[1]).interpolated(to: ReplayCoordinate(coordinates[2]), fraction: 0.5).coordinate
            UIView.animate(withDuration: 1) { coordinator.update(surface, animated: false) }
            let marker = try XCTUnwrap(map.annotations.compactMap { map.view(for: $0) }.first)
            let tail = try XCTUnwrap(marker.superview?.layer.sublayers?.compactMap { $0 as? ReplayTrailLayer }.first)
            XCTAssertEqual(tail.animationKeys() ?? [], [])
            let projected = map.convert(surface.selected!, toPointTo: marker.superview)
            XCTAssertEqual(tail.path!.currentPoint.x + tail.frame.minX, projected.x, accuracy: 0.01)
            XCTAssertEqual(tail.path!.currentPoint.y + tail.frame.minY, projected.y, accuracy: 0.01)
        }
    }

    private func assertCentered(_ coordinate: CLLocationCoordinate2D, on map: MKMapView,
                                tolerance: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let actual = map.convert(coordinate, toPointTo: map)
        let expected = NativeMapSurface.visibleCenter(on: map)
        XCTAssertEqual(actual.x, expected.x, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: tolerance, file: file, line: line)
    }

    private func withMap(_ work: (NativeMapSurface, NativeMapSurface.Coordinator, MKMapView) async throws -> Void) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let host = UIViewController()
        window.rootViewController = host
        window.makeKeyAndVisible()
        host.view.layoutIfNeeded()
        let coordinates = [
            CLLocationCoordinate2D(latitude: 45, longitude: -122),
            CLLocationCoordinate2D(latitude: 45.001, longitude: -121.999),
            CLLocationCoordinate2D(latitude: 45.002, longitude: -121.997)
        ]
        let points = coordinates.enumerated().map {
            RecordedLocation(id: Int64($0.offset), timestamp: Date(timeIntervalSince1970: Double($0.offset)),
                             latitude: $0.element.latitude, longitude: $0.element.longitude)
        }
        let surface = NativeMapSurface(
            position: .camera(MapCamera(centerCoordinate: coordinates[0], distance: 2_000)),
            mapType: .standard, coordinates: [], replayRoute: ReplayRouteGeometry(points: points),
            replayPosition: 0, replayActive: true, replayFollowing: true, replayFollowDistance: 2_000,
            selected: coordinates[0], selectedTitle: "Recorded point", scenePhase: .active, pageActive: true,
            onCameraChange: { _, _ in }, onInteraction: {})
        let coordinator = surface.makeCoordinator()
        let map = surface.makeMap(coordinator: coordinator)
        map.frame = host.view.bounds
        map.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        host.view.addSubview(map)
        NativeMapSurface.setDrawerTop(map.bounds.height - 240, on: map)
        map.setNeedsLayout()
        map.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        defer {
            coordinator.stopCameraTransition()
            coordinator.stopReplayHeading()
            coordinator.stopLiveMotion()
            map.delegate = nil
            window.isHidden = true
            previous?.makeKey()
        }
        try await work(surface, coordinator, map)
    }
}

private final class FixedUserLocation: MKUserLocation {
    private let fix: CLLocation
    override var location: CLLocation? { fix }

    init(coordinate: CLLocationCoordinate2D) {
        fix = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        super.init()
    }
}
