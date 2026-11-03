import MapKit
import UIKit

struct DeviceHeadingReading: Sendable {
    let degrees: CLLocationDirection
    let accuracy: CLLocationDirection

    init?(trueHeading: CLLocationDirection, magneticHeading: CLLocationDirection,
          accuracy: CLLocationDirection) {
        guard accuracy.isFinite, accuracy >= 0 else { return nil }
        let heading = trueHeading.isFinite && trueHeading >= 0 ? trueHeading : magneticHeading
        guard heading.isFinite, heading >= 0 else { return nil }
        degrees = heading.truncatingRemainder(dividingBy: 360)
        self.accuracy = accuracy
    }
}

@MainActor
protocol DeviceHeadingProviding: AnyObject {
    var onHeading: ((DeviceHeadingReading?) -> Void)? { get set }
    var orientation: UIInterfaceOrientation { get set }
    func start()
    func stop()
}

// This manager reads only the compass; it never changes GLManager's location acquisition.
@MainActor
final class DeviceHeadingSource: NSObject, CLLocationManagerDelegate, DeviceHeadingProviding {
    static var available: Bool { CLLocationManager.headingAvailable() }
    var onHeading: ((DeviceHeadingReading?) -> Void)?
    private let manager = CLLocationManager()

    var orientation: UIInterfaceOrientation = .portrait {
        didSet { manager.headingOrientation = Self.headingOrientation(for: orientation) }
    }

    static func headingOrientation(for orientation: UIInterfaceOrientation) -> CLDeviceOrientation {
        // Interface landscape left is the device turned right, and the reverse.
        switch orientation {
        case .portraitUpsideDown: return .portraitUpsideDown
        case .landscapeLeft: return .landscapeRight
        case .landscapeRight: return .landscapeLeft
        default: return .portrait
        }
    }

    override init() {
        super.init()
        manager.headingFilter = 2
    }

    func start() {
        manager.delegate = self
        manager.startUpdatingHeading()
    }

    func stop() {
        manager.stopUpdatingHeading()
        manager.delegate = nil
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateHeading heading: CLHeading) {
        let reading = DeviceHeadingReading(trueHeading: heading.trueHeading, magneticHeading: heading.magneticHeading,
                                          accuracy: heading.headingAccuracy)
        MainActor.assumeIsolated { onHeading?(reading) }
    }
}

struct HeadingBeamStyle: Equatable {
    let width: Double
    let opacity: Double
    let radius = 46.0

    init?(accuracy: CLLocationDirection?) {
        guard let accuracy, accuracy.isFinite, accuracy >= 0 else { return nil }
        let uncertainty = min(1, accuracy / 90)
        width = (68 + 52 * uncertainty) * .pi / 180
        opacity = 0.35 * (1 - 0.75 * uncertainty)
    }
}

enum MapHeadingProjection {
    // Core Location has already adjusted the reading for headingOrientation.
    static func rotation(heading: Double, cameraHeading: CLLocationDirection) -> Double {
        let angle = heading - cameraHeading * .pi / 180
        return atan2(sin(angle), cos(angle))
    }

    @MainActor static func angle(heading: Double, coordinate: CLLocationCoordinate2D, on map: MKMapView) -> CGFloat {
        let world = MKMapRect.world
        let origin = MKMapPoint(coordinate)
        let distance = min(world.width / 1024,
            max(1, map.visibleMapRect.width / max(1, Double(map.bounds.width)) * 24))
        var x = (origin.x + sin(heading) * distance).truncatingRemainder(dividingBy: world.width)
        if x < 0 { x += world.width }
        let y = min(world.maxY, max(0, origin.y - cos(heading) * distance))
        let start = map.convert(coordinate, toPointTo: map)
        let end = map.convert(MKMapPoint(x: x, y: y).coordinate, toPointTo: map)
        let dx = end.x - start.x
        let dy = end.y - start.y
        return dx.isFinite && dy.isFinite && hypot(dx, dy) > 0.01
            ? atan2(dx, -dy) : CGFloat(rotation(heading: heading, cameraHeading: map.camera.heading))
    }
}

@MainActor
final class LiveHeadingBeamLayer: CAGradientLayer {
    private var beamStyle: HeadingBeamStyle?
    private var appearance: UIUserInterfaceStyle?

    override init() {
        super.init()
        type = .radial
        startPoint = CGPoint(x: 0.5, y: 0.5)
        endPoint = CGPoint(x: 1, y: 1)
        locations = [0, 0.35, 1]
    }

    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { super.init(coder: coder) }

    func hide() { removeFromSuperlayer() }

    func center(in marker: MKUserLocationView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        position = CGPoint(x: marker.bounds.midX, y: marker.bounds.midY)
        CATransaction.commit()
    }

