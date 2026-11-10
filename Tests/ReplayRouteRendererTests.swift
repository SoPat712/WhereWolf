import XCTest
import MapKit
@testable import WhereWolf

@MainActor
final class ReplayRouteRendererTests: XCTestCase {
    func testUsesNativeVectorRenderersAndThinnerFutureDashes() throws {
        let route = ReplayRoutePresentation(coordinates: coordinates(count: 3_500))
        _ = route.updatePosition(1_500)
        for line in route.sections.map(\.polyline) {
            let renderer = try XCTUnwrap(route.renderer(for: line))
            XCTAssertTrue(type(of: renderer) == MKPolylineRenderer.self)
            XCTAssertFalse(renderer.shouldRasterize)
            XCTAssertEqual(renderer.lineWidth, 2.5)
            XCTAssertEqual(renderer.strokeColor, .systemBlue)
        }
        for line in route.futureSections {
            let renderer = try XCTUnwrap(route.renderer(for: line))
            XCTAssertTrue(type(of: renderer) == MKPolylineRenderer.self)
            XCTAssertFalse(renderer.shouldRasterize)
            XCTAssertEqual(renderer.lineWidth, 1.25)
            XCTAssertEqual(renderer.lineDashPattern, [1, 5])
            XCTAssertEqual(renderer.lineCap, .round)
        }
        XCTAssertNil(route.renderer(for: MKPolyline()))
    }

    func testEveryVertexSurvivesAndSectionsStayStableAcrossLargeScrubs() {
        let values = coordinates(count: 10_000)
        let route = ReplayRoutePresentation(coordinates: values)
        let lines = route.sections.map { ObjectIdentifier($0.polyline) }
        let dots = route.futureSections.map { ObjectIdentifier($0) }
        XCTAssertEqual(route.fullRoute.pointCount, values.count)
        for index in values.indices {
            let point = route.fullRoute.points()[index].coordinate
            XCTAssertEqual(point.latitude, values[index].latitude, accuracy: 0.0000001)
            XCTAssertEqual(point.longitude, values[index].longitude, accuracy: 0.0000001)
        }
        for position in [255.9, 256, 511.999, 512, 9_998.38, 1_100, 0, 9_999] {
            _ = route.updatePosition(position)
            XCTAssertEqual(route.sections.map { ObjectIdentifier($0.polyline) }, lines)
            XCTAssertEqual(route.futureSections.map { ObjectIdentifier($0) }, dots)
            let shown = Set(route.overlays.map { ObjectIdentifier($0) })
            for (index, section) in route.sections.enumerated() {
                XCTAssertEqual(shown.contains(ObjectIdentifier(section.polyline)), index < route.activeIndex)
                XCTAssertEqual(shown.contains(ObjectIdentifier(section.future)), index > route.activeIndex)
                XCTAssertEqual(section.polyline.pointCount, section.end - section.start + section.prefix + 1)
                XCTAssertLessThanOrEqual(section.end - section.start, 1_024)
                for offset in section.prefix..<section.polyline.pointCount {
                    let point = section.polyline.points()[offset]
                    let expected = route.fullRoute.points()[section.start + offset - section.prefix]
                    XCTAssertEqual(point.x, expected.x)
                    XCTAssertEqual(point.y, expected.y)
                }
            }
        }
    }

    func testAppendKeepsUntouchedOverlaysAndChangesOnlyTheTail() {
        let values = coordinates(count: 5_500), ids = (0..<5_500).map { Int64($0 + 40_000) }
        let route = ReplayRoutePresentation(coordinates: Array(values.prefix(4_700)),
            pointIDs: Array(ids.prefix(4_700)), position: 1_500, now: 10)
        let old = route.sections
        let change = route.update(coordinates: values, pointIDs: ids, position: 1_500, now: 11)
        for index in 0..<(old.count - 1) {
            XCTAssertTrue(route.sections[index].polyline === old[index].polyline)
            XCTAssertTrue(route.sections[index].future === old[index].future)
        }
        XCTAssertEqual(change.removed.count, 0)
        XCTAssertEqual(change.removedDots.count, 1)
        XCTAssertTrue(change.removedDots.first === old.last!.future)
        XCTAssertEqual(change.addedDots.count, 2)
        XCTAssertEqual(route.fullRoute.pointCount, values.count)
        assertCoverage(route, position: 1_500, now: 11)
        let untouched = route.fullRoute
        XCTAssertTrue(route.update(coordinates: values, pointIDs: ids, position: 1_501, now: 11).isEmpty)
        XCTAssertTrue(route.fullRoute === untouched, "An identical snapshot keeps the geometry too")
    }

