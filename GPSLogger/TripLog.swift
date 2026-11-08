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
}
