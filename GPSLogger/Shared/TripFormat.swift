import Foundation

enum TripFormat {
    // Pace reads better than speed on foot.
    static func usesPace(_ mode: String) -> Bool {
        ["walking", "running", "hiking"].contains(TripModeStore.healthWorkout(mode) ?? "")
    }

    static func day(_ date: Date, calendar: Calendar = .current) -> String {
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today, \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday, \(time)" }
        return "\(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())), \(time)"
    }

    static func speed(_ metersPerSecond: Double, metric: Bool) -> String {
        let unit = metric ? "km/h" : "mph"
        guard metersPerSecond >= 0, metersPerSecond.isFinite else { return "– \(unit)" }
        return String(format: "%.1f %@", metersPerSecond * (metric ? 3.6 : 2.236_936), unit)
    }

    static func pace(distance meters: Double, duration seconds: Double, metric: Bool) -> String {
        let unit = metric ? "/km" : "/mi"
        guard seconds >= 1, seconds.isFinite, meters >= 10, meters.isFinite else { return "– \(unit)" }
        let value = (seconds / (meters / (metric ? 1_000 : 1_609.344))).rounded()
        guard value < 100 * 60 else { return "– \(unit)" }
        let perUnit = Int(value)
        return String(format: "%d:%02d %@", perUnit / 60, perUnit % 60, unit)
    }

    static func climb(_ meters: Double, metric: Bool) -> String {
        guard meters >= 0, meters.isFinite else { return metric ? "– m" : "– ft" }
        return metric ? "\(Int(meters.rounded())) m" : "\(Int((meters * 3.280_84).rounded())) ft"
    }

    static func duration(_ seconds: Double) -> String {
        let t = Int(max(0, seconds))
        return String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60)
    }

    static func distance(_ meters: Double, metric: Bool) -> String {
        let v = metric ? meters / 1000 : meters / 1609.344
        return String(format: v < 10 ? "%.2f %@" : "%.1f %@", v, metric ? "km" : "mi")
    }

    static func averageSpeed(distance meters: Double, duration seconds: Double, metric: Bool) -> String {
        guard seconds >= 1, meters.isFinite, meters >= 0 else { return metric ? "– km/h" : "– mph" }
        return speed(meters / seconds, metric: metric)
    }
}

