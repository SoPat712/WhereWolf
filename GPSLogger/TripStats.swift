import Foundation

// Top speed and climb for the trip in progress, fed each stored trip fix in time order.
@objc(GLTripStatsAccumulator) final class TripStatsAccumulator: NSObject {
    // GPS altitude wanders by a few meters, so only a rise this far above the lowest point since
    // the last counted rise is climbing.
    static let climbStep = 5.0
    static let maximumVerticalAccuracy = 10.0
    static let maximumSpeedAccuracy = 5.0

    @objc private(set) var topSpeed: Double = -1
    @objc private(set) var climb: Double = 0
    private var anchor: Double?
    private var route = TripRouteSketchBuilder()
    private var cachedRoute: TripRouteSketch?

    func routeSketch() -> TripRouteSketch {
        if let cachedRoute { return cachedRoute }
        let sketch = route.sketch()
        cachedRoute = sketch
        return sketch
    }

    @objc func reset() {
        topSpeed = -1
        climb = 0
        anchor = nil
        route.reset()
        cachedRoute = nil
    }

    // The live append and ordered database replay feed both accumulators together.
    @objc func add(speed: Double, speedAccuracy: Double, altitude: Double, verticalAccuracy: Double,
                   latitude: Double, longitude: Double) {
        add(speed: speed, speedAccuracy: speedAccuracy, altitude: altitude, verticalAccuracy: verticalAccuracy)
        route.add(latitude: latitude, longitude: longitude)
        cachedRoute = nil
    }

    // Negative values mean unknown, as in Core Location.
    @objc func add(speed: Double, speedAccuracy: Double, altitude: Double, verticalAccuracy: Double) {
        if speed >= 0, speedAccuracy >= 0, speedAccuracy <= Self.maximumSpeedAccuracy { topSpeed = max(topSpeed, speed) }
        guard verticalAccuracy > 0, verticalAccuracy <= Self.maximumVerticalAccuracy, altitude.isFinite else { return }
        guard let low = anchor else { anchor = altitude; return }
        if altitude - low >= Self.climbStep {
            climb += altitude - low
            anchor = altitude
        } else if altitude < low {
            anchor = altitude
        }
    }
}
