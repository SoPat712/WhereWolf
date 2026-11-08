import XCTest
import MapKit
import SwiftUI
@testable import WhereWolf

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

    @MainActor func testHeldScrubbingUsesCachedPayloadsAndLoadsOnceOnRelease() {
        let points = locations(400)
        var requests = [[Int64]]()
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) },
                                         payloadLoader: { ids, completion in
            requests.append(ids)
            completion(self.payloads(ids))
        })
        model.setConsumerActive(true)
        XCTAssertEqual(requests.count, 1)
        model.beginRulerInteraction()
        model.setRulerHold(ReplayRulerHold(pointsPerBar: 20, visibleBars: 20))
        model.scrub(rulerPosition: 1, liveEdge: Date())
        XCTAssertEqual(model.payload?.device, "device-400")
        for position in [300.0, 350, 200] {
            model.scrub(rulerPosition: position, liveEdge: Date())
            XCTAssertNil(model.payload)
            XCTAssertEqual(requests.count, 1)
        }
        model.scrub(rulerPosition: 10, liveEdge: Date())
        XCTAssertEqual(model.payload?.device, "device-391")
        model.scrub(rulerPosition: 300, liveEdge: Date())
        model.endRulerInteraction(at: 300, onLive: { XCTFail("Unexpected Live") })
        XCTAssertNil(model.rulerHold)
        XCTAssertFalse(model.rulerHoldCancelled)
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests[1].contains(101))
        XCTAssertEqual(model.payload?.device, "device-101")
    }

    @MainActor func testPayloadCompletionDuringHoldDoesNotStartAnotherRead() {
        let points = locations(400)
        var pending = [([Int64], ([Int64: RecordedPayload]) -> Void)]()
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) },
                                         payloadLoader: { pending.append(($0, $1)) })
        model.setConsumerActive(true)
        model.beginRulerInteraction()
        model.scrub(rulerPosition: 300, liveEdge: Date())
        model.setRulerHold(ReplayRulerHold(pointsPerBar: 20, visibleBars: 20))
        model.scrub(rulerPosition: 350, liveEdge: Date())
        pending[0].1(payloads(pending[0].0))
        XCTAssertNil(model.payload)
        XCTAssertEqual(pending.count, 1)
        model.endRulerInteraction(at: 350, onLive: { XCTFail("Unexpected Live") })
        XCTAssertEqual(pending.count, 2)
        XCTAssertTrue(pending[1].0.contains(51))
        pending[1].1(payloads(pending[1].0))
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

    func testRulerMenuMapsTimeTargetsInLogSpaceAndChecksTheMatchingStep() {
        let detents = HistoryRulerCoarseDrag.Detents(tickCount: 20_000, rulerWidth: 350)
        let entries = detents.menuEntries(interval: 30, current: 20)
        XCTAssertEqual(entries.map(\.title), ["Every point", "1 minute", "5 minutes", "15 minutes", "1 hour", "6 hours", "Whole history"])
        XCTAssertEqual(entries.map(\.step), [1, 2, 10, 20, 100, 1_000, 2_000])
        XCTAssertEqual(entries.filter(\.selected).map(\.title), ["15 minutes"])
        for entry in entries {
            XCTAssertEqual(detents.menuEntries(interval: 30, current: entry.step).filter(\.selected).map(\.step), [entry.step])
        }
    }

    func testRulerMenuDropsStepsAlreadyUsedByEarlierEntries() {
        let detents = HistoryRulerCoarseDrag.Detents(tickCount: 20_000, rulerWidth: 350)
        let entries = detents.menuEntries(interval: 3_600, current: 5)
        XCTAssertEqual(entries.map(\.title), ["Every point", "6 hours", "Whole history"])
        XCTAssertEqual(entries.map(\.step), [1, 5, 2_000])
        XCTAssertEqual(entries.filter(\.selected).map(\.title), ["6 hours"])
        let short = HistoryRulerCoarseDrag.Detents(tickCount: 50, rulerWidth: 350)
        XCTAssertEqual(short.menuEntries(interval: 30, current: 5).map(\.title), ["Every point", "1 minute", "5 minutes"])
        let single = HistoryRulerCoarseDrag.Detents(tickCount: 1, rulerWidth: 350)
        XCTAssertEqual(single.menuEntries(interval: 30, current: 1), [.init(title: "Every point", step: 1, selected: true)])
    }

    func testRulerScrollOffsetsKeepTheNeedleAnchoredAtEveryScaleIncludingLive() {
        let detents = HistoryRulerCoarseDrag.Detents(tickCount: 20_000, rulerWidth: 350)
        for position in [0.0, 0.25, 5_123.5, 20_000] {
            for index in detents.steps.indices {
                let scale = detents.scale(at: index)
                let offset = scale.contentOffset(at: position, tickCount: 20_000)
                XCTAssertEqual(scale.position(at: offset, tickCount: 20_000), position, accuracy: 1e-9)
                XCTAssertEqual(scale.screenOffset(of: position, at: position), 0)
                if position == 0 { XCTAssertEqual(scale.position(at: offset, tickCount: 20_000), 0) }
            }
        }
    }

    func testCoarseScrollingMovesOneBarPerBarSpacingIncludingMomentumOffsets() {
        let scale = HistoryRulerCoarseDrag.scale(step: 200, coarsest: 2_000)
        let start = 5_123.5
        let offset = scale.contentOffset(at: start, tickCount: 20_000)
        for bars in [-4.0, -1, 0.5, 1, 6] {
            let moved = scale.position(at: offset - CGFloat(bars) * scale.spacing, tickCount: 20_000)
            XCTAssertEqual(moved - start, bars * 200, accuracy: 1e-9)
        }
    }

    @MainActor func testRulerScaleChangesPreserveSelectionAndLiveWithoutStartingAHold() {
        let (model, _) = replay(at: (0..<400).map { Double($0) * 60 })
        model.beginRulerInteraction()
        model.scrub(rulerPosition: 250.25, liveEdge: Date())
        model.endRulerInteraction(at: 250.25, onLive: { XCTFail("Unexpected Live") })
        let pose = model.renderPose
        let index = model.selectedIndex
        let time = model.rulerTime
        let revision = model.rulerInteractionRevision
        for step in [20.0, 5, 1, 50] {
            model.setRulerStep(step)
            XCTAssertEqual(model.rulerStep, step)
            XCTAssertEqual(model.rulerPosition, 250.25)
            XCTAssertEqual(model.renderPose, pose)
            XCTAssertEqual(model.selectedIndex, index)
            XCTAssertEqual(model.rulerTime, time)
            XCTAssertEqual(model.rulerInteractionRevision, revision)
            XCTAssertNil(model.rulerHold)
            XCTAssertEqual(model.rulerZoom?.pointsPerBar, step > 1 ? step : nil)
        }
        model.returnToLive()
        model.setRulerStep(5)
        XCTAssertFalse(model.isBrowsing)
        XCTAssertNil(model.rulerPosition)
        XCTAssertNil(model.selectedIndex)
        XCTAssertNil(model.renderPose)
        XCTAssertNil(model.rulerHold)
    }

    @MainActor func testRulerScalePersistsAcrossTabChangesPlaybackAndCancellationUntilReturningToLive() {
        let points = locations(400)
        let model = HistoryPlaybackModel(pointLoader: { after, completion in completion(points.filter { $0.id > after }) },
            payloadLoader: { _, completion in completion([:]) })
        model.setConsumerActive(true)
        model.setRulerStep(20)
        model.setConsumerActive(false)
        model.setConsumerActive(true)
        XCTAssertEqual(model.rulerStep, 20)
        model.scrub(pointAt: 100)
        XCTAssertEqual(model.rulerStep, 20)
        model.togglePlayback()
        model.advancePlayback(by: 1)
        XCTAssertEqual(model.rulerStep, 20)
        model.pause()
        model.beginRulerInteraction()
        model.setRulerHold(ReplayRulerHold(pointsPerBar: 20, visibleBars: 20))
        model.endRulerInteraction()
        XCTAssertTrue(model.rulerHoldCancelled)
        XCTAssertEqual(model.rulerStep, 20)
        model.returnToLive()
        XCTAssertEqual(model.rulerStep, 1)
        XCTAssertNil(model.rulerZoom)
        model.setRulerStep(20)
        model.setConsumerActive(false)
        model.setConsumerActive(true)
        XCTAssertEqual(model.rulerStep, 20)
        model.beginRulerInteraction()
        model.scrub(rulerPosition: 0, liveEdge: Date())
        model.endRulerInteraction(at: 0) { model.returnToLive() }
        XCTAssertFalse(model.isBrowsing)
        XCTAssertEqual(model.rulerStep, 1)
    }

    @MainActor func testRulerScaleClampsWhenLoadingOrPruningShrinksTheLadder() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        var clock = now
        let points = (0..<400).map { index in
            RecordedLocation(id: Int64(index + 1), timestamp: now.addingTimeInterval(Double(index - 399) * 120),
                             latitude: 45, longitude: -122)
        }
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) },
            payloadLoader: { _, completion in completion([:]) }, clock: { clock })
        model.setRulerStep(5)
        model.setConsumerActive(true)
        model.setRulerStep(50)
        XCTAssertEqual(model.rulerStep, 50)
        clock = now.addingTimeInterval(86_400 - 1_200)
        model.expireOldPoints()
        XCTAssertEqual(model.points.count, 11)
        XCTAssertEqual(model.rulerStep, 1)

        let short = HistoryPlaybackModel(pointLoader: { _, completion in completion(Array(points.suffix(30))) },
            payloadLoader: { _, completion in completion([:]) }, clock: { now })
        short.setRulerStep(5)
        short.setConsumerActive(true)
        XCTAssertEqual(short.rulerDetents.steps, [2, 1])
        XCTAssertEqual(short.rulerStep, 2)
    }

    @MainActor func testPinchScaleChangesDeferPayloadReadsUntilReleaseAndPreserveTheNeedle() {
        let points = locations(400)
        var pending = [([Int64], ([Int64: RecordedPayload]) -> Void)]()
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) },
            payloadLoader: { pending.append(($0, $1)) })
        model.setConsumerActive(true)
        model.scrub(pointAt: 100)
        let pose = model.renderPose
        let index = model.selectedIndex
        model.beginRulerInteraction()
        model.setRulerHold(ReplayRulerHold(pointsPerBar: 1, visibleBars: 20))
        pending[0].1(payloads(pending[0].0))
        XCTAssertEqual(pending.count, 1, "An in-flight completion must not start a read during a pinch")
        for step in [5.0, 20, 50, 2] {
            model.setRulerHold(ReplayRulerHold(pointsPerBar: step, visibleBars: 20))
            model.setRulerStep(step)
            XCTAssertEqual(model.renderPose, pose)
            XCTAssertEqual(model.selectedIndex, index)
            XCTAssertNil(model.rulerPosition)
            XCTAssertEqual(pending.count, 1)
        }
        model.endRulerInteraction(at: 300, onLive: { XCTFail("Unexpected Live") })
        XCTAssertNil(model.rulerHold)
        XCTAssertFalse(model.rulerHoldCancelled)
        XCTAssertEqual(model.rulerStep, 2)
        XCTAssertEqual(model.rulerZoom?.pointsPerBar, 2)
        XCTAssertEqual(model.renderPose, pose)
        XCTAssertEqual(pending.count, 2)
        XCTAssertTrue(pending[1].0.contains(101))
        pending[1].1(payloads(pending[1].0))
        XCTAssertEqual(model.payload?.device, "device-101")
        XCTAssertEqual(pending.count, 2)
        model.beginRulerInteraction()
        model.scrub(rulerPosition: 200, liveEdge: Date())
        XCTAssertEqual(pending.count, 3, "Ordinary coarse dragging still reads point details")
        model.endRulerInteraction(at: 200, onLive: { XCTFail("Unexpected Live") })
        model.scrub(pointAt: 300)
        XCTAssertEqual(pending.count, 3)
        pending[2].1(payloads(pending[2].0))
        XCTAssertEqual(pending.count, 4, "A coarse scale alone must not block a follow-up read")
        model.returnToLive()
    }

    func testHeldScrubbingIgnoresVerticalMovementAndStillSnapsAtTheCurrentScale() {
        let start = Date(timeIntervalSince1970: 0)
        let points = (0..<11).map { index in
            RecordedLocation(id: Int64(index + 1), timestamp: start.addingTimeInterval(Double(index) * 60),
                             latitude: 45, longitude: -122)
        }
        let landmarks = HistoryLandmarks(points: points, timeline: ReplayTimeline(points: points), places: [])
        let scale = HistoryRulerCoarseDrag.scale(step: 2, coarsest: 5)
        var hold = HistoryRulerCoarseDrag.Hold(at: CGPoint(x: 100, y: 500))
        var snap = HistoryStopSnap()
        var position = 1.0
        for y in [CGFloat(0), 900, -500, 500] {
            let translation = hold.translation(to: CGPoint(x: 100, y: y))
            XCTAssertEqual(translation, 0)
            position = snap.move(position: position, translation: Double(translation), finger: 100,
                pointsPerBar: scale.pointsPerTick, spacing: Double(scale.spacing), pointCount: points.count, landmarks: landmarks)
            XCTAssertEqual(position, 1)
            XCTAssertEqual(snap.boundary?.index, 10)
            XCTAssertEqual(scale.pointsPerTick, 2)
        }
        let translation = hold.translation(to: CGPoint(x: 111, y: -1_000))
        XCTAssertEqual(translation, 11)
        let released = snap.move(position: position, translation: Double(translation), finger: 111,
            pointsPerBar: scale.pointsPerTick, spacing: Double(scale.spacing), pointCount: points.count, landmarks: landmarks)
        XCTAssertEqual(released, position)
        XCTAssertNil(snap.boundary)
    }

    func testRulerLadderRoundsUpToCoverTheEntireHistory() {
        let cases: [(Int, [Double])] = [
            (1, [1]), (50, [5, 2, 1]),
            (4_000, [500, 200, 100, 50, 20, 10, 5, 2, 1]),
            (20_000, [2_000, 1_000, 500, 200, 100, 50, 20, 10, 5, 2, 1])
        ]
        for (count, expected) in cases {
            let detents = HistoryRulerCoarseDrag.Detents(tickCount: count, rulerWidth: 350)
            XCTAssertEqual(detents.steps, expected)
            let coarse = detents.scale(at: 0)
            XCTAssertGreaterThanOrEqual(350 / Double(coarse.spacing) * coarse.pointsPerTick, Double(count))
            if expected.count > 1 {
                let smaller = expected[1]
                XCTAssertLessThan(350 / 18 * smaller, Double(count))
            }
            XCTAssertEqual(detents.scale(at: expected.count - 1), HistoryRulerCoarseDrag.Scale())
        }
        let empty = HistoryRulerCoarseDrag.Detents(tickCount: 48, rulerWidth: 350)
        XCTAssertEqual(empty.steps, [5, 2, 1])
        XCTAssertEqual(HistoryRulerCoarseDrag.Detents(tickCount: 20, rulerWidth: 350).steps, [1])
        for value in [1.0, 2, 5, 10, 20, 50, 100, 200, 500, 1_000] {
            XCTAssertEqual(HistoryRulerCoarseDrag.niceStep(value), value)
        }
        XCTAssertEqual(HistoryRulerCoarseDrag.niceStep(2.01), 5)
        XCTAssertEqual(HistoryRulerCoarseDrag.niceStep(201), 500)
    }

    func testRulerBarGeometryUsesLogarithmicCoarseness() {
        XCTAssertEqual(HistoryRulerCoarseDrag.coarseness(step: 1, coarsest: 2_000), 0)
        XCTAssertEqual(HistoryRulerCoarseDrag.coarseness(step: 2_000, coarsest: 2_000), 1)
        XCTAssertEqual(HistoryRulerCoarseDrag.coarseness(step: 1, coarsest: 1), 0)
        let coarseness = log(20.0) / log(2_000.0)
        XCTAssertEqual(HistoryRulerCoarseDrag.coarseness(step: 20, coarsest: 2_000), coarseness, accuracy: 1e-12)
        let scale = HistoryRulerCoarseDrag.scale(step: 20, coarsest: 2_000)
        let amount = CGFloat(coarseness)
        XCTAssertEqual(scale.spacing, 12 + 6 * amount, accuracy: 1e-9)
        XCTAssertEqual(scale.minorHeight, 12 + 8 * amount, accuracy: 1e-9)
        XCTAssertEqual(scale.majorHeight, 17 + 7 * amount, accuracy: 1e-9)
        XCTAssertEqual(scale.lineWidth, 1 + 0.6 * amount, accuracy: 1e-9)
        XCTAssertEqual(scale.bottom, 21 + 5 * amount, accuracy: 1e-9)
        let coarse = HistoryRulerCoarseDrag.scale(step: 2_000, coarsest: 2_000)
        XCTAssertEqual(coarse.spacing, 18)
        XCTAssertEqual(coarse.minorHeight, 20)
        XCTAssertEqual(coarse.majorHeight, 24)
        XCTAssertEqual(coarse.lineWidth, 1.6)
        XCTAssertEqual(coarse.bottom, 26)
    }

    func testRulerTicksFollowTheFingerOneToOneAtEveryPrecision() {
        let detents = HistoryRulerCoarseDrag.Detents(tickCount: 10_000, rulerWidth: 350)
        for index in detents.steps.indices {
            let scale = detents.scale(at: index)
            for dx in [CGFloat(-48), -6, 1, 17, 48] {
                let start = 5_000.25
                let end = HistoryRulerCoarseDrag.position(after: start, translation: dx, tickCount: 10_000, scale: scale)
                XCTAssertEqual(end - start, Double(dx / scale.spacing) * scale.pointsPerTick, accuracy: 1e-9)
                let tick = floor(start / scale.pointsPerTick) * scale.pointsPerTick
                let movement = scale.screenOffset(of: tick, at: end) - scale.screenOffset(of: tick, at: start)
                XCTAssertEqual(movement, dx, accuracy: 1e-9)
            }
        }
    }

    func testRulerScaleTweenKeepsTheNeedlePositionAndFingerMovement() {
        let ease = HistoryRulerCoarseDrag.ScaleEase(from: 1_000, to: 20, start: 10)
        for progress in [0.0, 0.25, 0.5, 1] {
            let value = ease.value(at: 10 + progress * HistoryRulerCoarseDrag.ScaleEase.duration)
            let scale = HistoryRulerCoarseDrag.scale(step: value, coarsest: 1_000)
            let position = 5_123.5
            XCTAssertEqual(scale.pointsPerTick, value)
            XCTAssertEqual(scale.screenOffset(of: position, at: position), 0)
            XCTAssertEqual(scale.spacing, 12 + 6 * log(value) / log(1_000), accuracy: 1e-9)
            let end = HistoryRulerCoarseDrag.position(after: position, translation: 7, tickCount: 10_000, scale: scale)
            XCTAssertEqual(scale.screenOffset(of: position, at: end), 7, accuracy: 1e-9)
        }
    }

    func testRulerScrubbingClampsAndCanReverseFromEitherBoundary() {
        for count in [1, 10_000] {
            let detents = HistoryRulerCoarseDrag.Detents(tickCount: count, rulerWidth: 350)
            for index in detents.steps.indices {
                let scale = detents.scale(at: index)
                let live = HistoryRulerCoarseDrag.position(after: Double(count) / 2, translation: -1_000_000,
                                                         tickCount: count, scale: scale)
                let oldest = HistoryRulerCoarseDrag.position(after: Double(count) / 2, translation: 1_000_000,
                                                           tickCount: count, scale: scale)
                XCTAssertEqual(live, 0)
                XCTAssertEqual(oldest, Double(count))
                XCTAssertGreaterThan(HistoryRulerCoarseDrag.position(after: live, translation: 1, tickCount: count, scale: scale), live)
                XCTAssertLessThan(HistoryRulerCoarseDrag.position(after: oldest, translation: -1, tickCount: count, scale: scale), oldest)
            }
        }
    }

    func testRulerBubbleScaleUsesLocalRecordedIntervalsAndHonestRounding() {
        let offsets = (0..<20).map { Double($0) * 45 } + (1...10).map { 855 + Double($0) * 3_600 }
        let timestamps = offsets.map { Date(timeIntervalSince1970: $0) }
        func label(_ step: Double, _ position: Double) -> HistoryRulerCoarseDrag.ScaleLabel {
            HistoryRulerCoarseDrag.scaleLabel(pointsPerTick: step, position: position,
                                             pointCount: timestamps.count, timestampAt: { timestamps[$0] },
                                             emptyInterval: 1_800)
        }
        XCTAssertEqual(label(20, 25).text, "1 bar ≈ 15 min")
        XCTAssertEqual(label(20, 30).text, "1 bar ≈ 15 min")
        XCTAssertEqual(label(2, 5).text, "1 bar ≈ 2 h")
        XCTAssertEqual(label(2, 0).accessibility, "1 bar about 2 hours")
        XCTAssertEqual(label(100, 25).text, "1 bar ≈ 1.3 h")
        XCTAssertEqual(label(1, 5).text, "1 bar = 1 point")
        XCTAssertEqual(label(1, 5).accessibility, "1 bar equals 1 point")
        XCTAssertEqual(label(1, 5).buttonText, "Every point")
        XCTAssertEqual(label(1, 5).buttonAccessibility, "Ruler scale, every point")
        XCTAssertEqual(label(20, 25).buttonText, "≈ 15 min per bar")
        XCTAssertEqual(label(20, 25).buttonAccessibility, "Ruler scale, about 15 minutes per bar")
        let interval = HistoryRulerCoarseDrag.estimatedInterval(position: 25, pointCount: timestamps.count,
            timestampAt: { timestamps[$0] }, emptyInterval: 1_800)
        XCTAssertEqual(interval, 45)
        let detents = HistoryRulerCoarseDrag.Detents(tickCount: 20_000, rulerWidth: 350)
        XCTAssertEqual(detents.menuEntries(interval: interval!, current: 20).first { $0.title == "15 minutes" }?.step, 20)
    }

    func testRulerBubbleScaleHandlesEmptySingleAndEqualTimestampHistories() {
        let date = Date(timeIntervalSince1970: 0)
        let empty = HistoryRulerCoarseDrag.scaleLabel(pointsPerTick: 2, position: 20, pointCount: 0,
                                                     timestampAt: { _ in XCTFail("Empty history read"); return date },
                                                     emptyInterval: 1_800)
        XCTAssertEqual(empty.text, "1 bar ≈ 1 h")
        XCTAssertEqual(empty.accessibility, "1 bar about 1 hour")
        let emptyPoint = HistoryRulerCoarseDrag.scaleLabel(pointsPerTick: 1, position: 20, pointCount: 0,
            timestampAt: { _ in XCTFail("Empty history read"); return date }, emptyInterval: 1_800)
        XCTAssertEqual(emptyPoint.text, "1 bar ≈ 30 min")
        XCTAssertEqual(emptyPoint.buttonText, "Every point")
        XCTAssertEqual(emptyPoint.buttonAccessibility, "Ruler scale, every point")
        let single = HistoryRulerCoarseDrag.scaleLabel(pointsPerTick: 1, position: 1, pointCount: 1,
                                                      timestampAt: { _ in date }, emptyInterval: 1_800)
        XCTAssertEqual(single.text, "1 bar = 1 point")
        let equal = HistoryRulerCoarseDrag.scaleLabel(pointsPerTick: 5, position: 2, pointCount: 8,
                                                     timestampAt: { _ in date }, emptyInterval: 1_800)
        XCTAssertEqual(equal.text, "1 bar = 5 points")
    }

    func testRulerBubbleTimeInterpolatesRecordedAndEmptyHistoryPositions() {
        let timestamps = [100.0, 200, 300].map { Date(timeIntervalSince1970: $0) }
        let live = Date(timeIntervalSince1970: 400)
        for (position, seconds) in [(0.0, 400.0), (0.5, 350), (1, 300), (1.5, 250), (3, 100)] {
            let time = HistoryRulerCoarseDrag.time(at: position, pointCount: timestamps.count,
                                                  timestampAt: { timestamps[$0] }, liveEdge: live, retentionInterval: 86_400)
            XCTAssertEqual(time.timeIntervalSince1970, seconds, accuracy: 1e-9)
        }
        let empty = HistoryRulerCoarseDrag.time(at: 24, pointCount: 0, timestampAt: { _ in live },
                                               liveEdge: live, retentionInterval: 86_400)
        XCTAssertEqual(empty.timeIntervalSince(live), -43_200)
    }

    @MainActor func testRulerReachingLiveKeepsInteractionAndRevisionUntilRelease() {
        let (model, _) = replay(at: [0, 60, 120])
        let live = Date()
        model.beginRulerInteraction()
        let revision = model.rulerInteractionRevision
        model.scrub(rulerPosition: 2, liveEdge: live)
        model.scrub(rulerPosition: 0, liveEdge: live)
        XCTAssertTrue(model.isRulerInteracting)
        XCTAssertTrue(model.isBrowsing)
        XCTAssertEqual(model.rulerInteractionRevision, revision)
        XCTAssertEqual(model.rulerPosition, 0)
        XCTAssertEqual(model.rulerTime, live)
        model.scrub(rulerPosition: 1.5, liveEdge: live)
        XCTAssertEqual(model.rulerPosition, 1.5)
        XCTAssertEqual(model.rulerInteractionRevision, revision)
        model.scrub(rulerPosition: 0, liveEdge: live)
        var liveCalls = 0
        model.endRulerInteraction(at: 0) {
            liveCalls += 1
            model.returnToLive()
        }
        XCTAssertEqual(liveCalls, 1)
        XCTAssertFalse(model.isRulerInteracting)
        XCTAssertFalse(model.isBrowsing)
        XCTAssertNil(model.rulerPosition)
    }

    @MainActor func testRulerReleaseAboveLiveStaysBrowsingAndCancellationDoesNotReturnToLive() {
        let (model, _) = replay(at: [0, 60, 120])
        model.beginRulerInteraction()
        let revision = model.rulerInteractionRevision
        model.scrub(rulerPosition: 1.5, liveEdge: Date())
        model.endRulerInteraction(at: 1.5) { XCTFail("Released above Live") }
        XCTAssertFalse(model.isRulerInteracting)
        XCTAssertTrue(model.isBrowsing)
        XCTAssertEqual(model.rulerPosition, 1.5)
        XCTAssertEqual(model.rulerInteractionRevision, revision)
        model.beginRulerInteraction()
        model.scrub(rulerPosition: 0, liveEdge: Date())
        model.endRulerInteraction()
        XCTAssertFalse(model.isRulerInteracting)
        XCTAssertTrue(model.isBrowsing)
        XCTAssertEqual(model.rulerInteractionRevision, revision)
    }

    @MainActor func testRulerAtLiveStillDefersIncomingPointsUntilRelease() {
        var points = locations(2)
        var reads = 0
        let model = HistoryPlaybackModel(pointLoader: { after, completion in
            reads += 1
            completion(points.filter { $0.id > after })
        }, payloadLoader: { _, completion in completion([:]) })
        model.setConsumerActive(true)
        model.beginRulerInteraction()
        let revision = model.rulerInteractionRevision
        model.scrub(rulerPosition: 0, liveEdge: Date())
        points.append(RecordedLocation(id: 3, timestamp: Date(), latitude: 45, longitude: -122))
        model.reload()
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(model.points.count, 2)
        XCTAssertTrue(model.isRulerInteracting)
        XCTAssertEqual(model.rulerInteractionRevision, revision)
        model.endRulerInteraction(at: 0) { model.returnToLive() }
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(model.points.count, 3)
        XCTAssertFalse(model.isBrowsing)
    }

    @MainActor func testEmptyRulerKeepsTheHoldAtLiveUntilRelease() {
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion([]) },
                                         payloadLoader: { _, completion in completion([:]) })
        model.setConsumerActive(true)
        model.beginRulerInteraction()
        let revision = model.rulerInteractionRevision
        let live = Date()
        model.scrub(rulerPosition: 12, liveEdge: live)
        model.scrub(rulerPosition: 0, liveEdge: live)
        XCTAssertTrue(model.isRulerInteracting)
        XCTAssertTrue(model.isBrowsing)
        XCTAssertEqual(model.rulerInteractionRevision, revision)
        XCTAssertEqual(model.rulerTime, live)
        model.endRulerInteraction(at: 0) { model.returnToLive() }
        XCTAssertFalse(model.isRulerInteracting)
        XCTAssertFalse(model.isBrowsing)
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

    func testSilenceEndingAcrossTheLotKeepsTheStayUntilTheDeparture() throws {
        let start = Date().addingTimeInterval(-20_000)
        func visit(silence: TimeInterval, departure: Double) -> (points: [RecordedLocation], departure: Int, inside: Range<Int>) {
            var points: [RecordedLocation] = []
            func fix(north: Double, east: Double = 0, after seconds: TimeInterval) {
                points.append(RecordedLocation(id: Int64(points.count + 1), timestamp: start.addingTimeInterval(seconds),
                                               latitude: 45 + north / 111_195,
                                               longitude: -122 + east / (111_195 * cos(45 * Double.pi / 180))))
            }
            // Drive in, sit in the car for a few minutes, then walk 65 m into a building.
            for step in 0..<30 { fix(north: -65 - Double(29 - step) * 15, after: Double(step)) }
            for step in 0..<22 { fix(north: -65, east: step.isMultiple(of: 2) ? 2 : -2, after: 30 + Double(step) * 10) }
            for step in 0..<5 { fix(north: -50 + Double(step) * 10, after: 250 + Double(step) * 10) }
            let first = points.count
            for step in 0..<8 { fix(north: sin(Double(step)) * 3, east: cos(Double(step) * 1.7) * 4, after: 300 + Double(step) * 30) }
            let inside = first..<points.count
            // The phone logs nothing inside, then wakes back at the car when it drives away.
            fix(north: departure, after: 510 + silence)
            let left = points.count - 1
            for step in 1...30 { fix(north: departure - Double(step) * 12, after: 510 + silence + Double(step)) }
            return (points, left, inside)
        }

        let owner = visit(silence: 3_870, departure: -64)
        let timeline = ReplayTimeline(points: owner.points)
        XCTAssertEqual(timeline.stays.count, 1)
        let stay = try XCTUnwrap(timeline.stays.first)
        XCTAssertEqual(stay.end, owner.departure)
        XCTAssertTrue(owner.inside.contains(stay.start), "the stay starts at \(stay.start), outside the building")
        XCTAssertGreaterThan(stay.span, 3_600)
        for index in owner.departure..<(owner.points.count - 1) {
            XCTAssertNil(timeline.stay(during: index), "driving fix \(index) is inside a stay")
        }

        XCTAssertTrue(ReplayTimeline(points: visit(silence: 3_870, departure: -150).points).stays.isEmpty)
        XCTAssertTrue(ReplayTimeline(points: visit(silence: 240, departure: -64).points).stays.isEmpty)

        // Arriving and going silent at once still leaves a stay of the last fix and the departure.
        var arrival = (0..<10).map { step in
            RecordedLocation(id: Int64(step + 1), timestamp: start.addingTimeInterval(Double(step)),
                             latitude: 45 - Double(9 - step) * 15 / 111_195, longitude: -122)
        }
        arrival += (0..<10).map { step in
            RecordedLocation(id: Int64(step + 11), timestamp: start.addingTimeInterval(609 + Double(step)),
                             latitude: 45 + (80 + Double(step) * 15) / 111_195, longitude: -122)
        }
        let quiet = ReplayTimeline(points: arrival).stays
        XCTAssertEqual(quiet.map(\.start), [9])
        XCTAssertEqual(quiet.map(\.end), [10])
        XCTAssertEqual(quiet.first?.span ?? 0, 600, accuracy: 0.001)
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
        XCTAssertEqual(timeline.distance(from: 0, through: points.count - 1), 3_100, accuracy: 20)
        XCTAssertEqual(timeline.distance(from: stay.count + first.count - 1, through: points.count - 1), last, accuracy: 0.001)
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

    func testArchivePointLoadsUseInferredActivityForJourneyRowsWithoutPayloadPrefetch() {
        let suite = "WhereWolf.HistoryLandmarkMotion.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let store = RecentLocationHistory(directoryURL: directory, defaults: defaults, clock: { now })
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        for index in 0..<2 {
            store.recordUpdate([
                "type": "Feature", "geometry": ["type": "Point", "coordinates": [-122.0, 45 + Double(index) * 60 / 111_195]],
                "properties": ["timestamp": ISO8601DateFormatter().string(from: now.addingTimeInterval(Double(index - 2) * 60)),
                               "motion": ["cycling"]]
            ] as NSDictionary)
        }
        let loaded = expectation(description: "point metadata")
        var points: [RecordedLocation] = []
        store.load(after: 0) { points = $0; loaded.fulfill() }
        wait(for: [loaded], timeout: 2)
        XCTAssertEqual(points.count, 2)
        let landmarks = HistoryLandmarks(points: points, timeline: ReplayTimeline(points: points), places: [])
        XCTAssertEqual(landmarks.journey.first?.rows.first?.title, "Walk")
    }

    @MainActor func testStopJumpsAndGoToUseTheSelectionPathAndKeepLandmarksCached() {
        let start = Date().addingTimeInterval(-1_200)
        var points = (0...10).map {
            RecordedLocation(id: Int64($0 + 1), timestamp: start.addingTimeInterval(Double($0) * 60),
                             latitude: 45, longitude: -122)
        }
        var landmarkTime = 0.0
        let model = HistoryPlaybackModel(pointLoader: { after, completion in
            completion(points.filter { $0.id > after })
        }, payloadLoader: { _, completion in completion([:]) }, places: { [] },
           landmarkBuilder: immediateLandmarks, landmarkClock: { landmarkTime })
        model.setConsumerActive(true)
        let landmarks = model.landmarks
        XCTAssertEqual(landmarks.boundaries.map(\.index), [0, 10])
        model.beginRulerInteraction()
        model.scrub(rulerPosition: 5.5, liveEdge: Date())
        let revision = model.rulerInteractionRevision
        model.goTo(start.addingTimeInterval(5.6 * 60))
        XCTAssertTrue(model.isBrowsing)
        XCTAssertEqual(model.selectedIndex, 6)
        XCTAssertEqual(model.renderPose?.position, 6)
        XCTAssertNil(model.rulerPosition)
        XCTAssertNil(model.playbackTime)
        XCTAssertFalse(model.isRulerInteracting)
        XCTAssertGreaterThan(model.rulerInteractionRevision, revision)
        model.jumpToStop(1)
        XCTAssertEqual(model.selectedIndex, 10)
        XCTAssertNil(model.stopBoundary(1))
        model.jumpToStop(-1)
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertNil(model.stopBoundary(-1))
        XCTAssertTrue(model.landmarks === landmarks)
        model.reload()
        XCTAssertTrue(model.landmarks === landmarks)
        points.append(RecordedLocation(id: 12, timestamp: start.addingTimeInterval(660), latitude: 45.001, longitude: -122))
        model.reload()
        XCTAssertTrue(model.landmarks === landmarks, "New points retain the cached landmarks until the coalesced build")
        landmarkTime = 30
        model.reload()
        XCTAssertFalse(model.landmarks === landmarks)
        XCTAssertEqual(model.landmarks.timestamps.count, points.count)
        model.goTo(start.addingTimeInterval(-60))
        XCTAssertEqual(model.selectedIndex, 0)
        model.goTo(Date())
        XCTAssertEqual(model.selectedIndex, points.count - 1)
    }

    @MainActor func testReturningAfterExpiryBuildsLandmarksWithTheNewPointsAndGoToRefreshes() {
        var now = Date()
        let start = now.addingTimeInterval(-1_000)
        var points = (0...4).map {
            RecordedLocation(id: Int64($0 + 1), timestamp: start.addingTimeInterval(Double($0) * 60),
                             latitude: 45, longitude: -122)
        }
        var landmarkTime = 0.0
        let model = HistoryPlaybackModel(pointLoader: { after, completion in
            completion(points.filter { $0.id > after })
        }, payloadLoader: { _, completion in completion([:]) }, retentionDuration: { 86_400 }, places: { [] },
           landmarkBuilder: immediateLandmarks, landmarkClock: { landmarkTime }, clock: { now })
        model.setConsumerActive(true)
        XCTAssertEqual(model.landmarks.timestamps.count, 5)
        model.setConsumerActive(false)
        // A day in the background: the earlier points expire while new ones arrive.
        now = now.addingTimeInterval(90_000)
        points += (5...9).map {
            RecordedLocation(id: Int64($0 + 1), timestamp: start.addingTimeInterval(90_000 + Double($0) * 60),
                             latitude: 45.01, longitude: -122)
        }
        landmarkTime = 1
        model.setConsumerActive(true)
        XCTAssertEqual(model.points.map(\.id), Array(6...10))
        XCTAssertEqual(model.landmarks.timestamps, model.points.map(\.timestamp))
        XCTAssertEqual(model.landmarks.journey.flatMap(\.rows).last?.end, 4)
        points.append(RecordedLocation(id: 11, timestamp: start.addingTimeInterval(90_600), latitude: 45.01, longitude: -122))
        model.reload()
        XCTAssertEqual(model.landmarks.timestamps.count, 5, "Appended points wait for the coalesced build.")
        model.refreshLandmarks()
        XCTAssertEqual(model.landmarks.timestamps, model.points.map(\.timestamp), "Opening Go To does not wait.")
    }

    @MainActor func testStopJumpButtonsHaveNoTargetWithoutStays() {
        let points = locations(5)
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) },
                                         payloadLoader: { _, completion in completion([:]) }, places: { [] })
        model.setConsumerActive(true)
        model.scrub(pointAt: 2)
        XCTAssertNil(model.stopBoundary(-1))
        XCTAssertNil(model.stopBoundary(1))
        model.jumpToStop(-1)
        model.jumpToStop(1)
        XCTAssertEqual(model.selectedIndex, 2)
    }

    @MainActor func testStaleLandmarkGenerationCannotReplaceANewerBuild() {
        let points = locations(5)
        var places: [WifiPlace] = []
        var builds: [(result: HistoryLandmarks, publish: (HistoryLandmarks) -> Void)] = []
        let model = HistoryPlaybackModel(pointLoader: { after, completion in
            completion(points.filter { $0.id > after })
        }, payloadLoader: { _, completion in completion([:]) }, places: { places },
           landmarkBuilder: { points, timeline, places, calendar, locale, publish in
            builds.append((HistoryLandmarks(points: points, timeline: timeline, places: places,
                                             calendar: calendar, locale: locale), publish))
        })
        model.setConsumerActive(true)
        let previous = model.landmarks
        XCTAssertEqual(builds.count, 1)
        places = [WifiPlace(id: "home", name: "Home", latitude: 45, longitude: -122)]
        model.reload()
        XCTAssertEqual(builds.count, 2, "Place changes bypass new-point coalescing")
        XCTAssertTrue(model.landmarks === previous)
        builds[1].publish(builds[1].result)
        XCTAssertTrue(model.landmarks === builds[1].result)
        builds[0].publish(builds[0].result)
        XCTAssertTrue(model.landmarks === builds[1].result)
    }

    @MainActor func testLandmarkNavigationClampsWhenPointsShrinkBeforeAPendingBuildLands() {
        let now = Date()
        let points: [RecordedLocation] = (0..<12).map { (index: Int) -> RecordedLocation in
            let offset: TimeInterval = index < 6 ? -30 * 3_600 + Double(index) * 60 : -1_200 + Double(index - 6) * 60
            let latitude: Double = index < 6 ? 45 : 45.01
            return RecordedLocation(id: Int64(index + 1), timestamp: now.addingTimeInterval(offset),
                                    latitude: latitude, longitude: -122)
        }
        var retention: TimeInterval = 48 * 3_600
        var places: [WifiPlace] = []
        var builds: [(result: HistoryLandmarks, publish: (HistoryLandmarks) -> Void)] = []
        let model = HistoryPlaybackModel(pointLoader: { after, completion in
            completion(points.filter { $0.id > after })
        }, payloadLoader: { _, completion in completion([:]) }, retentionDuration: { retention }, places: { places },
           landmarkBuilder: { points, timeline, places, calendar, locale, publish in
            builds.append((HistoryLandmarks(points: points, timeline: timeline, places: places,
                                             calendar: calendar, locale: locale), publish))
        })
        model.setConsumerActive(true)
        builds[0].publish(builds[0].result)
        let previous = model.landmarks
        places = [WifiPlace(id: "home", name: "Home", latitude: 45, longitude: -122)]
        model.reload()
        XCTAssertEqual(builds.count, 2)
        retention = 24 * 3_600
        model.retentionDidChange()
        XCTAssertEqual(model.points.count, 6)
        XCTAssertTrue(model.landmarks === previous)
        model.goTo(points.last!.timestamp)
        XCTAssertEqual(model.selectedIndex, 5)
        XCTAssertNil(model.stopBoundary(1))
        model.scrub(pointAt: previous.journey.first!.rows.first!.start)
        XCTAssertEqual(model.selectedIndex, 5)
        model.scrub(pointAt: 0)
        XCTAssertEqual(model.stopBoundary(1)?.index, 5)
        model.jumpToStop(1)
        XCTAssertEqual(model.selectedIndex, 5)
        builds[1].publish(builds[1].result)
        XCTAssertTrue(model.landmarks === previous, "The pending pre-expiry generation must be ignored")
        let latest = builds.last!
        latest.publish(latest.result)
        XCTAssertTrue(model.landmarks === latest.result)
        XCTAssertEqual(model.landmarks.timestamps, model.points.map { (point: RecordedLocation) -> Date in point.timestamp })
    }

    @MainActor private func immediateLandmarks(points: [RecordedLocation], timeline: ReplayTimeline, places: [WifiPlace],
                                              calendar: Calendar, locale: Locale,
                                              completion: @escaping (HistoryLandmarks) -> Void) {
        completion(HistoryLandmarks(points: points, timeline: timeline, places: places, calendar: calendar, locale: locale))
    }

    private func payloads(_ ids: [Int64]) -> [Int64: RecordedPayload] {
        Dictionary(uniqueKeysWithValues: ids.map { id in
            (id, RecordedPayload(format: "GeoJSON", speed: 2, accuracy: 5, altitude: 10,
                                 device: "device-\(id)", battery: "50%", rawJSON: Data("{}".utf8)))
        })
    }
}