    func testExpiryRemovesOnlyLeadingSectionsAndRebuildsTheFirstPartialSection() {
        let values = coordinates(count: 6_000), ids = (0..<6_000).map { Int64($0 + 100) }
        let route = ReplayRoutePresentation(coordinates: values, pointIDs: ids, position: 3_300, now: 10)
        let old = route.sections, trim = 1_400
        let change = route.update(coordinates: Array(values.dropFirst(trim)), pointIDs: Array(ids.dropFirst(trim)),
                                  position: 3_300 - Double(trim), now: 11)
        XCTAssertEqual(route.sections[0].start, 0)
        XCTAssertEqual(route.sections[0].end, old[1].end - trim)
        XCTAssertEqual(route.sections[0].prefix, 0)
        XCTAssertFalse(route.sections[0].polyline === old[1].polyline)
        for index in 2..<old.count {
            XCTAssertTrue(route.sections[index - 1].polyline === old[index].polyline)
            XCTAssertTrue(route.sections[index - 1].future === old[index].future)
            XCTAssertEqual(route.sections[index - 1].start, old[index].start - trim)
        }
        XCTAssertEqual(change.removed.count, 2)
        XCTAssertEqual(change.added.count, 1)
        XCTAssertTrue(change.removedDots.isEmpty)
        XCTAssertTrue(change.addedDots.isEmpty)
        assertCoverage(route, position: 1_900, now: 11)
    }

    func testAppendAndTrimTogetherKeepStoredBoundariesAndRebaseTheSplit() {
        let values = coordinates(count: 7_000), ids = (0..<7_000).map { Int64($0) }
        let route = ReplayRoutePresentation(coordinates: Array(values.prefix(6_000)),
            pointIDs: Array(ids.prefix(6_000)), position: 3_500.5, now: 10)
        let old = route.sections
        _ = route.update(coordinates: Array(values.dropFirst(1_024)), pointIDs: Array(ids.dropFirst(1_024)),
                         position: 3_500.5 - 1_024, now: 11)
        // The first retained section loses its shared tail; later boundaries keep their records.
        XCTAssertEqual(route.sections[0].start, 0)
        XCTAssertEqual(route.sections[0].prefix, 0)
        XCTAssertTrue(route.sections[0].future === old[1].future, "Dropping only a blue join tail leaves the dots unchanged")
        XCTAssertTrue(route.sections[1].polyline === old[2].polyline)
        XCTAssertTrue(route.sections[2].future === old[3].future)
        assertCoverage(route, position: 2_476.5, now: 11)
    }

    func testChangedSnapshotFallsBackToRebuilding() {
        var values = coordinates(count: 3_500)
        let ids = values.indices.map { Int64($0) }
        let route = ReplayRoutePresentation(coordinates: values, pointIDs: ids, position: 1_500)
        let previous = route.sections
        values[1_700].latitude += 0.001
        let change = route.update(coordinates: values, pointIDs: ids, position: 1_500)
        XCTAssertTrue(zip(previous, route.sections).allSatisfy { $0.0.polyline !== $0.1.polyline })
        XCTAssertEqual(change.removed.count + change.removedDots.count, previous.count - 1)
        XCTAssertEqual(change.added.count + change.addedDots.count, route.sections.count - 1)
    }

