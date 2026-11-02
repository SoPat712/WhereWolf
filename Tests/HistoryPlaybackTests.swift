import XCTest
import MapKit
import SwiftUI
@testable import Overland

final class HistoryPlaybackTests: XCTestCase {
    func testLiveMapMovesContinuouslyAcrossSuccessiveFixesAndSettlesWithoutOvershoot() {
        let origin = MKMapPoint(CLLocationCoordinate2D(latitude: 45, longitude: -122))
        var motion = LiveMapMotion()
        XCTAssertFalse(motion.receive(origin.coordinate, at: 0))
        var previous = origin.x
        for frame in 1...360 {
            let time = Double(frame) / 60
            if frame == 1 || frame == 61 || frame == 121 {
                let point = motion.point!
                let velocity = motion.velocity
                let goal = MKMapPoint(x: origin.x + Double((frame - 1) / 60 + 1) * 300, y: origin.y)
                XCTAssertTrue(motion.receive(goal.coordinate, at: time - 1 / 60))
                XCTAssertEqual(motion.point!.x, point.x, accuracy: 0.000001)
                XCTAssertEqual(motion.velocity.dx, velocity.dx, accuracy: 0.000001)
            }
            motion.advance(at: time)
            XCTAssertGreaterThanOrEqual(motion.point!.x, previous)
            XCTAssertLessThanOrEqual(motion.point!.x, origin.x + 900.000001)
            XCTAssertLessThan(motion.point!.x - previous, 12)
            previous = motion.point!.x
        }
        XCTAssertTrue(motion.settled(at: 6, tolerance: 0.01))
        motion.finish()
        XCTAssertEqual(motion.point!.x, origin.x + 900, accuracy: 0.000001)
    }

    func testLiveMapKeepsDatelineMotionShortAndIgnoresIdenticalFixes() {
        var motion = LiveMapMotion()
        let from = CLLocationCoordinate2D(latitude: 0, longitude: 179.99)
        let to = CLLocationCoordinate2D(latitude: 0, longitude: -179.99)
        XCTAssertFalse(motion.receive(from, at: 0))
        XCTAssertFalse(motion.receive(from, at: 0.5))
        XCTAssertTrue(motion.receive(to, at: 0.5))
        XCTAssertLessThan(abs(motion.target!.x - motion.point!.x), MKMapRect.world.width / 100)
        for frame in 31...180 {
            motion.advance(at: Double(frame) / 60)
            XCTAssertTrue(CLLocationCoordinate2DIsValid(motion.coordinate!))
            XCTAssertGreaterThan(abs(motion.coordinate!.longitude), 179.98)
        }
    }