final class HistoryRulerContinuousScaleTests: XCTestCase {
    private let detents = HistoryRulerCoarseDrag.Detents(tickCount: 20_000, rulerWidth: 350)

    func testPinchTracksFingersAndRubberBandsOnlyBeyondTheLadder() {
        for scale in [0.02, 0.25, 0.7, 1, 1.3, 4, 20] {
            XCTAssertEqual(HistoryRulerCoarseDrag.continuous(start: 20, pinchScale: scale, coarsest: 2_000),
                           20 / scale, accuracy: 1e-9)
        }
        XCTAssertEqual(HistoryRulerCoarseDrag.continuous(start: 20, pinchScale: 40, coarsest: 2_000),
                       pow(0.5, 0.35), accuracy: 1e-9)
        XCTAssertEqual(HistoryRulerCoarseDrag.continuous(start: 20, pinchScale: 0.005, coarsest: 2_000),
                       2_000 * pow(2, 0.35), accuracy: 1e-9)
        XCTAssertEqual(HistoryRulerCoarseDrag.continuous(start: 20, pinchScale: 0, coarsest: 2_000), 20)
    }

    func testContinuousDensityKeepsTheNeedleAnchoredIncludingLive() {
        for position in [0.0, 0.25, 5_123.5, 20_000] {
            for c in [0.8, 1, 1.4, 3.7, 28, 419, 2_100] {
                let scale = HistoryRulerCoarseDrag.scale(step: c, coarsest: 2_000)
                let offset = scale.contentOffset(at: position, tickCount: 20_000)
                XCTAssertEqual(scale.position(at: offset, tickCount: 20_000), position, accuracy: 1e-9)
                XCTAssertEqual(scale.screenOffset(of: position, at: position), 0)
                XCTAssertEqual(scale.screenOffset(of: position - 1, at: position), scale.spacing / c, accuracy: 1e-9)
            }
        }
    }