    func update(angle: CGFloat, style: HeadingBeamStyle, in marker: MKUserLocationView) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        marker.clipsToBounds = false
        if superlayer !== marker.layer { marker.layer.insertSublayer(self, at: 0) }
        bounds = CGRect(x: 0, y: 0, width: style.radius * 2, height: style.radius * 2)
        center(in: marker)
        transform = CATransform3DMakeRotation(angle, 0, 0, 1)
        if beamStyle != style {
            // An angular mask feathers both sides without rebuilding geometry on heading frames.
            let mask = CAGradientLayer()
            mask.frame = bounds
            mask.type = .conic
            mask.startPoint = CGPoint(x: 0.5, y: 0.5)
            mask.endPoint = CGPoint(x: 0.5, y: 0)
            let span = style.width / (2 * .pi)
            mask.locations = [0, NSNumber(value: span * 0.12), NSNumber(value: span * 0.88), NSNumber(value: span), 1]
            mask.colors = [UIColor.clear.cgColor, UIColor.white.cgColor, UIColor.white.cgColor,
                           UIColor.clear.cgColor, UIColor.clear.cgColor]
            mask.transform = CATransform3DMakeRotation(-style.width / 2, 0, 0, 1)
            self.mask = mask
        }
        if beamStyle != style || appearance != marker.traitCollection.userInterfaceStyle {
            let blue = UIColor.systemBlue.resolvedColor(with: marker.traitCollection)
            colors = [blue.withAlphaComponent(style.opacity).cgColor,
                      blue.withAlphaComponent(style.opacity * 0.65).cgColor,
                      blue.withAlphaComponent(0).cgColor]
        }
        beamStyle = style
        appearance = marker.traitCollection.userInterfaceStyle
    }
}

@MainActor
final class LiveHeadingController {
    var onHeading: ((CLLocationDirection) -> Void)?
    var onNeedsDisplay: (() -> Void)?
    private(set) var reading: DeviceHeadingReading?
    private let makeSource: @MainActor () -> any DeviceHeadingProviding
    private let available: @MainActor () -> Bool
    private let reduceMotion: @MainActor () -> Bool
    private var source: (any DeviceHeadingProviding)?
    private var sourceRevision = 0
    private var motion = HeadingMotion()
    private var displayLink: CADisplayLink?
    private let beam = LiveHeadingBeamLayer()

    init(available: @escaping @MainActor () -> Bool = { DeviceHeadingSource.available },
         makeSource: @escaping @MainActor () -> any DeviceHeadingProviding = { DeviceHeadingSource() },
         reduceMotion: @escaping @MainActor () -> Bool = { UIAccessibility.isReduceMotionEnabled }) {
        self.available = available
        self.makeSource = makeSource
        self.reduceMotion = reduceMotion
    }

    func update(tracking: Bool, sceneActive: Bool, mapVisible: Bool, showsLiveLocation: Bool,
                orientation: UIInterfaceOrientation) {
        guard tracking, sceneActive, mapVisible, showsLiveLocation, available() else { stop(); return }
        if source != nil {
            updateOrientation(orientation)
            return
        }
        let source = makeSource()
        self.source = source
        sourceRevision += 1
        let revision = sourceRevision
        source.orientation = orientation
        source.onHeading = { [weak self] reading in
            guard let self, self.sourceRevision == revision else { return }
            self.receive(reading)
        }
        source.start()
    }

    private func updateOrientation(_ orientation: UIInterfaceOrientation) {
        guard let source, source.orientation != orientation else { return }
        clearReading()
        source.orientation = orientation
    }

    func stop() {
        sourceRevision += 1
        source?.onHeading = nil
        source?.stop()
        source = nil
        clearReading()
    }

    private func clearReading() {
        reading = nil
        motion = HeadingMotion()
        hide()
    }

    private func receive(_ reading: DeviceHeadingReading?, at time: TimeInterval = CACurrentMediaTime()) {
        guard source != nil else { return }
        guard let reading else { clearReading(); return }
        self.reading = reading
        motion.receive(reading.degrees * .pi / 180, at: time)
        if reduceMotion() { motion.finish() }
        onHeading?(reading.degrees)
        onNeedsDisplay?()
    }

    func hide() {
        beam.hide()
        stopFrames()
    }

    private func stopFrames() {
        displayLink?.invalidate()
        displayLink = nil
        motion.finish()
    }

    func render(coordinate: CLLocationCoordinate2D, on map: MKMapView, marker: MKUserLocationView) {
        if let orientation = map.window?.windowScene?.interfaceOrientation { updateOrientation(orientation) }
        guard source != nil, let style = HeadingBeamStyle(accuracy: reading?.accuracy),
              motion.angle != nil, marker.window != nil,
              map.bounds.intersects(marker.convert(marker.bounds, to: map)) else { hide(); return }
        if reduceMotion() || motion.settled { stopFrames() }
        guard let heading = motion.angle else { return }
        // Project after smoothing, so camera rotation and pitch take effect in this transaction.
        beam.update(angle: MapHeadingProjection.angle(heading: heading, coordinate: coordinate, on: map),
                    style: style, in: marker)
        if !motion.settled, displayLink == nil {
            let target = LiveHeadingFrameTarget(controller: self)
            let link = CADisplayLink(target: target, selector: #selector(LiveHeadingFrameTarget.frame(_:)))
            let maximum = Float(map.window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
            link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    fileprivate func advance(at time: TimeInterval) {
        motion.advance(at: time)
        if reduceMotion() || motion.settled { stopFrames() }
        onNeedsDisplay?()
    }
}

@MainActor
private final class LiveHeadingFrameTarget: NSObject {
    private weak var controller: LiveHeadingController?

    init(controller: LiveHeadingController) { self.controller = controller }

    @objc func frame(_ link: CADisplayLink) {
        guard let controller else { link.invalidate(); return }
        controller.advance(at: link.timestamp)
    }
}
