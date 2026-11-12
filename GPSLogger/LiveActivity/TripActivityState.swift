import Foundation

// No geographic frame or coordinates enter ContentState; map points are in image space.
struct TripActivityState: Codable, Hashable {
    var mode: String
    var distance: Double // meters
    var speed: Double // m/s, retained for old activities
    var topSpeed: Double? = nil // m/s; negative means unknown
    var climb: Double? = nil // meters
    var averageSpeed: Double? = nil // m/s, sampled at the activity update
    var route: TripRouteSketch? = nil
    var map: TripActivityMap? = nil
}

enum TripActivityFormat {
    static var usesMetricSystem: Bool {
        (NSLocale.current as NSLocale).object(forKey: .usesMetricSystem) as? Bool ?? true
    }

    static var distanceUnit: String { usesMetricSystem ? "km" : "mi" }
    static var speedUnit: String { usesMetricSystem ? "km/h" : "mph" }

    static func modeName(_ mode: String) -> String {
        TripModeStore.name(mode)
    }

    static func distance(_ meters: Double) -> String {
        let distance = meters * (usesMetricSystem ? 0.001 : 0.000621371)
        let format: String
        if distance >= 1000 {
            format = "%0.0f"
        } else if distance >= 100 {
            format = "%0.1f"
        } else {
            format = "%0.2f"
        }
        return String(format: format, distance)
    }

    static func speed(_ metersPerSecond: Double) -> String {
        speed(metersPerSecond, metric: usesMetricSystem)
    }

    static func speed(_ metersPerSecond: Double, metric: Bool) -> String {
        guard metersPerSecond.isFinite, metersPerSecond >= 0 else { return "–" }
        let speed = Int((metersPerSecond * (metric ? 3.6 : 2.23694)).rounded())
        return String(max(speed, 0))
    }

    // Average (pace on foot), then top speed and climb when known, one short line each.
    static func details(_ state: TripActivityState, metric: Bool = usesMetricSystem) -> [String] {
        let unit = metric ? "km/h" : "mph"
        let average = state.averageSpeed ?? -1
        let value: String
        if TripFormat.usesPace(state.mode) {
            let duration = average > 0 ? state.distance / average : 0
            value = TripFormat.pace(distance: state.distance, duration: duration, metric: metric)
        } else {
            value = "\(speed(average, metric: metric)) \(unit)"
        }
        var lines = ["avg \(value)"]
        if let top = state.topSpeed, top >= 0, top.isFinite {
            lines.append("top \(speed(top, metric: metric)) \(unit)")
        }
        if let climb = state.climb, climb >= 0, climb.isFinite {
            lines.append("climb \(TripFormat.climb(climb, metric: metric))")
        }
        return lines
    }
}