    func testNeighboringBarsCrossfadeAndSharedTicksDrawOnce() throws {
        for step in detents.steps {
            let bracket = detents.bracket(at: step)
            XCTAssertEqual(bracket.lower, step)
            XCTAssertEqual(bracket.upper, step)
            XCTAssertEqual(bracket.alphas.lower, 1)
            XCTAssertEqual(bracket.alphas.upper, 0)
            let bars = bracket.bars(in: 0...50)
            XCTAssertTrue(bars.allSatisfy { $0.alpha == 1 && $0.position.truncatingRemainder(dividingBy: step) == 0 })
        }
        let bracket = detents.bracket(at: sqrt(10))
        XCTAssertEqual(bracket.lower, 2)
        XCTAssertEqual(bracket.upper, 5)
        XCTAssertEqual(bracket.t, 0.5, accuracy: 1e-9)
        XCTAssertEqual(bracket.alphas.lower, 0.5, accuracy: 1e-9)
        XCTAssertEqual(bracket.alphas.upper, 0.5, accuracy: 1e-9)
        let bars = bracket.bars(in: 0...100)
        XCTAssertEqual(Set(bars.map(\.position)).count, bars.count)
        let shared = try XCTUnwrap(bars.first { $0.position == 10 })
        XCTAssertEqual(shared.alpha, 0.5, accuracy: 1e-9)
        XCTAssertEqual(shared.majorAlpha, 0.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(bars.first { $0.position == 5 }).majorAlpha, 0)
        let lowerOnly = detents.bracket(at: 2 * pow(2.5, 0.2))
        let upperOnly = detents.bracket(at: 2 * pow(2.5, 0.8))
        XCTAssertEqual(lowerOnly.alphas.upper, 0)
        XCTAssertEqual(upperOnly.alphas.lower, 0)
        let mixed = detents.bracket(at: 2 * pow(2.5, 0.65))
        let mixedShared = try XCTUnwrap(mixed.bars(in: 0...20).first { $0.position == 10 })
        XCTAssertEqual(mixedShared.alpha, mixed.alphas.upper, accuracy: 1e-9)
        XCTAssertEqual(mixedShared.majorAlpha, mixed.alphas.lower, accuracy: 1e-9)
    }

