import Foundation
import CoreFoundation
import CoreLocation

struct DawarichStopPlace: Codable, Equatable, Hashable {
    let id: Int64?
    let name: String
    let latitude: Double
    let longitude: Double

    var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    var symbol: String { WifiPlace.autoSymbol(for: name) }
}

struct DawarichStopVisit: Codable, Equatable, Hashable {
    struct Center: Codable, Equatable, Hashable {
        let latitude: Double
        let longitude: Double

        var location: CLLocation { CLLocation(latitude: latitude, longitude: longitude) }
    }

    let id: Int64
    let startedAt: Date
    let endedAt: Date
    let status: String
    let placeID: Int64?
    let place: DawarichStopPlace?
    let customName: String?
    let displayName: String?
    let center: Center?

    init(id: Int64, startedAt: Date, endedAt: Date, status: String, placeID: Int64?, place: DawarichStopPlace?,
         customName: String? = nil, displayName: String? = nil, center: Center? = nil) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.status = status
        self.placeID = placeID
        self.place = place
        self.customName = customName
        self.displayName = displayName
        self.center = center
    }

    func overlaps(_ start: Date, _ end: Date) -> Bool { startedAt < end && endedAt > start }

    func clipped(from start: Date, to end: Date) -> Self? {
        guard overlaps(start, end) else { return nil }
        return Self(id: id, startedAt: max(start, startedAt), endedAt: min(end, endedAt),
                    status: status, placeID: placeID, place: place,
                    customName: customName, displayName: displayName, center: center)
    }
}

struct DawarichStopNames: Equatable {
    var places: [DawarichStopPlace] = []
    var visits: [DawarichStopVisit] = []
    var days: Set<Date> = []
}

// Constructed once on the landmark queue, never on a ruler frame. Suggestions are not owner names.
struct HistoryStopNamer {
    struct Name {
        let identity: String
        let title: String
        let symbol: String
        let color: String
    }
    private let wifi: [WifiPlace]
    private let visits: [(visit: DawarichStopVisit, name: Name, location: CLLocation)]
    private let latestEnds: [Date]
    private let distance: Double

    init(wifi: [WifiPlace], names: DawarichStopNames, distance: Double) {
        self.wifi = wifi
        self.distance = distance
        let places = Dictionary(names.places.compactMap { place in place.id.map { ($0, place) } },
                                uniquingKeysWith: { _, new in new })
        visits = names.visits.compactMap { visit -> (visit: DawarichStopVisit, name: Name, location: CLLocation)? in
            guard visit.status == "confirmed" else { return nil }
            let title: String, identity: String, location: CLLocation
            // Match only coordinates visible on the visit; a cached place must not undo a privacy mask.
            if let visible = visit.place {
                let place = visit.placeID.flatMap({ places[$0] }) ?? visible
                title = visit.customName ?? place.name
                identity = place.id.map { "dawarich:\($0)" } ?? "visit:\(visit.id)"
                location = visible.location
            } else if let center = visit.center, let name = visit.customName ?? visit.displayName {
                title = name
                identity = "visit:\(visit.id)"
                location = center.location
            } else { return nil }
            return (visit, Name(identity: identity, title: title, symbol: WifiPlace.autoSymbol(for: title), color: "gray"), location)
        }.sorted { $0.visit.startedAt == $1.visit.startedAt ? $0.visit.id < $1.visit.id : $0.visit.startedAt < $1.visit.startedAt }
        var end = Date.distantPast
        latestEnds = visits.map { end = max(end, $0.visit.endedAt); return end }
    }

    func name(at center: CLLocation, from start: Date, to end: Date) -> Name? {
        if let place = wifi.map({ ($0, center.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))) })
            .filter({ $0.1 <= distance }).min(by: { $0.1 < $1.1 })?.0 {
            return Name(identity: "wifi:\(place.id)", title: place.name, symbol: place.symbol, color: place.color)
        }
        let first = HistoryLandmarks.lowerBound(latestEnds.count) { latestEnds[$0] > start }
        let last = HistoryLandmarks.lowerBound(visits.count) { visits[$0].visit.startedAt >= end }
        guard first < last else { return nil }
        var candidates: [Int64: (name: Name, overlap: Double, meters: Double)] = [:]
        for item in visits[first..<last] where item.visit.overlaps(start, end) {
            let meters = center.distance(from: item.location)
            guard meters <= distance else { continue }
            let overlap = min(end, item.visit.endedAt).timeIntervalSince(max(start, item.visit.startedAt))
            // Sum the published day slices, never filling gaps excluded by refreshed empty days.
            if let previous = candidates[item.visit.id] {
                candidates[item.visit.id] = (meters < previous.meters ? item.name : previous.name,
                                             previous.overlap + overlap, min(previous.meters, meters))
            } else {
                candidates[item.visit.id] = (item.name, overlap, meters)
            }
        }
        return candidates.min {
            if $0.value.overlap != $1.value.overlap { return $0.value.overlap > $1.value.overlap }
            if $0.value.meters != $1.value.meters { return $0.value.meters < $1.value.meters }
            return $0.key < $1.key
        }?.value.name
    }
}