    func testOverlaysChangeOnlyAtSectionBoundaries() {
        let route = ReplayRoutePresentation(coordinates: coordinates(count: 4_500))
        let originals = route.overlays.map { ObjectIdentifier($0) }
        for position in [1.0, 63.9, 64, 128, 320, 384, 1_023.99, 300, 0] {
            XCTAssertTrue(route.updatePosition(position).isEmpty, "At \(position)")
            XCTAssertEqual(route.overlays.map { ObjectIdentifier($0) }, originals)
        }
        let forward = route.updatePosition(2_100)
        XCTAssertEqual(route.activeIndex, 2)
        XCTAssertEqual(forward.added.count, 2)
        XCTAssertEqual(forward.removedDots.count, 2)
        XCTAssertTrue(forward.added.contains { $0 === route.sections[0].polyline })
        XCTAssertTrue(forward.added.contains { $0 === route.sections[1].polyline })
        XCTAssertTrue(route.updatePosition(2_500).isEmpty)
        let back = route.updatePosition(10)
        XCTAssertEqual(back.removed.count, 2)
        XCTAssertEqual(back.addedDots.count, 2)
        XCTAssertTrue(route.overlays.allSatisfy { route.isDots($0) })
    }

    func testOverlayAndLayerCoveragePartitionTheRouteAcrossJumpsAndReloads() {
        let values = coordinates(count: 7_000), ids = values.indices.map { Int64($0) }
        let route = ReplayRoutePresentation(coordinates: Array(values.prefix(6_000)),
            pointIDs: Array(ids.prefix(6_000)), now: 10)
        var positions = Array(stride(from: 0.0, through: 200, by: 7.5))
        positions += [1_023.99, 1_024, 1_500.5, 5_999, 2_990, 1_200, 30, 4_500, 0, 5_500.75]
        for position in positions {
            _ = route.updatePosition(position, now: 10.5)
            assertCoverage(route, position: position, now: 10.5)
            route.renderingBegan()
            route.renderingFinished(fullyRendered: true)
            assertCoverage(route, position: position, now: 10.6)
        }
        _ = route.update(coordinates: Array(values.dropFirst(1_300)), pointIDs: Array(ids.dropFirst(1_300)),
                         position: 4_200.75, now: 11)
        assertCoverage(route, position: 4_200.75, now: 11)
        assertCoverage(route, position: 4_200.75, now: 14)
    }

    func testNewSectionsStayCoveredUntilTheirRenderOrTimeout() {
        let route = ReplayRoutePresentation(coordinates: coordinates(count: 5_000), now: 10)
        route.renderingBegan()
        _ = route.updatePosition(2_100, now: 10.1)
        XCTAssertEqual(route.layerCoverage(future: false, now: 10.2).filter { !$0.marker }.count, 2)
        // This render began before the two blue overlays were added.
        route.renderingFinished(fullyRendered: true)
        XCTAssertEqual(route.layerCoverage(future: false, now: 10.3).filter { !$0.marker }.count, 2)
        route.renderingBegan()
        route.renderingFinished(fullyRendered: false)
        XCTAssertEqual(route.layerCoverage(future: false, now: 10.4).filter { !$0.marker }.count, 2)
        route.renderingFinished(fullyRendered: true)
        XCTAssertEqual(route.layerCoverage(future: false, now: 10.5).count, 1, "The active section stays synchronous")
        _ = route.updatePosition(4_300, now: 11)
        XCTAssertFalse(route.layerCoverage(future: false, now: 12.99).filter { !$0.marker }.isEmpty)
        XCTAssertEqual(route.layerCoverage(future: false, now: 13.01).count, 1)
        route.coverDuringCameraChange(now: 14)
        XCTAssertFalse(route.layerCoverage(future: false, now: 14).filter { !$0.marker }.isEmpty)
        route.coverDuringCameraChange(now: 15)
        XCTAssertEqual(route.nextCoverageDeadline, 16, "Camera motion must not extend existing deadlines")
        XCTAssertEqual(route.layerCoverage(future: false, now: 16.01).count, 1)
    }