    func testSettleProjectsVelocityByAtMostOneStepAndCancellationUsesNearest() {
        for value in [0.8, 1, 1.4, 3.7, 28, 419, 2_100] {
            let nearest = detents.index(nearest: value)
            XCTAssertEqual(detents.settleTarget(at: value), nearest)
            XCTAssertEqual(detents.settleTarget(at: value, velocity: -10_000), max(0, nearest - 1))
            XCTAssertEqual(detents.settleTarget(at: value, velocity: 10_000), min(detents.steps.count - 1, nearest + 1))
        }
        XCTAssertEqual(detents.steps[detents.settleTarget(at: 3, velocity: -3, pinchScale: 0.5)], 5)
        XCTAssertEqual(detents.steps[detents.settleTarget(at: 3)], 2)
    }

    func testSettleCurveIsLogarithmicEaseOutWithoutOvershoot() {
        let ease = HistoryRulerCoarseDrag.ScaleEase(from: 2, to: 20, start: 10)
        XCTAssertEqual(ease.value(at: 9), 2)
        XCTAssertEqual(ease.value(at: 10.11), 2 * pow(10, 0.875), accuracy: 1e-8)
        XCTAssertEqual(ease.value(at: 11), 20)
        var previous = 2.0
        for frame in 0...120 {
            let value = ease.value(at: ease.start + Double(frame) / 120 * 0.22)
            XCTAssertGreaterThanOrEqual(value, previous)
            XCTAssertLessThanOrEqual(value, 20)
            previous = value
        }
    }

    @MainActor func testPinchCommitsOnceAtSettleEndAndKeepsItsAnchor() throws {
        for position in [0.0, 5_123.5] {
            let harness = RulerScaleHarness(position: position)
            defer { harness.ruler.cancelMotion() }
            harness.ruler.beginPinch()
            for scale in [1.2, 1.7, 2.3, 3.4] {
                harness.ruler.updatePinch(scale: scale)
                XCTAssertEqual(harness.ruler.displayedPointsPerBar, 20 / scale, accuracy: 1e-9)
                XCTAssertEqual(harness.ruler.anchoredPosition, position, accuracy: 1e-8)
                XCTAssertTrue(harness.commits.isEmpty)
            }
            harness.ruler.endPinch(scale: 3.4)
            let ease = try XCTUnwrap(harness.ruler.scaleEase)
            XCTAssertTrue(harness.commits.isEmpty)
            harness.ruler.advanceScale(at: ease.start + 0.11)
            XCTAssertTrue(harness.commits.isEmpty)
            harness.ruler.advanceScale(at: ease.start + 1)
            XCTAssertEqual(harness.commits, [5])
            XCTAssertEqual(harness.ruler.anchoredPosition, position, accuracy: 1e-8)
            XCTAssertNil(harness.frames.last!)
            XCTAssertEqual(harness.events.suffix(2), ["commit", "channelEnd"])
            harness.ruler.advanceScale(at: ease.start + 2)
            XCTAssertEqual(harness.commits, [5])
        }
    }

    @MainActor func testNewPinchStartsAtInFlightScaleAndScrollCommitsBeforeBeginning() throws {
        let harness = RulerScaleHarness()
        defer { harness.ruler.cancelMotion() }
        harness.ruler.beginPinch()
        harness.ruler.endPinch(scale: 3.4)
        let ease = try XCTUnwrap(harness.ruler.scaleEase)
        harness.ruler.advanceScale(at: ease.start + 0.07)
        let current = harness.ruler.displayedPointsPerBar
        let endCount = harness.events.filter { $0 == "channelEnd" }.count
        harness.ruler.beginPinch()
        XCTAssertEqual(harness.ruler.displayedPointsPerBar, current)
        XCTAssertTrue(harness.commits.isEmpty)
        XCTAssertEqual(harness.events.filter { $0 == "channelEnd" }.count, endCount)
        harness.ruler.updatePinch(scale: 1.1)
        XCTAssertEqual(harness.ruler.displayedPointsPerBar, current / 1.1, accuracy: 1e-9)
        harness.ruler.endPinch(scale: 1.1)
        let target = try XCTUnwrap(harness.ruler.scaleEase).to
        harness.events.removeAll()
        harness.ruler.scrollViewWillBeginDragging(UIScrollView())
        XCTAssertEqual(harness.commits, [target])
        XCTAssertEqual(harness.ruler.displayedPointsPerBar, target)
        XCTAssertEqual(harness.events.suffix(3), ["commit", "channelEnd", "begin"])
    }

    @MainActor func testCancelledPinchAndConfigurationCancellationCommitNearestOnce() throws {
        let harness = RulerScaleHarness()
        defer { harness.ruler.cancelMotion() }
        harness.ruler.beginPinch()
        harness.ruler.updatePinch(scale: 6)
        harness.ruler.endPinch(scale: 1, velocity: -100, cancelled: true)
        XCTAssertEqual(try XCTUnwrap(harness.ruler.scaleEase).to, 5)
        harness.configuration.active = false
        harness.ruler.configure(harness.configuration)
        XCTAssertEqual(harness.commits, [5])
        XCTAssertEqual(harness.ruler.displayedPointsPerBar, 5)
        XCTAssertNil(harness.ruler.scaleEase)
    }

    @MainActor func testMenuCommitsImmediatelyAndUsesContinuousVisualEase() throws {
        let harness = RulerScaleHarness()
        defer { harness.ruler.cancelMotion() }
        // The menu commits on the model before updating the representable.
        harness.configuration.onScale(100)
        harness.configuration.step = 100
        harness.ruler.configure(harness.configuration)
        XCTAssertEqual(harness.commits, [100])
        let ease = try XCTUnwrap(harness.ruler.scaleEase)
        XCTAssertEqual(harness.ruler.displayedPointsPerBar, 20)
        harness.ruler.advanceScale(at: ease.start + 0.11)
        XCTAssertEqual(harness.ruler.displayedPointsPerBar, ease.value(at: ease.start + 0.11))
        XCTAssertTrue(harness.frames.isEmpty)
        harness.ruler.advanceScale(at: ease.start + 1)
        XCTAssertEqual(harness.commits, [100])
        XCTAssertEqual(harness.ruler.displayedPointsPerBar, 100)
    }

    @MainActor func testReduceMotionJumpsAndCommitsAtRelease() {
        let harness = RulerScaleHarness(reduceMotion: true)
        defer { harness.ruler.cancelMotion() }
        harness.ruler.beginPinch()
        harness.ruler.updatePinch(scale: 3.4)
        XCTAssertTrue(harness.commits.isEmpty)
        harness.ruler.endPinch(scale: 3.4)
        XCTAssertEqual(harness.commits, [5])
        XCTAssertEqual(harness.ruler.displayedPointsPerBar, 5)
        XCTAssertNil(harness.ruler.scaleEase)
    }

    @MainActor func testMomentumSettlingOnThePixelBeforeACoarseLiveEdgeReturnsToLive() throws {
        let harness = RulerScaleHarness()
        defer { harness.ruler.cancelMotion() }
        var ends: [Double] = []
        harness.configuration.onEnd = { ends.append($0) }
        harness.ruler.configure(harness.configuration)
        let scrollView = try XCTUnwrap(harness.ruler.subviews.compactMap { $0 as? UIScrollView }.first)
        let pixel = 1 / max(1, harness.ruler.traitCollection.displayScale)
        let maximum = scrollView.contentSize.width - scrollView.bounds.width
        let settled = floor(maximum / pixel) * pixel
        XCTAssertGreaterThan(maximum - settled, 0.001)
        for offset in [settled, settled - pixel] {
            harness.ruler.scrollViewWillBeginDragging(scrollView)
            scrollView.contentOffset.x = offset
            harness.ruler.scrollViewDidEndDragging(scrollView, willDecelerate: true)
            harness.ruler.scrollViewDidEndDecelerating(scrollView)
        }
        XCTAssertEqual(ends.count, 2)
        XCTAssertEqual(ends.first, 0)
        XCTAssertGreaterThan(ends.last ?? 0, 0)
    }

    @MainActor func testMomentumAimedAtLiveReturnsOnArrivalWithoutWaitingForItsBounce() throws {
        let harness = RulerScaleHarness()
        defer { harness.ruler.cancelMotion() }
        var ends: [Double] = []
        harness.configuration.onEnd = { ends.append($0) }
        harness.ruler.configure(harness.configuration)
        let scrollView = try XCTUnwrap(harness.ruler.subviews.compactMap { $0 as? UIScrollView }.first)
        let pixel = 1 / max(1, harness.ruler.traitCollection.displayScale)
        let maximum = scrollView.contentSize.width - scrollView.bounds.width
        func release(at offset: CGFloat, target: CGFloat) {
            harness.ruler.scrollViewWillBeginDragging(scrollView)
            scrollView.contentOffset.x = offset
            var target = CGPoint(x: target, y: 0)
            harness.ruler.scrollViewWillEndDragging(scrollView, withVelocity: .zero, targetContentOffset: &target)
            harness.ruler.scrollViewDidEndDragging(scrollView, willDecelerate: true)
        }

        release(at: maximum - 300, target: maximum)
        scrollView.contentOffset.x = maximum - 40
        XCTAssertTrue(ends.isEmpty)
        scrollView.contentOffset.x = maximum + 6
        XCTAssertEqual(ends, [0])
        XCTAssertEqual(scrollView.contentOffset.x, maximum, accuracy: pixel)
        harness.ruler.scrollViewDidEndDecelerating(scrollView)
        XCTAssertEqual(ends, [0])

        // A flick back out of the bounce keeps browsing.
        release(at: maximum + 20, target: maximum - 300)
        scrollView.contentOffset.x = maximum + 10
        XCTAssertEqual(ends, [0])
        scrollView.contentOffset.x = maximum - 300
        harness.ruler.scrollViewDidEndDecelerating(scrollView)
        XCTAssertEqual(ends.count, 2)
        XCTAssertGreaterThan(ends.last ?? 0, 0)

        // A finger held at the edge stays in the interaction, and lifting there returns at once.
        harness.ruler.scrollViewWillBeginDragging(scrollView)
        scrollView.contentOffset.x = maximum + 12
        XCTAssertEqual(ends.count, 2)
        var target = CGPoint(x: maximum, y: 0)
        harness.ruler.scrollViewWillEndDragging(scrollView, withVelocity: .zero, targetContentOffset: &target)
        harness.ruler.scrollViewDidEndDragging(scrollView, willDecelerate: true)
        XCTAssertEqual(ends.last, 0)
        XCTAssertEqual(ends.count, 3)
    }
}

