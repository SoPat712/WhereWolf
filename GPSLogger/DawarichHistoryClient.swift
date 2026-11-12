import Foundation
import CoreFoundation

enum ServerHistoryDayState: String, Codable {
    case notDownloaded, loading, loaded, unavailable
}

struct ServerHistoryInterval: Codable, Equatable, Hashable {
    let startedAt: Date
    let endedAt: Date
    let name: String?
    let visit: DawarichStopVisit?

    init(startedAt: Date, endedAt: Date, name: String? = nil, visit: DawarichStopVisit? = nil) {
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.name = name
        self.visit = visit
    }
}

struct ServerHistoryDay: Codable, Equatable {
    let day: Date
    var pointCount: Int
    /// Exact server range distance, in meters.
    var distance: Double
    var firstTimestamp: Date?
    var lastTimestamp: Date?
    var state: ServerHistoryDayState
    var stops: [ServerHistoryInterval]
    var drives: [ServerHistoryInterval]

    init(day: Date, pointCount: Int = 0, distance: Double = 0,
         firstTimestamp: Date? = nil, lastTimestamp: Date? = nil,
         state: ServerHistoryDayState = .notDownloaded,
         stops: [ServerHistoryInterval] = [], drives: [ServerHistoryInterval] = []) {
        self.day = day
        self.pointCount = pointCount
        self.distance = distance
        self.firstTimestamp = firstTimestamp
        self.lastTimestamp = lastTimestamp
        self.state = state
        self.stops = stops
        self.drives = drives
    }
}

struct ServerHistoryPoint {
    let location: RecordedLocation
    let payload: RecordedPayload?

    init(location: RecordedLocation, payload: RecordedPayload? = nil) {
        self.location = location
        self.payload = payload
    }
}

// Only fixed descriptions escape this layer. URLSession errors can contain request
// URLs; response bodies can contain account, place and coordinate information.
enum DawarichHistoryError: Error, LocalizedError, Equatable {
    case unsupportedVersion, authentication, unavailable, invalidResponse, network, redirectRejected
    case httpStatus(Int)

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion: return "Server history requires a supported Dawarich version (1.20 or later in version 1)."
        case .authentication: return "The server did not accept the configured credentials."
        case .unavailable: return "Server history is unavailable."
        case .invalidResponse: return "The server returned incomplete or invalid history."
        case .network: return "The server could not be reached."
        case .redirectRejected: return "The server redirected history outside its configured address."
        case .httpStatus: return "The server could not complete the history request."
        }
    }
}

/// Read-only history. Uploads, live acquisition, Health and the phone queue never use this client.
final class DawarichHistoryClient {
    private let server: DawarichServer
    private let headers: [String: String]
    private let supported: Bool
    private let transport: DawarichHistoryTransport

    init(server: DawarichServer, headers: [String: String], version: String,
         configuration: URLSessionConfiguration = .default) {
        self.server = server
        self.headers = headers
        supported = Self.supports(version: version)
        transport = DawarichHistoryTransport(root: server.root, configuration: configuration)
    }

    // Verified against tags 1.20.0 and 1.22.0: exact /maps/statistics was added in
    // 1.20.0; both points and timeline accept mask_privacy_zones there. Unknown
    // major versions and prereleases do not imply this contract is available.
    static func supports(version: String) -> Bool {
        DawarichVersion.supports(version, minimum: "1.20.0", policy: .stableMajor(1))
    }

    func cancelAll() async { await transport.cancelAll() }

    func firstPointDate() async throws -> Date? {
        // This is the only unrestricted points query: one first point, never a
        // whole-account download or a guessed oldest date.
        try await pointDate(order: "asc", range: [])
    }

