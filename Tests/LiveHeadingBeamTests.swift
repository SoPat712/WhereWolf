import MapKit
import XCTest
@testable import WhereWolf

@MainActor
final class LiveHeadingBeamTests: XCTestCase {
    func testTrueHeadingWinsAndMagneticHeadingIsTheFallback() throws {
        XCTAssertEqual(try XCTUnwrap(reading(trueHeading: 72, magneticHeading: 80)).degrees, 72)
        XCTAssertEqual(try XCTUnwrap(reading(trueHeading: -1, magneticHeading: 80)).degrees, 80)
        XCTAssertEqual(try XCTUnwrap(reading(trueHeading: .nan, magneticHeading: 80)).degrees, 80)
        XCTAssertEqual(try XCTUnwrap(reading(trueHeading: 360)).degrees, 0)
        XCTAssertEqual(try XCTUnwrap(reading(trueHeading: 0)).degrees, 0)
        XCTAssertNil(reading(trueHeading: -1, magneticHeading: -1))
        XCTAssertNil(reading(trueHeading: -1, magneticHeading: .infinity))
    }

    func testBeamRotationSubtractsTheCurrentCameraHeading() {
        for (device, camera, expected) in [(0.0, 0.0, 0.0), (90, 0, 90), (90, 90, 0),
                                           (0, 90, -90), (359, 1, -2), (1, 359, 2), (180, 270, -90)] {
            XCTAssertEqual(MapHeadingProjection.rotation(heading: device * .pi / 180, cameraHeading: camera),
                           expected * .pi / 180, accuracy: 0.000001)
        }
    }

    func testInterfaceOrientationIsAppliedByCoreLocation() {
        XCTAssertEqual(DeviceHeadingSource.headingOrientation(for: .portrait), .portrait)
        XCTAssertEqual(DeviceHeadingSource.headingOrientation(for: .portraitUpsideDown), .portraitUpsideDown)
        XCTAssertEqual(DeviceHeadingSource.headingOrientation(for: .landscapeLeft), .landscapeRight)
        XCTAssertEqual(DeviceHeadingSource.headingOrientation(for: .landscapeRight), .landscapeLeft)
        XCTAssertEqual(DeviceHeadingSource.headingOrientation(for: .unknown), .portrait)
        // After Core Location's orientation correction, a reading matching the camera faces up.
        for screenTop in [0.0, 90, 180, 270] {
            XCTAssertEqual(MapHeadingProjection.rotation(heading: screenTop * .pi / 180, cameraHeading: screenTop),
                           0, accuracy: 0.000001)
        }
    }

    func testUncertaintyWidensAndFadesTheBeamWithinBounds() throws {
        let sharp = try XCTUnwrap(HeadingBeamStyle(accuracy: 0))
        let middle = try XCTUnwrap(HeadingBeamStyle(accuracy: 45))
        let broad = try XCTUnwrap(HeadingBeamStyle(accuracy: 90))
        XCTAssertEqual(sharp.width * 180 / .pi, 68, accuracy: 0.000001)
        XCTAssertEqual(sharp.radius, 46)
        XCTAssertEqual(sharp.opacity, 0.35, accuracy: 0.000001)
        XCTAssertEqual(middle.width * 180 / .pi, 94, accuracy: 0.000001)
        XCTAssertGreaterThan(sharp.opacity, middle.opacity)
        XCTAssertGreaterThan(middle.opacity, broad.opacity)
        XCTAssertEqual(broad.width * 180 / .pi, 120, accuracy: 0.000001)
        XCTAssertEqual(broad.opacity, 0.0875, accuracy: 0.000001)
        XCTAssertEqual(HeadingBeamStyle(accuracy: 1_000), broad)
    }

    func testMissingOrInvalidAccuracyHidesTheBeam() {
        let accuracies: [Double?] = [nil, -1, .nan, .infinity, -.infinity]
        for accuracy in accuracies {
            XCTAssertNil(HeadingBeamStyle(accuracy: accuracy))
            if let accuracy { XCTAssertNil(reading(accuracy: accuracy)) }
        }
        XCTAssertNotNil(reading(accuracy: 0))
    }

    func testHeadingSpringCrossesNorthByTheShortestArcInBothDirections() throws {
        for (from, to, end) in [(359.0, 1.0, 361.0), (1.0, 359.0, -1.0)] {
            var motion = HeadingMotion()
            motion.receive(from * .pi / 180, at: 100)
            motion.receive(to * .pi / 180, at: 100)
            for frame in 1...120 {
                motion.advance(at: 100 + Double(frame) / 60)
                let degrees = try XCTUnwrap(motion.angle) * 180 / .pi
                XCTAssertGreaterThanOrEqual(degrees, min(from, end) - 0.001)
                XCTAssertLessThanOrEqual(degrees, max(from, end) + 0.001)
                if frame == 3 { XCTAssertGreaterThan(abs(degrees - end), 0.1) }
            }
            XCTAssertEqual(try XCTUnwrap(motion.angle) * 180 / .pi, end, accuracy: 0.001)
            XCTAssertTrue(motion.settled)
        }
    }

    func testHeadingRetargetPreservesMotionAndFinishHonorsReduceMotion() throws {
        var motion = HeadingMotion()
        motion.receive(0, at: 100)
        motion.receive(.pi / 2, at: 100)
        motion.advance(at: 100.05)
        let before = try XCTUnwrap(motion.angle)
        motion.receive(0, at: 100.05)
        motion.advance(at: 100.06)
        XCTAssertGreaterThan(try XCTUnwrap(motion.angle), before)
        motion.finish()
        XCTAssertEqual(try XCTUnwrap(motion.angle), 0, accuracy: 0.000001)
        XCTAssertTrue(motion.settled)
    }