    func testForegroundLayersCoverTheEntireActiveSectionAndKeepDotsAnchored() throws {
        let values = coordinates(count: 1_025)
        let route = ReplayRoutePresentation(coordinates: values, now: 10)
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        map.region = MKCoordinateRegion(center: values[512], latitudinalMeters: 1_000, longitudinalMeters: 1_000)
        map.layoutIfNeeded()
        let marker = MKAnnotationView()
        map.addSubview(marker)
        let blue = ReplayTrailLayer(), dots = ReplayTrailLayer(future: true)
        for position in [0.0, 100.5, 500, 1_023.75, 1_024] {
            _ = route.updatePosition(position, now: 10)
            let here = interpolated(values, at: position)
            let screen = ReplayScreenProjection(map: map, container: map)
            blue.update(route: route.fullRoute, position: position, coordinate: here,
                coverage: route.layerCoverage(future: false, now: 20), projection: screen, on: map, below: marker)
            dots.update(route: route.fullRoute, position: position, coordinate: here,
                coverage: route.layerCoverage(future: true, now: 20), projection: screen, on: map, below: marker)
            if position > 0 {
                let path = try XCTUnwrap(blue.path)
                let end = map.convert(here, toPointTo: map)
                XCTAssertEqual(path.currentPoint.x, end.x, accuracy: 0.01)
                XCTAssertEqual(path.currentPoint.y, end.y, accuracy: 0.01)
                var count = 0
                path.applyWithBlock { _ in count += 1 }
                XCTAssertEqual(count, Int(position) + 2)
            }
            if position < 1_024 {
                var first: CGPoint?
                dots.path?.applyWithBlock { element in
                    if first == nil { first = element.pointee.points[0] }
                }
                let farEnd = map.convert(values[1_024], toPointTo: map)
                XCTAssertEqual(try XCTUnwrap(first).x, farEnd.x, accuracy: 0.5)
                XCTAssertEqual(try XCTUnwrap(first).y, farEnd.y, accuracy: 0.5)
            } else {
                XCTAssertTrue(dots.path?.isEmpty ?? true)
            }
            XCTAssertEqual(dots.lineDashPattern, [1, 5])
            XCTAssertEqual(dots.lineCap, .round)
            XCTAssertEqual(blue.animationKeys() ?? [], [])
        }
        blue.hide()
        XCTAssertNil(blue.superlayer)
        XCTAssertNil(blue.path)
    }

