import Foundation
import MapKit

extension DawarichHistoryClient {
    // Verified in 1.20.0 and current Swagger. The index filters overlapping tracks;
    // its vertices have no times, so a track crossing midnight cannot be clipped safely.
    func tracks(on date: Date, calendar: Calendar) async throws -> [[MKMapPoint]] {
        try checkSupported()
        let day = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: day) else {
            throw DawarichHistoryError.invalidResponse
        }
        let formatter = ISO8601DateFormatter()
        var page = 1, lines: [[MKMapPoint]] = [], seen = Set<Int64>()
        repeat {
            try Task.checkCancellation()
            let response = try await get("/api/v1/tracks", [
                .init(name: "start_at", value: formatter.string(from: day)),
                .init(name: "end_at", value: formatter.string(from: end.addingTimeInterval(-1))),
                .init(name: "mask_privacy_zones", value: "true"),
                .init(name: "page", value: String(page)), .init(name: "per_page", value: "500")
            ])
            guard let collection = try? JSONDecoder().decode(DawarichTrackCollection.self, from: response.data),
                  collection.type == "FeatureCollection",
                  response.http.value(forHTTPHeaderField: "X-Current-Page").flatMap(Int.init) == page,
                  let total = response.http.value(forHTTPHeaderField: "X-Total-Pages").flatMap(Int.init),
                  total >= 0, total <= 10_000, collection.features.count <= 500,
                  total >= page || (page == 1 && total == 0 && collection.features.isEmpty) else {
                throw DawarichHistoryError.invalidResponse
            }
            for feature in collection.features {
                guard feature.type == "Feature", let start = Self.trackDate(feature.properties.start_at),
                      let finish = Self.trackDate(feature.properties.end_at), finish >= start else {
                    throw DawarichHistoryError.invalidResponse
                }
                guard seen.insert(feature.properties.id).inserted, start >= day, finish < end else { continue }
                lines += try feature.geometry.lines()
            }
            guard lines.reduce(0, { $0 + $1.count }) <= 250_000 else { throw DawarichHistoryError.unavailable }
            if page >= total { break }
            guard !collection.features.isEmpty else { throw DawarichHistoryError.invalidResponse }
            page += 1
        } while true
        return lines
    }

    private static func trackDate(_ text: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions.insert(.withFractionalSeconds)
        return formatter.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

private struct DawarichTrackCollection: Decodable {
    let type: String
    let features: [Feature]
    struct Feature: Decodable {
        let type: String
        let geometry: Geometry
        let properties: Properties
    }
    struct Properties: Decodable {
        let id: Int64
        let start_at: String
        let end_at: String
    }
    struct Geometry: Decodable {
        let type: String
        let coordinates: [[[Double]]]
        enum CodingKeys: String, CodingKey { case type, coordinates }
        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            type = try values.decode(String.self, forKey: .type)
            switch type {
            case "LineString": coordinates = [try values.decode([[Double]].self, forKey: .coordinates)]
            case "MultiLineString": coordinates = try values.decode([[[Double]]].self, forKey: .coordinates)
            default: throw DawarichHistoryError.invalidResponse
            }
        }

        func lines() throws -> [[MKMapPoint]] {
            try coordinates.map { line in
                try line.map { value in
                    guard value.count >= 2, value[0].isFinite, value[1].isFinite,
                          (-180...180).contains(value[0]), (-90...90).contains(value[1]) else {
                        throw DawarichHistoryError.invalidResponse
                    }
                    return MKMapPoint(CLLocationCoordinate2D(latitude: value[1], longitude: value[0]))
                }
            }.filter { $0.count > 1 }
        }
    }
}
