import CoreLocation
import Foundation

// One finished trip, without coordinates, for the Trip tab's recent list.
struct TripSummary: Codable, Equatable, Identifiable {
    let mode: String
    let start: Date
    let end: Date
    let distance: Double
    let topSpeed: Double?
    let climb: Double?

    var id: Date { start }
}

// One retained history fix that was recorded during a trip.
struct RecordedTripFix {
    let trip: String
    let mode: String
    let timestamp: Date
    let latitude: Double
    let longitude: Double
    var speed = -1.0
    var speedAccuracy = -1.0
    var altitude = 0.0
    var verticalAccuracy = -1.0
}

// Recent finished trips, newest first, kept on this device only.
@objc(GLTripLog) final class TripLog: NSObject {
    static let limit = 20
    static let changed = Notification.Name("WhereWolfTripLogChanged")
    private static let key = "WhereWolfRecentTrips"
    static var defaults: UserDefaults = .standard

    static var trips: [TripSummary] {
        guard let data = defaults.data(forKey: key),
              let trips = try? JSONDecoder().decode([TripSummary].self, from: data) else { return [] }
        return trips
    }

    @objc(recordTripWithMode:start:end:distance:topSpeed:climb:)
    static func record(mode: String, start: Date, end: Date, distance: Double, topSpeed: Double, climb: Double) {
        guard end > start else { return }
        let trip = TripSummary(mode: mode, start: start, end: end, distance: max(0, distance),
                               topSpeed: topSpeed >= 0 ? topSpeed : nil, climb: climb >= 0 ? climb : nil)
        let trips = Array(([trip] + Self.trips.filter { $0.start != start }).sorted { $0.start > $1.start }.prefix(limit))
        guard let data = try? JSONEncoder().encode(trips) else { return }
        defaults.set(data, forKey: key)
        NotificationCenter.default.post(name: changed, object: nil)
    }

    // History tags every fix with its trip, so a trip whose summary was never saved, or that ended before
    // this log existed, is rebuilt from its fixes while they are retained. Fixes arrive in time order.
    static func recordedTrips(_ fixes: [RecordedTripFix], excluding current: Date? = nil) -> [TripSummary] {
        var trips: [TripSummary] = []
        var index = fixes.startIndex
        while index < fixes.endIndex {
            let tag = fixes[index].trip
            var end = index
            while end < fixes.endIndex && fixes[end].trip == tag { end += 1 }
            let run = fixes[index..<end]
            index = end
            guard let first = run.first, let last = run.last else { continue }
            let start = startFormatter.date(from: tag) ?? first.timestamp
            if let current, abs(current.timeIntervalSince(start)) < 1 { continue }
            guard last.timestamp > start else { continue }
            let stats = TripStatsAccumulator()
            var distance = 0.0
            var previous: CLLocation?
            for fix in run {
                let location = CLLocation(latitude: fix.latitude, longitude: fix.longitude)
                if let previous { distance += location.distance(from: previous) }
                previous = location
                stats.add(speed: fix.speed, speedAccuracy: fix.speedAccuracy, altitude: fix.altitude,
                          verticalAccuracy: fix.verticalAccuracy)
            }
            trips.append(TripSummary(mode: TripModeStore.modeID(serverValue: first.mode) ?? first.mode, start: start,
                                     end: last.timestamp, distance: distance,
                                     topSpeed: stats.topSpeed >= 0 ? stats.topSpeed : nil, climb: stats.climb))
        }
        return trips
    }

    // Saved summaries win; their starts keep the fractions of a second that a trip's tag drops.
    static func merged(_ saved: [TripSummary], recorded: [TripSummary]) -> [TripSummary] {
        let missing = recorded.filter { trip in !saved.contains { abs($0.start.timeIntervalSince(trip.start)) < 1 } }
        return (saved + missing).sorted { $0.start > $1.start }
    }

    private static let startFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()
}