@MainActor
private final class RulerScaleHarness {
    let ruler = HistoryRulerContainer()
    let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 350, height: 56))
    var configuration: HistoryRulerSurface!
    var commits: [Double] = []
    var frames: [RulerScaleChannel.Frame?] = []
    var events: [String] = []

    init(position: Double = 5_123.5, reduceMotion: Bool = false) {
        window.addSubview(ruler)
        ruler.frame = window.bounds
        configuration = HistoryRulerSurface(position: position, tickCount: 20_000, step: 20,
            detents: .init(tickCount: 20_000, rulerWidth: 350), revision: 0, active: true,
            reduceMotion: true, value: "Recorded point", points: [],
            landmarks: HistoryLandmarks(points: [], timeline: ReplayTimeline(points: []), places: []),
            retentionInterval: 86_400, onBegin: { [weak self] in self?.events.append("begin"); return Date() },
            onMove: { _ in 0 }, onEnd: { [weak self] _ in self?.events.append("end") }, onCancel: {},
            onHold: { _ in }, onScale: { [weak self] step in
                self?.commits.append(step)
                self?.events.append("commit")
            }, onContinuousScale: { [weak self] frame in
                self?.frames.append(frame)
                if frame == nil { self?.events.append("channelEnd") }
            }, onAdjust: { _ in })
        ruler.configure(configuration)
        configuration.reduceMotion = reduceMotion
        ruler.configure(configuration)
    }
}