    func testAnOpenedTripDrawsItsWholeSpanInRedOverTheBlue() throws {
        let values = coordinates(count: 400)
        let route = ReplayRoutePresentation(coordinates: values, now: 10)
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        map.region = MKCoordinateRegion(center: values[200], latitudinalMeters: 1_000, longitudinalMeters: 1_000)
        map.layoutIfNeeded()
        let marker = MKAnnotationView()
        map.addSubview(marker)
        let red = ReplayTrailLayer(highlight: true)
        let rect = route.fullRoute.boundingMapRect
        let span = ReplayRoutePresentation.Coverage(start: 120, end: 260, prefix: false, marker: false,
            bounds: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
        let screen = ReplayScreenProjection(map: map, container: map)
        red.update(route: route.fullRoute, position: 300, coordinate: values[300], coverage: [span],
                   projection: screen, on: map, below: marker)
        let path = try XCTUnwrap(red.path)
        var count = 0
        path.applyWithBlock { _ in count += 1 }
        XCTAssertEqual(count, 141, "Every fix of the trip, and none past it toward the marker")
        let end = map.convert(values[260], toPointTo: map)
        XCTAssertEqual(path.currentPoint.x, end.x, accuracy: 0.5)
        XCTAssertEqual(path.currentPoint.y, end.y, accuracy: 0.5)
        XCTAssertEqual(red.lineWidth, ReplayRouteStyle.highlightWidth)
        XCTAssertEqual(red.strokeColor, UIColor.systemRed.resolvedColor(with: map.traitCollection).cgColor)
        XCTAssertNil(red.lineDashPattern)

        // The trip stays hidden while the camera flies there, then draws from its start to its end.
        red.conceal()
        XCTAssertEqual(red.strokeEnd, 0)
        XCTAssertNil(red.animation(forKey: "reveal"))
        red.reveal(animated: true)
        XCTAssertEqual(red.strokeEnd, 1)
        let reveal = try XCTUnwrap(red.animation(forKey: "reveal") as? CABasicAnimation)
        XCTAssertEqual(reveal.keyPath, "strokeEnd")
        XCTAssertEqual(reveal.fromValue as? Double, 0)
        red.reveal(animated: false)
        XCTAssertNil(red.animation(forKey: "reveal"))
        XCTAssertEqual(red.strokeEnd, 1)
    }

    func testAnOpenedTripMovesToRedOverlaysAboveTheBlueOnceRendered() throws {
        let route = ReplayRoutePresentation(coordinates: coordinates(count: 5_000), now: 10)
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        map.addOverlays(route.overlays, level: .aboveRoads)
        XCTAssertFalse(route.highlightRendered(now: 10))
        let change = route.highlight(1_000...3_500, now: 10)
        XCTAssertTrue(change.removed.isEmpty)
        change.apply(to: map)
        let reds = route.highlightOverlays.compactMap { $0 as? MKPolyline }
        XCTAssertGreaterThan(reds.count, 1)
        var next = 1_000
        for line in reds {
            XCTAssertLessThanOrEqual(line.pointCount - 1, ReplayRoutePresentation.maximumSegments)
            let first = line.points()[0], expected = route.fullRoute.points()[next]
            XCTAssertEqual(first.x, expected.x)
            XCTAssertEqual(first.y, expected.y)
            next += line.pointCount - 1
        }
        XCTAssertEqual(next, 3_500, "Sections join end to start and stop at the trip's last fix")
        let renderer = try XCTUnwrap(route.renderer(for: reds[0]) as? MKPolylineRenderer)
        XCTAssertEqual(renderer.strokeColor, .systemRed)
        XCTAssertEqual(renderer.lineWidth, ReplayRouteStyle.highlightWidth)
        XCTAssertEqual(renderer.lineCap, .round)
        XCTAssertTrue(route.contains(reds[0]))
        XCTAssertTrue(route.highlight(1_000...3_500, now: 10.1).isEmpty, "The same trip keeps its overlays")

        // The layer keeps drawing the trip until MapKit has drawn the red.
        XCTAssertFalse(route.highlightRendered(now: 10.2))
        route.renderingBegan()
        route.renderingFinished(fullyRendered: true)
        XCTAssertTrue(route.highlightRendered(now: 10.3))

        // Blue added later goes beneath the red.
        let ids = Set(reds.map { ObjectIdentifier($0) })
        let moved = route.updatePosition(4_900, now: 11)
        XCTAssertFalse(moved.added.isEmpty)
        moved.apply(to: map)
        let drawn = map.overlays(in: .aboveRoads)
        XCTAssertEqual(Set(drawn.suffix(reds.count).map { ObjectIdentifier($0) }), ids)

        // Another trip replaces the red and waits for its own render, or the timeout.
        route.highlight(200...300, now: 12).apply(to: map)
        XCTAssertTrue(Set(map.overlays.map { ObjectIdentifier($0) }).isDisjoint(with: ids))
        XCTAssertFalse(route.highlightRendered(now: 13.9))
        XCTAssertTrue(route.highlightRendered(now: 14.01))
        route.highlight(nil).apply(to: map)
        XCTAssertTrue(route.highlightOverlays.isEmpty)
        XCTAssertFalse(route.highlightRendered(now: 15))
        XCTAssertEqual(Set(map.overlays.map { ObjectIdentifier($0) }), Set(route.overlays.map { ObjectIdentifier($0) }))
    }

    func testLayersLeaveAnOpenedTripsSegmentsToItsOverlays() throws {
        let values = coordinates(count: 400)
        let route = ReplayRoutePresentation(coordinates: values, now: 10)
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        map.region = MKCoordinateRegion(center: values[200], latitudinalMeters: 1_000, longitudinalMeters: 1_000)
        map.layoutIfNeeded()
        let marker = MKAnnotationView()
        map.addSubview(marker)
        let screen = ReplayScreenProjection(map: map, container: map)
        let rect = route.fullRoute.boundingMapRect
        let all = ReplayRoutePresentation.Coverage(start: 0, end: 399, prefix: false, marker: true,
            bounds: CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height))
        // Back-to-back moves collapse into one, so a hidden trip leaves one gap and none of its segments.
        func drawn(_ layer: ReplayTrailLayer) throws -> (gaps: Int, segments: Int) {
            var moves = 0, lines = 0
            try XCTUnwrap(layer.path).applyWithBlock {
                if $0.pointee.type == .moveToPoint { moves += 1 } else if $0.pointee.type == .addLineToPoint { lines += 1 }
            }
            return (moves - 1, lines)
        }
        let blue = ReplayTrailLayer(), dots = ReplayTrailLayer(future: true)
        blue.update(route: route.fullRoute, position: 300.5, coordinate: values[300], coverage: [all],
                    hiding: 100...200, projection: screen, on: map, below: marker)
        XCTAssertEqual(try drawn(blue).gaps, 1)
        XCTAssertEqual(try drawn(blue).segments, 300 + 1 - 100, "Every segment to the marker except the trip's 100")
        dots.update(route: route.fullRoute, position: 50.5, coordinate: values[50], coverage: [all],
                    hiding: 100...200, projection: screen, on: map, below: marker)
        XCTAssertEqual(try drawn(dots).gaps, 1)
        XCTAssertEqual(try drawn(dots).segments, 348 + 1 - 100)
        // With the marker inside the trip, the blue stops at the trip's start and leaves the way to the marker.
        blue.update(route: route.fullRoute, position: 150.5, coordinate: values[150], coverage: [all],
                    hiding: 100...200, projection: screen, on: map, below: marker)
        XCTAssertEqual(try drawn(blue).segments, 100)
        blue.update(route: route.fullRoute, position: 150.5, coordinate: values[150], coverage: [all],
                    projection: screen, on: map, below: marker)
        XCTAssertEqual(try drawn(blue).gaps, 0)
        XCTAssertEqual(try drawn(blue).segments, 151)
    }