extension DawarichHistoryClient {
    // Masking, pagination and these shapes are verified in 1.20.0 and 1.22.0; get() applies that gate.
    func stopPlaces() async throws -> [DawarichStopPlace] {
        var result: [Int64: DawarichStopPlace] = [:]
        var expectedPages: Int?
        var page = 1
        while true {
            let response = try await get("/api/v1/places", [URLQueryItem(name: "mask_privacy_zones", value: "true"),
                URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "per_page", value: "500")])
            let (rows, total) = try stopNamePage(response, page: page, expectedPages: expectedPages)
            expectedPages = total
            for row in rows {
                guard let place = DawarichStopDecoder.place(row), let id = place.id, id > 0 else {
                    throw DawarichHistoryError.invalidResponse
                }
                if let previous = result[id], previous != place { throw DawarichHistoryError.invalidResponse }
                result[id] = place
            }
            if page >= total { break }
            page += 1
        }
        return result.values.sorted { $0.id! < $1.id! }
    }

    func stopVisits(from start: Date, to end: Date) async throws -> [DawarichStopVisit] {
        guard end > start, end.timeIntervalSince(start) <= 31 * 86_400 else { throw DawarichHistoryError.invalidResponse }
        let mask = [URLQueryItem(name: "mask_privacy_zones", value: "true")]
        // /visits filters arrival, not overlap. The masked timeline supplies original arrival times
        // for overnight visits without a whole-account query or sending phone coordinates.
        let timeline = try await get("/api/v1/timeline", Self.range(start, end) + [
            URLQueryItem(name: "distance_unit", value: "km")
        ] + mask)
        let intervals = try Self.decodeTimeline(timeline.data).stops.filter { $0.startedAt < end && $0.endedAt > start }
        let earliest = max(start.addingTimeInterval(-31 * 86_400), min(start, intervals.map(\.startedAt).min() ?? start))
        let arrival = Date(timeIntervalSince1970: floor(earliest.timeIntervalSince1970))
        var visits: [Int64: DawarichStopVisit] = [:]
        for visit in intervals.compactMap(\.visit) where visit.startedAt < arrival && visit.overlaps(start, end) {
            visits[visit.id] = visit
        }
        var expectedPages: Int?
        var page = 1
        while true {
            let response = try await get("/api/v1/visits", Self.range(arrival, end) + mask + [
                URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "per_page", value: "500")
            ])
            let (rows, total) = try stopNamePage(response, page: page, expectedPages: expectedPages)
            expectedPages = total
            for row in rows {
                guard let visit = DawarichStopDecoder.visit(row), visit.startedAt >= arrival, visit.startedAt < end else {
                    throw DawarichHistoryError.invalidResponse
                }
                if let previous = visits[visit.id], previous != visit { throw DawarichHistoryError.invalidResponse }
                if visit.overlaps(start, end) { visits[visit.id] = visit }
            }
            if page >= total { break }
            page += 1
        }
        return visits.values.sorted { $0.startedAt == $1.startedAt ? $0.id < $1.id : $0.startedAt < $1.startedAt }
    }

    private func stopNamePage(_ response: DawarichResponse, page: Int, expectedPages: Int?) throws -> ([[String: Any]], Int) {
        guard let current = response.http.value(forHTTPHeaderField: "X-Current-Page").flatMap(Int.init), current == page,
              let total = response.http.value(forHTTPHeaderField: "X-Total-Pages").flatMap(Int.init),
              (0...100).contains(total), total == 0 ? page == 1 : page <= total,
              expectedPages == nil || expectedPages == total,
              let rows = (try? JSONSerialization.jsonObject(with: response.data)) as? [[String: Any]],
              rows.count <= 500, (total == 0) == rows.isEmpty else { throw DawarichHistoryError.invalidResponse }
        return (rows, total)
    }
}

enum DawarichStopDecoder {
    static func place(_ row: [String: Any], id: Int64? = nil, timeline: Bool = false) -> DawarichStopPlace? {
        guard let name = name(row["name"]),
              let latitude = number(row[timeline ? "lat" : "latitude"]), (-90...90).contains(latitude),
              let longitude = number(row[timeline ? "lng" : "longitude"]), (-180...180).contains(longitude) else { return nil }
        return DawarichStopPlace(id: id ?? integer(row["id"]), name: name,
                                 latitude: latitude, longitude: longitude)
    }

    static func visit(_ row: [String: Any], timeline: Bool = false) -> DawarichStopVisit? {
        guard let id = integer(row[timeline ? "visit_id" : "id"]), id > 0,
              let start = date(row["started_at"]), let end = date(row["ended_at"]), end >= start,
              let status = row["status"] as? String else { return nil }
        let placeID = integer(row["place_id"])
        return DawarichStopVisit(id: id, startedAt: start, endedAt: end, status: status, placeID: placeID,
            place: (row["place"] as? [String: Any]).flatMap { place($0, id: placeID, timeline: timeline) },
            customName: name(row["custom_name"]), displayName: name(row["display_name"]) ?? name(row["name"]),
            center: (row["center"] as? [String: Any]).flatMap(center))
    }

    private static func center(_ row: [String: Any]) -> DawarichStopVisit.Center? {
        guard let latitude = number(row["latitude"]), (-90...90).contains(latitude),
              let longitude = number(row["longitude"]), (-180...180).contains(longitude) else { return nil }
        return .init(latitude: latitude, longitude: longitude)
    }

    private static func name(_ value: Any?) -> String? {
        guard let raw = value as? String else { return nil }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : String(name.prefix(512))
    }

    private static func number(_ value: Any?) -> Double? {
        let number: Double?
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { number = value.doubleValue }
        else if let value = value as? String { number = Double(value) }
        else { number = nil }
        return number.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func integer(_ value: Any?) -> Int64? {
        if let value = value as? String { return Int64(value) }
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return Int64(value.stringValue)
    }

    private static func date(_ value: Any?) -> Date? {
        guard let text = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: text) { return date }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: text)
    }
}
