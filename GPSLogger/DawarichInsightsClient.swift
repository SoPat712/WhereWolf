import Foundation

struct DawarichInsightsConnection: Equatable {
    let server: DawarichServer
    let headers: [String: String]
    let version: String?
    let id: String

    init?(status: DawarichStatus, endpoint: String, token: String, headers: [String: String]) {
        guard case .dawarich(let version, true, _) = status,
              let server = DawarichServer(endpoint: endpoint, token: token) else { return nil }
        self.server = server
        self.headers = headers
        self.version = version
        let request = server.healthRequest(headers: headers)
        let values = (request.allHTTPHeaderFields ?? [:]).map { ($0.key.lowercased(), $0.value) }.sorted { $0.0 < $1.0 }
        // An account, proxy header or key change cannot reuse another account's cache.
        id = DawarichInsightsCache.hash((request.url?.absoluteString ?? "") + "\n"
            + values.map { $0.0 + ":" + $0.1 }.joined(separator: "\n") + "\n" + (version ?? ""))
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id }
}

// Freika/dawarich swagger/v1/swagger.yaml, checked 2026-11-12. Release floors follow the
// changelog; 1.2 is the verified baseline for the older visits, places and cities APIs.
enum DawarichInsightsEndpoint: Hashable {
    case trackedMonths, digests, overview(Int?), details(Int), countries(Int), cities(Int), residency(Int)
    case places, visits(Int), photos(Int), digest(Int), thumbnail(id: String, source: String)

    var minimumVersion: String {
        switch self {
        case .trackedMonths: return "0.20.0"
        case .photos, .thumbnail: return "0.19.0"
        case .residency: return "1.5.0"
        case .countries: return "1.15.0"
        case .overview, .details, .digests, .digest, .places, .visits, .cities: return "1.2.0"
        }
    }

    func supports(_ version: String?) -> Bool {
        DawarichVersion.supports(version, minimum: minimumVersion)
    }

    var path: String {
        switch self {
        case .trackedMonths: return "/api/v1/points/tracked_months"
        case .digests: return "/api/v1/digests"
        case .overview: return "/api/v1/insights"
        case .details: return "/api/v1/insights/details"
        case .countries: return "/api/v1/countries/visited"
        case .cities: return "/api/v1/countries/visited_cities"
        case .residency: return "/api/v1/residency"
        case .places: return "/api/v1/places"
        case .visits: return "/api/v1/visits"
        case .photos: return "/api/v1/photos"
        case .digest(let year): return "/api/v1/digests/\(year)"
        case .thumbnail(let id, _):
            let segment = id.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
            return "/api/v1/photos/\(segment)/thumbnail"
        }
    }

    var query: [URLQueryItem] {
        var values: [(String, String)] = []
        switch self {
        case .overview(let year):
            if let year { values.append(("year", String(year))) }
            values.append(("distance_unit", "km"))
        case .details(let year): values = [("year", String(year)), ("distance_unit", "km")]
        case .residency(let year): values = [("year", String(year))]
        case .countries(let year), .visits(let year):
            values = [("start_at", "\(year)-01-01T00:00:00Z"), ("end_at", "\(year)-12-31T23:59:59Z")]
            if case .visits = self { values.append(("mask_privacy_zones", "true")) }
        case .cities(let year): values = [("start_at", "\(year)-01-01"), ("end_at", "\(year)-12-31")]
        case .photos(let year):
            values = [("start_date", "\(year)-01-01"), ("end_date", "\(year)-12-31"), ("mask_privacy_zones", "true")]
        case .places: values = [("mask_privacy_zones", "true")]
        case .digest: values = [("distance_unit", "km")]
        case .thumbnail(_, let source): values = [("source", source)]
        default: break
        }
        return values.map { URLQueryItem(name: $0.0, value: $0.1) }
    }