    func testProjectionMatchesMapKitWithinHalfAPointAcrossZoomHeadingPitchAndDateline() {
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        for longitude in [-122.0, 179.999] {
            let origin = MKMapPoint(CLLocationCoordinate2D(latitude: 45, longitude: longitude))
            let values = (0..<1_025).map { index in
                let world = MKMapRect.world.width
                var x = (origin.x + Double(index - 512) * 6).truncatingRemainder(dividingBy: world)
                if x < 0 { x += world }
                return MKMapPoint(x: x, y: origin.y + sin(Double(index) * 0.02) * 600).coordinate
            }
            let route = ReplayRoutePresentation(coordinates: values)
            for distance in [2_000.0, 60_000] {
                for (heading, pitch) in [(0.0, 0.0), (37, 45), (170, 65)] {
                    map.setCamera(MKMapCamera(lookingAtCenter: origin.coordinate, fromDistance: distance,
                                             pitch: CGFloat(pitch), heading: heading), animated: false)
                    map.layoutIfNeeded()
                    let screen = ReplayScreenProjection(map: map, container: map)
                    let fast = screen.canProject(route.fullRoute, start: 0, end: 1_024)
                    for index in 0..<route.fullRoute.pointCount {
                        let point = route.fullRoute.points()[index]
                        let actual = screen.point(point, fast: fast), expected = screen.direct(point)
                        XCTAssertLessThanOrEqual(hypot(actual.x - expected.x, actual.y - expected.y), 0.5,
                            "distance \(distance), heading \(heading), pitch \(pitch), index \(index)")
                    }
                }
            }
        }
    }

