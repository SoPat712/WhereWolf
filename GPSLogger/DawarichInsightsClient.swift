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

// Probe read-only capabilities: version headers can be absent, customized or older
// than a backported endpoint. A release floor is not evidence of HTTP support.
enum DawarichInsightsEndpoint: Hashable {
    case trackedMonths, digests, overview(Int?), details(Int), countries(Int), cities(Int), residency(Int)
    case places, visits(Int), photos(Int), digest(Int), thumbnail(id: String, source: String)

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

enum DawarichInsightsFailure: Error, Equatable {
    case http(Int), timedOut, decoding, cancelled, network, invalidRequest, missingYear

    var message: String {
        switch self {
        case .http(let status):
            if status == 401 || status == 403 { return "Your server declined access (HTTP \(status))." }
            if status == 422 { return "Your server could not provide this year (HTTP 422)." }
            return "Your server returned HTTP \(status)."
        case .timedOut: return "Your server took too long to respond."
        case .decoding: return "This response could not be read."
        case .cancelled: return "Loading was interrupted."
        case .network: return "Your server could not be reached."
        case .invalidRequest: return "This request could not be made."
        case .missingYear: return "Your server returned a different year."
        }
    }
}

actor DawarichInsightsClient {
    enum Policy { case cacheOnly, refresh(force: Bool) }
    enum Outcome: Equatable {
        case notCached, available, unsupported(Int), failed(DawarichInsightsFailure)
    }
    struct Result<Value> {
        var value: Value?
        var updated: Date?
        var offline = false
        var outcome: Outcome = .notCached
    }
    let connection: DawarichInsightsConnection
    private let cache: DawarichInsightsCache
    private let session: URLSession
    private let redirects = DawarichRequestPolicy()
    private let clock: () -> Date
    private let timeout: TimeInterval

    init(connection: DawarichInsightsConnection, cache: DawarichInsightsCache = .shared,
         configuration: URLSessionConfiguration = .default, clock: @escaping () -> Date = Date.init,
         timeout: TimeInterval = 15) {
        self.connection = connection
        self.cache = cache
        self.clock = clock
        self.timeout = timeout.isFinite && timeout > 0 ? timeout : 15
        let configuration = DawarichTransport.configuration(configuration, requestTimeout: self.timeout,
                                                            resourceTimeout: self.timeout, maximumConnections: 4)
        session = URLSession(configuration: configuration, delegate: redirects, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func read<T: Decodable>(_ endpoint: DawarichInsightsEndpoint, as: T.Type, policy: Policy) async -> Result<T> {
        await load(endpoint, policy: policy) { try JSONDecoder().decode(T.self, from: $0) }
    }

    func thumbnail(_ photo: DawarichInsights.Photo, force: Bool = false) async -> Data? {
        let result: Result<Data> = await load(.thumbnail(id: photo.id, source: photo.source), policy: .refresh(force: force)) { data in
            guard data.count >= 3, data[0] == 0xff, data[1] == 0xd8, data[2] == 0xff else {
                throw DawarichInsightsFailure.decoding
            }
            return data
        }
        return result.value
    }

    private func load<T>(_ endpoint: DawarichInsightsEndpoint, policy: Policy,
                         decode: (Data) throws -> T) async -> Result<T> {
        guard endpoint.isValid else { return Result(outcome: .failed(.invalidRequest)) }
        guard !Task.isCancelled else { return Result(outcome: .failed(.cancelled)) }
        let generation = await cache.generation
        let cached = await cache.read(scope: connection.id, key: endpoint.cacheKey, thumbnail: endpoint.isThumbnail)
        let value = cached.flatMap { $0.unavailable ? nil : try? decode($0.body) }
        var fallback = Result(value: value, updated: value == nil ? nil : cached?.updated,
                              outcome: value == nil ? .notCached : .available)
        // Legacy negative entries included authentication and validation failures. Re-probe
        // those instead of hiding sections for another six hours after an app update.
        if let status = cached?.unavailableStatus, cached?.unavailable == true,
           isUnsupported(status, endpoint: endpoint) { fallback.outcome = .unsupported(status) }
        switch policy {
        case .cacheOnly: return fallback
        case .refresh(let force):
            if !force, let cached, cached.isFresh(at: clock()), fallback.outcome != .notCached { return fallback }
        }
        do {
            var request = connection.server.request(path: endpoint.path, queryItems: endpoint.query, headers: connection.headers)
            request.timeoutInterval = timeout
            if endpoint.isThumbnail { request.setValue("image/jpeg", forHTTPHeaderField: "Accept") }
            let response = try await response(for: request, endpoint: endpoint)
            try Task.checkCancellation()
            guard generation == (await cache.generation) else { throw CancellationError() }
            let status = response.http.statusCode
            if isUnsupported(status, endpoint: endpoint) {
                await cache.write(.init(body: Data(), updated: clock(), unavailable: true, unavailableStatus: status),
                                  scope: connection.id, key: endpoint.cacheKey,
                                  thumbnail: endpoint.isThumbnail, generation: generation)
                return Result(outcome: .unsupported(status))
            }
            guard (200..<300).contains(status) else { throw DawarichInsightsFailure.http(status) }
            let value: T
            do { value = try decode(response.data) }
            catch { throw DawarichInsightsFailure.decoding }
            try Task.checkCancellation()
            let updated = clock()
            guard generation == (await cache.generation) else { throw CancellationError() }
            await cache.write(.init(body: response.data, updated: updated), scope: connection.id,
                              key: endpoint.cacheKey, thumbnail: endpoint.isThumbnail, generation: generation)
            return Result(value: value, updated: updated, outcome: .available)
        } catch {
            guard generation == (await cache.generation) else { return Result(outcome: .failed(.cancelled)) }
            let failure: DawarichInsightsFailure
            if Task.isCancelled || error is CancellationError { failure = .cancelled }
            else if let error = error as? DawarichInsightsFailure { failure = error }
            else if let transport = error as? DawarichRequestError {
                switch transport {
                case .network(let code) where code == .timedOut: failure = .timedOut
                case .invalidResponse: failure = .decoding
                default: failure = .network
                }
            }
            else { failure = .network }
            return Result(value: fallback.value, updated: fallback.updated, offline: failure != .cancelled,
                          outcome: .failed(failure))
        }
    }

    private func isUnsupported(_ status: Int, endpoint: DawarichInsightsEndpoint) -> Bool {
        if [404, 405, 410, 501].contains(status) { return true }
        // Dawarich uses 401 specifically when no photo integration is configured.
        if status == 401 {
            switch endpoint { case .photos, .thumbnail: return true; default: break }
        }
        return false
    }

    private func response(for request: URLRequest, endpoint: DawarichInsightsEndpoint) async throws -> DawarichResponse {
        let limit = endpoint.isThumbnail ? DawarichInsightsCache.thumbnailLimit : DawarichInsightsCache.responseLimit
        let deadline = UInt64(timeout * 1_000_000_000)
        // An absolute deadline also covers URLSession's connection queue and a server
        // that keeps its idle timeout alive by trickling bytes. Cancellation stops the GET.
        return try await withThrowingTaskGroup(of: DawarichResponse.self) { group in
            group.addTask { [session, redirects] in
                try await DawarichTransport.response(for: request, session: session, redirects: redirects, maximumBytes: limit)
            }
            group.addTask {
                try await Task.sleep(nanoseconds: deadline)
                throw DawarichInsightsFailure.timedOut
            }
            defer { group.cancelAll() }
            guard let response = try await group.next() else { throw CancellationError() }
            return response
        }
    }
}