    var cacheKey: String { path + "?" + query.map { $0.name + "=" + ($0.value ?? "") }.joined(separator: "&") }
    var isThumbnail: Bool { if case .thumbnail = self { return true }; return false }
    var isValid: Bool {
        switch self {
        case .thumbnail(let id, let source):
            return !id.isEmpty && id.count <= 512 && id != "." && id != ".." && ["immich", "photoprism"].contains(source)
        case .overview(let year): return year.map { (1970...9998).contains($0) } ?? true
        case .details(let year), .countries(let year), .cities(let year), .residency(let year),
             .visits(let year), .photos(let year), .digest(let year): return (1970...9998).contains(year)
        default: return true
        }
    }
}

actor DawarichInsightsClient {
    enum Policy { case cacheOnly, refresh(force: Bool) }
    struct Result<Value> {
        var value: Value?
        var updated: Date?
        var offline = false
    }
    let connection: DawarichInsightsConnection
    private let cache: DawarichInsightsCache
    private let session: URLSession
    private let redirects = DawarichRequestPolicy()
    private let clock: () -> Date

    init(connection: DawarichInsightsConnection, cache: DawarichInsightsCache = .shared,
         configuration: URLSessionConfiguration = .default, clock: @escaping () -> Date = Date.init) {
        self.connection = connection
        self.cache = cache
        self.clock = clock
        let configuration = DawarichTransport.configuration(configuration, requestTimeout: 15,
                                                            resourceTimeout: 30, maximumConnections: 4)
        session = URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func read<T: Decodable>(_ endpoint: DawarichInsightsEndpoint, as: T.Type, policy: Policy) async -> Result<T> {
        await load(endpoint, policy: policy) { try JSONDecoder().decode(T.self, from: $0) }
    }

    func thumbnail(_ photo: DawarichInsights.Photo, force: Bool = false) async -> Data? {
        let result: Result<Data> = await load(.thumbnail(id: photo.id, source: photo.source), policy: .refresh(force: force)) { data in
            guard data.count >= 3, data[0] == 0xff, data[1] == 0xd8, data[2] == 0xff else { throw InsightsReadError.invalid }
            return data
        }
        return result.value
    }

    private func load<T>(_ endpoint: DawarichInsightsEndpoint, policy: Policy,
                         decode: (Data) throws -> T) async -> Result<T> {
        guard endpoint.isValid, endpoint.supports(connection.version), !Task.isCancelled else { return Result() }
        let generation = await cache.generation
        let cached = await cache.read(scope: connection.id, key: endpoint.cacheKey, thumbnail: endpoint.isThumbnail)
        let value = cached.flatMap { $0.unavailable ? nil : try? decode($0.body) }
        let fallback = Result(value: value, updated: value == nil ? nil : cached?.updated)
        switch policy {
        case .cacheOnly: return fallback
        case .refresh(let force):
            if !force, let cached, cached.isFresh(at: clock()), cached.unavailable || value != nil { return fallback }
        }
        do {
            var request = connection.server.request(path: endpoint.path, queryItems: endpoint.query, headers: connection.headers)
            if endpoint.isThumbnail { request.setValue("image/jpeg", forHTTPHeaderField: "Accept") }
            let response = try await DawarichTransport.response(for: request, session: session, redirects: redirects,
                maximumBytes: endpoint.isThumbnail ? DawarichInsightsCache.thumbnailLimit : DawarichInsightsCache.responseLimit)
            switch response.status(for: .insights) {
            case .unavailable:
                await cache.write(.init(body: Data(), updated: clock(), unavailable: true), scope: connection.id,
                                  key: endpoint.cacheKey, thumbnail: endpoint.isThumbnail, generation: generation)
                return Result()
            case .success: break
            default: throw InsightsReadError.invalid
            }
            let data = response.data
            let value = try decode(data)
            let updated = clock()
            guard generation == (await cache.generation) else { return Result() }
            await cache.write(.init(body: data, updated: updated), scope: connection.id,
                              key: endpoint.cacheKey, thumbnail: endpoint.isThumbnail, generation: generation)
            return Result(value: value, updated: updated)
        } catch {
            let current = await cache.generation
            if Task.isCancelled || generation != current { return Result() }
            return Result(value: fallback.value, updated: fallback.updated, offline: true)
        }
    }
}

private enum InsightsReadError: Error { case invalid }