    func testLayerUpdateTimingFor1024PointSection() {
        let values = coordinates(count: 1_025)
        let route = ReplayRoutePresentation(coordinates: values, now: 10)
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 402, height: 874))
        let marker = MKAnnotationView()
        map.addSubview(marker)
        let blue = ReplayTrailLayer(), dots = ReplayTrailLayer(future: true)
        var durations: [TimeInterval] = [], fastFrames = 0
        for frame in 0..<45 {
            let position = 100.5 + Double(frame) * 19
            _ = route.updatePosition(position, now: 10)
            let here = interpolated(values, at: position)
            map.setCamera(MKMapCamera(lookingAtCenter: values[512], fromDistance: 3_000 + Double(frame) * 20,
                pitch: 40, heading: Double(frame)), animated: false)
            map.layoutIfNeeded()
            let start = CACurrentMediaTime()
            let screen = ReplayScreenProjection(map: map, container: map)
            blue.update(route: route.fullRoute, position: position, coordinate: here,
                coverage: route.layerCoverage(future: false, now: 20), projection: screen, on: map, below: marker)
            dots.update(route: route.fullRoute, position: position, coordinate: here,
                coverage: route.layerCoverage(future: true, now: 20), projection: screen, on: map, below: marker)
            if frame >= 5 { durations.append(CACurrentMediaTime() - start) }
            if screen.canProject(route.fullRoute, start: 0, end: 1_024) { fastFrames += 1 }
        }
        let sorted = durations.sorted(), median = sorted[sorted.count / 2], p95 = sorted[sorted.count * 95 / 100]
        print("Replay route 1024 segments, 402x874, both layers + projection: median \(median * 1_000) ms, p95 \(p95 * 1_000) ms, max \(sorted.last! * 1_000) ms; homography \(fastFrames)/45 frames")
        XCTAssertLessThan(p95, 0.1, "Generous device bound; inspect the logged timings for frame-budget tuning")
        XCTAssertNotNil(blue.path)
        XCTAssertNotNil(dots.path)
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

    func testSectionChangesNeverLeakOverlaysAndRealMapKeepsDotsBeneathBlue() {
        let route = ReplayRoutePresentation(coordinates: coordinates(count: 5_000))
        let map = MKMapView(frame: CGRect(x: 0, y: 0, width: 400, height: 400))
        map.addOverlays(route.overlays, level: .aboveRoads)
        var shown = Set(route.overlays.map { ObjectIdentifier($0) })
        var positions = Array(stride(from: 0.0, through: 4_999, by: 3.7))
        positions += [4_999, 2_990, 1_500, 1_501, 1_024, 1_023, 0, 4_100, 0, 5, 1_030, 1_024, 4_999, 0]
        for position in positions {
            let change = route.updatePosition(position)
            for overlay in change.added + change.addedDots {
                XCTAssertTrue(shown.insert(ObjectIdentifier(overlay)).inserted, "Added twice at \(position)")
            }
            for overlay in change.removed + change.removedDots {
                XCTAssertNotNil(shown.remove(ObjectIdentifier(overlay)), "Removed but not shown at \(position)")
            }
            XCTAssertEqual(shown, Set(route.overlays.map { ObjectIdentifier($0) }))
            change.apply(to: map)
            let drawn = map.overlays(in: .aboveRoads)
            XCTAssertEqual(Set(drawn.map { ObjectIdentifier($0) }), shown)
            let lastDots = drawn.lastIndex { route.isDots($0) } ?? -1
            let firstRoute = drawn.firstIndex { !route.isDots($0) } ?? .max
            XCTAssertLessThan(lastDots, firstRoute)
        }
    }

    func testInvalidAndOutOfRangePositionsKeepTheTrailValid() {
        let route = ReplayRoutePresentation(coordinates: coordinates(count: 2_500), now: 10)
        _ = route.updatePosition(1_500)
        let shown = route.overlays.map { ObjectIdentifier($0) }
        for invalid in [Double.nan, .infinity, -.infinity] {
            XCTAssertTrue(route.updatePosition(invalid).isEmpty)
            XCTAssertEqual(route.overlays.map { ObjectIdentifier($0) }, shown)
            XCTAssertEqual(route.position, 1_500)
        }
        _ = route.updatePosition(-1)
        XCTAssertEqual(route.position, 0)
        assertCoverage(route, position: 0, now: 20)
        _ = route.updatePosition(10_000)
        XCTAssertEqual(route.position, 2_499)
        assertCoverage(route, position: 2_499, now: 20)
        XCTAssertTrue(route.layerCoverage(future: true, now: 20).isEmpty)
        XCTAssertFalse(route.overlays.contains { route.isDots($0) })
    }

    func testDensePointsRetainEveryVertexAndIsolateLongJumps() {
        let origin = MKMapPoint(CLLocationCoordinate2D(latitude: 45, longitude: -122))
        var values = (0..<12_000).map { MKMapPoint(x: origin.x + Double($0) * 6, y: origin.y).coordinate }
        values.insert(CLLocationCoordinate2D(latitude: 0, longitude: 0), at: 0)
        values.append(CLLocationCoordinate2D(latitude: 0, longitude: 0))
        let route = ReplayRoutePresentation(coordinates: values)
        XCTAssertEqual(route.fullRoute.pointCount, values.count)
        XCTAssertEqual(route.sections.first!.end, 1)
        XCTAssertEqual(route.sections.last!.end - route.sections.last!.start, 1)
        for section in route.sections {
            XCTAssertLessThanOrEqual(section.end - section.start, 1_024)
            for offset in section.prefix..<section.polyline.pointCount {
                let point = section.polyline.points()[offset]
                let expected = route.fullRoute.points()[section.start + offset - section.prefix]
                XCTAssertEqual(point.x, expected.x)
                XCTAssertEqual(point.y, expected.y)
            }
            if section.prefix > 0 {
                let tail = section.polyline.points()[0], start = section.polyline.points()[1]
                XCTAssertLessThanOrEqual(hypot(tail.x - start.x, tail.y - start.y), 100.001)
            }
        }
    }

    func testDatelineAppendTrimAndStationaryRoutesStayFinite() {
        let values = [179.9, -179.9, -179.8, -179.7].map { CLLocationCoordinate2D(latitude: 0, longitude: $0) }
        let route = ReplayRoutePresentation(coordinates: Array(values.prefix(3)), pointIDs: [10, 11, 12])
        XCTAssertLessThan(route.fullRoute.boundingMapRect.width, MKMapRect.world.width / 100)
        _ = route.update(coordinates: Array(values.dropFirst()), pointIDs: [11, 12, 13], position: 0.5)
        XCTAssertLessThan(route.fullRoute.boundingMapRect.width, MKMapRect.world.width / 100)
        for section in route.sections { XCTAssertLessThan(section.polyline.boundingMapRect.width, MKMapRect.world.width / 100) }
        let point = CLLocationCoordinate2D(latitude: 45, longitude: -122)
        for count in [0, 1, 10] {
            let still = ReplayRoutePresentation(coordinates: Array(repeating: point, count: count), now: 10)
            _ = still.updatePosition(2.5)
            for section in still.sections {
                XCTAssertTrue(still.renderer(for: section.polyline).map { type(of: $0) == MKPolylineRenderer.self } ?? false)
            }
            assertCoverage(still, position: min(2.5, Double(max(0, count - 1))), now: 20)
        }
    }

    private struct Interval: Hashable {
        let start: Double
        let end: Double
    }

    private func assertCoverage(_ route: ReplayRoutePresentation, position: Double, now: TimeInterval, line: UInt = #line) {
        // Union coverage counts a pending section once: its layer temporarily shadows the identical
        // native stroke. Shared join tails are deliberately outside the logical segment partition.
        var blue = Set<Interval>(), dots = Set<Interval>()
        let shown = Set(route.overlays.map { ObjectIdentifier($0) })
        for section in route.sections {
            if shown.contains(ObjectIdentifier(section.polyline)) {
                blue.insert(Interval(start: Double(section.start), end: Double(section.end)))
            }
            if shown.contains(ObjectIdentifier(section.future)) {
                XCTAssertGreaterThan(Double(section.start), position, line: line)
                dots.insert(Interval(start: Double(section.start), end: Double(section.end)))
            }
        }
        for span in route.layerCoverage(future: false, now: now) {
            blue.insert(Interval(start: Double(span.start), end: span.marker ? position : Double(span.end)))
        }
        for span in route.layerCoverage(future: true, now: now) {
            let start = span.marker ? position : Double(span.start)
            XCTAssertGreaterThanOrEqual(start, position, line: line)
            dots.insert(Interval(start: start, end: Double(span.end)))
        }
        func partition(_ intervals: Set<Interval>, from start: Double, to end: Double) {
            var cursor = start
            for interval in intervals.sorted(by: { $0.start < $1.start }) where interval.end > interval.start {
                XCTAssertEqual(interval.start, cursor, accuracy: 0.000001, "Gap or duplicate segment at \(position)", line: line)
                cursor = interval.end
            }
            XCTAssertEqual(cursor, end, accuracy: 0.000001, "Missing route at \(position)", line: line)
        }
        partition(blue, from: 0, to: position)
        partition(dots, from: position, to: Double(max(0, route.fullRoute.pointCount - 1)))
    }

    private func interpolated(_ values: [CLLocationCoordinate2D], at position: Double) -> CLLocationCoordinate2D {
        let index = Int(position)
        guard index + 1 < values.count else { return values[index] }
        return ReplayCoordinate(values[index]).interpolated(to: ReplayCoordinate(values[index + 1]), fraction: position - Double(index)).coordinate
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
