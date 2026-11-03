import MapKit
import SwiftUI
import XCTest
@testable import WhereWolf

@MainActor
final class MapChromeTests: XCTestCase {
    func testLegalTouchTargetStaysAboveMapControls() async throws {
        try await withMap { _, _, map in
            @MainActor func findLegalControl(in view: UIView) -> UIView? {
                if view.accessibilityIdentifier == "wherewolf.map.legal" { return view }
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

    func testOverviewKeepsItsCameraWhenTheDrawerMovesOrPlaybackAdvances() async throws {
        try await withMap { surface, coordinator, map in
            var surface = surface
            let records = (0..<3).map { index in
                RecordedLocation(id: Int64(index), timestamp: Date().addingTimeInterval(Double(index)),
                    latitude: 45 + Double(index) * 0.2, longitude: -122 + Double(index) * 0.2)
            }
            surface.replayRoute = ReplayRouteGeometry(points: records)
            surface.replayOverview = true
            surface.replayFollowing = false
            NativeMapSurface.setDrawerTop(map.bounds.height - 360, on: map)
            coordinator.update(surface, animated: false)
            let camera = MapCamera(map.camera)
            self.assertTrail(surface.replayRoute!.coordinates, inside: NativeMapSurface.replayClearRect(on: map), on: map)
            for bottom in [240.0, 400, 360] {
                NativeMapSurface.setDrawerTop(map.bounds.height - bottom, on: map)
                map.layoutIfNeeded()
                coordinator.viewportChanged(on: map)
                try await Task.sleep(for: .milliseconds(150))
                XCTAssertEqual(MapCamera(map.camera), camera)
                surface.replayPosition = 1.5
                surface.selected = records[1].coordinate
                coordinator.update(surface, animated: false)
                XCTAssertEqual(MapCamera(map.camera), camera)
            }
            map.frame.size.width *= 0.75
            map.layoutIfNeeded()
            coordinator.viewportChanged(on: map)
            self.assertTrail(surface.replayRoute!.coordinates, inside: NativeMapSurface.replayClearRect(on: map), on: map)
        }
    }

    func testOverviewKeepsTheEastEndOfAThinTrailClearOfTheControlColumn() async throws {
        try await withMap { surface, coordinator, map in
            var surface = surface
            let coordinates = self.overviewTrails[0]
            surface.replayRoute = ReplayRouteGeometry(points: self.records(coordinates))
            surface.replayFollowing = false
            surface.replayOverview = true
            coordinator.update(surface, animated: false)
            let clear = NativeMapSurface.replayClearRect(on: map)
            self.assertTrail(coordinates, inside: clear, on: map)
            let east = map.convert(coordinates.last!, toPointTo: map)
            XCTAssertLessThan(east.x, map.bounds.maxX - MapChrome.edge - MapChrome.width)
            XCTAssertEqual((map.convert(coordinates[0], toPointTo: map).x + east.x) / 2,
                           clear.midX, accuracy: 1)
        }
    }

    func testProjectedOverviewFitsTrailShapesAtSeveralHeadingsAndPitches() async throws {
        try await withMap { _, _, map in
            let clear = MapChrome.replayClearRect(in: map.bounds, safeArea: map.safeAreaInsets,
                                                 drawerTop: map.bounds.height - 300)
            let reference = self.overviewReference(on: map)
            for heading in [0.0, 37, 90, 161, 270] {
                for pitch in [0.0, 35, 60] {
                    for trail in self.overviewTrails {
                        map.setCamera(MKMapCamera(lookingAtCenter: trail[0], fromDistance: 2_000,
                                                  pitch: pitch, heading: heading), animated: false)
                        let requested = MapCamera(map.camera)
                        let fit = try XCTUnwrap(ReplayOverviewFit.camera(for: trail, on: map, clearRect: clear),
                                               "heading \(heading), pitch \(pitch), count \(trail.count)")
                        map.setCamera(MKMapCamera(fit), animated: false)
                        self.assertTrail(trail, inside: clear, on: map)
                        self.assertOverviewCamera(on: map, requested: requested, reference: reference)
                        XCTAssertEqual(Double(map.camera.pitch), fit.pitch, accuracy: 0.01)
                        let bounds = try XCTUnwrap(ReplayOverviewFit.projectedBounds(trail.map { map.convert($0, toPointTo: map) }))
                        XCTAssertEqual(bounds.midX, clear.midX, accuracy: 1)
                        XCTAssertEqual(bounds.midY, clear.midY, accuracy: 1)
                    }
                }
            }
        }
    }

    func testProjectedOverviewSupportsTabletAndLandscapeViewports() throws {
        for size in [CGSize(width: 874, height: 402), CGSize(width: 768, height: 1024),
                     CGSize(width: 1024, height: 768)] {
            let map = MKMapView(frame: CGRect(origin: .zero, size: size))
            map.insetsLayoutMarginsFromSafeArea = false
            map.layoutMargins = .zero
            let safe = UIEdgeInsets(top: 24, left: 44, bottom: 34, right: 44)
            let clear = MapChrome.replayClearRect(in: map.bounds, safeArea: safe,
                                                 drawerTop: map.bounds.height - 150)
            for heading in [0.0, 73, 180] {
                for trail in self.overviewTrails {
                    map.setCamera(MKMapCamera(lookingAtCenter: trail[0], fromDistance: 2_000,
                                              pitch: 55, heading: heading), animated: false)
                    let fit = try XCTUnwrap(ReplayOverviewFit.camera(for: trail, on: map, clearRect: clear))
                    map.setCamera(MKMapCamera(fit), animated: false)
                    self.assertTrail(trail, inside: clear, on: map)
                }
            }
        }
    }

    func testOverviewTransitionPreservesRotationAndRestoresTheFollowingZoom() async throws {
        try await withMap { surface, coordinator, map in
            var surface = surface
            let coordinates = self.overviewTrails[0]
            surface.replayRoute = ReplayRouteGeometry(points: self.records(coordinates))
            surface.selected = coordinates[0]
            surface.replayFollowDistance = 1_300
            map.setCamera(MKMapCamera(lookingAtCenter: coordinates[0], fromDistance: 1_300,
                                      pitch: 40, heading: 53), animated: false)
            coordinator.update(surface, animated: false)
            let requested = MapCamera(map.camera)
            let reference = self.overviewReference(on: map)
            surface.replayOverview = true
            surface.replayFollowing = false
            surface.replayCameraAction += 1
            coordinator.update(surface, animated: true)
            coordinator.advanceCameraTransition(at: CACurrentMediaTime() + 2)
            self.assertTrail(coordinates, inside: NativeMapSurface.replayClearRect(on: map), on: map)
            self.assertOverviewCamera(on: map, requested: requested, reference: reference)
            surface.replayOverview = false
            surface.replayFollowing = true
            surface.replayCameraAction += 1
            surface.selected = coordinates[1]
            coordinator.update(surface, animated: true)
            coordinator.advanceCameraTransition(at: CACurrentMediaTime() + 2)
            XCTAssertEqual(map.camera.centerCoordinateDistance, 1_300, accuracy: 1)
            self.assertCentered(coordinates[1], on: map, tolerance: 2)
        }
    }

    func testReplayClearRectFollowsChromeSafeAreasCreditAndDrawer() {
        let bounds = CGRect(x: 0, y: 0, width: 1024, height: 768)
        let safe = UIEdgeInsets(top: 24, left: 44, bottom: 34, right: 44)
        let clear = MapChrome.replayClearRect(in: bounds, safeArea: safe, drawerTop: 500, statusHeight: 80)
        XCTAssertEqual(clear.minX, safe.left + MapChrome.edge + MapChrome.attributionGap)
        XCTAssertEqual(clear.maxX, bounds.maxX - safe.right - MapChrome.edge - MapChrome.width - MapChrome.attributionGap)
        XCTAssertEqual(clear.minY, safe.top + MapChrome.topInset + 80 + MapChrome.attributionGap)
        XCTAssertEqual(clear.maxY, 500 - MapChrome.attributionGap)
        let credit = MapChrome.replayClearRect(in: bounds, safeArea: safe, drawerTop: nil)
        XCTAssertEqual(credit.minY, MapChrome.attributionTop(safeTop: safe.top)
                       + MapChrome.attributionHeight + MapChrome.attributionGap)
        XCTAssertEqual(credit.maxY, bounds.maxY - safe.bottom - MapChrome.attributionGap)
    }

    func testOverviewRejectsAnUnavailableViewport() {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        XCTAssertNil(ReplayOverviewFit.camera(for: [], on: map, clearRect: map.bounds))
        XCTAssertNil(ReplayOverviewFit.camera(for: overviewTrails[0], on: map, clearRect: .zero))
        XCTAssertNil(ReplayOverviewFit.projectedBounds([CGPoint(x: CGFloat.infinity, y: 0)]))
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
            coordinator.advanceCameraTransition(at: CACurrentMediaTime() + 5)
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
            coordinator.advanceCameraTransition(at: CACurrentMediaTime() + 5)
            self.assertCentered(location.location!.coordinate, on: map, tolerance: 2)

            let displaced = map.camera.copy() as! MKMapCamera
            displaced.centerCoordinate.latitude += 0.002
            map.setCamera(displaced, animated: false)
            let point = map.convert(location.location!.coordinate, toPointTo: map)
            XCTAssertGreaterThan(abs(point.y - NativeMapSurface.visibleCenter(on: map).y), 20)
            let distance = map.camera.centerCoordinateDistance

            surface.recenterAction += 1
            coordinator.update(surface, animated: false)
            XCTAssertEqual(map.convert(location.location!.coordinate, toPointTo: map).y, point.y, accuracy: 1)
            coordinator.advanceCameraTransition(at: CACurrentMediaTime() + 5)
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

    func testCompassTurnsTheMapNorthAndKeepsTheZoom() async throws {
        XCTAssertFalse(NativeMapSurface.isRotated(heading: 0.5))
        XCTAssertFalse(NativeMapSurface.isRotated(heading: 359.5))
        XCTAssertTrue(NativeMapSurface.isRotated(heading: 90))
        XCTAssertTrue(NativeMapSurface.isRotated(heading: -30))
        try await withMap { surface, coordinator, map in
            map.setCamera(MKMapCamera(lookingAtCenter: surface.selected!, fromDistance: 3_000, pitch: 0, heading: 90), animated: false)
            let distance = map.camera.centerCoordinateDistance
            let result = try XCTUnwrap(NativeMapSurface.faceNorth(on: map))
            XCTAssertEqual(result.camera.heading, 0)
            XCTAssertEqual(result.camera.distance, distance, accuracy: 1)
            XCTAssertTrue(result.replayFollowing)
            coordinator.advanceCameraTransition(at: CACurrentMediaTime() + 1)
            XCTAssertEqual(remainder(map.camera.heading, 360), 0, accuracy: 0.5)
            XCTAssertEqual(map.camera.centerCoordinateDistance, distance, accuracy: distance * 0.01)
        }
    }

    func testCompassTakesItsTapInsteadOfTheMap() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let map = MKMapView()
        var taps = 0
        let host = FullScreenMapHost(rootView: AnyView(ZStack(alignment: .topTrailing) {
            MapViewHolder(map: map).ignoresSafeArea()
            MapCompassControl(readMap: { map }, action: { taps += 1 })
                .frame(width: MapChrome.width, height: MapChrome.width)
                .padding(.top, 200)
                .padding(.trailing, MapChrome.edge)
        }))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true
            previous?.makeKey()
        }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(200))
        @MainActor func findCompass(in view: UIView) -> UIControl? {
            if view.accessibilityIdentifier == "wherewolf.map.compass" { return view as? UIControl }
            return view.subviews.lazy.compactMap { findCompass(in: $0) }.first
        }
        let compass = try XCTUnwrap(findCompass(in: host.view))
        let center = compass.convert(CGPoint(x: compass.bounds.midX, y: compass.bounds.midY), to: host.view)
        let hit = try XCTUnwrap(host.view.hitTest(center, with: nil))
        XCTAssertTrue(hit.isDescendant(of: compass), "\(hit)")
        compass.sendActions(for: .touchUpInside)
        XCTAssertEqual(taps, 1)
        let elsewhere = try XCTUnwrap(host.view.hitTest(CGPoint(x: host.view.bounds.midX, y: host.view.bounds.midY), with: nil))
        XCTAssertTrue(elsewhere.isDescendant(of: map), "\(elsewhere)")
    }

    func testShowMyLocationFliesThereInsteadOfJumping() async throws {
        try await withMap { surface, coordinator, map in
            var surface = surface
            surface.replayRoute = nil
            surface.replayActive = false
            surface.selected = nil
            coordinator.update(surface, animated: false)
            let live = CLLocationCoordinate2D(latitude: 45.5152, longitude: -122.6784)
            coordinator.receiveLiveLocation(CLLocation(latitude: live.latitude, longitude: live.longitude), on: map)
            map.setCamera(MKMapCamera(lookingAtCenter: CLLocationCoordinate2D(latitude: 40, longitude: -100),
                                      fromDistance: 2_000, pitch: 0, heading: 0), animated: false)
            surface.position = .userLocation(fallback: .automatic)
            surface.recenterAction += 1
            coordinator.update(surface, animated: false)
            let start = CACurrentMediaTime()
            XCTAssertEqual(map.camera.centerCoordinate.longitude, -100, accuracy: 0.01)
            coordinator.advanceCameraTransition(at: start + 0.9)
            XCTAssertGreaterThan(map.camera.centerCoordinateDistance, 50_000)
            let middle = map.camera.centerCoordinate.longitude
            XCTAssertTrue(middle < -100.5 && middle > -122, "\(middle)")
            coordinator.advanceCameraTransition(at: start + 5)
            XCTAssertEqual(map.camera.centerCoordinateDistance, 2_000, accuracy: 20)
            self.assertCentered(live, on: map, tolerance: 2)
        }
    }

    func testADragStopsFollowingAtOnceAndCommitsWhenTheFingerLifts() async throws {
        try await withMap { surface, coordinator, map in
            var surface = surface
            surface.replayRoute = nil
            surface.replayActive = false
            surface.selected = nil
            surface.position = .userLocation(fallback: .automatic)
            var interactions = 0
            var committed: MapCamera?
            surface.onInteraction = { interactions += 1 }
            surface.onCameraChange = { camera, byUser in if byUser { committed = camera } }
            coordinator.update(surface, animated: false)
            let live = CLLocationCoordinate2D(latitude: 45.5152, longitude: -122.6784)
            coordinator.receiveLiveLocation(CLLocation(latitude: live.latitude, longitude: live.longitude), on: map)
            coordinator.advanceCameraTransition(at: CACurrentMediaTime() + 5)

            let pan = HeldPan()
            map.addGestureRecognizer(pan)
            defer { map.removeGestureRecognizer(pan) }
            pan.held = .began
            coordinator.gestureChanged(pan)
            try await Task.sleep(for: .milliseconds(20))
            XCTAssertEqual(interactions, 1)

            // MapKit reports this region while the finger is down, and nothing once it lifts.
            let moved = map.camera.copy() as! MKMapCamera
            moved.centerCoordinate.latitude += 0.01
            map.setCamera(moved, animated: false)
            try await Task.sleep(for: .milliseconds(50))
            XCTAssertNil(committed)
            pan.held = .ended
            coordinator.gestureChanged(pan)
            try await Task.sleep(for: .milliseconds(300))
            let camera = try XCTUnwrap(committed)
            XCTAssertEqual(camera.centerCoordinate.latitude, moved.centerCoordinate.latitude, accuracy: 1e-6)
            XCTAssertFalse(coordinator.parent.position.followsUserLocation)
        }
    }

    func testHeadingModeTurnsTheMapAroundTheDotAndReturnsNorth() async throws {
        try await withMap { surface, coordinator, map in
            var surface = surface
            surface.trackingEnabled = true
            surface.replayRoute = nil
            surface.replayActive = false
            surface.selected = nil
            surface.position = .userLocation(fallback: .automatic)
            coordinator.update(surface, animated: false)
            let live = CLLocationCoordinate2D(latitude: 45.5152, longitude: -122.6784)
            coordinator.receiveLiveLocation(CLLocation(latitude: live.latitude, longitude: live.longitude), on: map)
            coordinator.advanceCameraTransition(at: CACurrentMediaTime() + 5)
            self.assertCentered(live, on: map, tolerance: 2)

            surface.position = .userLocation(followsHeading: true, fallback: .automatic)
            coordinator.update(surface, animated: false)
            let start = CACurrentMediaTime()
            coordinator.receiveDeviceHeading(90, at: start)
            for frame in 1...120 {
                coordinator.advanceMapHeading(at: start + Double(frame) / 60)
                self.assertCentered(live, on: map, tolerance: 2)
                if frame == 6 {
                    XCTAssertTrue(map.camera.heading > 5 && map.camera.heading < 85, "\(map.camera.heading)")
                }
            }
            XCTAssertEqual(map.camera.heading, 90, accuracy: 0.5)
            XCTAssertEqual(map.camera.centerCoordinateDistance, 2_000, accuracy: 20)

            surface.position = .userLocation(fallback: .automatic)
            coordinator.update(surface, animated: false)
            let turn = CACurrentMediaTime()
            coordinator.advanceCameraTransition(at: turn + MapZoom.duration / 2)
            XCTAssertTrue(map.camera.heading > 5 && map.camera.heading < 85, "\(map.camera.heading)")
            self.assertCentered(live, on: map, tolerance: 2)
            coordinator.advanceCameraTransition(at: turn + 1)
            XCTAssertEqual(remainder(map.camera.heading, 360), 0, accuracy: 0.5)
            self.assertCentered(live, on: map, tolerance: 2)
            coordinator.receiveDeviceHeading(180)
            XCTAssertEqual(remainder(map.camera.heading, 360), 0, accuracy: 0.5)
        }
    }

    func testBeamCompassLifecycleIsIndependentOfCameraFollowing() async throws {
        let source = StubDeviceHeadingSource()
        let heading = LiveHeadingController(available: { true }, makeSource: { source })
        try await withMap(liveHeading: heading) { surface, coordinator, map in
            var live = surface
            live.replayRoute = nil
            live.replayActive = false
            live.selected = nil
            live.trackingEnabled = true
            coordinator.update(live, animated: false)
            XCTAssertEqual(source.starts, 1)
            let camera = map.camera.copy() as! MKMapCamera
            source.onHeading?(DeviceHeadingReading(trueHeading: 90, magneticHeading: 80, accuracy: 5))
            XCTAssertEqual(map.camera.heading, camera.heading, accuracy: 0.001)
            XCTAssertEqual(map.userTrackingMode, .none)

            live.position = .userLocation(followsHeading: true, fallback: .automatic)
            coordinator.update(live, animated: false)
            XCTAssertEqual(source.starts, 1)
            live.position = .userLocation(fallback: .automatic)
            coordinator.update(live, animated: false)
            XCTAssertEqual(source.stops, 0)

            for gate in 0..<6 {
                var hidden = live
                switch gate {
                case 0: hidden.trackingEnabled = false
                case 1: hidden.scenePhase = .inactive
                case 2: hidden.scenePhase = .background
                case 3: hidden.pageActive = false
                case 4: hidden.replayActive = true
                default: hidden.replayRoute = surface.replayRoute
                }
                let callback = source.onHeading
                let stops = source.stops
                coordinator.update(hidden, animated: false)
                XCTAssertEqual(source.stops, stops + 1, "gate \(gate)")
                XCTAssertNil(heading.reading)
                callback?(DeviceHeadingReading(trueHeading: 180, magneticHeading: 170, accuracy: 5))
                XCTAssertNil(heading.reading)
                coordinator.update(live, animated: false)
                XCTAssertNotNil(source.onHeading)
            }
        }
    }

    func testBeamProjectsCameraChangesImmediatelyAndReduceMotionJumps() async throws {
        let source = StubDeviceHeadingSource()
        let heading = LiveHeadingController(available: { true }, makeSource: { source }, reduceMotion: { true })
        try await withMap(liveHeading: heading) { surface, coordinator, map in
            var live = surface
            live.replayRoute = nil
            live.replayActive = false
            live.selected = nil
            live.trackingEnabled = true
            coordinator.update(live, animated: false)
            let coordinate = CLLocationCoordinate2D(latitude: 45, longitude: -122)
            let marker = MKUserLocationView(annotation: nil, reuseIdentifier: nil)
            marker.bounds = CGRect(x: 0, y: 0, width: 22, height: 22)
            marker.center = CGPoint(x: map.bounds.midX, y: map.bounds.midY)
            map.addSubview(marker)
            defer { marker.removeFromSuperview(); heading.onNeedsDisplay = nil }
            heading.onNeedsDisplay = { [weak heading, weak map, weak marker] in
                guard let map, let marker else { return }
                heading?.render(coordinate: coordinate, on: map, marker: marker)
            }
            for degrees in [359.0, 1, 90, 270] {
                source.onHeading?(DeviceHeadingReading(trueHeading: degrees, magneticHeading: 0, accuracy: 5))
                let beam = try XCTUnwrap(marker.layer.sublayers?.compactMap { $0 as? LiveHeadingBeamLayer }.first)
                let expected = MapHeadingProjection.angle(heading: degrees * .pi / 180, coordinate: coordinate, on: map)
                XCTAssertEqual(remainder(atan2(beam.transform.m12, beam.transform.m11) - expected, 2 * .pi),
                               0, accuracy: 0.000001)
            }
            for cameraHeading in [0.0, 37, 90, 270] {
                map.setCamera(MKMapCamera(lookingAtCenter: coordinate, fromDistance: 2_000,
                                         pitch: 35, heading: cameraHeading), animated: false)
                heading.render(coordinate: coordinate, on: map, marker: marker)
                let beam = try XCTUnwrap(marker.layer.sublayers?.compactMap { $0 as? LiveHeadingBeamLayer }.first)
                let expected = MapHeadingProjection.angle(heading: 270 * .pi / 180, coordinate: coordinate, on: map)
                XCTAssertEqual(remainder(atan2(beam.transform.m12, beam.transform.m11) - expected, 2 * .pi),
                               0, accuracy: 0.000001)
                XCTAssertEqual(beam.animationKeys() ?? [], [])
            }
            source.onHeading?(nil)
            XCTAssertFalse(marker.layer.sublayers?.contains { $0 is LiveHeadingBeamLayer } ?? false)
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

    private var overviewTrails: [[CLLocationCoordinate2D]] {
        let center = CLLocationCoordinate2D(latitude: 45, longitude: -122)
        return [
            (-4...4).map { CLLocationCoordinate2D(latitude: 45, longitude: -122 + Double($0) * 0.04) },
            (-4...4).map { CLLocationCoordinate2D(latitude: 45 + Double($0) * 0.04, longitude: -122) },
            [CLLocationCoordinate2D(latitude: 44.9, longitude: -122.1),
             CLLocationCoordinate2D(latitude: 45.07, longitude: -122.03),
             CLLocationCoordinate2D(latitude: 45.02, longitude: -121.85),
             CLLocationCoordinate2D(latitude: 44.92, longitude: -121.95)],
            [center],
            [center, CLLocationCoordinate2D(latitude: 45.00001, longitude: -121.99999)]
        ]
    }

    private func records(_ coordinates: [CLLocationCoordinate2D]) -> [RecordedLocation] {
        coordinates.enumerated().map {
            RecordedLocation(id: Int64($0.offset), timestamp: Date(timeIntervalSince1970: Double($0.offset)),
                             latitude: $0.element.latitude, longitude: $0.element.longitude)
        }
    }

    private func assertTrail(_ coordinates: [CLLocationCoordinate2D], inside clear: CGRect, on map: MKMapView,
                             file: StaticString = #filePath, line: UInt = #line) {
        for coordinate in coordinates {
            let point = map.convert(coordinate, toPointTo: map)
            XCTAssertTrue(clear.contains(point), "Route point \(point) is outside \(clear), camera \(map.camera)",
                          file: file, line: line)
        }
    }

    private func overviewReference(on map: MKMapView) -> MKMapView {
        let reference = MKMapView(frame: CGRect(origin: .zero, size: map.bounds.size))
        reference.insetsLayoutMarginsFromSafeArea = false
        reference.layoutMargins = .zero
        reference.mapType = map.mapType
        reference.layoutIfNeeded()
        return reference
    }

    private func assertOverviewCamera(on map: MKMapView, requested: MapCamera, reference: MKMapView,
                                      file: StaticString = #filePath, line: UInt = #line) {
        var expected = MapCamera(map.camera)
        expected.heading = requested.heading
        expected.pitch = requested.pitch
        // Ask MapKit independently at the final center and distance; its pitch limit varies with zoom.
        reference.setCamera(MKMapCamera(expected), animated: false)
        XCTAssertEqual(remainder(map.camera.heading - requested.heading, 360), 0, accuracy: 0.01,
                       file: file, line: line)
        XCTAssertEqual(map.camera.pitch, reference.camera.pitch, accuracy: 0.01, file: file, line: line)
    }

    private func assertCentered(_ coordinate: CLLocationCoordinate2D, on map: MKMapView,
                                tolerance: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        let actual = map.convert(coordinate, toPointTo: map)
        let expected = NativeMapSurface.visibleCenter(on: map)
        XCTAssertEqual(actual.x, expected.x, accuracy: tolerance, file: file, line: line)
        XCTAssertEqual(actual.y, expected.y, accuracy: tolerance, file: file, line: line)
    }

    private func withMap(liveHeading: LiveHeadingController? = nil,
                         _ work: (NativeMapSurface, NativeMapSurface.Coordinator, MKMapView) async throws -> Void) async throws {
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
        let coordinator = NativeMapSurface.Coordinator(surface, liveHeading: liveHeading ?? LiveHeadingController())
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
            coordinator.stopHeadingMode()
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

private struct MapViewHolder: UIViewRepresentable {
    let map: MKMapView
    func makeUIView(context: Context) -> MKMapView { map }
    func updateUIView(_ map: MKMapView, context: Context) {}
}

private final class HeldPan: UIPanGestureRecognizer {
    var held: UIGestureRecognizer.State = .possible
    override var state: UIGestureRecognizer.State {
        get { held }
        set { held = newValue }
    }
}