    func testHistoryCameraTransitionCompletesInOneSecondAtEveryZoomRange() {
        let center = CLLocationCoordinate2D(latitude: 45, longitude: -122)
        for distances in [(150.0, 30_000_000.0), (30_000_000.0, 150.0), (2_000.0, 80_000.0)] {
            let from = MapCamera(centerCoordinate: center, distance: distances.0)
            let to = MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: 46, longitude: -120),
                               distance: distances.1)
            let transition = MapCameraTransition(from: from, to: to, start: 50)
            XCTAssertEqual(transition.camera(at: 50), from)
            XCTAssertEqual(transition.camera(at: 51), to)
            XCTAssertEqual(transition.camera(at: 52), to)
            let samples = (0...120).map { transition.camera(at: 50 + Double($0) / 120).distance }
            XCTAssertTrue(zip(samples, samples.dropFirst()).allSatisfy {
                distances.0 < distances.1 ? $0.0 <= $0.1 : $0.0 >= $0.1
            })
            let finalRatio = max(samples[119], samples[120]) / min(samples[119], samples[120])
            XCTAssertLessThan(finalRatio, 1.001)
        }
    }

    func testHistoryCameraUsesShortestDatelineAndHeadingPaths() {
        let from = MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: 0, longitude: 179),
                             distance: 1_000, heading: 350)
        let to = MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: 0, longitude: -179),
                           distance: 100_000, heading: 10)
        let transition = MapCameraTransition(from: from, to: to, start: 0)
        let middle = transition.camera(at: 0.5)
        XCTAssertGreaterThan(abs(middle.centerCoordinate.longitude), 179)
        XCTAssertEqual(middle.distance, 10_000, accuracy: 0.000001)
        XCTAssertEqual(middle.heading.truncatingRemainder(dividingBy: 360), 0, accuracy: 0.000001)
    }

    func testHistoryZoomDoesNotLeaveThePanUntilStreetLevel() {
        let from = MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: 45, longitude: -122),
                             distance: 2_000_000)
        let to = MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: 46, longitude: -120), distance: 150)
        let transition = MapCameraTransition(from: from, to: to, start: 0)
        let start = MKMapPoint(from.centerCoordinate), end = MKMapPoint(to.centerCoordinate)
        let initialScreenOffset = hypot(end.x - start.x, end.y - start.y) / from.distance
        for step in 1..<120 {
            let camera = transition.camera(at: Double(step) / 120)
            let point = MKMapPoint(camera.centerCoordinate)
            let screenOffset = hypot(end.x - point.x, end.y - point.y) / camera.distance
            XCTAssertLessThanOrEqual(screenOffset, initialScreenOffset * 1.001)
        }
    }

    func testFlightZoomsOutOnlyAsFarAsTheMoveNeeds() {
        let start = CLLocationCoordinate2D(latitude: 45.5, longitude: -122.6)
        let width = MKMapPointsPerMeterAtLatitude(start.latitude) * 2_000
        func peak(toward destination: CLLocationCoordinate2D) -> (ratio: Double, length: TimeInterval) {
            let from = MapCamera(centerCoordinate: start, distance: 2_000, heading: 30)
            let to = MapCamera(centerCoordinate: destination, distance: 2_000, heading: 30)
            let transition = MapCameraTransition.flight(from: from, to: to, start: 10, width: width)
            XCTAssertEqual(transition.camera(at: 10), from)
            XCTAssertEqual(transition.camera(at: 10 + transition.length), to)
            var previous = 0.0
            var highest = 0.0
            let path = MKMapPoint(destination).x - MKMapPoint(start).x
            for step in 1..<100 {
                let camera = transition.camera(at: 10 + transition.length * Double(step) / 100)
                let travelled = (MKMapPoint(camera.centerCoordinate).x - MKMapPoint(start).x) / path
                XCTAssertGreaterThanOrEqual(travelled, previous - 1e-9)
                XCTAssertEqual(camera.heading, 30, accuracy: 1e-9)
                previous = travelled
                highest = max(highest, camera.distance)
            }
            return (highest / 2_000, transition.length)
        }
        let hop = peak(toward: CLLocationCoordinate2D(latitude: 45.5, longitude: -122.596))
        let city = peak(toward: CLLocationCoordinate2D(latitude: 45.5, longitude: -122.4))
        let world = peak(toward: CLLocationCoordinate2D(latitude: 45.5, longitude: 2.3))
        XCTAssertLessThan(hop.ratio, 1.2)
        XCTAssertGreaterThan(city.ratio, 2)
        XCTAssertGreaterThan(world.ratio, city.ratio * 100)
        XCTAssertEqual(hop.length, 0.6, accuracy: 0.05)
        XCTAssertGreaterThan(city.length, hop.length)
        XCTAssertEqual(world.length, 2)
    }

    func testFlightTakesTheShortWayAcrossTheDateline() {
        let from = MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: 0, longitude: 179), distance: 5_000)
        let to = MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: 0, longitude: -179), distance: 5_000)
        let transition = MapCameraTransition.flight(from: from, to: to, start: 0,
            width: MKMapPointsPerMeterAtLatitude(0) * 5_000)
        for step in 1..<20 {
            let camera = transition.camera(at: transition.length * Double(step) / 20)
            XCTAssertGreaterThan(abs(camera.centerCoordinate.longitude), 178.9)
        }
    }

    func testMapAnchorTurnsWithTheCamera() {
        let anchor = MKMapPoint(CLLocationCoordinate2D(latitude: 45.5, longitude: -122.6))
        // The camera center sits 400 map points north of the visible center.
        let target = MKMapPoint(x: anchor.x, y: anchor.y + 400)
        func center(turning degrees: Double) -> MKMapPoint {
            MKMapPoint(MapViewport.anchoredCenter(anchor.coordinate, projectionCenter: anchor.coordinate,
                projectionTarget: target.coordinate, rotation: degrees * .pi / 180))
        }
        XCTAssertEqual(center(turning: 0).x, anchor.x, accuracy: 0.01)
        XCTAssertEqual(center(turning: 0).y, anchor.y - 400, accuracy: 0.01)
        // Facing east, the top of the screen is east, so the camera center lies east of the dot.
        XCTAssertEqual(center(turning: 90).x, anchor.x + 400, accuracy: 0.01)
        XCTAssertEqual(center(turning: 90).y, anchor.y, accuracy: 0.01)
        XCTAssertEqual(center(turning: 180).y, anchor.y + 400, accuracy: 0.01)
    }

    func testVisibleMapCenterTracksDrawerAndSafeArea() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 900)
        XCTAssertEqual(MapViewport.center(in: bounds, safeTop: 60, drawerTop: 760), CGPoint(x: 200, y: 410))
        XCTAssertEqual(MapViewport.center(in: bounds, safeTop: 60, drawerTop: 360), CGPoint(x: 200, y: 210))
        XCTAssertEqual(MapViewport.center(in: bounds, safeTop: 60, drawerTop: nil), CGPoint(x: 200, y: 480))
    }

    func testMovingTheDrawerLeavesTheMapStillUnlessItWouldCoverTheDot() {
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 900)
        func center(_ top: CGFloat?) -> CGPoint {
            MapViewport.restingCenter(in: bounds, safeTop: 60, closedDrawerTop: 760, drawerTop: top)
        }
        let resting = CGPoint(x: 200, y: 410)
        for top in [nil, 760, 700, 600, 500, 458] as [CGFloat?] {
            XCTAssertEqual(center(top), resting, "Drawer top \(String(describing: top))")
        }
        // A very tall drawer moves the dot only as far as it takes to keep it visible.
        XCTAssertEqual(center(400), CGPoint(x: 200, y: 352))
        XCTAssertEqual(center(120), CGPoint(x: 200, y: 90))
        // Without a closed position, as before the drawer has measured itself, use what is visible.
        XCTAssertEqual(MapViewport.restingCenter(in: bounds, safeTop: 60, closedDrawerTop: nil, drawerTop: 360),
                       CGPoint(x: 200, y: 210))
    }

    func testVisibleMapCenterClampsDrawerOvershootAndUsesLocalBounds() {
        let bounds = CGRect(x: 20, y: 30, width: 400, height: 800)
        XCTAssertEqual(MapViewport.center(in: bounds, safeTop: 80, drawerTop: 1_000), CGPoint(x: 220, y: 455))
        XCTAssertEqual(MapViewport.center(in: bounds, safeTop: 80, drawerTop: 0), CGPoint(x: 220, y: 80))
    }

    func testVisibleMapRectExcludesDrawerAndTopSafeArea() {
        let bounds = CGRect(x: 20, y: 30, width: 400, height: 800)
        XCTAssertEqual(MapViewport.visibleRect(in: bounds, safeTop: 80, drawerTop: 600),
                       CGRect(x: 20, y: 80, width: 400, height: 520))
        XCTAssertEqual(MapViewport.visibleRect(in: bounds, safeTop: 80, drawerTop: nil),
                       CGRect(x: 20, y: 80, width: 400, height: 750))
        XCTAssertEqual(MapViewport.visibleRect(in: bounds, safeTop: 80, drawerTop: 0).height, 0)
    }

    func testLocationButtonChoosesTheClosestRelativeZoom() {
        XCTAssertEqual(ReplayCameraFocus.nearest(current: 200_000, point: 1_000, trail: 50_000), .trail)
        XCTAssertEqual(ReplayCameraFocus.nearest(current: 40_000, point: 1_000, trail: 50_000), .trail)
        XCTAssertEqual(ReplayCameraFocus.nearest(current: 600, point: 1_000, trail: 50_000), .point)
        XCTAssertEqual(ReplayCameraFocus.nearest(current: 4_000, point: 1_000, trail: 50_000), .point)
        XCTAssertEqual(ReplayCameraFocus.nearest(current: .nan, point: 1_000, trail: 50_000), .point)
        XCTAssertEqual(ReplayCameraFocus.nearest(current: 1_000, point: 0, trail: 50_000), .point)
    }

    func testMapAnchorCorrectionTakesShortestPathAcrossDateline() {
        let center = CLLocationCoordinate2D(latitude: 0, longitude: 179.9)
        let selected = CLLocationCoordinate2D(latitude: 0, longitude: -179.9)
        let result = MapViewport.anchoredCenter(center, projectionCenter: selected, projectionTarget: center)
        XCTAssertEqual(result.longitude, -179.9, accuracy: 0.000001)
        XCTAssertEqual(result.latitude, 0, accuracy: 0.000001)
    }

    func testMapAnchorCorrectionDoesNotAccumulateWhenProjectionLagsCamera() {
        let anchor = MKMapPoint(CLLocationCoordinate2D(latitude: 45.5, longitude: -122.6))
        let offset = MKMapPoint(x: 120, y: 600)
        let initial = MapViewport.anchoredCenter(anchor.coordinate, projectionCenter: anchor.coordinate,
                                                projectionTarget: MKMapPoint(x: anchor.x - offset.x,
                                                                            y: anchor.y - offset.y).coordinate)
        for displacement in [0.0, 300.0, 600.0, 1_200.0] {
            let center = MKMapPoint(x: anchor.x, y: anchor.y + displacement)
            let target = MKMapPoint(x: center.x - offset.x, y: center.y - offset.y)
            let repeated = MapViewport.anchoredCenter(anchor.coordinate, projectionCenter: center.coordinate,
                                                      projectionTarget: target.coordinate)
            XCTAssertEqual(repeated.latitude, initial.latitude, accuracy: 0.000001)
            XCTAssertEqual(repeated.longitude, initial.longitude, accuracy: 0.000001)
        }
        XCTAssertEqual(MKMapPoint(initial).y, anchor.y + offset.y, accuracy: 0.001)
    }

    @MainActor func testNearbyScrubbingShowsPrefetchedDetailsImmediately() {
        let points = locations(5)
        var requests = [[Int64]]()
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) },
                                         payloadLoader: { ids, completion in
            requests.append(ids)
            completion(self.payloads(ids))
        })
        model.setConsumerActive(true)
        XCTAssertEqual(requests.count, 1)
        model.beginRulerInteraction()
        model.scrub(rulerPosition: 2.25, liveEdge: Date())
        XCTAssertEqual(model.payload?.device, "device-3")
        model.scrub(rulerPosition: 1.25, liveEdge: Date())
        XCTAssertEqual(model.payload?.device, "device-4")
        XCTAssertEqual(requests.count, 1)
    }

    @MainActor func testRapidScrubbingCoalescesReadsAndShowsLatestSelection() {
        let points = locations(400)
        var pending = [([Int64], ([Int64: RecordedPayload]) -> Void)]()
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) },
                                         payloadLoader: { pending.append(($0, $1)) })
        model.setConsumerActive(true)
        model.beginRulerInteraction()
        model.scrub(rulerPosition: 300, liveEdge: Date())
        model.scrub(rulerPosition: 350, liveEdge: Date())
        XCTAssertEqual(pending.count, 1)
        pending[0].1(payloads(pending[0].0))
        XCTAssertNil(model.payload)
        XCTAssertEqual(pending.count, 2)
        XCTAssertTrue(pending[1].0.contains(51))
        pending[1].1(payloads(pending[1].0))
        XCTAssertEqual(model.selectedPoint?.id, 51)
        XCTAssertEqual(model.payload?.device, "device-51")
        XCTAssertEqual(pending.count, 2)
    }

    @MainActor func testInactiveConsumerDoesNotLoadReplayDetails() {
        let points = locations(100)
        var pending = [([Int64], ([Int64: RecordedPayload]) -> Void)]()
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) },
                                         payloadLoader: { pending.append(($0, $1)) })
        model.setConsumerActive(true)
        model.setConsumerActive(false)
        pending[0].1(payloads(pending[0].0))
        model.scrub(pointAt: 10)
        XCTAssertNil(model.payload)
        XCTAssertEqual(pending.count, 1)
    }

    @MainActor func testInterpolatedMarkerMovesAlongStableRecordedRoute() {
        let points = locations(3)
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) },
                                         payloadLoader: { ids, completion in
            completion(self.payloads(ids))
        })
        model.setConsumerActive(true)
        model.beginRulerInteraction()
        model.scrub(rulerPosition: 1.75, liveEdge: Date())
        let coordinate = model.playbackCoordinate
        let route = model.routeGeometry!
        let pose = model.renderPose!
        model.scrub(rulerPosition: 1.25, liveEdge: Date())
        XCTAssertNotEqual(model.playbackCoordinate, coordinate)
        XCTAssertTrue(model.routeGeometry === route)
        XCTAssertGreaterThan(model.renderPose!.position, pose.position)
        XCTAssertEqual(route.coordinates.map(\.latitude), points.map(\.latitude))
        XCTAssertEqual(route.coordinates.map(\.longitude), points.map(\.longitude))
    }

    @MainActor func testFullDayRouteRetainsEveryPointAcrossScrubs() {
        let start = Date().addingTimeInterval(-23.5 * 3600)
        let points = (0..<86_400).map { index -> RecordedLocation in
            let latitude = 45.0 + sin(Double(index) * 1.7) * 0.0001
            let longitude = -122.0 + Double(index) * 0.000001
            return RecordedLocation(id: Int64(index + 1), timestamp: start.addingTimeInterval(Double(index) * 0.95),
                                    latitude: latitude, longitude: longitude)
        }
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) },
                                         payloadLoader: { _, completion in completion([:]) })
        model.setConsumerActive(true)
        model.scrub(pointAt: 1000)
        let route = model.routeGeometry!
        XCTAssertEqual(route.coordinates.count, points.count)
        XCTAssertTrue(zip(route.coordinates, points).allSatisfy { pair in
            pair.0.latitude == pair.1.latitude && pair.0.longitude == pair.1.longitude
        })
        for index in [1001, 20_000, 599, 70_000, 0, points.count - 1, 1000] {
            model.scrub(pointAt: index)
            XCTAssertTrue(model.routeGeometry === route)
            XCTAssertEqual(model.playbackCoordinate, ReplayCoordinate(points[index].coordinate))
        }
    }

    @MainActor func testTrailFollowsFractionalPlaybackAndReverseScrubbing() {
        let (model, _) = replay(at: [0, 60, 120])
        defer { model.pause() }
        model.playbackRate = 1
        model.togglePlayback()
        let route = model.routeGeometry!
        model.advancePlayback(by: 0.25)
        let first = model.renderPose!
        XCTAssertGreaterThan(first.position, 0)
        XCTAssertEqual(model.selectedIndex, 0)
        model.advancePlayback(by: 0.25)
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertGreaterThan(model.renderPose!.position, first.position)
        model.beginRulerInteraction()
        model.scrub(rulerPosition: 2.25, liveEdge: Date())
        let forward = model.renderPose!
        model.scrub(rulerPosition: 2.9, liveEdge: Date())
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertLessThan(model.renderPose!.position, forward.position)
        XCTAssertEqual(model.renderPose!.position, model.playbackIndex)
        XCTAssertEqual(model.renderPose!.coordinate, model.playbackCoordinate)
        XCTAssertTrue(model.routeGeometry === route)
    }

    @MainActor func testRenderPoseStaysCoherentAcrossLoggedPoints() {
        let (model, points) = replay(at: [0, 60, 120, 180, 240])
        defer { model.pause() }
        model.playbackRate = 1
        model.togglePlayback()
        var previous = 0.0
        for _ in 0..<Int(pace(60) * 3.5 * 30) {
            model.advancePlayback(by: 1.0 / 30)
            let pose = model.renderPose!
            XCTAssertGreaterThanOrEqual(pose.position, previous)
            let index = Int(pose.position)
            let expected = ReplayCoordinate(points[index].coordinate).interpolated(
                to: ReplayCoordinate(points[index + 1].coordinate), fraction: pose.position - Double(index))
            XCTAssertEqual(pose.coordinate.latitude, expected.latitude, accuracy: 0.0000000001)
            XCTAssertEqual(pose.coordinate.longitude, expected.longitude, accuracy: 0.0000000001)
            XCTAssertEqual(model.playbackCoordinate, pose.coordinate)
            XCTAssertEqual(model.cameraCenter, pose.coordinate)
            previous = pose.position
        }
        XCTAssertGreaterThan(model.playbackIndex, 2.9)
    }

    func testTripLineRetainsEveryPointWhenScrubbing() {
        let points: [[String: NSNumber]] = (0..<2401).map { index in
            ["id": NSNumber(value: index), "latitude": NSNumber(value: 45.0 + Double(index) * 0.00001),
             "longitude": NSNumber(value: -122.0 + sin(Double(index)) * 0.001)]
        }
        var trip = TripMapState(points: points)
        XCTAssertEqual(trip.displayCoords.count, points.count)
        trip.followingLive = false
        trip.scrubID = 1800
        let first = trip.displayCoords
        XCTAssertEqual(first.count, 1801)
        trip.scrubID = 1801
        let second = trip.displayCoords
        XCTAssertEqual(second.count, 1802)
        XCTAssertEqual(first.map(\.latitude), second.dropLast().map(\.latitude))
        XCTAssertEqual(first.map(\.longitude), second.dropLast().map(\.longitude))
    }

    func testCoarseRulerGainScalesToFillTheTimelineAndClamps() {
        XCTAssertEqual(HistoryRulerCoarseDrag.gain(tickCount: 48, rulerWidth: 320), 24)
        XCTAssertEqual(HistoryRulerCoarseDrag.gain(tickCount: 86_400, rulerWidth: 320), 9_720, accuracy: 0.000001)
        XCTAssertEqual(HistoryRulerCoarseDrag.position(after: 0, translation: 320,
                                                        tickCount: 86_400, rulerWidth: 320), 86_400,
                       accuracy: 0.000001)
        XCTAssertEqual(HistoryRulerCoarseDrag.position(after: 86_400, translation: -320,
                                                        tickCount: 86_400, rulerWidth: 320), 0,
                       accuracy: 0.000001)
    }

    func testCoarseRulerGainHasAnUpperBoundForVeryDenseHistories() {
        XCTAssertEqual(HistoryRulerCoarseDrag.gain(tickCount: 1_000_000, rulerWidth: 320),
                       HistoryRulerCoarseDrag.maximumGain)
    }

    @MainActor func testRouteOnlyRebuildsWhenStoredPointsChange() {
        let points = locations(5)
        var reads = 0
        let model = HistoryPlaybackModel(pointLoader: { _, completion in
            reads += 1
            completion(reads == 1 ? Array(points.prefix(3)) : reads == 2 ? [] : Array(points.suffix(2)))
        }, payloadLoader: { _, completion in completion([:]) })
        model.setConsumerActive(true)
        model.scrub(pointAt: 1)
        let original = model.routeGeometry!
        model.reload()
        XCTAssertTrue(model.routeGeometry === original)
        model.reload()
        let updated = model.routeGeometry!
        XCTAssertFalse(updated === original)
        XCTAssertEqual(updated.coordinates.count, points.count)
        XCTAssertEqual(updated.coordinates.map(\.latitude), points.map(\.latitude))
        model.scrub(pointAt: 4)
        XCTAssertTrue(model.routeGeometry === updated)
        model.returnToLive()
        XCTAssertNil(model.routeGeometry)
    }

    @MainActor func testChronologicalLoadsAdvanceCursorByLargestID() {
        let samples = locations(2)
        let points = [RecordedLocation(id: 5, timestamp: samples[0].timestamp,
                                      latitude: samples[0].latitude, longitude: samples[0].longitude), samples[1]]
        var cursors = [Int64]()
        let model = HistoryPlaybackModel(pointLoader: { after, completion in
            cursors.append(after)
            completion(after == 0 ? points : [])
        }, payloadLoader: { ids, completion in completion(self.payloads(ids)) })
        model.setConsumerActive(true)
        model.reload()
        XCTAssertEqual(cursors, [0, 5])
        XCTAssertEqual(model.points.count, 2)
    }

    func testPaceFollowsMovementInsteadOfTheClock() {
        XCTAssertEqual(ReplayPacing.rates, [0.25, 0.5, 1, 2, 5, 10, 25, 50])
        func mapSpeed(_ speed: Double, every interval: TimeInterval) -> Double {
            let distance = speed * interval
            return distance / ReplayPacing.baseDuration(recordedInterval: interval, distance: distance)
        }
        for interval in [1.0, 5, 30] {
            XCTAssertEqual(mapSpeed(1.4, every: interval), 21, accuracy: 1)
            XCTAssertEqual(mapSpeed(30, every: interval), 99, accuracy: 1)
        }
        XCTAssertLessThan(mapSpeed(30, every: 1) / mapSpeed(1.4, every: 1), 5)
        XCTAssertEqual(ReplayPacing.baseDuration(recordedInterval: 7_200, distance: 100_000), 16)
        XCTAssertEqual(ReplayPacing.baseDuration(recordedInterval: 60, distance: 0), 0.2, accuracy: 0.000001)
        XCTAssertEqual(mapSpeed(0.1, every: 5), 20, accuracy: 0.001)
        XCTAssertLessThanOrEqual(ReplayPacing.baseDuration(recordedInterval: 3_036, distance: 24), 2)
        XCTAssertLessThanOrEqual(ReplayPacing.baseDuration(recordedInterval: 21_904, distance: 5), 2)
        for rate in ReplayPacing.rates {
            XCTAssertEqual(ReplayPacing.segmentDuration(recordedInterval: 60, distance: 500, rate: rate),
                           ReplayPacing.baseDuration(recordedInterval: 60, distance: 500) / rate, accuracy: 0.000001)
        }
    }

    func testInvalidReplayRatesAndIntervalsKeepFinitePositiveDurations() {
        let expected = ReplayPacing.baseDuration(recordedInterval: 60, distance: 500)
        for rate in [0.0, -1, .nan, .infinity] {
            XCTAssertEqual(ReplayPacing.segmentDuration(recordedInterval: 60, distance: 500, rate: rate), expected)
        }
        for interval in [0.0, -1, .nan, .infinity] {
            XCTAssertEqual(ReplayPacing.baseDuration(recordedInterval: interval, distance: 500), 0.2)
        }
        for distance in [-1.0, .nan, .infinity] {
            let duration = ReplayPacing.baseDuration(recordedInterval: 60, distance: distance)
            XCTAssertTrue(duration.isFinite && duration > 0)
        }
    }

    func testHomeStaysPassInSecondsAtAnyPointDensity() {
        for interval in [1.0, 60] {
            let timeline = ReplayTimeline(points: home(hours: 8, every: interval))
            XCTAssertEqual(timeline.stays.count, 1)
            XCTAssertEqual(timeline.stays[0].span, 8 * 3_600, accuracy: interval)
            let count = Int(8 * 3_600 / interval)
            let total = (0..<count).reduce(0) { $0 + timeline.duration(segment: $1, rate: 1) }
            XCTAssertLessThanOrEqual(total, 3.001)
            XCTAssertGreaterThan(total, 1)
        }
    }

    func testStaysStayOnScreenAtEveryRate() {
        let points = home(hours: 8, every: 60)
        let moving = route(startID: 1, start: Date().addingTimeInterval(-3_600), fromLatitude: 45, speed: 20, every: 5, count: 3)
        let timeline = ReplayTimeline(points: points)
        func total(_ rate: Double) -> TimeInterval {
            (0..<(points.count - 1)).reduce(0) { $0 + timeline.duration(segment: $1, rate: rate) }
        }
        XCTAssertEqual(total(1), 3, accuracy: 0.001)
        XCTAssertEqual(total(0.25), 12, accuracy: 0.001)
        for rate in ReplayPacing.rates {
            XCTAssertGreaterThanOrEqual(total(rate), ReplayPacing.shortestStay - 0.001, "\(rate)x")
        }
        XCTAssertEqual(total(50), ReplayPacing.shortestStay, accuracy: 0.001)
        XCTAssertLessThan(ReplayPacing.stayDuration(span: 5 * 60), ReplayPacing.stayDuration(span: 3_600))

        // Only stays hold. Movement keeps scaling with the rate.
        let trip = ReplayTimeline(points: moving)
        XCTAssertEqual(trip.duration(segment: 0, rate: 50), trip.duration(segment: 0, rate: 1) / 50, accuracy: 0.000001)
    }

    func testAnyFixOutsideTheBoxEndsAStay() {
        var points = home(hours: 1, every: 30)
        let spike = points[60]
        points[60] = RecordedLocation(id: spike.id, timestamp: spike.timestamp,
                                      latitude: spike.latitude + 0.01, longitude: spike.longitude)
        let stays = ReplayTimeline(points: points).stays
        XCTAssertEqual(stays.count, 2)
        XCTAssertLessThan(stays[0].end, 60)
        XCTAssertGreaterThan(stays[1].start, 60)

        let leaving = home(hours: 1, every: 60) + route(startID: 100, start: Date().addingTimeInterval(-3_000),
                                                         fromLatitude: 45.001, speed: 20, every: 5, count: 60)
        let departed = ReplayTimeline(points: leaving).stays
        XCTAssertEqual(departed.count, 1)
        XCTAssertLessThan(departed[0].end, 65)
    }

    func testSilenceBetweenWalksIsAStayThatPassesQuickly() throws {
        let start = Date().addingTimeInterval(-20_000)
        func fix(_ index: Int, north: Double, after seconds: TimeInterval) -> RecordedLocation {
            RecordedLocation(id: Int64(index + 1), timestamp: start.addingTimeInterval(seconds),
                             latitude: 45 + north / 111_195, longitude: -122)
        }
        // A phone that logs only when it moves goes quiet for 50 minutes between two walks.
        var points = (0..<12).map { fix($0, north: Double($0) * 7, after: Double($0) * 5) }
        let parked = points.count - 1
        let parkedAt = points[parked].timestamp.timeIntervalSince(start)
        points += (0..<12).map { fix(12 + $0, north: 83 + Double($0) * 7, after: parkedAt + 3_000 + Double($0) * 5) }
        let timeline = ReplayTimeline(points: points)
        XCTAssertEqual(timeline.stays, [ReplayStay(start: parked, end: parked + 1, span: 3_000)])
        XCTAssertLessThanOrEqual(timeline.duration(segment: parked, rate: 1), 2)
        for index in points.indices.dropLast() where index != parked {
            XCTAssertNil(timeline.stay(during: index), "walking fix \(index) is inside a stay")
        }
    }

    func testLocalTripsAroundHomeAreNeverSwallowedByAStay() throws {
        let start = Date().addingTimeInterval(-20_000)
        func at(_ meters: (north: Double, east: Double), after seconds: TimeInterval, id: Int) -> RecordedLocation {
            RecordedLocation(id: Int64(id), timestamp: start.addingTimeInterval(seconds),
                             latitude: 45 + meters.north / 111_195,
                             longitude: -122 + meters.east / (111_195 * cos(45 * Double.pi / 180)))
        }
        func still(at place: (north: Double, east: Double), from seconds: TimeInterval, count: Int, id: Int) -> [RecordedLocation] {
            (0..<count).map { index in
                at((place.north + sin(Double(index)) * 8, place.east + cos(Double(index) * 1.7) * 8),
                   after: seconds + Double(index) * 30, id: id + index)
            }
        }

        // A 150 m drive between two parked spots, well inside what looks like one neighborhood.
        var points = still(at: (0, 0), from: 0, count: 60, id: 1)
        for step in 1...15 { points.append(at((0, Double(step) * 10), after: 1_770 + Double(step), id: 100 + step)) }
        points += still(at: (0, 150), from: 1_800, count: 60, id: 200)
        var timeline = ReplayTimeline(points: points)
        XCTAssertEqual(timeline.stays.count, 2)
        let driven = 59..<75
        for index in driven {
            XCTAssertNil(timeline.stay(during: index), "fix \(index) of the drive is inside a stay")
        }
        XCTAssertGreaterThan(driven.reduce(0) { $0 + timeline.duration(segment: $1, rate: 1) }, 2)

        // Six and a half minutes around a 100 m block, slowly enough to look stationary from afar.
        let corners: [(north: Double, east: Double)] = [(0, 0), (100, 0), (100, 100), (0, 100), (0, 0)]
        var walk: [RecordedLocation] = []
        for side in 0..<4 {
            for step in 0..<100 {
                let t = Double(step) / 100
                walk.append(at((corners[side].north + (corners[side + 1].north - corners[side].north) * t,
                                corners[side].east + (corners[side + 1].east - corners[side].east) * t),
                               after: Double(walk.count), id: walk.count + 1))
            }
        }
        XCTAssertTrue(ReplayTimeline(points: walk).stays.isEmpty)

        // Ten minutes out along a street at a slow walk, around a corner and back the same way.
        var stroll: [RecordedLocation] = []
        for step in 0..<60 { stroll.append(at((5, Double(step) * 2.5), after: Double(stroll.count) * 2.3, id: stroll.count + 1)) }
        for step in 0..<40 { stroll.append(at((5 - Double(step), 150), after: Double(stroll.count) * 2.3, id: stroll.count + 1)) }
        for step in 0..<40 { stroll.append(at((-35 + Double(step), 150), after: Double(stroll.count) * 2.3, id: stroll.count + 1)) }
        for step in 0..<60 { stroll.append(at((5, 150 - Double(step) * 2.5), after: Double(stroll.count) * 2.3, id: stroll.count + 1)) }
        XCTAssertGreaterThan(stroll.last!.timestamp.timeIntervalSince(stroll[0].timestamp), 400)
        XCTAssertTrue(ReplayTimeline(points: stroll).stays.isEmpty)

        // A very slow crawl may read as stops, but no single stay can drift across the block.
        let crawl = (0..<900).map { at((0, Double($0) * 0.2), after: Double($0), id: $0 + 1) }
        for stay in ReplayTimeline(points: crawl).stays {
            XCTAssertLessThanOrEqual(ReplayTimeline.distance(crawl[stay.start], crawl[stay.end]), 60)
        }

        // An errand that returns in under two minutes is a trip, not a stray fix.
        var errand = still(at: (0, 0), from: 0, count: 60, id: 1)
        for (offset, meters) in [300.0, 700, 1_000, 700, 300].enumerated() {
            errand.append(at((0, meters), after: 1_780 + Double(offset + 1) * 20, id: 100 + offset))
        }
        errand += still(at: (0, 0), from: 1_900, count: 60, id: 200)
        timeline = ReplayTimeline(points: errand)
        XCTAssertEqual(timeline.stays.count, 2)
        XCTAssertNil(timeline.stay(during: 62))
    }

    @MainActor func testPlaybackFollowsTheRouteThroughEveryLocalTrip() throws {
        let start = Date().addingTimeInterval(-20_000)
        func at(east meters: Double, north: Double = 0, after seconds: TimeInterval, id: Int) -> RecordedLocation {
            RecordedLocation(id: Int64(id), timestamp: start.addingTimeInterval(seconds),
                             latitude: 45 + north / 111_195,
                             longitude: -122 + meters / (111_195 * cos(45 * Double.pi / 180)))
        }
        var points = (0..<40).map { at(east: sin(Double($0)) * 8, after: Double($0) * 30, id: $0 + 1) }
        // Out along a street and back along the next one, ending where it began.
        for step in 1...40 { points.append(at(east: Double(step) * 5, after: 1_170 + Double(step), id: 100 + step)) }
        for step in 1...20 { points.append(at(east: 200, north: Double(step) * 5, after: 1_210 + Double(step), id: 200 + step)) }
        for step in 1...40 { points.append(at(east: 200 - Double(step) * 5, north: 100, after: 1_230 + Double(step), id: 300 + step)) }
        for step in 1...20 { points.append(at(east: 0, north: 100 - Double(step) * 5, after: 1_270 + Double(step), id: 400 + step)) }
        points += (0..<40).map { at(east: sin(Double($0)) * 8, after: 1_300 + Double($0) * 30, id: $0 + 500) }

        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) },
                                         payloadLoader: { ids, completion in completion(self.payloads(ids)) })
        defer { model.pause() }
        model.setConsumerActive(true)
        model.togglePlayback()
        var farthest = 0.0, furthestFromRoute = 0.0, frames = 0, tripFrames = 0
        let home = points[0]
        func distanceToRoute(_ pose: RecordedLocation) -> Double {
            points.indices.dropLast().reduce(.greatestFiniteMagnitude) { best, index in
                let a = points[index], b = points[index + 1]
                let along = ReplayTimeline.distance(a, b)
                var nearest = ReplayTimeline.distance(pose, a)
                if along > 0 {
                    let steps = max(1, Int(along))
                    for step in 1...steps {
                        let t = Double(step) / Double(steps)
                        nearest = min(nearest, ReplayTimeline.distance(pose, RecordedLocation(
                            id: 0, timestamp: a.timestamp,
                            latitude: a.latitude + (b.latitude - a.latitude) * t,
                            longitude: a.longitude + (b.longitude - a.longitude) * t)))
                    }
                }
                return min(best, nearest)
            }
        }
        while model.isPlaying {
            model.advancePlayback(by: 1.0 / 60)
            frames += 1
            XCTAssertLessThan(frames, 10_000)
            let pose = try XCTUnwrap(model.renderPose)
            let place = RecordedLocation(id: 0, timestamp: home.timestamp,
                                         latitude: pose.coordinate.latitude, longitude: pose.coordinate.longitude)
            let away = ReplayTimeline.distance(home, place)
            farthest = max(farthest, away)
            if away > 60 { tripFrames += 1 }
            if frames % 10 == 0 { furthestFromRoute = max(furthestFromRoute, distanceToRoute(place)) }
        }
        XCTAssertGreaterThan(farthest, 220, "the marker must reach the far corner of the loop")
        XCTAssertLessThanOrEqual(furthestFromRoute, 30, "the marker must stay on the route")
        XCTAssertGreaterThan(tripFrames, 240, "a 600 m loop must take several seconds at 1x")
    }

    func testRecordingGapsDoNotDissolveAStay() {
        let start = Date().addingTimeInterval(-40_000)
        // Tracking paused overnight leaves widely spaced fixes with no measurable speed.
        let points = (0..<8).map { index in
            RecordedLocation(id: Int64(index + 1), timestamp: start.addingTimeInterval(Double(index) * 3_600),
                             latitude: 45 + Double(index % 2) * 0.0001, longitude: -122)
        }
        let timeline = ReplayTimeline(points: points)
        XCTAssertEqual(timeline.stays, [ReplayStay(start: 0, end: 7, span: 7 * 3_600)])
    }

    func testShortStopsPassQuicklyEvenWithWanderingFixes() {
        let start = Date().addingTimeInterval(-7_200)
        let stop = (0..<240).map { index in
            RecordedLocation(id: Int64(index + 1), timestamp: start.addingTimeInterval(Double(index)),
                             latitude: 45 + sin(Double(index) * 0.7) * 0.00003,
                             longitude: -122 + cos(Double(index) * 1.3) * 0.00003)
        }
        let timeline = ReplayTimeline(points: stop)
        XCTAssertTrue(timeline.stays.isEmpty)
        let total = (0..<239).reduce(0) { $0 + timeline.duration(segment: $1, rate: 1) }
        XCTAssertLessThan(total, 1.5)
    }

    func testConsecutiveStaysShareAFixWithoutInterruptingTheGlide() {
        let start = Date().addingTimeInterval(-20_000)
        // Slow drift outgrows the first box, and the second continues from its last fix.
        let points = (0..<60).map { index in
            RecordedLocation(id: Int64(index + 1), timestamp: start.addingTimeInterval(Double(index) * 60),
                             latitude: 45 + Double(index / 20) * 40 / 111_195, longitude: -122)
        }
        let timeline = ReplayTimeline(points: points)
        XCTAssertEqual(timeline.stays.count, 2)
        let shared = timeline.stays[0].end
        XCTAssertEqual(timeline.stays[1].start, shared)
        XCTAssertEqual(timeline.stay(during: shared - 1), timeline.stays[0])
        XCTAssertEqual(timeline.stay(during: shared), timeline.stays[1])
        XCTAssertEqual(timeline.stay(containing: shared), timeline.stays[0])
        XCTAssertNil(timeline.stay(during: points.count - 1))
    }

    func testDrivingAndShortStopsAreNotStays() {
        let start = Date().addingTimeInterval(-7_200)
        XCTAssertTrue(ReplayTimeline(points: route(startID: 1, start: start, fromLatitude: 45,
                                                   speed: 25, every: 1, count: 2_000)).stays.isEmpty)
        XCTAssertTrue(ReplayTimeline(points: route(startID: 1, start: start, fromLatitude: 45,
                                                   speed: 1.4, every: 1, count: 2_000)).stays.isEmpty)
        let stopped = route(startID: 1, start: start, fromLatitude: 45, speed: 0, every: 10, count: 24)
        XCTAssertTrue(ReplayTimeline(points: stopped).stays.isEmpty)
        XCTAssertTrue(ReplayTimeline(points: []).stays.isEmpty)
        XCTAssertTrue(ReplayTimeline(points: Array(stopped.prefix(1))).stays.isEmpty)
    }

    func testLegDistanceRestartsAfterEachStay() throws {
        let start = Date().addingTimeInterval(-20_000)
        let first = route(startID: 1, start: start, fromLatitude: 45, speed: 20, every: 5, count: 11)
        let origin = first.last!
        let stay = (1...20).map { index in
            RecordedLocation(id: Int64(100 + index), timestamp: origin.timestamp.addingTimeInterval(Double(index) * 60),
                             latitude: origin.latitude, longitude: origin.longitude)
        }
        let second = route(startID: 200, start: stay.last!.timestamp.addingTimeInterval(5), fromLatitude: origin.latitude + 0.0009,
                           speed: 20, every: 5, count: 21)
        let points = first + stay + second
        let timeline = ReplayTimeline(points: points)
        XCTAssertEqual(timeline.stays.count, 1)
        let leg = try XCTUnwrap(timeline.legDistance(at: first.count - 2))
        XCTAssertEqual(leg, 900, accuracy: 5)
        XCTAssertNil(timeline.legDistance(at: first.count + 5))
        let last = try XCTUnwrap(timeline.legDistance(at: points.count - 1))
        XCTAssertEqual(last, 2_100, accuracy: 20)
    }

    func testLegDistanceSkipsGPSJumpsAndStillWandering() throws {
        let start = Date().addingTimeInterval(-20_000)
        var walk = route(startID: 1, start: start, fromLatitude: 45, speed: 1.4, every: 5, count: 40)
        let spike = walk[20]
        walk[20] = RecordedLocation(id: spike.id, timestamp: spike.timestamp,
                                    latitude: spike.latitude + 400 / 111_195, longitude: spike.longitude)
        let timeline = ReplayTimeline(points: walk)
        XCTAssertEqual(try XCTUnwrap(timeline.legDistance(at: 20)), 19 * 7, accuracy: 1)
        XCTAssertEqual(try XCTUnwrap(timeline.legDistance(at: walk.count - 1)), 39 * 7, accuracy: 1)

        // Driving out and back at the same speed is a real U-turn.
        let out = route(startID: 1, start: start, fromLatitude: 45, speed: 25, every: 5, count: 10)
        let back = (1..<10).map { index in
            RecordedLocation(id: Int64(100 + index), timestamp: out.last!.timestamp.addingTimeInterval(Double(index) * 5),
                             latitude: out.last!.latitude - Double(index) * 125 / 111_195, longitude: -122)
        }
        XCTAssertEqual(try XCTUnwrap(ReplayTimeline(points: out + back).legDistance(at: 18)), 18 * 125, accuracy: 2)

        // Fixes wandering for a few minutes in one spot add nothing.
        let wander = (0..<36).map { index in
            RecordedLocation(id: Int64(index + 1), timestamp: start.addingTimeInterval(Double(index) * 5),
                             latitude: 45 + (index.isMultiple(of: 2) ? 0 : 15 / 111_195), longitude: -122)
        }
        XCTAssertEqual(try XCTUnwrap(ReplayTimeline(points: wander).legDistance(at: 35)), 0, accuracy: 0.1)
    }

    func testActivityInfersSpeedAndPrefersRecordedMotion() {
        XCTAssertEqual(ReplayActivity.inferred(speed: 0.1), .stopped)
        XCTAssertEqual(ReplayActivity.inferred(speed: 1.4), .walking)
        XCTAssertEqual(ReplayActivity.inferred(speed: 3.5), .running)
        XCTAssertEqual(ReplayActivity.inferred(speed: 7), .moving)
        XCTAssertEqual(ReplayActivity.inferred(speed: 25), .driving)
        XCTAssertEqual(ReplayActivity.inferred(speed: 200), .flying)
        XCTAssertEqual(ReplayActivity.resolved(recorded: ["driving"], inferred: .stopped), .driving)
        XCTAssertEqual(ReplayActivity.resolved(recorded: ["cycling"], inferred: .moving), .cycling)
        XCTAssertEqual(ReplayActivity.resolved(recorded: ["stationary"], inferred: .driving), .driving)
        XCTAssertEqual(ReplayActivity.resolved(recorded: ["stationary", "walking"], inferred: .stopped), .walking)
        XCTAssertEqual(ReplayActivity.resolved(recorded: [], inferred: .walking), .walking)
        XCTAssertEqual(ReplayActivity.resolved(recorded: ["driving"], inferred: .flying), .flying)
        let walk = route(startID: 1, start: Date().addingTimeInterval(-3_000), fromLatitude: 45, speed: 1.4, every: 1, count: 300)
        XCTAssertEqual(ReplayTimeline(points: walk).inferredActivity(at: 150), .walking)
        let sparse = route(startID: 1, start: Date().addingTimeInterval(-3_000), fromLatitude: 45, speed: 25, every: 60, count: 10)
        XCTAssertEqual(ReplayTimeline(points: sparse).inferredActivity(at: 5), .driving)
    }

    func testStatusFormatting() {
        XCTAssertEqual(ReplayActivity.format(12 * 60), "12m")
        XCTAssertEqual(ReplayActivity.format(3 * 3_600), "3h")
        XCTAssertEqual(ReplayActivity.format(3 * 3_600 + 12 * 60), "3h 12m")
        XCTAssertEqual(ReplayActivity.format(49 * 3_600), "2d 1h")
        XCTAssertEqual(ReplayActivity.stayed(90 * 60).title, "Stayed 1h 30m")
        XCTAssertEqual(ReplayStatus.altitudeText(142, metric: true), "140 m")
        XCTAssertEqual(ReplayStatus.altitudeText(100, metric: false), "330 ft")
        XCTAssertEqual(ReplayStatus.distanceText(12_400, metric: true), "12.4 km")
        XCTAssertEqual(ReplayStatus.distanceText(1_609.344, metric: false), "1.0 mi")
        XCTAssertEqual(ReplayStatus.trend(Array(repeating: 10, count: 9)), 0)
        XCTAssertEqual(ReplayStatus.trend((0..<20).map { 10 + Double($0) }), 1)
        XCTAssertEqual(ReplayStatus.trend((0..<20).map { 40 - Double($0) }), -1)
        XCTAssertEqual(ReplayStatus.trend((0..<20).map { 10 + Double($0 % 3) }), 0)
    }

    func testPayloadReadsMotionAndRejectsInvalidAltitude() throws {
        func decode(_ properties: [String: Any]) throws -> RecordedPayload? {
            let data = try JSONSerialization.data(withJSONObject: ["properties": properties])
            return RecentLocationHistory.shared.decodePayload(data, format: 0)
        }
        let valid = try decode(["altitude": 120.5, "vertical_accuracy": 8, "motion": ["driving"]])
        XCTAssertEqual(valid?.altitude, 120.5)
        XCTAssertEqual(valid?.motion, ["driving"])
        XCTAssertNil(try decode(["altitude": 0, "vertical_accuracy": -1])?.altitude)
        XCTAssertEqual(try decode(["altitude": 7])?.altitude, 7)
        XCTAssertEqual(try decode([:])?.motion, [])
    }

    @MainActor func testPlaybackThroughAStayHoldsThePinSteady() throws {
        let points = home(hours: 2, every: 60)
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) },
                                         payloadLoader: { ids, completion in completion(self.payloads(ids)) })
        defer { model.pause() }
        model.setConsumerActive(true)
        model.togglePlayback()
        let route = try XCTUnwrap(model.routeGeometry)
        let start = ReplayCoordinate(points[0].coordinate), end = ReplayCoordinate(points[points.count - 1].coordinate)
        var positions = 0
        while model.isPlaying {
            model.advancePlayback(by: 1.0 / 60)
            positions += 1
            let pose = try XCTUnwrap(model.renderPose)
            let progress = pose.position / Double(points.count - 1)
            let expected = start.interpolated(to: end, fraction: progress)
            XCTAssertEqual(pose.coordinate.latitude, expected.latitude, accuracy: 0.0000001)
            XCTAssertEqual(pose.coordinate.longitude, expected.longitude, accuracy: 0.0000001)
            XCTAssertEqual(model.replayStatus?.activity, .stayed(2 * 3_600))
            XCTAssertLessThan(positions, 200)
        }
        XCTAssertGreaterThan(positions, 30)
        XCTAssertEqual(model.playbackCoordinate, end)
        XCTAssertTrue(route.direction(at: 10) == nil || route.direction(at: 10) == route.direction(at: 50))
        model.select(30)
        XCTAssertEqual(model.renderPose?.coordinate, ReplayCoordinate(points[30].coordinate))
    }

    @MainActor func testStatusUsesRecordedValuesAndHoldsAltitudeBetweenReads() throws {
        let points = route(startID: 1, start: Date().addingTimeInterval(-3_000), fromLatitude: 45, speed: 25, every: 5, count: 40)
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) }, payloadLoader: { ids, completion in
            completion(Dictionary(uniqueKeysWithValues: ids.map { id in
                (id, RecordedPayload(format: "GeoJSON", speed: 25, accuracy: 5, altitude: id == 10 ? nil : Double(id) * 4,
                                     device: nil, battery: nil, rawJSON: Data("{}".utf8),
                                     motion: id == 20 ? ["cycling"] : []))
            }))
        })
        model.setConsumerActive(true)
        XCTAssertNil(model.replayStatus)
        model.scrub(pointAt: 19)
        var status = try XCTUnwrap(model.replayStatus)
        XCTAssertEqual(status.activity, .cycling)
        XCTAssertEqual(status.altitude, 80)
        XCTAssertEqual(status.altitudeTrend, 1)
        XCTAssertEqual(status.legDistance ?? 0, 19 * 125, accuracy: 10)
        model.select(9)
        status = try XCTUnwrap(model.replayStatus)
        XCTAssertEqual(status.activity, .driving)
        XCTAssertEqual(status.altitude, 36)
        model.returnToLive()
        XCTAssertNil(model.replayStatus)
    }

    @MainActor func testFractionalReplayRatesPreservePositionAcrossSpeedChanges() {
        let (model, _) = replay(at: [0, 60, 120])
        defer { model.pause() }
        XCTAssertEqual(model.playbackRate, 1)
        let pace = pace(60)
        model.playbackRate = 0.25
        model.togglePlayback()
        model.advancePlayback(by: pace)
        XCTAssertEqual(model.playbackIndex, 0.25, accuracy: 0.000001)
        let pose = model.renderPose
        model.playbackRate = 0.5
        XCTAssertEqual(model.renderPose, pose)
        model.advancePlayback(by: pace / 2)
        XCTAssertEqual(model.playbackIndex, 0.5, accuracy: 0.000001)
        model.playbackRate = 0.25
        model.advancePlayback(by: pace * 0.4)
        XCTAssertEqual(model.playbackIndex, 0.6, accuracy: 0.000001)
    }

    @MainActor func testReplayCompressesLongGapsAndInterpolatesMovement() {
        let (model, points) = replay(at: [0, 3600, 3660])
        defer { model.pause() }
        model.playbackRate = 1
        model.togglePlayback()
        model.advancePlayback(by: 4)
        XCTAssertEqual(model.playbackIndex, 0.25, accuracy: 0.000001)
        XCTAssertEqual(model.playbackTime!, points[0].timestamp.timeIntervalSince1970 + 900, accuracy: 0.000001)
        XCTAssertGreaterThan(model.playbackCoordinate!.latitude, points[0].latitude)
        XCTAssertLessThan(model.playbackCoordinate!.latitude, points[1].latitude)

        model.advancePlayback(by: 12 + pace(60) / 2)
        XCTAssertEqual(model.playbackIndex, 1.5, accuracy: 0.000001)
        XCTAssertEqual(model.playbackTime!, points[0].timestamp.timeIntervalSince1970 + 3630, accuracy: 0.000001)
    }

    @MainActor func testReplaySpeedChangeKeepsTheCurrentPosition() {
        let (model, _) = replay(at: [0, 60, 120])
        defer { model.pause() }
        model.playbackRate = 1
        model.togglePlayback()
        let pace = pace(60)
        model.advancePlayback(by: pace / 4)
        let coordinate = model.playbackCoordinate
        let time = model.playbackTime
        model.playbackRate = 2
        XCTAssertEqual(model.playbackCoordinate, coordinate)
        XCTAssertEqual(model.playbackTime, time)
        model.advancePlayback(by: pace / 8)
        XCTAssertEqual(model.playbackIndex, 0.5, accuracy: 0.000001)
    }

    @MainActor func testFasterReplayAlsoSpeedsUpDenseRecordings() {
        let intervals = (0...20).map(Double.init)
        let (normal, _) = replay(at: intervals)
        let (faster, _) = replay(at: intervals)
        defer { normal.pause(); faster.pause() }
        normal.playbackRate = 1
        faster.playbackRate = 2
        normal.togglePlayback()
        faster.togglePlayback()
        normal.advancePlayback(by: pace(1) * 2)
        faster.advancePlayback(by: pace(1) * 2)
        XCTAssertEqual(normal.playbackIndex, 2, accuracy: 0.000001)
        XCTAssertEqual(faster.playbackIndex, 4, accuracy: 0.000001)
    }

    @MainActor func testPlaybackCarriesFrameTimeAcrossPointsAndStopsAtTheEnd() {
        let (model, points) = replay(at: [0, 60, 120, 180])
        model.playbackRate = 1
        model.togglePlayback()
        model.advancePlayback(by: pace(60) * 1.5)
        XCTAssertEqual(model.playbackIndex, 1.5, accuracy: 0.000001)
        XCTAssertEqual(model.selectedPoint?.id, points[1].id)
        model.advancePlayback(by: 400)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.playbackIndex, 3)
        XCTAssertEqual(model.playbackCoordinate, ReplayCoordinate(points[3].coordinate))
    }

    @MainActor func testPlaybackResumesFromFractionalScrubAndSeekResetsProgress() {
        let (model, _) = replay(at: [0, 60, 120])
        defer { model.pause() }
        model.playbackRate = 1
        model.beginRulerInteraction()
        model.scrub(rulerPosition: 1.5, liveEdge: Date())
        model.togglePlayback()
        let pace = pace(60)
        model.advancePlayback(by: pace * 0.2)
        XCTAssertEqual(model.playbackIndex, 1.7, accuracy: 0.000001)
        model.pause()
        model.advancePlayback(by: 40)
        XCTAssertEqual(model.playbackIndex, 1.7, accuracy: 0.000001)
        model.togglePlayback()
        model.advancePlayback(by: pace * 0.1)
        XCTAssertEqual(model.playbackIndex, 1.8, accuracy: 0.000001)
        model.select(0)
        model.togglePlayback()
        model.advancePlayback(by: pace * 0.25)
        XCTAssertEqual(model.playbackIndex, 0.25, accuracy: 0.000001)
    }

    @MainActor func testPlaybackHandlesEqualTimestampsWithoutSkippingMovement() {
        let (model, points) = replay(at: [0, 0, 60])
        defer { model.pause() }
        model.playbackRate = 1
        model.togglePlayback()
        model.advancePlayback(by: 0.1)
        XCTAssertEqual(model.playbackIndex, 0.5, accuracy: 0.000001)
        XCTAssertEqual(model.playbackTime, points[0].timestamp.timeIntervalSince1970)
        model.advancePlayback(by: 0.1 + pace(60) / 2)
        XCTAssertEqual(model.playbackIndex, 1.5, accuracy: 0.000001)
    }

    @MainActor func testLatePointDoesNotRewindAnActiveReplay() {
        let start = Date().addingTimeInterval(-3600)
        let first = RecordedLocation(id: 1, timestamp: start, latitude: 45, longitude: -122)
        let last = RecordedLocation(id: 3, timestamp: start.addingTimeInterval(120), latitude: 45.002, longitude: -122)
        let late = RecordedLocation(id: 4, timestamp: start.addingTimeInterval(60), latitude: 45.001, longitude: -122)
        var reads = 0
        let model = HistoryPlaybackModel(pointLoader: { _, completion in
            reads += 1
            completion(reads == 1 ? [first, last] : reads == 2 ? [late] : [])
        }, payloadLoader: { ids, completion in completion(self.payloads(ids)) })
        defer { model.pause() }
        model.setConsumerActive(true)
        model.playbackRate = 1
        model.togglePlayback()
        model.advancePlayback(by: ReplayPacing.baseDuration(recordedInterval: 120,
                                                            distance: ReplayTimeline.distance(first, last)) * 0.75)
        let time = model.playbackTime
        model.reload()
        XCTAssertEqual(model.playbackTime, time)
        XCTAssertEqual(model.selectedPoint?.id, first.id)
        model.pause()
        XCTAssertEqual(model.selectedPoint?.id, late.id)
        XCTAssertEqual(model.playbackIndex, 1.5, accuracy: 0.000001)
        model.togglePlayback()
        model.advancePlayback(by: 0.4)
        XCTAssertGreaterThan(model.playbackTime!, time!)
    }

    @MainActor func testRetentionIncreaseUsesFullSnapshotWithoutDuplicateIDsAndPreservesSelection() {
        let now = Date()
        let old = RecordedLocation(id: 1, timestamp: now.addingTimeInterval(-36 * 60 * 60), latitude: 45, longitude: -122)
        let recent = RecordedLocation(id: 2, timestamp: now.addingTimeInterval(-2 * 60 * 60), latitude: 45.001, longitude: -122)
        var hours = 24.0
        var cursors = [Int64]()
        let model = HistoryPlaybackModel(pointLoader: { after, completion in
            cursors.append(after)
            completion([old, recent, recent])
        }, payloadLoader: { _, completion in completion([:]) }, retentionDuration: { hours * 60 * 60 })
        model.setConsumerActive(true)
        XCTAssertEqual(model.points.map(\.id), [recent.id])
        model.select(0)
        let selectedTime = model.playbackTime

        hours = 72
        model.retentionDidChange()

        XCTAssertEqual(model.points.map(\.id), [old.id, recent.id])
        XCTAssertEqual(Set(model.points.map(\.id)).count, model.points.count)
        XCTAssertEqual(model.selectedPoint?.id, recent.id)
        XCTAssertEqual(model.playbackTime, selectedTime)
        XCTAssertEqual(model.renderPose?.position, 1)
        XCTAssertEqual(model.renderPose?.coordinate, ReplayCoordinate(recent.coordinate))
        XCTAssertEqual(cursors, [0, 0])
    }

    @MainActor func testRetentionSnapshotKeepsRulerAndRoutePoseTogetherWhenPointsArrive() {
        let now = Date()
        let old = RecordedLocation(id: 1, timestamp: now.addingTimeInterval(-36 * 3600), latitude: 45, longitude: -122)
        let recent = RecordedLocation(id: 2, timestamp: now.addingTimeInterval(-2 * 3600), latitude: 45.001, longitude: -122)
        let next = RecordedLocation(id: 3, timestamp: now.addingTimeInterval(-3600), latitude: 45.002, longitude: -122)
        var samples = [old, recent, next]
        var hours = 24.0
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(samples) },
                                         payloadLoader: { _, completion in completion([:]) },
                                         retentionDuration: { hours * 3600 })
        model.setConsumerActive(true)
        model.beginRulerInteraction()
        model.scrub(rulerPosition: 1.5, liveEdge: now)
        let coordinate = model.renderPose?.coordinate
        let time = model.playbackTime
        hours = 72
        model.retentionDidChange()
        samples.append(RecordedLocation(id: 4, timestamp: now, latitude: 45.003, longitude: -122))
        model.endRulerInteraction()
        XCTAssertEqual(model.points.count, 4)
        XCTAssertEqual(model.renderPose?.coordinate, coordinate)
        XCTAssertEqual(model.playbackTime, time)
        XCTAssertEqual(model.renderPose?.position, 1.5)
        XCTAssertEqual(model.rulerPosition, 2.5)
        XCTAssertEqual(model.playbackIndex, 1.5)
    }

    @MainActor func testRetentionShrinkExpiresSelectedPointAndKeepsCurrentPolicy() {
        let now = Date()
        let old = RecordedLocation(id: 1, timestamp: now.addingTimeInterval(-36 * 60 * 60), latitude: 45, longitude: -122)
        let recent = RecordedLocation(id: 2, timestamp: now.addingTimeInterval(-2 * 60 * 60), latitude: 45.001, longitude: -122)
        var hours = 72.0
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion([old, recent]) },
                                         payloadLoader: { _, completion in completion([:]) },
                                         retentionDuration: { hours * 60 * 60 })
        model.setConsumerActive(true)
        model.select(0)
        hours = 24
        model.retentionDidChange()

        XCTAssertEqual(model.points.map(\.id), [recent.id])
        XCTAssertEqual(model.selectedPoint?.id, recent.id)
        XCTAssertEqual(model.rulerTime, recent.timestamp)
        XCTAssertEqual(model.retentionInterval, 24.0 * 60 * 60, accuracy: 0.000001)
    }

    @MainActor func testRetentionChangeFiltersStaleInFlightResultsAndReloadsInactiveLater() {
        let now = Date()
        let old = RecordedLocation(id: 1, timestamp: now.addingTimeInterval(-36 * 60 * 60), latitude: 45, longitude: -122)
        let recent = RecordedLocation(id: 2, timestamp: now.addingTimeInterval(-2 * 60 * 60), latitude: 45.001, longitude: -122)
        var hours = 72.0
        var pending = [(Int64, ([RecordedLocation]) -> Void)]()
        let model = HistoryPlaybackModel(pointLoader: { after, completion in
            pending.append((after, completion))
        }, payloadLoader: { _, completion in completion([:]) }, retentionDuration: { hours * 60 * 60 })
        model.setConsumerActive(true)
        XCTAssertEqual(pending.map { $0.0 }, [0])
        hours = 24
        model.retentionDidChange()
        pending[0].1([old, recent])
        XCTAssertEqual(model.points.map(\.id), [recent.id])
        XCTAssertEqual(pending.map { $0.0 }, [0, 0])
        pending[1].1([old, recent])
        XCTAssertEqual(model.points.map(\.id), [recent.id])

        let inactive = HistoryPlaybackModel(pointLoader: { after, completion in
            pending.append((after, completion))
        }, payloadLoader: { _, completion in completion([:]) }, retentionDuration: { hours * 60 * 60 })
        inactive.setConsumerActive(true)
        inactive.setConsumerActive(false)
        hours = 72
        inactive.retentionDidChange()
        let request = pending.removeLast()
        request.1([old, recent])
        XCTAssertTrue(inactive.points.isEmpty)
        inactive.setConsumerActive(true)
        XCTAssertFalse(pending.isEmpty)
        pending.removeLast().1([old, recent])
        XCTAssertEqual(inactive.points.map(\.id), [old.id, recent.id])
    }

    @MainActor func testReloadCoalescesWhileRulerDraggingAndPlayback() {
        var points = locations(2)
        var reads = 0
        let model = HistoryPlaybackModel(pointLoader: { after, completion in
            reads += 1
            completion(points.filter { $0.id > after })
        }, payloadLoader: { _, completion in completion([:]) })
        model.setConsumerActive(true)
        model.beginRulerInteraction()
        points.append(RecordedLocation(id: 3, timestamp: Date(), latitude: 45.01, longitude: -122))
        model.reload()
        XCTAssertEqual(reads, 1)
        model.endRulerInteraction()
        XCTAssertEqual(reads, 2)

        model.select(0)
        model.togglePlayback()
        points.append(RecordedLocation(id: 4, timestamp: Date(), latitude: 45.02, longitude: -122))
        model.reload()
        XCTAssertEqual(reads, 2)
        model.pause()
        XCTAssertEqual(reads, 3)
        XCTAssertEqual(Set(model.points.map(\.id)).count, model.points.count)
    }

    @MainActor func testSevenDayRouteRetainsEveryPointAndReusesGeometryDuringInteraction() {
        let count = 120_960
        let now = Date()
        let start = now.addingTimeInterval(-Double(count - 1) * 5)
        var samples = (0..<count).map { index in
            RecordedLocation(id: Int64(index + 1), timestamp: start.addingTimeInterval(Double(index) * 5),
                             latitude: 45 + Double(index) * 0.0000001, longitude: -122)
        }
        var reads = 0
        let model = HistoryPlaybackModel(pointLoader: { after, completion in
            reads += 1
            completion(samples.filter { $0.id > after })
        }, payloadLoader: { _, completion in completion([:]) }, retentionDuration: { 7 * 24 * 3600 })
        model.setConsumerActive(true)
        model.scrub(pointAt: count / 2)
        let route = model.routeGeometry!
        XCTAssertEqual(route.coordinates.count, count)
        XCTAssertEqual(route.coordinates.first?.latitude, samples.first?.latitude)
        XCTAssertEqual(route.coordinates.last?.latitude, samples.last?.latitude)
        model.beginRulerInteraction()
        samples.append(RecordedLocation(id: Int64(count + 1), timestamp: Date(), latitude: 45.02, longitude: -122))
        for position in 1...60 {
            model.reload()
            model.scrub(rulerPosition: Double(position * 100), liveEdge: now)
            XCTAssertTrue(model.routeGeometry === route)
        }
        XCTAssertEqual(reads, 1)
        model.endRulerInteraction()
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(model.points.count, count + 1)
        XCTAssertEqual(model.routeGeometry?.coordinates.count, count + 1)
    }

    @MainActor func testReplayStopsAndCannotRestartWhileConsumerIsInactive() {
        let (model, _) = replay(at: [0, 60, 120])
        model.togglePlayback()
        model.advancePlayback(by: 0.1)
        let time = model.playbackTime
        model.setConsumerActive(false)
        model.togglePlayback()
        model.advancePlayback(by: 10)
        XCTAssertFalse(model.isPlaying)
        XCTAssertEqual(model.playbackTime, time)
    }

    @MainActor private func replay(at intervals: [TimeInterval]) -> (HistoryPlaybackModel, [RecordedLocation]) {
        let start = Date().addingTimeInterval(-12 * 60 * 60)
        let points = intervals.enumerated().map { index, interval in
            RecordedLocation(id: Int64(index + 1), timestamp: start.addingTimeInterval(interval),
                             latitude: 45 + Double(index) * Self.replaySpacing, longitude: -122)
        }
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) },
                                         payloadLoader: { ids, completion in completion(self.payloads(ids)) })
        model.setConsumerActive(true)
        return (model, points)
    }

    private static let replaySpacing = 0.01

    private func pace(_ interval: TimeInterval) -> TimeInterval {
        let start = Date(timeIntervalSince1970: 0)
        let a = RecordedLocation(id: 1, timestamp: start, latitude: 45, longitude: -122)
        let b = RecordedLocation(id: 2, timestamp: start, latitude: 45 + Self.replaySpacing, longitude: -122)
        return ReplayPacing.baseDuration(recordedInterval: interval, distance: ReplayTimeline.distance(a, b))
    }

    private func home(hours: Double, every interval: TimeInterval) -> [RecordedLocation] {
        let count = Int(hours * 3_600 / interval)
        let start = Date().addingTimeInterval(-hours * 3_600 - 60)
        return (0...count).map { index in
            RecordedLocation(id: Int64(index + 1), timestamp: start.addingTimeInterval(Double(index) * interval),
                             latitude: 45 + sin(Double(index) * 1.7) * 0.00005,
                             longitude: -122 + cos(Double(index) * 2.3) * 0.00005)
        }
    }

    private func route(startID: Int64, start: Date, fromLatitude latitude: Double, speed: Double,
                       every interval: TimeInterval, count: Int) -> [RecordedLocation] {
        (0..<count).map { index in
            RecordedLocation(id: startID + Int64(index), timestamp: start.addingTimeInterval(Double(index) * interval),
                             latitude: latitude + Double(index) * interval * speed / 111_195, longitude: -122)
        }
    }

    private func locations(_ count: Int) -> [RecordedLocation] {
        let start = Date().addingTimeInterval(-1_000)
        return (0..<count).map {
            RecordedLocation(id: Int64($0 + 1), timestamp: start.addingTimeInterval(Double($0)),
                             latitude: 45 + Double($0) * 0.0001, longitude: -122)
        }
    }

    @MainActor func testReplayAccuracyInterpolatesRecordedValuesAndClearsOnLive() {
        let points = locations(3)
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) },
                                         payloadLoader: { ids, completion in
            completion(Dictionary(uniqueKeysWithValues: ids.map { id in
                (id, RecordedPayload(format: "GeoJSON", speed: nil, accuracy: Double(id) * 10,
                                     altitude: nil, device: nil, battery: nil, rawJSON: Data()))
            }))
        })
        model.setConsumerActive(true)
        model.beginRulerInteraction()
        model.scrub(rulerPosition: Double(points.count) - 0.5, liveEdge: Date())
        model.endRulerInteraction()
        XCTAssertEqual(model.playbackAccuracy!, 15, accuracy: 0.000001)
        model.select(1)
        XCTAssertEqual(model.playbackAccuracy!, 20, accuracy: 0.000001)
        model.returnToLive()
        XCTAssertNil(model.playbackAccuracy)
    }

    @MainActor func testReplayDoesNotInventAccuracyForMissingOrInvalidRecords() {
        let points = locations(3)
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) },
                                         payloadLoader: { ids, completion in
            completion(Dictionary(uniqueKeysWithValues: ids.map { id in
                (id, RecordedPayload(format: "GeoJSON", speed: nil, accuracy: id == 1 ? nil : -1,
                                     altitude: nil, device: nil, battery: nil, rawJSON: Data()))
            }))
        })
        model.setConsumerActive(true)
        for index in 0..<3 {
            model.select(index)
            XCTAssertNil(model.playbackAccuracy)
        }
    }

    private func payloads(_ ids: [Int64]) -> [Int64: RecordedPayload] {
        Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, RecordedPayload(format: "GeoJSON", speed: 2, accuracy: 5, altitude: 10,
                                 device: "device-\(id)", battery: "50%", rawJSON: Data("{}".utf8)))
        })
    }
}