final class HistoryRulerZoomTests: XCTestCase {
    @MainActor func testLiveCoordinatesAreCachedAcrossFramesAndDoNotCreateAReplayRoute() {
        let points = replayPoints()
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) },
            payloadLoader: { _, completion in completion([:]) }, places: { [] },
            clock: { Date(timeIntervalSince1970: 100) })
        model.setConsumerActive(true)
        defer { model.setConsumerActive(false) }
        let geometry = model.liveRulerGeometry
        XCTAssertNil(model.routeGeometry)
        XCTAssertEqual(geometry.coordinates.count, points.count)
        XCTAssertEqual(geometry.pointIDs, points.map(\.id))
        for step in [2.0, 5, 1] {
            model.setRulerStep(step)
            XCTAssertTrue(model.liveRulerGeometry === geometry)
        }
        model.scrub(pointAt: 50)
        XCTAssertTrue(model.liveRulerGeometry === geometry)
        model.returnToLive()
        XCTAssertNil(model.routeGeometry)
        XCTAssertTrue(model.liveRulerGeometry === geometry)
    }

    @MainActor func testLiveFitEndsAtNewestPointAndIncludesTheLiveCoordinate() throws {
        var points = replayPoints()
        points[0] = RecordedLocation(id: 0, timestamp: points[0].timestamp, latitude: -20, longitude: 80)
        var (surface, coordinator, map) = nativeLive(base: 3_000, points: points)
        defer { tearDown(coordinator, map: map) }
        let zoom = ReplayRulerHold(pointsPerBar: 2, visibleBars: 20)
        let window = zoom.window(at: 100, count: points.count)
        XCTAssertEqual(window, 80..<101)
        let coordinate = map.userLocation.location!.coordinate
        let bounds = try XCTUnwrap(ReplayHoldZoom.bounds(in: surface.liveRulerGeometry!.coordinates,
            window: window, anchor: coordinate))
        XCTAssertEqual(bounds.maxY, MKMapPoint(points[80].coordinate).y, accuracy: 0.001)
        XCTAssertEqual(bounds.minY, MKMapPoint(coordinate).y, accuracy: 0.001)
        let expected = try liveDistance(zoom, surface: surface, map: map, base: 3_000)
        surface.rulerZoom = zoom
        coordinator.update(surface, animated: false)
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        XCTAssertEqual(map.camera.centerCoordinateDistance, expected, accuracy: 0.1)
        XCTAssertGreaterThan(expected, 3_000)
        XCTAssertEqual(coordinator.rulerFitPosition, 100)
        XCTAssertTrue(map.overlays.isEmpty)
        XCTAssertNil(coordinator.parent.replayRoute)
        XCTAssertTrue(coordinator.parent.position.followsUserLocation)
        assertLiveCentered(on: map)
        surface.rulerZoom = nil
        coordinator.update(surface, animated: false)
        coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
        XCTAssertEqual(map.camera.centerCoordinateDistance, 3_000, accuracy: 0.1)
        assertLiveCentered(on: map)
    }

    @MainActor func testLiveChannelZoomsEveryFrameAndFitsEachStepOnceWithHeadingOnOrOff() {
        for heading in [false, true] {
            var (surface, coordinator, map) = nativeLive()
            defer { tearDown(coordinator, map: map) }
            surface.position = .userLocation(followsHeading: heading, fallback: .automatic)
            surface.trackingEnabled = heading
            let channel = RulerScaleChannel()
            let detents = HistoryRulerCoarseDrag.Detents(tickCount: 101, rulerWidth: 402)
            surface.rulerScaleChannel = channel
            coordinator.update(surface, animated: false)
            if heading {
                coordinator.receiveDeviceHeading(71, at: 10)
                coordinator.advanceMapHeading(at: 20)
            }
            let originalHeading = map.camera.heading
            let originalPitch = map.camera.pitch
            var previous = map.camera.centerCoordinateDistance
            for frame in 0...120 {
                // A moving live fix must not invalidate the gesture's step fits.
                map.liveLocation.fix = CLLocation(latitude: 45.11 + Double(frame) * 0.000001, longitude: -122)
                channel.send(.init(pointsPerBar: exp(log(5) * Double(frame) / 120), detents: detents, width: 402))
                XCTAssertGreaterThanOrEqual(map.camera.centerCoordinateDistance, previous - 0.1)
                XCTAssertEqual(map.camera.heading, originalHeading, accuracy: 0.01)
                XCTAssertEqual(map.camera.pitch, originalPitch, accuracy: 0.01)
                XCTAssertTrue(coordinator.parent.position.followsUserLocation)
                XCTAssertNil(coordinator.parent.position.camera)
                XCTAssertNil(coordinator.rulerDistanceEase)
                assertLiveCentered(on: map)
                previous = map.camera.centerCoordinateDistance
            }
            XCTAssertGreaterThan(previous, 2_000)
            XCTAssertEqual(Set(coordinator.rulerScaleFitCounts.keys), Set(detents.steps))
            XCTAssertTrue(coordinator.rulerScaleFitCounts.values.allSatisfy { $0 == 1 })
            let counts = coordinator.rulerScaleFitCounts
            // These frames also model the ruler's projected settle, including a return to Every point.
            for step in [3.0, 2, 1.5, 1] {
                channel.send(.init(pointsPerBar: step, detents: detents, width: 402))
            }
            XCTAssertEqual(coordinator.rulerScaleFitCounts, counts)
            XCTAssertEqual(map.camera.centerCoordinateDistance, 2_000, accuracy: 0.1)
            channel.send(nil)
            coordinator.update(surface, animated: false)
            XCTAssertNil(coordinator.rulerDistanceEase)
            coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
            XCTAssertEqual(map.camera.centerCoordinateDistance, 2_000, accuracy: 0.1)
        }
    }

    @MainActor func testLiveChannelCommitKeepsItsFitWithoutAnotherEase() {
        var (surface, coordinator, map) = nativeLive()
        defer { tearDown(coordinator, map: map) }
        let channel = RulerScaleChannel()
        let detents = HistoryRulerCoarseDrag.Detents(tickCount: 101, rulerWidth: 402)
        surface.rulerScaleChannel = channel
        coordinator.update(surface, animated: false)
        channel.send(.init(pointsPerBar: 5, detents: detents, width: 402))
        let distance = map.camera.centerCoordinateDistance
        channel.send(nil)
        surface.rulerZoom = detents.zoom(step: 5, width: 402)
        coordinator.update(surface, animated: false)
        XCTAssertNil(coordinator.rulerDistanceEase)
        XCTAssertEqual(map.camera.centerCoordinateDistance, distance, accuracy: 0.1)
        XCTAssertTrue(coordinator.parent.position.followsUserLocation)
    }

    @MainActor func testLiveMenuChangeEasesDistanceInLogSpace() throws {
        var (surface, coordinator, map) = nativeLive()
        defer { tearDown(coordinator, map: map) }
        let before = map.camera.centerCoordinateDistance
        surface.rulerZoom = ReplayRulerHold(pointsPerBar: 5, visibleBars: 20)
        let expected = try liveDistance(surface.rulerZoom!, surface: surface, map: map, base: before)
        coordinator.update(surface, animated: true)
        if !UIAccessibility.isReduceMotionEnabled {
            let ease = try XCTUnwrap(coordinator.rulerDistanceEase)
            XCTAssertEqual(ease.to, expected, accuracy: 0.1)
            XCTAssertEqual(ease.progress(at: ease.start + 0.3), 1, accuracy: 1e-9)
            coordinator.advanceRulerZoom(at: ease.start + 0.15)
            XCTAssertEqual(map.camera.centerCoordinateDistance, sqrt(before * expected), accuracy: 0.1)
            assertLiveCentered(on: map)
        }
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        XCTAssertEqual(map.camera.centerCoordinateDistance, expected, accuracy: 0.1)
        XCTAssertTrue(coordinator.parent.position.followsUserLocation)
        assertLiveCentered(on: map)
    }

    @MainActor func testLiveSceneAndTabChangesRestoreAndReapplyImmediately() {
        var (surface, coordinator, map) = nativeLive(base: 3_000)
        defer { tearDown(coordinator, map: map) }
        surface.rulerZoom = ReplayRulerHold(pointsPerBar: 5, visibleBars: 20)
        coordinator.update(surface, animated: false)
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        let coarse = map.camera.centerCoordinateDistance
        let geometry = surface.liveRulerGeometry
        for exit in 0..<4 {
            if exit == 0 { surface.scenePhase = .inactive }
            if exit == 1 { surface.scenePhase = .background }
            if exit == 2 { surface.pageActive = false }
            if exit == 3 {
                surface.rulerZoomActive = false
                surface.rulerZoom = nil
                surface.liveRulerGeometry = nil
            }
            coordinator.update(surface, animated: false)
            XCTAssertNil(coordinator.rulerDistanceEase)
            XCTAssertEqual(map.camera.centerCoordinateDistance, 3_000, accuracy: 0.1)
            if exit == 3 {
                _ = coordinator.zoom(inward: false, on: map)
                coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
                XCTAssertEqual(map.camera.centerCoordinateDistance, 6_000, accuracy: 0.1)
            }
            surface.scenePhase = .active
            surface.pageActive = true
            surface.rulerZoomActive = true
            surface.rulerZoom = ReplayRulerHold(pointsPerBar: 5, visibleBars: 20)
            surface.liveRulerGeometry = geometry
            coordinator.update(surface, animated: true)
            XCTAssertNil(coordinator.rulerDistanceEase)
            XCTAssertEqual(map.camera.centerCoordinateDistance, coarse, accuracy: 0.1)
            assertLiveCentered(on: map)
        }
    }

    @MainActor func testLiveRefitsOnlyAfterNewPointsMoveHalfAWindowIncludingExpiry() {
        var (surface, coordinator, map) = nativeLive()
        defer { tearDown(coordinator, map: map) }
        surface.rulerZoom = ReplayRulerHold(pointsPerBar: 2, visibleBars: 20)
        coordinator.update(surface, animated: false)
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        for newest in 101...121 {
            let points = ((newest - 100)...newest).map { index in
                RecordedLocation(id: Int64(index), timestamp: Date(timeIntervalSince1970: Double(index)),
                    latitude: 45 + Double(index) * 0.001, longitude: -122)
            }
            surface.liveRulerGeometry = LiveRulerGeometry(points: points)
            coordinator.update(surface, animated: false)
            XCTAssertEqual(coordinator.rulerLiveFitID, newest <= 120 ? 100 : 121)
            if newest <= 120 { XCTAssertNil(coordinator.rulerDistanceEase) }
        }
    }

    @MainActor func testLiveFreedCameraIgnoresScaleAndRecenterFliesToTheFit() throws {
        var (surface, coordinator, map) = nativeLive(base: 3_000)
        defer { tearDown(coordinator, map: map) }
        surface.rulerZoom = ReplayRulerHold(pointsPerBar: 2, visibleBars: 20)
        coordinator.update(surface, animated: false)
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        let pan = RulerMapPan()
        pan.held = .began
        coordinator.gestureChanged(pan)
        surface.position = .camera(MapCamera(centerCoordinate: CLLocationCoordinate2D(latitude: 46, longitude: -121),
            distance: 9_000))
        map.setCamera(MKMapCamera(surface.position.camera!), animated: false)
        pan.held = .ended
        coordinator.update(surface, animated: false)
        let freed = MapCamera(map.camera)
        XCTAssertEqual(freed.distance, 9_000, accuracy: 0.1)
        surface.rulerZoom = ReplayRulerHold(pointsPerBar: 5, visibleBars: 20)
        coordinator.update(surface, animated: false)
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        XCTAssertEqual(MapCamera(map.camera), freed)
        XCTAssertNil(coordinator.rulerFitPosition)
        let expected = try liveDistance(surface.rulerZoom!, surface: surface, map: map, base: 3_000)
        surface.position = .userLocation(fallback: .automatic)
        surface.recenterAction += 1
        coordinator.update(surface, animated: false)
        coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
        XCTAssertEqual(map.camera.centerCoordinateDistance, expected, accuracy: 0.1)
        assertLiveCentered(on: map)
        surface.rulerZoom = nil
        coordinator.update(surface, animated: false)
        coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
        XCTAssertEqual(map.camera.centerCoordinateDistance, 3_000, accuracy: 0.1)
    }

    @MainActor func testLiveEveryPointPreservesManualZoomAndEmptyHistoryKeepsIt() throws {
        var (surface, coordinator, map) = nativeLive(base: 6_000)
        defer { tearDown(coordinator, map: map) }
        _ = try XCTUnwrap(coordinator.zoom(inward: true, on: map))
        coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
        let manual = map.camera.centerCoordinateDistance
        surface.liveRulerGeometry = LiveRulerGeometry(points: [])
        surface.rulerZoom = ReplayRulerHold(pointsPerBar: 5, visibleBars: 20)
        coordinator.update(surface, animated: false)
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        XCTAssertEqual(map.camera.centerCoordinateDistance, manual, accuracy: 0.1)
        surface.liveRulerGeometry = LiveRulerGeometry(points: replayPoints())
        coordinator.update(surface, animated: false)
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        XCTAssertGreaterThan(map.camera.centerCoordinateDistance, manual)
        _ = try XCTUnwrap(coordinator.zoom(inward: true, on: map))
        coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
        XCTAssertTrue(coordinator.parent.position.followsUserLocation)
        surface.rulerZoom = nil
        coordinator.update(surface, animated: false)
        coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
        XCTAssertEqual(map.camera.centerCoordinateDistance, manual, accuracy: 0.1)
    }

    @MainActor func testChannelMatchesEveryExactStepAndCommitDoesNotEaseAgain() {
        let detents = HistoryRulerCoarseDrag.Detents(tickCount: 101, rulerWidth: 402)
        for step in detents.steps.reversed() {
            var (plain, plainCoordinator, plainMap) = nativeReplay()
            defer { tearDown(plainCoordinator, map: plainMap) }
            plain.rulerZoom = step == 1 ? nil : detents.zoom(step: step, width: 402)
            plainCoordinator.update(plain, animated: false)
            let expected = plainCoordinator.rulerDistanceEase?.to ?? plainMap.camera.centerCoordinateDistance

            var (surface, coordinator, map) = nativeReplay()
            defer { tearDown(coordinator, map: map) }
            let channel = RulerScaleChannel()
            surface.rulerScaleChannel = channel
            coordinator.update(surface, animated: false)
            channel.send(.init(pointsPerBar: step, detents: detents, width: 402))
            XCTAssertEqual(map.camera.centerCoordinateDistance, expected, accuracy: 0.1)
            XCTAssertEqual(coordinator.parent.replayFollowDistance, 2_000)
            XCTAssertNil(coordinator.rulerDistanceEase)
            let settled = map.camera.centerCoordinateDistance
            channel.send(nil)
            surface.rulerZoom = plain.rulerZoom
            coordinator.update(surface, animated: false)
            XCTAssertNil(coordinator.rulerDistanceEase)
            coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
            XCTAssertEqual(map.camera.centerCoordinateDistance, settled, accuracy: 0.1)
        }
    }

    @MainActor func testChannelInterpolatesMonotonicallyAndFitsEachStepOnce() {
        var (surface, coordinator, map) = nativeReplay()
        defer { tearDown(coordinator, map: map) }
        let channel = RulerScaleChannel()
        let detents = HistoryRulerCoarseDrag.Detents(tickCount: 101, rulerWidth: 402)
        surface.rulerScaleChannel = channel
        coordinator.update(surface, animated: false)
        let outer = coordinator.parent.position.camera
        var previous = 2_000.0
        for frame in 0...120 {
            let c = exp(log(5) * Double(frame) / 120)
            channel.send(.init(pointsPerBar: c, detents: detents, width: 402))
            let distance = map.camera.centerCoordinateDistance
            XCTAssertGreaterThanOrEqual(distance, previous - 0.1)
            XCTAssertEqual(coordinator.parent.position.camera, outer)
            XCTAssertNil(coordinator.rulerDistanceEase)
            let point = map.convert(surface.selected!, toPointTo: map)
            let target = NativeMapSurface.visibleCenter(on: map)
            XCTAssertEqual(point.x, target.x, accuracy: 1)
            XCTAssertEqual(point.y, target.y, accuracy: 1)
            previous = distance
        }
        XCTAssertEqual(Set(coordinator.rulerScaleFitCounts.keys), Set(detents.steps))
        XCTAssertTrue(coordinator.rulerScaleFitCounts.values.allSatisfy { $0 == 1 })
        let counts = coordinator.rulerScaleFitCounts
        for c in [2.0, 3, 4, 5, 3, 1, 0.8, 6] {
            channel.send(.init(pointsPerBar: c, detents: detents, width: 402))
        }
        XCTAssertEqual(coordinator.rulerScaleFitCounts, counts)
        let coarsest = map.camera.centerCoordinateDistance
        channel.send(.init(pointsPerBar: 5, detents: detents, width: 402))
        XCTAssertEqual(map.camera.centerCoordinateDistance, coarsest, accuracy: 0.1)
        channel.send(.init(pointsPerBar: 0.8, detents: detents, width: 402))
        XCTAssertEqual(map.camera.centerCoordinateDistance, 2_000, accuracy: 0.1)
    }

    func testChannelDistanceUsesLogInterpolationWithTheSameBracketAsBars() {
        let detents = HistoryRulerCoarseDrag.Detents(tickCount: 20_000, rulerWidth: 350)
        let bracket = detents.bracket(at: sqrt(10))
        XCTAssertEqual(bracket.distance(lower: 2_000, upper: 200_000), 20_000, accuracy: 1e-7)
        XCTAssertEqual(detents.bracket(at: 2).distance(lower: 2_000, upper: 200_000), 2_000)
    }

    @MainActor func testChannelCancelsADiscreteEaseAndSettlesBackToBaseWithoutASecondMove() {
        var (surface, coordinator, map) = nativeReplay()
        defer { tearDown(coordinator, map: map) }
        let channel = RulerScaleChannel()
        let detents = HistoryRulerCoarseDrag.Detents(tickCount: 101, rulerWidth: 402)
        surface.rulerScaleChannel = channel
        surface.rulerZoom = detents.zoom(step: 2, width: 402)
        coordinator.update(surface, animated: false)
        if !UIAccessibility.isReduceMotionEnabled { XCTAssertNotNil(coordinator.rulerDistanceEase) }
        channel.send(.init(pointsPerBar: 3, detents: detents, width: 402))
        XCTAssertNil(coordinator.rulerDistanceEase)
        channel.send(.init(pointsPerBar: 1, detents: detents, width: 402))
        XCTAssertEqual(map.camera.centerCoordinateDistance, 2_000, accuracy: 0.1)
        channel.send(nil)
        surface.rulerZoom = nil
        coordinator.update(surface, animated: false)
        XCTAssertNil(coordinator.rulerDistanceEase)
        coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
        XCTAssertEqual(map.camera.centerCoordinateDistance, 2_000, accuracy: 0.1)
        XCTAssertEqual(coordinator.parent.replayFollowDistance, 2_000)
    }

    @MainActor func testDiscreteChangeCanReplaceASettleBeforeItsCommitRenders() throws {
        var (surface, coordinator, map) = nativeReplay()
        defer { tearDown(coordinator, map: map) }
        let channel = RulerScaleChannel()
        let detents = HistoryRulerCoarseDrag.Detents(tickCount: 101, rulerWidth: 402)
        surface.rulerScaleChannel = channel
        coordinator.update(surface, animated: false)
        channel.send(.init(pointsPerBar: 5, detents: detents, width: 402))
        let settled = map.camera.centerCoordinateDistance
        channel.send(nil)
        surface.rulerZoom = detents.zoom(step: 2, width: 402)
        coordinator.update(surface, animated: false)
        if !UIAccessibility.isReduceMotionEnabled {
            let ease = try XCTUnwrap(coordinator.rulerDistanceEase)
            XCTAssertEqual(ease.from, settled, accuracy: 0.1)
            XCTAssertEqual(ease.progress(at: ease.start + 0.3), 1, accuracy: 1e-9)
        }
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        XCTAssertLessThan(map.camera.centerCoordinateDistance, settled)
    }

    @MainActor func testOverviewFreedCamerasAndMapContactIgnoreChannelFrames() {
        for mode in 0..<6 {
            var (surface, coordinator, map) = nativeReplay()
            defer { tearDown(coordinator, map: map) }
            let channel = RulerScaleChannel()
            surface.rulerScaleChannel = channel
            if mode == 0 {
                surface.replayActive = false
                surface.replayRoute = nil
                surface.selected = nil
                surface.liveRulerGeometry = LiveRulerGeometry(points: replayPoints())
            }
            if mode == 1 { surface.replayOverview = true }
            if mode == 2 { surface.replayFollowing = false }
            if mode == 3 { surface.rulerZoomActive = false }
            if mode == 4 { surface.scenePhase = .inactive }
            coordinator.update(surface, animated: false)
            if mode == 5 { coordinator.mapContactChanged(true) }
            let before = MapCamera(map.camera)
            let detents = HistoryRulerCoarseDrag.Detents(tickCount: 101, rulerWidth: 402)
            for c in [1.0, 1.5, 3, 5] { channel.send(.init(pointsPerBar: c, detents: detents, width: 402)) }
            XCTAssertEqual(MapCamera(map.camera), before)
            XCTAssertTrue(coordinator.rulerScaleFitCounts.isEmpty)
            channel.send(nil)
        }
    }

    @MainActor func testMapContactDefersAChannelRestoreUntilTheFingerLifts() {
        var (surface, coordinator, map) = nativeReplay()
        defer { tearDown(coordinator, map: map) }
        let channel = RulerScaleChannel()
        let detents = HistoryRulerCoarseDrag.Detents(tickCount: 101, rulerWidth: 402)
        surface.rulerScaleChannel = channel
        coordinator.update(surface, animated: false)
        channel.send(.init(pointsPerBar: 5, detents: detents, width: 402))
        let coarse = map.camera.centerCoordinateDistance
        coordinator.mapContactChanged(true)
        channel.send(.init(pointsPerBar: 1, detents: detents, width: 402))
        channel.send(nil)
        coordinator.update(surface, animated: false)
        XCTAssertEqual(map.camera.centerCoordinateDistance, coarse, accuracy: 0.1)
        coordinator.mapContactChanged(false)
        coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
        XCTAssertEqual(map.camera.centerCoordinateDistance, 2_000, accuracy: 0.1)
    }

    func testHoldWindowAndRecomputeThreshold() {
        let hold = ReplayRulerHold(pointsPerBar: 5, visibleBars: 20)
        XCTAssertEqual(hold.halfWindow, 50)
        XCTAssertEqual(hold.window(at: 100, count: 400), 50..<151)
        XCTAssertEqual(hold.window(at: 0, count: 400), 0..<51)
        XCTAssertEqual(hold.window(at: 399, count: 400), 349..<400)
        XCTAssertEqual(hold.window(at: 100.5, count: 400), 51..<151)
        XCTAssertTrue(hold.window(at: 0, count: 0).isEmpty)
        XCTAssertTrue(hold.needsFit(at: 100, since: nil))
        XCTAssertFalse(hold.needsFit(at: 150, since: 100))
        XCTAssertFalse(hold.needsFit(at: 50, since: 100))
        XCTAssertTrue(hold.needsFit(at: 150.001, since: 100))
        XCTAssertTrue(hold.needsFit(at: 49.999, since: 100))
    }

    func testMidDetentsFitOnlyTheBarsNearTheNeedle() {
        XCTAssertEqual(ReplayRulerHold(pointsPerBar: 20, visibleBars: 24, coarseness: 1).halfWindow, 240)
        XCTAssertEqual(ReplayRulerHold(pointsPerBar: 20, visibleBars: 24, coarseness: 0).halfWindow, 40)
        XCTAssertEqual(ReplayRulerHold(pointsPerBar: 20, visibleBars: 24, coarseness: 0.5).halfWindow, 40 + 200 * 0.25,
                       accuracy: 0.0001)
        XCTAssertEqual(ReplayRulerHold(pointsPerBar: 20, visibleBars: 3, coarseness: 0).halfWindow, 30)
        let mid = ReplayRulerHold(pointsPerBar: 20, visibleBars: 24, coarseness: 0.45)
        XCTAssertLessThan(mid.halfWindow, ReplayRulerHold(pointsPerBar: 20, visibleBars: 24).halfWindow / 2)
    }

    func testPointPrecisionUsesBaseAndCoarseZoomNeverGoesBelowIt() {
        XCTAssertEqual(ReplayHoldZoom.distance(base: 2_000, pointsPerBar: 1, fitted: 80_000), 2_000)
        XCTAssertEqual(ReplayHoldZoom.distance(base: 2_000, pointsPerBar: 20, fitted: 500), 2_000)
        XCTAssertEqual(ReplayHoldZoom.distance(base: 2_000, pointsPerBar: 20, fitted: nil), 2_000)
        XCTAssertEqual(ReplayHoldZoom.distance(base: 2_000, pointsPerBar: 20, fitted: 80_000), 80_000)
        XCTAssertEqual(ReplayHoldZoom.distance(base: 2_000, pointsPerBar: 20, fitted: 1e9), MapZoom.maximumDistance)
    }

    func testWindowBoundsRetainEveryPointAndWrapTheDateline() throws {
        let anchor = MKMapPoint(CLLocationCoordinate2D(latitude: 45, longitude: 179.999))
        let points = [(-400.0, -100.0), (0, 900), (800, 300), (9_000, 20_000)].map {
            MKMapPoint(x: (anchor.x + $0.0).truncatingRemainder(dividingBy: MKMapRect.world.width),
                       y: anchor.y + $0.1).coordinate
        }
        let box = try XCTUnwrap(ReplayHoldZoom.bounds(in: points, window: 0..<3, anchor: anchor.coordinate))
        XCTAssertEqual(box.minX, anchor.x - 400, accuracy: 0.001)
        XCTAssertEqual(box.maxX, anchor.x + 800, accuracy: 0.001)
        XCTAssertEqual(box.minY, anchor.y - 100, accuracy: 0.001)
        XCTAssertEqual(box.maxY, anchor.y + 900, accuracy: 0.001)
        XCTAssertNil(ReplayHoldZoom.bounds(in: [], window: 0..<0, anchor: anchor.coordinate))
    }

    func testKnownProjectedBoxFitsAroundThePose() {
        let clear = CGRect(x: 0, y: 0, width: 200, height: 100)
        let anchor = CGPoint(x: 100, y: 50)
        let bounds = CGRect(x: 0, y: 0, width: 400, height: 200)
        let ratio = ReplayHoldZoom.requiredScale(bounds: bounds, anchor: anchor, clear: clear)
        XCTAssertEqual(ratio, 3)
        let scale = CGFloat(ratio)
        let fitted = CGRect(x: anchor.x + (bounds.minX - anchor.x) / scale,
                            y: anchor.y + (bounds.minY - anchor.y) / scale,
                            width: bounds.width / scale, height: bounds.height / scale)
        XCTAssertGreaterThanOrEqual(fitted.minX, clear.minX)
        XCTAssertLessThanOrEqual(fitted.maxX, clear.maxX)
        XCTAssertGreaterThanOrEqual(fitted.minY, clear.minY)
        XCTAssertLessThanOrEqual(fitted.maxY, clear.maxY)
    }

    func testLogDistanceEaseEndpointsMidpointAndRetarget() {
        let ease = ReplayHoldDistanceEase(from: 2_000, to: 200_000, start: 10)
        XCTAssertEqual(ease.distance(at: 9), 2_000)
        XCTAssertEqual(ease.distance(at: 10), 2_000)
        XCTAssertEqual(ease.distance(at: 10.15), 20_000, accuracy: 1e-6)
        XCTAssertEqual(ease.distance(at: 10.3), 200_000)
        XCTAssertEqual(ease.distance(at: 11), 200_000)
        let current = ease.distance(at: 10.1)
        let retarget = ReplayHoldDistanceEase(from: current, to: 5_000, start: 10.1)
        XCTAssertEqual(retarget.distance(at: 10.1), current)
        XCTAssertEqual(retarget.distance(at: 10.4), 5_000)
    }

    @MainActor func testScaleZoomUsesTheRulerGeometryAndSurvivesGestureReleaseAndCancellation() throws {
        let points = replayPoints()
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) },
            payloadLoader: { _, completion in completion([:]) }, places: { [] },
            clock: { Date(timeIntervalSince1970: 100) })
        model.setConsumerActive(true)
        model.scrub(pointAt: 50)
        model.setRulerStep(5)
        model.setRulerWidth(402)
        let detents = model.rulerDetents
        let scale = detents.scale(at: detents.index(nearest: 5))
        let zoom = try XCTUnwrap(model.rulerZoom)
        XCTAssertEqual(zoom.pointsPerBar, 5)
        XCTAssertEqual(zoom.visibleBars, Double(402 / scale.spacing))
        XCTAssertEqual(zoom.coarseness, HistoryRulerCoarseDrag.coarseness(step: 5, coarsest: detents.steps[0]))
        var (surface, coordinator, map) = nativeReplay()
        defer { tearDown(coordinator, map: map); model.returnToLive() }
        for cancelled in [false, true] {
            model.beginRulerInteraction()
            model.setRulerHold(zoom)
            surface.rulerZoom = model.rulerZoom
            coordinator.update(surface, animated: false)
            coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
            let coarse = map.camera.centerCoordinateDistance
            XCTAssertGreaterThan(coarse, 2_000)
            if cancelled { model.endRulerInteraction() }
            else { model.endRulerInteraction(at: 51, onLive: { XCTFail("Unexpected Live") }) }
            XCTAssertNil(model.rulerHold)
            XCTAssertEqual(model.rulerZoom, zoom)
            surface.rulerZoom = model.rulerZoom
            coordinator.update(surface, animated: false)
            coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
            XCTAssertEqual(map.camera.centerCoordinateDistance, coarse, accuracy: 0.1)
            XCTAssertEqual(coordinator.parent.replayFollowDistance, 2_000)
        }
        model.setRulerWidth(300)
        XCTAssertNotEqual(model.rulerZoom?.visibleBars, zoom.visibleBars)
        model.setRulerStep(1)
        XCTAssertNil(model.rulerZoom)
    }

    @MainActor func testNativeScaleFollowsPoseAndEasesBackToBaseAtEveryPoint() {
        var (surface, coordinator, map) = nativeReplay()
        defer { tearDown(coordinator, map: map) }
        let outerCamera = surface.position.camera
        surface.rulerZoom = ReplayRulerHold(pointsPerBar: 5, visibleBars: 20)
        coordinator.update(surface, animated: false)
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        let coarse = map.camera.centerCoordinateDistance
        XCTAssertGreaterThan(coarse, 2_000)
        XCTAssertEqual(coordinator.parent.replayFollowDistance, 2_000)
        surface.replayPosition = 51
        surface.selected = surface.replayRoute!.coordinates[51]
        coordinator.update(surface, animated: false)
        XCTAssertEqual(map.camera.centerCoordinateDistance, coarse, accuracy: 0.1)
        XCTAssertEqual(coordinator.parent.position.camera, outerCamera)
        let point = map.convert(surface.selected!, toPointTo: map)
        let target = NativeMapSurface.visibleCenter(on: map)
        XCTAssertEqual(point.x, target.x, accuracy: 1)
        XCTAssertEqual(point.y, target.y, accuracy: 1)
        surface.rulerZoom = nil
        coordinator.update(surface, animated: false)
        if !UIAccessibility.isReduceMotionEnabled {
            XCTAssertEqual(map.camera.centerCoordinateDistance, coarse, accuracy: 0.1)
        }
        coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
        XCTAssertEqual(map.camera.centerCoordinateDistance, 2_000, accuracy: 0.1)
        XCTAssertEqual(coordinator.parent.replayFollowDistance, 2_000)
    }

    @MainActor func testPlaybackAndMomentumRefitOnlyAfterHalfAWindow() throws {
        let points = replayPoints()
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) },
            payloadLoader: { _, completion in completion([:]) }, places: { [] },
            clock: { Date(timeIntervalSince1970: 100) })
        model.setConsumerActive(true)
        model.scrub(pointAt: 25)
        model.setRulerStep(2)
        var (surface, coordinator, map) = nativeReplay()
        defer { tearDown(coordinator, map: map); model.returnToLive() }
        surface.rulerZoom = model.rulerZoom
        let zoom = try XCTUnwrap(model.rulerZoom)
        surface.replayPosition = model.playbackIndex
        surface.selected = model.renderPose!.coordinate.coordinate
        coordinator.update(surface, animated: false)
        var fittedAt = try XCTUnwrap(coordinator.rulerFitPosition)
        var refits = 0
        model.togglePlayback()
        for _ in 0..<120 where model.isPlaying {
            model.advancePlayback(by: 0.1)
            surface.replayPosition = model.playbackIndex
            surface.selected = model.renderPose!.coordinate.coordinate
            coordinator.update(surface, animated: false)
            if abs(surface.replayPosition - fittedAt) > zoom.halfWindow {
                fittedAt = surface.replayPosition
                refits += 1
            }
            XCTAssertEqual(coordinator.rulerFitPosition, fittedAt)
            coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        }
        XCTAssertGreaterThan(refits, 0)
        model.pause()
        model.beginRulerInteraction()
        // Scroll-view deceleration publishes ruler positions through the same path as a drag.
        for index in [50.0, 51, 52, 70, 70.25, 71, 90] {
            model.scrub(rulerPosition: Double(points.count) - index, liveEdge: Date())
            surface.replayPosition = model.playbackIndex
            surface.selected = model.renderPose!.coordinate.coordinate
            coordinator.update(surface, animated: false)
            if abs(index - fittedAt) > zoom.halfWindow { fittedAt = index }
            XCTAssertEqual(coordinator.rulerFitPosition, fittedAt)
            let easeStart = coordinator.rulerDistanceEase?.start
            for _ in 0..<3 {
                coordinator.update(surface, animated: false)
                XCTAssertEqual(coordinator.rulerFitPosition, fittedAt)
                XCTAssertEqual(coordinator.rulerDistanceEase?.start, easeStart)
            }
            coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        }
        model.endRulerInteraction(at: 11, onLive: { XCTFail("Unexpected Live") })
        XCTAssertEqual(coordinator.parent.replayFollowDistance, 2_000)
    }

    @MainActor func testMenuScaleChangeEasesDistanceWithoutStartingAGesture() throws {
        let points = replayPoints()
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) },
            payloadLoader: { _, completion in completion([:]) }, places: { [] },
            clock: { Date(timeIntervalSince1970: 100) })
        model.setConsumerActive(true)
        model.scrub(pointAt: 50)
        var (surface, coordinator, map) = nativeReplay()
        defer { tearDown(coordinator, map: map); model.returnToLive() }
        let entry = try XCTUnwrap(model.rulerScaleMenu(at: 51).last)
        model.setRulerStep(entry.step)
        XCTAssertNil(model.rulerHold)
        XCTAssertFalse(model.isRulerInteracting)
        surface.rulerZoom = model.rulerZoom
        let before = map.camera.centerCoordinateDistance
        coordinator.update(surface, animated: true)
        if UIAccessibility.isReduceMotionEnabled {
            XCTAssertNil(coordinator.rulerDistanceEase)
            XCTAssertGreaterThan(map.camera.centerCoordinateDistance, before)
            return
        }
        let ease = try XCTUnwrap(coordinator.rulerDistanceEase)
        XCTAssertGreaterThan(ease.to, before)
        coordinator.advanceRulerZoom(at: ease.start + 0.15)
        XCTAssertEqual(map.camera.centerCoordinateDistance, sqrt(before * ease.to), accuracy: 0.1)
        coordinator.advanceRulerZoom(at: ease.start + 1)
        XCTAssertEqual(map.camera.centerCoordinateDistance, ease.to, accuracy: 0.1)
        coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
        XCTAssertEqual(map.camera.centerCoordinateDistance, ease.to, accuracy: 0.1)
        XCTAssertEqual(coordinator.parent.replayFollowDistance, 2_000)
        XCTAssertEqual(coordinator.parent.position.camera, surface.position.camera)
        XCTAssertNil(coordinator.rulerDistanceEase)
    }

    @MainActor func testInactiveSceneAndTrackerTabRestoreAndReapplyWithoutAnimation() {
        var (surface, coordinator, map) = nativeReplay()
        defer { tearDown(coordinator, map: map) }
        surface.rulerZoom = ReplayRulerHold(pointsPerBar: 5, visibleBars: 20)
        coordinator.update(surface, animated: false)
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        let route = surface.replayRoute
        let selected = surface.selected
        for exit in 0..<3 {
            let coarse = map.camera.centerCoordinateDistance
            XCTAssertGreaterThan(coarse, 2_000)
            if exit == 0 { surface.scenePhase = .inactive }
            else { surface.rulerZoomActive = false }
            if exit == 2 {
                surface.rulerZoom = nil
                surface.replayActive = false
                surface.replayRoute = nil
                surface.selected = nil
                surface.position = .userLocation(fallback: .automatic)
            }
            coordinator.update(surface, animated: false)
            XCTAssertEqual(map.camera.centerCoordinateDistance, 2_000, accuracy: 0.1)
            coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
            XCTAssertEqual(map.camera.centerCoordinateDistance, 2_000, accuracy: 0.1)
            surface.scenePhase = .active
            surface.rulerZoomActive = true
            surface.rulerZoom = ReplayRulerHold(pointsPerBar: 5, visibleBars: 20)
            surface.replayActive = true
            surface.replayRoute = route
            surface.selected = selected
            coordinator.update(surface, animated: false)
            XCTAssertNil(coordinator.rulerDistanceEase)
            XCTAssertEqual(map.camera.centerCoordinateDistance, coarse, accuracy: 0.1)
        }
    }

    @MainActor func testOverviewIgnoresScaleAndReturningToFollowUsesBase() {
        var (surface, coordinator, map) = nativeReplay()
        defer { tearDown(coordinator, map: map) }
        surface.replayOverview = true
        coordinator.update(surface, animated: false)
        let overview = MapCamera(map.camera)
        for step in [2.0, 5, 20] {
            surface.rulerZoom = ReplayRulerHold(pointsPerBar: step, visibleBars: 20)
            coordinator.update(surface, animated: false)
            coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
            XCTAssertEqual(MapCamera(map.camera), overview)
            XCTAssertNil(coordinator.rulerFitPosition)
            XCTAssertTrue(coordinator.parent.replayOverview)
        }
        surface.replayOverview = false
        surface.replayCameraAction += 1
        coordinator.update(surface, animated: true)
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        let coarse = map.camera.centerCoordinateDistance
        coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
        XCTAssertEqual(map.camera.centerCoordinateDistance, coarse, accuracy: 0.1)
        XCTAssertEqual(coordinator.parent.replayFollowDistance, 2_000)
        surface.rulerZoom = nil
        coordinator.update(surface, animated: false)
        coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
        XCTAssertEqual(map.camera.centerCoordinateDistance, 2_000, accuracy: 0.1)
    }

    @MainActor func testFreedCameraIgnoresScaleAndLocationButtonResumesFromBase() {
        var (surface, coordinator, map) = nativeReplay()
        defer { tearDown(coordinator, map: map) }
        surface.rulerZoom = ReplayRulerHold(pointsPerBar: 5, visibleBars: 20)
        coordinator.update(surface, animated: false)
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        surface.replayFollowing = false
        surface.position = .camera(MapCamera(centerCoordinate: surface.selected!, distance: 6_000))
        coordinator.update(surface, animated: false)
        let freed = MapCamera(map.camera)
        surface.rulerZoom = ReplayRulerHold(pointsPerBar: 20, visibleBars: 20)
        coordinator.update(surface, animated: false)
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        XCTAssertEqual(MapCamera(map.camera), freed)
        XCTAssertEqual(coordinator.parent.replayFollowDistance, 2_000)
        XCTAssertNil(coordinator.rulerFitPosition)
        surface.replayFollowing = true
        surface.replayCameraAction += 1
        coordinator.update(surface, animated: true)
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        XCTAssertGreaterThan(map.camera.centerCoordinateDistance, 6_000)
        XCTAssertEqual(coordinator.parent.replayFollowDistance, 2_000)
        surface.rulerZoom = nil
        coordinator.update(surface, animated: false)
        coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
        XCTAssertEqual(map.camera.centerCoordinateDistance, 2_000, accuracy: 0.1)
    }

    @MainActor func testLeavingScaledHistoryLandsAtTheLiveZoomAndHistoryReappliesItsOwnBase() throws {
        var (surface, coordinator, map) = nativeLive(base: 6_000)
        defer { tearDown(coordinator, map: map) }
        surface.rulerZoom = ReplayRulerHold(pointsPerBar: 5, visibleBars: 20)
        coordinator.update(surface, animated: false)
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        let liveFit = map.camera.centerCoordinateDistance
        XCTAssertGreaterThan(liveFit, 6_000)
        let route = ReplayRouteGeometry(points: replayPoints())
        surface.replayActive = true
        surface.replayRoute = route
        surface.selected = route.coordinates[50]
        surface.replayPosition = 50
        surface.replayFollowDistance = 2_000
        surface.rulerZoom = ReplayRulerHold(pointsPerBar: 5, visibleBars: 20)
        coordinator.update(surface, animated: false)
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        XCTAssertGreaterThan(map.camera.centerCoordinateDistance, 6_000)
        surface.replayActive = false
        surface.replayRoute = nil
        surface.selected = nil
        surface.position = .userLocation(fallback: .automatic)
        // Returning to Live resets the ruler to every point.
        surface.rulerZoom = nil
        coordinator.update(surface, animated: false)
        coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
        XCTAssertEqual(map.camera.centerCoordinateDistance, 6_000, accuracy: 0.1)
        XCTAssertEqual(coordinator.parent.replayFollowDistance, 2_000)
        XCTAssertNil(coordinator.rulerLiveFitID)
        assertLiveCentered(on: map)
        surface.rulerZoom = ReplayRulerHold(pointsPerBar: 5, visibleBars: 20)
        coordinator.update(surface, animated: false)
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        XCTAssertEqual(map.camera.centerCoordinateDistance, liveFit, accuracy: 0.1)
        surface.replayActive = true
        surface.replayRoute = route
        surface.selected = route.coordinates[50]
        coordinator.update(surface, animated: false)
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        surface.rulerZoom = nil
        coordinator.update(surface, animated: false)
        coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
        XCTAssertEqual(map.camera.centerCoordinateDistance, 2_000, accuracy: 0.1)
    }

    @MainActor func testLeavingScaledHistoryWithAFreedCameraLandsAtTheLiveZoom() {
        var (surface, coordinator, map) = nativeLive(base: 6_000)
        defer { tearDown(coordinator, map: map) }
        surface.rulerZoom = ReplayRulerHold(pointsPerBar: 5, visibleBars: 20)
        coordinator.update(surface, animated: false)
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        let route = ReplayRouteGeometry(points: replayPoints())
        surface.replayActive = true
        surface.replayRoute = route
        surface.selected = route.coordinates[50]
        surface.replayPosition = 50
        surface.replayFollowDistance = 2_000
        coordinator.update(surface, animated: false)
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        // A map gesture frees the replay camera and the root keeps the camera it left.
        map.setCamera(MKMapCamera(lookingAtCenter: route.coordinates[50], fromDistance: 20_000, pitch: 0, heading: 0),
                      animated: false)
        surface.replayFollowing = false
        surface.position = .camera(MapCamera(map.camera))
        coordinator.update(surface, animated: false)
        XCTAssertEqual(map.camera.centerCoordinateDistance, 20_000, accuracy: 1)
        surface.replayActive = false
        surface.replayRoute = nil
        surface.selected = nil
        surface.rulerZoom = nil
        surface.position = .userLocation(fallback: .automatic)
        // Live asks for a recenter, as the root's Live action does.
        surface.recenterAction += 1
        coordinator.update(surface, animated: false)
        coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
        XCTAssertEqual(map.camera.centerCoordinateDistance, 6_000, accuracy: 0.1)
        assertLiveCentered(on: map)
    }

    @MainActor func testLiveKeepsTheReplayZoomWhenNoScaleZoomApplied() {
        var (surface, coordinator, map) = nativeReplay()
        defer { tearDown(coordinator, map: map) }
        let route = surface.replayRoute!
        let selected = surface.selected!
        surface.replayActive = false
        surface.replayRoute = nil
        surface.selected = nil
        surface.position = .camera(MapCamera(centerCoordinate: selected, distance: 6_000))
        coordinator.update(surface, animated: false)
        surface.replayActive = true
        surface.replayRoute = route
        surface.selected = selected
        coordinator.update(surface, animated: false)
        let replayDistance = map.camera.centerCoordinateDistance
        XCTAssertGreaterThan(abs(replayDistance - 6_000), 1)
        surface.replayActive = false
        surface.replayRoute = nil
        surface.selected = nil
        surface.position = .userLocation(fallback: .automatic)
        coordinator.update(surface, animated: false)
        map.showsUserLocation = true
        coordinator.receiveLiveLocation(CLLocation(latitude: 45.2, longitude: -121.9), on: map)
        coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
        XCTAssertEqual(map.camera.centerCoordinateDistance, replayDistance, accuracy: 1)
    }

    @MainActor func testCameraControlsKeepTheBaseAndOuterCameraWhileScaleZoomApplies() throws {
        var (surface, coordinator, map) = nativeReplay()
        defer { tearDown(coordinator, map: map) }
        surface.rulerZoom = ReplayRulerHold(pointsPerBar: 5, visibleBars: 20)
        coordinator.update(surface, animated: false)
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        let outerCamera = coordinator.parent.position.camera
        _ = try XCTUnwrap(coordinator.zoom(inward: true, on: map))
        coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
        XCTAssertEqual(coordinator.parent.replayFollowDistance, 2_000)
        XCTAssertEqual(coordinator.parent.position.camera, outerCamera)
        _ = try XCTUnwrap(coordinator.faceNorth(on: map))
        coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
        XCTAssertEqual(coordinator.parent.replayFollowDistance, 2_000)
        XCTAssertEqual(coordinator.parent.position.camera, outerCamera)
        surface.rulerZoom = nil
        coordinator.update(surface, animated: false)
        coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
        XCTAssertEqual(map.camera.centerCoordinateDistance, 2_000, accuracy: 0.1)
    }

    @MainActor func testEmptyHistoryScaleDoesNotChangeTheCamera() {
        var (surface, coordinator, map) = nativeReplay()
        defer { tearDown(coordinator, map: map) }
        surface.replayRoute = nil
        surface.selected = nil
        surface.position = .camera(MapCamera(centerCoordinate: map.centerCoordinate, distance: 6_000))
        coordinator.update(surface, animated: false)
        let before = MapCamera(map.camera)
        surface.rulerZoom = ReplayRulerHold(pointsPerBar: 5, visibleBars: 20)
        coordinator.update(surface, animated: false)
        coordinator.advanceRulerZoom(at: .greatestFiniteMagnitude)
        XCTAssertEqual(MapCamera(map.camera), before)
        surface.rulerZoom = nil
        coordinator.update(surface, animated: false)
        coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
        XCTAssertEqual(MapCamera(map.camera), before)
    }

    @MainActor private func nativeLive(base: CLLocationDistance = 2_000, points: [RecordedLocation]? = nil)
        -> (NativeMapSurface, NativeMapSurface.Coordinator, RulerLiveMapView) {
        let map = RulerLiveMapView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        map.insetsLayoutMarginsFromSafeArea = false
        map.layoutMargins = .zero
        let coordinate = map.userLocation.location!.coordinate
        var surface = NativeMapSurface(position: .camera(MapCamera(centerCoordinate: coordinate, distance: base)),
            mapType: .standard, coordinates: [], replayRoute: nil, replayPosition: 0,
            liveRulerGeometry: LiveRulerGeometry(points: points ?? replayPoints()), selected: nil,
            selectedTitle: "Recorded point", scenePhase: .active, pageActive: true,
            onCameraChange: { _, _ in }, onInteraction: {})
        let coordinator = NativeMapSurface.Coordinator(surface)
        map.delegate = coordinator
        coordinator.map = map
        coordinator.update(surface, animated: false)
        surface.position = .userLocation(fallback: .automatic)
        coordinator.update(surface, animated: false)
        coordinator.advanceCameraTransition(at: .greatestFiniteMagnitude)
        XCTAssertEqual(map.camera.centerCoordinateDistance, base, accuracy: 0.1)
        XCTAssertEqual(NativeMapSurface.displayedUserCoordinate(on: map)?.latitude, coordinate.latitude)
        XCTAssertEqual(NativeMapSurface.displayedUserCoordinate(on: map)?.longitude, coordinate.longitude)
        return (surface, coordinator, map)
    }

    @MainActor private func liveDistance(_ zoom: ReplayRulerHold, surface: NativeMapSurface,
                                       map: MKMapView, base: CLLocationDistance) throws -> CLLocationDistance {
        let coordinates = try XCTUnwrap(surface.liveRulerGeometry).coordinates
        let coordinate = try XCTUnwrap(NativeMapSurface.displayedUserCoordinate(on: map))
        let bounds = try XCTUnwrap(ReplayHoldZoom.bounds(in: coordinates,
            window: zoom.window(at: Double(coordinates.count - 1), count: coordinates.count), anchor: coordinate))
        let fit = try XCTUnwrap(ReplayHoldZoom.fittedDistance(bounds: bounds, anchor: coordinate, base: base, on: map,
            clearRect: NativeMapSurface.replayClearRect(on: map), anchorPoint: NativeMapSurface.visibleCenter(on: map)))
        return ReplayHoldZoom.distance(base: base, pointsPerBar: zoom.pointsPerBar, fitted: fit)
    }

    @MainActor private func assertLiveCentered(on map: MKMapView, file: StaticString = #filePath, line: UInt = #line) {
        let coordinate = NativeMapSurface.displayedUserCoordinate(on: map)!
        let point = map.convert(coordinate, toPointTo: map)
        let target = NativeMapSurface.visibleCenter(on: map)
        XCTAssertEqual(point.x, target.x, accuracy: 1, file: file, line: line)
        XCTAssertEqual(point.y, target.y, accuracy: 1, file: file, line: line)
    }

    private func replayPoints() -> [RecordedLocation] {
        (0...100).map { index in
            RecordedLocation(id: Int64(index), timestamp: Date(timeIntervalSince1970: Double(index)),
                             latitude: 45 + Double(index) * 0.001, longitude: -122)
        }
    }

    @MainActor private func nativeReplay() -> (NativeMapSurface, NativeMapSurface.Coordinator, MKMapView) {
        let points = replayPoints()
        let selected = points[50].coordinate
        let surface = NativeMapSurface(position: .camera(MapCamera(centerCoordinate: selected, distance: 2_000)),
            mapType: .standard, coordinates: [], replayRoute: ReplayRouteGeometry(points: points),
            replayPosition: 50, replayActive: true, replayFollowing: true, replayFollowDistance: 2_000,
            selected: selected, selectedTitle: "Recorded point", scenePhase: .active, pageActive: true,
            onCameraChange: { _, _ in }, onInteraction: {})
        let coordinator = NativeMapSurface.Coordinator(surface)
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        map.insetsLayoutMarginsFromSafeArea = false
        map.layoutMargins = .zero
        map.delegate = coordinator
        coordinator.map = map
        coordinator.update(surface, animated: false)
        return (surface, coordinator, map)
    }

    @MainActor private func tearDown(_ coordinator: NativeMapSurface.Coordinator, map: MKMapView) {
        coordinator.detachRulerScaleChannel()
        coordinator.stopRulerZoom()
        coordinator.stopCameraTransition()
        coordinator.stopReplayHeading()
        coordinator.stopLiveMotion()
        coordinator.stopHeadingMode()
        map.delegate = nil
    }

    @MainActor func testMapKitFitsTheBoxWhileKeepingThePoseAtTheVisibleCenter() throws {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        map.insetsLayoutMarginsFromSafeArea = false
        map.layoutMargins = .zero
        let anchor = CLLocationCoordinate2D(latitude: 45, longitude: -122)
        let coordinates = [CLLocationCoordinate2D(latitude: 44.98, longitude: -122.03),
                           CLLocationCoordinate2D(latitude: 45.01, longitude: -121.98)]
        let bounds = try XCTUnwrap(ReplayHoldZoom.bounds(in: coordinates, window: 0..<2, anchor: anchor))
        let clear = CGRect(x: 16, y: 140, width: 312, height: 400)
        let point = CGPoint(x: 201, y: 330)
        for heading in [0.0, 71] {
            for pitch in [0.0, 45] {
                map.setCamera(MKMapCamera(lookingAtCenter: anchor, fromDistance: 2_000, pitch: pitch, heading: heading), animated: false)
                let distance = try XCTUnwrap(ReplayHoldZoom.fittedDistance(bounds: bounds, anchor: anchor,
                    base: 2_000, on: map, clearRect: clear, anchorPoint: point))
                XCTAssertGreaterThanOrEqual(distance, 2_000)
                map.setCamera(MKMapCamera(lookingAtCenter: anchor, fromDistance: distance, pitch: pitch, heading: heading), animated: false)
                for _ in 0..<6 {
                    let camera = map.camera.copy() as! MKMapCamera
                    camera.centerCoordinate = MapViewport.anchoredCenter(anchor,
                        projectionCenter: map.convert(CGPoint(x: map.bounds.midX, y: map.bounds.midY), toCoordinateFrom: map),
                        projectionTarget: map.convert(point, toCoordinateFrom: map))
                    map.setCamera(camera, animated: false)
                }
                XCTAssertEqual(remainder(map.camera.heading - heading, 360), 0, accuracy: 0.01)
                let projectedAnchor = map.convert(anchor, toPointTo: map)
                XCTAssertEqual(projectedAnchor.x, point.x, accuracy: 1)
                XCTAssertEqual(projectedAnchor.y, point.y, accuracy: 1)
                for coordinate in coordinates {
                    let projected = map.convert(coordinate, toPointTo: map)
                    XCTAssertTrue(clear.insetBy(dx: -1, dy: -1).contains(projected))
                }
            }
        }
    }
}

private final class RulerLiveLocation: MKUserLocation {
    var fix = CLLocation(latitude: 45.11, longitude: -122)
    override var location: CLLocation? { fix }
    override var coordinate: CLLocationCoordinate2D { fix.coordinate }
}

@MainActor
private final class RulerLiveMapView: MKMapView {
    let liveLocation = RulerLiveLocation()
    private var liveLocationVisible = false
    override var userLocation: MKUserLocation { liveLocation }
    // Overriding the location getter does not replace MapKit's delegate fixes.
    override var showsUserLocation: Bool {
        get { liveLocationVisible }
        set { liveLocationVisible = newValue }
    }
}

@MainActor
private final class RulerMapPan: UIPanGestureRecognizer {
    var held: UIGestureRecognizer.State = .possible
    override var state: UIGestureRecognizer.State {
        get { held }
        set { held = newValue }
    }
}