    private func pointDate(order: String, range: [URLQueryItem]) async throws -> Date? {
        let response = try await get("/api/v1/points", range + [
            URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "per_page", value: "1"),
            URLQueryItem(name: "order", value: order), URLQueryItem(name: "mask_privacy_zones", value: "true")
        ])
        let points = try Self.decodePoints(response.data)
        guard points.count <= 1,
              response.http.value(forHTTPHeaderField: "X-Current-Page").flatMap(Int.init) == 1,
              let total = response.http.value(forHTTPHeaderField: "X-Total-Pages").flatMap(Int.init), total >= 0,
              (total == 0) == points.isEmpty else { throw DawarichHistoryError.invalidResponse }
        return points.first?.location.timestamp
    }

    /// Inclusive local calendar dates. Callers can publish month-sized batches.
    func days(from start: Date, through end: Date, calendar: Calendar) async throws -> [ServerHistoryDay] {
        try checkSupported()
        let first = calendar.startOfDay(for: start)
        let last = calendar.startOfDay(for: end)
        guard first <= last else { return [] }
        var result: [ServerHistoryDay] = []
        var chunkStart = first
        while chunkStart <= last {
            try Task.checkCancellation()
            guard let afterLast = calendar.date(byAdding: .day, value: 1, to: last),
                  let nextChunk = calendar.date(byAdding: .day, value: 30, to: chunkStart) else {
                throw DawarichHistoryError.invalidResponse
            }
            // Thirty local days stay below the server's 31*24-hour maximum even
            // over an autumn DST transition. All boundaries include UTC offsets.
            let chunkEnd = min(afterLast, nextChunk)
            let timeline = try await get("/api/v1/timeline", Self.range(chunkStart, chunkEnd) + [
                URLQueryItem(name: "distance_unit", value: "km"),
                URLQueryItem(name: "mask_privacy_zones", value: "true")
            ])
            let intervals = try Self.decodeTimeline(timeline.data)
            var day = chunkStart
            while day < chunkEnd {
                try Task.checkCancellation()
                guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day) else {
                    throw DawarichHistoryError.invalidResponse
                }
                // Timeline dates are in the account's timezone and omit untracked
                // points. Exact statistics supplies the count and distance for the
                // device-local day, including days with no tracks or visits.
                let response = try await get("/api/v1/maps/statistics", Self.range(day, nextDay))
                guard let object = try Self.json(response.data) as? [String: Any],
                      let count = Self.integer(object["points"]), count >= 0, count <= Int64(Int.max),
                      let distance = Self.number(object["distance_meters"]), distance >= 0 else {
                    throw DawarichHistoryError.invalidResponse
                }
                var firstTimestamp: Date?, lastTimestamp: Date?
                if count > 0 {
                    let range = Self.range(day, nextDay)
                    firstTimestamp = try await pointDate(order: "asc", range: range)
                    if count == 1 { lastTimestamp = firstTimestamp }
                    else { lastTimestamp = try await pointDate(order: "desc", range: range) }
                    guard let firstTimestamp, let lastTimestamp, firstTimestamp >= day,
                          lastTimestamp < nextDay, lastTimestamp >= firstTimestamp else {
                        throw DawarichHistoryError.invalidResponse
                    }
                }
                func clipped(_ values: [ServerHistoryInterval]) -> [ServerHistoryInterval] {
                    values.compactMap { value in
                        guard value.startedAt < nextDay && value.endedAt > day else { return nil }
                        return ServerHistoryInterval(startedAt: max(day, value.startedAt),
                                                     endedAt: min(nextDay, value.endedAt), name: value.name, visit: value.visit)
                    }.sorted { $0.startedAt < $1.startedAt }
                }
                result.append(ServerHistoryDay(day: day, pointCount: Int(count), distance: distance,
                                               firstTimestamp: firstTimestamp, lastTimestamp: lastTimestamp,
                                               stops: clipped(intervals.stops), drives: clipped(intervals.drives)))
                day = nextDay
            }
            chunkStart = chunkEnd
        }
        return result
    }

    func points(on date: Date, calendar: Calendar) async throws -> [ServerHistoryPoint] {
        try checkSupported()
        let day = calendar.startOfDay(for: date)
        guard let end = calendar.date(byAdding: .day, value: 1, to: day) else {
            throw DawarichHistoryError.invalidResponse
        }
        var byID: [Int64: ServerHistoryPoint] = [:]
        var expectedPages: Int?
        var page = 1
        while true {
            try Task.checkCancellation()
            let response = try await get("/api/v1/points", Self.range(day, end) + [
                URLQueryItem(name: "page", value: String(page)), URLQueryItem(name: "per_page", value: "1000"),
                URLQueryItem(name: "order", value: "asc"), URLQueryItem(name: "mask_privacy_zones", value: "true")
            ])
            guard let current = response.http.value(forHTTPHeaderField: "X-Current-Page").flatMap(Int.init), current == page,
                  let total = response.http.value(forHTTPHeaderField: "X-Total-Pages").flatMap(Int.init),
                  total >= 0, total <= 100_000, total == 0 ? page == 1 : page <= total,
                  expectedPages == nil || expectedPages == total else { throw DawarichHistoryError.invalidResponse }
            expectedPages = total
            let points = try Self.decodePoints(response.data)
            guard points.count <= 1000, (total == 0) == points.isEmpty else {
                throw DawarichHistoryError.invalidResponse
            }
            for point in points {
                guard point.location.timestamp >= day && point.location.timestamp < end else {
                    throw DawarichHistoryError.invalidResponse
                }
                if let previous = byID[point.location.id] {
                    guard previous.location.timestamp == point.location.timestamp,
                          previous.location.latitude == point.location.latitude,
                          previous.location.longitude == point.location.longitude else {
                        throw DawarichHistoryError.invalidResponse
                    }
                }
                byID[point.location.id] = point
            }
            if page >= total { break }
            page += 1
        }
        try Task.checkCancellation()
        return byID.values.sorted {
            $0.location.timestamp == $1.location.timestamp
                ? $0.location.id > $1.location.id : $0.location.timestamp < $1.location.timestamp
        }
    }

    func checkSupported() throws {
        guard supported else { throw DawarichHistoryError.unsupportedVersion }
    }

    func get(_ path: String, _ query: [URLQueryItem]) async throws -> DawarichResponse {
        try checkSupported()
        try Task.checkCancellation()
        let request = server.request(path: path, queryItems: query, headers: headers)
        return try await transport.response(for: request)
    }

    static func range(_ start: Date, _ exclusiveEnd: Date) -> [URLQueryItem] {
        let formatter = ISO8601DateFormatter()
        // Dawarich stores integer Unix seconds and both filters are inclusive.
        return [URLQueryItem(name: "start_at", value: formatter.string(from: start)),
                URLQueryItem(name: "end_at", value: formatter.string(from: exclusiveEnd.addingTimeInterval(-1)))]
    }

    private static func json(_ data: Data) throws -> Any {
        guard let object = try? JSONSerialization.jsonObject(with: data) else { throw DawarichHistoryError.invalidResponse }
        return object
    }

    private static func number(_ value: Any?) -> Double? {
        let result: Double?
        if let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() { result = value.doubleValue }
        else if let value = value as? String { result = Double(value) }
        else { result = nil }
        return result.flatMap { $0.isFinite ? $0 : nil }
    }

    private static func integer(_ value: Any?) -> Int64? {
        if let value = value as? String { return Int64(value) }
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
        return Int64(value.stringValue)
    }

    private static func decodePoints(_ data: Data) throws -> [ServerHistoryPoint] {
        guard let rows = try json(data) as? [[String: Any]] else { throw DawarichHistoryError.invalidResponse }
        return try rows.map { row in
            // The far-negative range is reserved for the local upload queue.
            guard let id = integer(row["id"]), id > 0, id < (1 << 62),
                  let timestamp = number(row["timestamp"]), timestamp >= 0,
                  let latitude = number(row["latitude"]), (-90...90).contains(latitude),
                  let longitude = number(row["longitude"]), (-180...180).contains(longitude) else {
                throw DawarichHistoryError.invalidResponse
            }
            func nonnegative(_ key: String) -> Double? { number(row[key]).flatMap { $0 >= 0 ? $0 : nil } }
            // Keep only point fields; raw import data and account fields are not
            // required for browsing and must not be copied into this cache.
            let fields = ["id", "timestamp", "latitude", "longitude", "velocity", "accuracy", "altitude",
                          "vertical_accuracy", "tracker_id", "battery", "battery_status", "mode", "ssid"]
            let safe = row.filter { fields.contains($0.key) }
            guard let raw = try? JSONSerialization.data(withJSONObject: safe, options: [.sortedKeys]) else {
                throw DawarichHistoryError.invalidResponse
            }
            let altitude = number(row["vertical_accuracy"]).map { $0 < 0 } == true ? nil : number(row["altitude"])
            let battery = nonnegative("battery").flatMap { $0 <= 100 ? "\(Int($0.rounded()))%" : nil }
            let payload = RecordedPayload(format: "Dawarich", speed: nonnegative("velocity").map { $0 / 3.6 },
                                          accuracy: nonnegative("accuracy"), altitude: altitude,
                                          device: row["tracker_id"] as? String, battery: battery, rawJSON: raw)
            return ServerHistoryPoint(location: RecordedLocation(id: -id, timestamp: Date(timeIntervalSince1970: timestamp),
                                                                 latitude: latitude, longitude: longitude), payload: payload)
        }
    }

    static func decodeTimeline(_ data: Data) throws -> (stops: [ServerHistoryInterval], drives: [ServerHistoryInterval]) {
        guard let object = try json(data) as? [String: Any], let days = object["days"] as? [[String: Any]] else {
            throw DawarichHistoryError.invalidResponse
        }
        let plain = ISO8601DateFormatter()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        func date(_ value: Any?) -> Date? {
            guard let string = value as? String else { return nil }
            return plain.date(from: string) ?? fractional.date(from: string)
        }
        var stops = Set<ServerHistoryInterval>()
        var drives = Set<ServerHistoryInterval>()
        for day in days {
            guard let entries = day["entries"] as? [[String: Any]] else { throw DawarichHistoryError.invalidResponse }
            for entry in entries {
                guard let type = entry["type"] as? String else { throw DawarichHistoryError.invalidResponse }
                guard ["visit", "journey"].contains(type) else { continue }
                guard let start = date(entry["started_at"]), let end = date(entry["ended_at"]), end >= start else {
                    throw DawarichHistoryError.invalidResponse
                }
                let place = entry["place"] as? [String: Any]
                let name = (entry["name"] as? String ?? place?["name"] as? String).flatMap { text -> String? in
                    let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
                    return text.isEmpty ? nil : String(text.prefix(512))
                }
                let interval = ServerHistoryInterval(startedAt: start, endedAt: end, name: name,
                    visit: type == "visit" ? DawarichStopDecoder.visit(entry, timeline: true) : nil)
                if type == "visit" { stops.insert(interval) } else { drives.insert(interval) }
            }
        }
        return (Array(stops), Array(drives))
    }
}