    func testSourceLifecycleStopsForEveryVisibilityGateAndRestartsOnce() throws {
        let source = StubDeviceHeadingSource()
        let controller = LiveHeadingController(available: { true }, makeSource: { source })
        defer { controller.stop() }
        func update(tracking: Bool = true, active: Bool = true, visible: Bool = true, live: Bool = true) {
            controller.update(tracking: tracking, sceneActive: active, mapVisible: visible,
                              showsLiveLocation: live, orientation: .portrait)
        }
        update()
        update()
        XCTAssertEqual(source.starts, 1)
        let gates = [(false, true, true, true),   // Stop
                     (true, false, true, true),  // Inactive or background scene
                     (true, true, false, true),  // Settings
                     (true, true, true, false)]  // Replay or lost location access
        for (tracking, active, visible, live) in gates {
            source.onHeading?(reading())
            XCTAssertNotNil(controller.reading)
            let starts = source.starts
            let stops = source.stops
            let callback = source.onHeading
            update(tracking: tracking, active: active, visible: visible, live: live)
            update(tracking: tracking, active: active, visible: visible, live: live)
            XCTAssertEqual(source.stops, stops + 1)
            XCTAssertNil(source.onHeading)
            XCTAssertNil(controller.reading)
            update()
            XCTAssertEqual(source.starts, starts + 1)
            XCTAssertNil(controller.reading)
            callback?(reading())
            XCTAssertNil(controller.reading)
        }
    }

    func testUnavailableCompassDoesNotCreateASource() {
        var creations = 0
        let controller = LiveHeadingController(available: { false }, makeSource: {
            creations += 1
            return StubDeviceHeadingSource()
        })
        controller.update(tracking: true, sceneActive: true, mapVisible: true,
                          showsLiveLocation: true, orientation: .portrait)
        XCTAssertEqual(creations, 0)
        XCTAssertNil(controller.reading)
    }

    func testInvalidReadingAndOrientationChangeClearStaleHeading() {
        let source = StubDeviceHeadingSource()
        let controller = LiveHeadingController(available: { true }, makeSource: { source })
        defer { controller.stop() }
        controller.update(tracking: true, sceneActive: true, mapVisible: true,
                          showsLiveLocation: true, orientation: .portrait)
        var deliveries: [Double] = []
        controller.onHeading = { deliveries.append($0) }
        source.onHeading?(reading(trueHeading: 45))
        source.onHeading?(nil)
        XCTAssertNil(controller.reading)
        XCTAssertEqual(deliveries, [45])
        source.onHeading?(reading(trueHeading: 90))
        controller.update(tracking: true, sceneActive: true, mapVisible: true,
                          showsLiveLocation: true, orientation: .landscapeLeft)
        XCTAssertEqual(source.orientation, .landscapeLeft)
        XCTAssertNil(controller.reading)
        XCTAssertEqual(source.starts, 1)
        source.onHeading?(reading(trueHeading: 180))
        XCTAssertEqual(controller.reading?.degrees, 180)
    }

    func testBeamTravelsWithTheNativeDotLayerAndHasNoViewOrImplicitAnimations() throws {
        let container = UIView(frame: CGRect(x: 0, y: 0, width: 400, height: 800))
        let marker = MKUserLocationView(annotation: nil, reuseIdentifier: nil)
        marker.bounds = CGRect(x: 0, y: 0, width: 22, height: 22)
        marker.center = CGPoint(x: 100, y: 200)
        container.addSubview(marker)
        let beam = LiveHeadingBeamLayer()
        let style = try XCTUnwrap(HeadingBeamStyle(accuracy: 0))
        beam.update(angle: .pi / 2, style: style, in: marker)
        XCTAssertTrue(beam.superlayer === marker.layer)
        XCTAssertTrue(marker.layer.sublayers?.first === beam)
        XCTAssertEqual(beam.bounds.width, 92)
        XCTAssertEqual(beam.type, .radial)
        XCTAssertEqual(beam.endPoint, CGPoint(x: 1, y: 1))
        XCTAssertEqual((beam.mask as? CAGradientLayer)?.type, .conic)
        XCTAssertEqual(marker.layer.convert(beam.position, to: container.layer), marker.center)
        marker.layer.position = CGPoint(x: 150, y: 250)
        XCTAssertEqual(marker.layer.convert(beam.position, to: container.layer), CGPoint(x: 150, y: 250))
        XCTAssertEqual(atan2(beam.transform.m12, beam.transform.m11), .pi / 2, accuracy: 0.000001)
        XCTAssertEqual(beam.animationKeys() ?? [], [])
        let colors = try XCTUnwrap(beam.colors as? [CGColor])
        XCTAssertEqual(colors.first?.alpha ?? -1, 0.35, accuracy: 0.000001)
        XCTAssertEqual(colors.last?.alpha, 0)
        beam.hide()
        XCTAssertNil(beam.superlayer)
    }

    private func reading(trueHeading: Double = 0, magneticHeading: Double = 10,
                         accuracy: Double = 5) -> DeviceHeadingReading? {
        DeviceHeadingReading(trueHeading: trueHeading, magneticHeading: magneticHeading, accuracy: accuracy)
    }
}

@MainActor
final class StubDeviceHeadingSource: DeviceHeadingProviding {
    var onHeading: ((DeviceHeadingReading?) -> Void)?
    var orientation: UIInterfaceOrientation = .portrait
    private(set) var starts = 0
    private(set) var stops = 0

    func start() { starts += 1 }
    func stop() { stops += 1 }
}