/// Coalesces identical GETs, limits in-flight operations to two, and releases a
/// cancelled caller immediately. The underlying request stops when its last
/// subscriber leaves, including queued work and Retry-After sleeps.
private actor DawarichHistoryTransport {
    private struct Work {
        let generation: UUID
        let request: URLRequest
        var waiters: [UUID: CheckedContinuation<DawarichResponse, Error>]
        var task: Task<Void, Never>?
    }
    private let session: URLSession
    private let redirectDelegate: DawarichRequestPolicy
    private var work: [URL: Work] = [:]
    private var queue: [URL] = []
    private var active = Set<UUID>()
    private var retryNotBefore = Date.distantPast

    init(root: URL, configuration: URLSessionConfiguration) {
        let configuration = DawarichTransport.configuration(configuration, requestTimeout: 30,
                                                            resourceTimeout: 60, maximumConnections: 2)
        let delegate = DawarichRequestPolicy(root: root)
        redirectDelegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit { session.invalidateAndCancel() }

    func response(for request: URLRequest) async throws -> DawarichResponse {
        guard let key = request.url, redirectDelegate.permits(key) else { throw DawarichHistoryError.redirectRejected }
        let waiter = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if var existing = work[key] {
                    existing.waiters[waiter] = continuation
                    work[key] = existing
                } else {
                    work[key] = Work(generation: UUID(), request: request, waiters: [waiter: continuation])
                    queue.append(key)
                }
                schedule()
            }
        } onCancel: {
            Task { await self.cancel(waiter: waiter, key: key) }
        }
    }

    func cancelAll() {
        let previous = work.values
        work.removeAll()
        queue.removeAll()
        for item in previous {
            item.task?.cancel()
            for continuation in item.waiters.values { continuation.resume(throwing: CancellationError()) }
        }
    }

    private func cancel(waiter: UUID, key: URL) {
        guard var item = work[key], let continuation = item.waiters.removeValue(forKey: waiter) else { return }
        continuation.resume(throwing: CancellationError())
        if item.waiters.isEmpty {
            item.task?.cancel()
            work.removeValue(forKey: key)
            queue.removeAll { $0 == key }
        } else { work[key] = item }
    }

    private func schedule() {
        while active.count < 2 && !queue.isEmpty {
            let key = queue.removeFirst()
            guard var item = work[key] else { continue }
            let generation = item.generation
            let request = item.request
            active.insert(generation)
            item.task = Task {
                let result: Result<DawarichResponse, Error>
                do { result = .success(try await self.perform(request)) }
                catch { result = .failure(error) }
                self.complete(key: key, generation: generation, result: result)
            }
            work[key] = item
        }
    }

    private func complete(key: URL, generation: UUID, result: Result<DawarichResponse, Error>) {
        active.remove(generation)
        if let item = work[key], item.generation == generation {
            work.removeValue(forKey: key)
            for continuation in item.waiters.values { continuation.resume(with: result) }
        }
        schedule()
    }

    private func perform(_ request: URLRequest) async throws -> DawarichResponse {
        for attempt in 0..<3 {
            try Task.checkCancellation()
            while retryNotBefore > Date() {
                try await Self.sleep(retryNotBefore.timeIntervalSinceNow)
            }
            do {
                let response = try await DawarichTransport.response(for: request, session: session,
                    redirects: redirectDelegate, maximumBytes: 32 * 1024 * 1024)
                switch response.status(for: .history) {
                case .success: return response
                case .authentication: throw DawarichHistoryError.authentication
                case .redirectRejected: throw DawarichHistoryError.redirectRejected
                case .unavailable: throw DawarichHistoryError.unavailable
                case .retryable:
                    let delay = DawarichHistoryRetry.delay(response: response.http, attempt: attempt)
                    retryNotBefore = max(retryNotBefore, Date().addingTimeInterval(delay))
                    if attempt < 2 { continue }
                case .failure: break
                }
                throw DawarichHistoryError.httpStatus(response.http.statusCode)
            } catch is CancellationError { throw CancellationError() }
            catch let error as DawarichHistoryError { throw error }
            catch let error as DawarichRequestError {
                switch error {
                case .invalidResponse: throw DawarichHistoryError.invalidResponse
                case .redirectRejected: throw DawarichHistoryError.redirectRejected
                case .network(let code):
                    if let code, [.timedOut, .networkConnectionLost, .cannotConnectToHost].contains(code), attempt < 2 {
                        try await Self.sleep(pow(2, Double(attempt)))
                        continue
                    }
                    throw DawarichHistoryError.network
                }
            }
            catch {
                if Task.isCancelled { throw CancellationError() }
                throw DawarichHistoryError.network
            }
        }
        throw DawarichHistoryError.network
    }

    private static func sleep(_ seconds: TimeInterval) async throws {
        // Split very long Retry-After values without overflowing nanoseconds.
        try await Task.sleep(nanoseconds: UInt64(max(0, min(seconds, 3600)) * 1_000_000_000))
    }
}

enum DawarichHistoryRetry {
    static func delay(response: HTTPURLResponse, attempt: Int, now: Date = Date()) -> TimeInterval {
        let exponential = pow(2, Double(min(6, max(0, attempt))))
        guard let header = response.value(forHTTPHeaderField: "Retry-After") else { return exponential }
        if let seconds = Double(header), seconds.isFinite, seconds >= 0 { return max(exponential, seconds) }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: header).map { max(exponential, $0.timeIntervalSince(now)) } ?? exponential
    }
}
