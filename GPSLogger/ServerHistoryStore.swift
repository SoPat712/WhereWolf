import Foundation
import CryptoKit
import Observation
import CoreLocation
import MapKit

extension Notification.Name {
    static let serverHistoryChanged = Notification.Name("WhereWolfServerHistoryChanged")
    static let serverHistoryNamesChanged = Notification.Name("WhereWolfServerHistoryNamesChanged")
}

struct ServerHistorySnapshot {
    var firstDay: Date?
    var days: [ServerHistoryDay] = []
    var points: [Date: [ServerHistoryPoint]] = [:]
    var loadingDays: Set<Date> = []
    var calendar: Calendar = .current
    var tracks: [Date: [[MKMapPoint]]] = [:]
    var stopNames = DawarichStopNames()
}

enum ServerHistoryRequestSource: Hashable { case ruler, calendar, calendarMonth, navigation, phoneNames }

// The cache is a destination for reads only. No path from here reaches acquisition or the upload queue.
@Observable @MainActor
final class ServerHistoryStore {
    static let shared = ServerHistoryStore()
    private(set) var available = false
    private(set) var storageBytes: Int64 = 0
    private(set) var errorMessage: String?
    private(set) var firstServerDay: Date?
    private(set) var days: [ServerHistoryDay] = []
    @ObservationIgnored private let cache: ServerHistoryCache
    @ObservationIgnored private let names: ServerHistoryNames
    @ObservationIgnored private let configuration: URLSessionConfiguration
    @ObservationIgnored private var client: DawarichHistoryClient?
    @ObservationIgnored private var remoteEnabled = false
    @ObservationIgnored private var clientVersion: String?
    @ObservationIgnored private var isClearing = false
    @ObservationIgnored private var identity: String?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var setup: Task<Void, Never>?
    @ObservationIgnored private var draining: Task<Void, Never>?
    @ObservationIgnored private var indexing: Task<Void, Never>?
    @ObservationIgnored private var indexID = UUID()
    @ObservationIgnored private var requests: [Date: Task<[ServerHistoryPoint], Never>] = [:]
    @ObservationIgnored private var downloaded: [Date: [ServerHistoryPoint]] = [:]
    @ObservationIgnored private var viewed: [Date] = []
    @ObservationIgnored private var retryAfter: [Date: Date] = [:]
    @ObservationIgnored private var calendar = Calendar.current
    @ObservationIgnored private var wantedDays: [ServerHistoryRequestSource: Set<Date>] = [:]
    @ObservationIgnored private var tracks: [Date: [[MKMapPoint]]] = [:]
    @ObservationIgnored private var trackRequest: Task<Void, Never>?
    @ObservationIgnored private var trackRange: ClosedRange<Date>?
    @ObservationIgnored private var trackRequestID = UUID()
    @ObservationIgnored private var tracksRetryAfter = Date.distantPast

    init(cache: ServerHistoryCache = ServerHistoryCache(), configuration: URLSessionConfiguration = .default) {
        self.cache = cache
        self.configuration = configuration
        names = ServerHistoryNames(cache: cache)
        names.changed = { [weak self] in
            guard let self else { return }
            NotificationCenter.default.post(name: .serverHistoryNamesChanged, object: self)
        }
    }

    var snapshot: ServerHistorySnapshot {
        .init(firstDay: firstServerDay, days: days, points: downloaded, loadingDays: Set(requests.keys),
              calendar: calendar, tracks: tracks, stopNames: names.snapshot)
    }

    func daySummary(on date: Date) -> ServerHistoryDay? {
        let day = calendar.startOfDay(for: date)
        let index = HistoryLandmarks.lowerBound(days.count) { days[$0].day >= day }
        return index < days.count && days[index].day == day ? days[index] : nil
    }

    func matches(endpoint: String, token: String, headers: [String: String]) -> Bool {
        if identity == nil, DawarichServer(endpoint: endpoint, token: token) == nil { return true }
        return identity == Self.sourceIdentity(endpoint: endpoint, token: token, headers: headers, calendar: .current)
    }

    private static func sourceIdentity(endpoint: String, token: String, headers: [String: String], calendar: Calendar) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: ["endpoint": endpoint, "token": token,
            "headers": headers, "timezone": calendar.timeZone.identifier], options: .sortedKeys)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func configure(endpoint: String, token: String, headers: [String: String], status: DawarichStatus) {
        guard !isClearing else { return }
        guard let server = DawarichServer(endpoint: endpoint, token: token) else { disconnect(); return }
        let calendar = Calendar.current
        let identity = Self.sourceIdentity(endpoint: endpoint, token: token, headers: headers, calendar: calendar)
        if self.identity != identity {
            disconnect()
            self.identity = identity
            self.calendar = calendar
            let generation = self.generation
            let draining = self.draining
            setup = Task { [weak self] in
                guard let self else { return }
                await draining?.value
                guard self.generation == generation, !Task.isCancelled else { return }
                do {
                    guard try await self.cache.storageBytes() > 0 else { return }
                    try await self.cache.selectSource(identity)
                    let cached = try await self.cache.days()
                    let first = try await self.cache.firstPointDate()
                    guard self.generation == generation, !Task.isCancelled else { return }
                    self.days = cached
                    self.firstServerDay = first.map { calendar.startOfDay(for: $0) } ?? cached.first?.day
                    self.available = self.firstServerDay != nil
                    self.changed()
                    await self.refreshStorageSize()
                } catch { }
            }
            names.configure(client: nil, identity: identity, calendar: calendar, after: setup)
        }
        guard case .dawarich(let version?, true, _) = status else {
            if case .dawarich(_, false, _) = status { disconnect() }
            else if status != .checking {
                remoteEnabled = false
                indexing?.cancel()
                for task in requests.values { task.cancel() }
                cancelTrackRequests()
                names.configure(client: nil, identity: identity, calendar: calendar, after: setup)
            }
            return
        }
        guard DawarichHistoryClient.supports(version: version) else { disconnect(); return }
        if !remoteEnabled { retryAfter.removeAll() }
        remoteEnabled = true
        if clientVersion == version, let indexing, !indexing.isCancelled { return }
        let generation = self.generation
        if client == nil {
            client = DawarichHistoryClient(server: server, headers: headers, version: version, configuration: configuration)
        }
        clientVersion = version
        names.configure(client: client, identity: identity, calendar: calendar, after: setup)
        let previousIndex = indexing
        previousIndex?.cancel()
        let preparation = setup
        let indexID = UUID()
        self.indexID = indexID
        indexing = Task { [weak self] in
            guard let self else { return }
            defer { if self.generation == generation, self.indexID == indexID { self.indexing = nil } }
            await preparation?.value
            await previousIndex?.value
            guard self.generation == generation, !Task.isCancelled, let client = self.client else { return }
            do {
                guard let first = try await client.firstPointDate() else { return }
                guard self.generation == generation, !Task.isCancelled else { return }
                try await self.cache.selectSource(identity)
                try await self.cache.setFirstPointDate(first)
                guard self.generation == generation, !Task.isCancelled else { return }
                self.firstServerDay = calendar.startOfDay(for: first)
                self.available = true
                self.changed()
                // Fill the small index progressively. Cached complete days need no new statistics request.
                let today = calendar.startOfDay(for: Date())
                var start = self.firstServerDay!
                while start <= today {
                    try Task.checkCancellation()
                    let end = min(today, calendar.date(byAdding: .day, value: 29, to: start)!)
                    var day = start
                    var firstMissing: Date?, lastMissing: Date?
                    while day <= end {
                        if self.daySummary(on: day) == nil || day == today {
                            if firstMissing == nil { firstMissing = day }
                            lastMissing = day
                        }
                        day = calendar.date(byAdding: .day, value: 1, to: day)!
                    }
                    if let firstMissing, let lastMissing {
                        let incoming = try await client.days(from: firstMissing, through: lastMissing, calendar: calendar)
                        guard self.generation == generation, !Task.isCancelled else { return }
                        try await self.cache.storeDays(incoming)
                        let saved = try await self.cache.days()
                        guard self.generation == generation, !Task.isCancelled else { return }
                        self.replaceDays(saved)
                        self.changed()
                    }
                    start = calendar.date(byAdding: .day, value: 1, to: end)!
                }
                await self.refreshStorageSize()
            } catch { /* Cached days remain readable when the server is unavailable. */ }
        }
    }

    private func disconnect() {
        let oldNames = names.reset()
        cancelTrackRequests()
        tracks.removeAll(); wantedDays.removeAll(); tracksRetryAfter = .distantPast
        generation &+= 1
        let oldSetup = setup, oldIndex = indexing, oldRequests = Array(requests.values), oldDrain = draining
        setup?.cancel(); indexing?.cancel()
        for task in oldRequests { task.cancel() }
        setup = nil; indexing = nil
        draining = Task {
            await oldDrain?.value
            await oldSetup?.value
            await oldIndex?.value
            for task in oldNames { await task.value }
            for task in oldRequests { _ = await task.value }
        }
        requests.removeAll(); downloaded.removeAll(); viewed.removeAll(); retryAfter.removeAll()
        remoteEnabled = false; client = nil; clientVersion = nil; identity = nil; firstServerDay = nil; days = []; available = false
        changed()
    }

    func requestDays(in range: ClosedRange<Date>?, source: ServerHistoryRequestSource = .ruler) {
        requestStopNames(in: range, source: source)
        guard available else { return }
        var wanted = Set<Date>()
        if let range {
            var day = calendar.startOfDay(for: range.lowerBound)
            let last = min(calendar.startOfDay(for: range.upperBound), calendar.startOfDay(for: Date()))
            while day <= last, wanted.count < 31 {
                if day >= (firstServerDay ?? day) { wanted.insert(day) }
                day = calendar.date(byAdding: .day, value: 1, to: day)!
            }
        }
        wantedDays[source] = wanted
        wanted = Set(wantedDays.values.flatMap { $0 })
        for day in requests.keys.filter({ !wanted.contains($0) }) { requests[day]?.cancel() }
        for day in wanted.sorted() {
            if downloaded[day] != nil { touch(day); continue }
            if let retry = retryAfter[day], retry > Date() { continue }
            _ = pointTask(on: day)
        }
    }

    func points(on date: Date) async -> [RecordedLocation] {
        let day = calendar.startOfDay(for: date)
        requestStopNames(in: day...day, source: .navigation)
        guard available, day >= (firstServerDay ?? day), day <= calendar.startOfDay(for: Date()) else { return [] }
        if let points = downloaded[day] { touch(day); return points.map(\.location) }
        return await pointTask(on: day).value.map(\.location)
    }

    func cancelPointRequests() {
        wantedDays.removeAll()
        for task in requests.values { task.cancel() }
        for source in [ServerHistoryRequestSource.ruler, .calendar, .calendarMonth, .navigation, .phoneNames] {
            names.request(nil, source: source)
        }
    }

    func requestStopNames(in range: ClosedRange<Date>?, source: ServerHistoryRequestSource) {
        names.request(range, source: source)
    }

    func requestTracks(in range: ClosedRange<Date>) {
        guard available, remoteEnabled, let client, Date() >= tracksRetryAfter else { return }
        let first = max(firstServerDay ?? range.lowerBound, calendar.startOfDay(for: range.lowerBound))
        let last = min(calendar.startOfDay(for: range.upperBound), calendar.startOfDay(for: Date()))
        guard first <= last, trackRange != (first...last) else { return }
        cancelTrackRequests()
        trackRange = first...last
        let id = UUID(), generation = generation, calendar = calendar
        trackRequestID = id
        trackRequest = Task { [weak self] in
            guard let self else { return }
            defer { if self.trackRequestID == id { self.trackRequest = nil } }
            var day = first
            do {
                while day <= last {
                    try Task.checkCancellation()
                    if self.downloaded[day] == nil, self.tracks[day] == nil {
                        let lines: [[MKMapPoint]]
                        if self.daySummary(on: day)?.pointCount == 0 { lines = [] }
                        else { lines = try await client.tracks(on: day, calendar: calendar) }
                        guard self.generation == generation, self.trackRequestID == id, !Task.isCancelled else { return }
                        self.tracks[day] = lines
                        // Geometry is disposable; complete point days and totals live on disk.
                        var count = self.tracks.values.reduce(0) { $0 + $1.reduce(0) { $0 + $1.count } }
                        for key in self.tracks.keys.sorted(by: { abs($0.timeIntervalSince(day)) > abs($1.timeIntervalSince(day)) })
                            where count > 250_000 && key != day {
                            count -= self.tracks.removeValue(forKey: key)?.reduce(0) { $0 + $1.count } ?? 0
                        }
                        self.changed()
                    }
                    day = calendar.date(byAdding: .day, value: 1, to: day)!
                }
            } catch {
                if self.trackRequestID == id, !Task.isCancelled {
                    self.trackRange = nil
                    self.tracksRetryAfter = Date().addingTimeInterval(60)
                }
            }
        }
    }

    func cancelTrackRequests() {
        trackRequestID = UUID()
        trackRequest?.cancel(); trackRequest = nil; trackRange = nil
    }

    private func pointTask(on day: Date) -> Task<[ServerHistoryPoint], Never> {
        if let task = requests[day] { return task }
        let generation = generation
        let preparation = setup
        let task = Task { [weak self] () -> [ServerHistoryPoint] in
            guard let self else { return [] }
            defer {
                if self.generation == generation {
                    self.requests.removeValue(forKey: day)
                    if let index = self.days.firstIndex(where: { $0.day == day }), self.days[index].state == .loading {
                        self.days[index].state = .notDownloaded
                    }
                    self.changed()
                }
            }
            await preparation?.value
            guard self.generation == generation, !Task.isCancelled else { return [] }
            do {
                let cached = try await self.cache.points(on: day, touch: true)
                try Task.checkCancellation()
                guard self.generation == generation else { return [] }
                if self.daySummary(on: day)?.state == .loaded || !cached.isEmpty {
                    self.downloaded[day] = cached
                    self.touch(day); self.changed()
                    return cached
                }
                guard self.remoteEnabled, let client = self.client else {
                    self.retryAfter[day] = Date().addingTimeInterval(60)
                    return []
                }
                let needsSummary = self.daySummary(on: day) == nil
                self.setState(.loading, on: day)
                if needsSummary {
                    let summaries = try await client.days(from: day, through: day, calendar: self.calendar)
                    guard self.generation == generation, !Task.isCancelled else { return [] }
                    try await self.cache.storeDays(summaries)
                    let indexed = try await self.cache.days()
                    guard self.generation == generation, !Task.isCancelled else { return [] }
                    self.replaceDays(indexed)
                    self.setState(.loading, on: day)
                }
                let points = try await client.points(on: day, calendar: self.calendar)
                try Task.checkCancellation()
                guard self.generation == generation else { return [] }
                try await self.cache.storePoints(points, on: day)
                let days = try await self.cache.days()
                guard self.generation == generation, !Task.isCancelled else { return [] }
                self.replaceDays(days)
                self.downloaded[day] = points
                self.touch(day); self.changed()
                await self.refreshStorageSize()
                return points
            } catch {
                guard self.generation == generation else { return [] }
                self.setState(.notDownloaded, on: day)
                if !Task.isCancelled { self.retryAfter[day] = Date().addingTimeInterval(60) }
                return []
            }
        }
        requests[day] = task
        return task
    }

    private func replaceDays(_ values: [ServerHistoryDay]) {
        days = values
        let retained = Set(values.filter { $0.state == .loaded }.map(\.day))
        downloaded = downloaded.filter { retained.contains($0.key) }
        viewed.removeAll { !retained.contains($0) }
    }

    private func setState(_ state: ServerHistoryDayState, on day: Date) {
        if let index = days.firstIndex(where: { $0.day == day }) { days[index].state = state }
        changed()
    }

    private func touch(_ day: Date) {
        guard viewed.last != day else { return }
        viewed.removeAll { $0 == day }; viewed.append(day)
        let generation = generation
        Task {
            guard self.generation == generation else { return }
            try? await self.cache.touch(day)
        }
        while viewed.count > 90 { downloaded.removeValue(forKey: viewed.removeFirst()) }
    }

    func clear() async {
        guard !isClearing else { return }
        isClearing = true
        defer { isClearing = false }
        let oldNames = names.reset()
        cancelTrackRequests()
        tracks.removeAll(); wantedDays.removeAll(); tracksRetryAfter = .distantPast
        generation &+= 1
        let oldSetup = setup, oldIndex = indexing, oldRequests = Array(requests.values)
        setup?.cancel(); indexing?.cancel()
        for task in oldRequests { task.cancel() }
        requests.removeAll(); downloaded.removeAll(); viewed.removeAll(); retryAfter.removeAll()
        remoteEnabled = false; client = nil; clientVersion = nil; setup = nil; indexing = nil
        days = []; firstServerDay = nil; available = false; errorMessage = nil
        changed()
        // Await old writers before deletion so cancelled responses cannot recreate the cache.
        await draining?.value
        await oldSetup?.value
        await oldIndex?.value
        for task in oldNames { await task.value }
        for task in oldRequests { _ = await task.value }
        do { try await cache.clear() }
        catch {
            errorMessage = "Downloaded history could not be cleared. Try again."
            days = (try? await cache.days()) ?? []
            firstServerDay = days.first?.day
            available = !days.isEmpty
            changed()
        }
        await refreshStorageSize()
    }

    func refreshStorageSize() async { storageBytes = (try? await cache.storageBytes()) ?? 0 }

    private func changed() { NotificationCenter.default.post(name: .serverHistoryChanged, object: self) }
}

enum ServerHistoryMerge {
    static func loadQueue(completion: @escaping ([ServerHistoryPoint]) -> Void) {
        GLManager.shared().loadQueuedReplayLocations { rows in
            DispatchQueue.global(qos: .utility).async {
                let points = (rows ?? []).compactMap { queuedPoint($0 as NSDictionary) }
                DispatchQueue.main.async { completion(points) }
            }
        }
    }

    static func queuedPoint(_ entry: NSDictionary) -> ServerHistoryPoint? {
        guard let key = entry["key"] as? String, !key.hasPrefix("healthkit:"),
              let record = entry["record"] as? [String: Any],
              let raw = try? JSONSerialization.data(withJSONObject: record) else { return nil }
        let date: Date, latitude: Double, longitude: Double, metadata: [String: Any], format: String
        // NSNumber accepts integer values too, such as OwnTracks' whole-second tst.
        if record["_type"] as? String == "location", let stamp = (record["tst"] as? NSNumber)?.doubleValue,
           let lat = (record["lat"] as? NSNumber)?.doubleValue, let lon = (record["lon"] as? NSNumber)?.doubleValue {
            date = Date(timeIntervalSince1970: stamp); latitude = lat; longitude = lon
            metadata = record; format = "owntracks"
        } else if let properties = record["properties"] as? [String: Any],
                  properties["source"] as? String != "healthkit", properties["action"] == nil, properties["type"] == nil,
                  let stamp = properties["timestamp"] as? String,
                  let geometry = record["geometry"] as? [String: Any], geometry["type"] as? String == "Point",
                  let coordinates = (geometry["coordinates"] as? [NSNumber])?.map(\.doubleValue), coordinates.count >= 2 {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions.insert(.withFractionalSeconds)
            let parsed = formatter.date(from: stamp) ?? ISO8601DateFormatter().date(from: stamp)
            guard let parsed else { return nil }
            date = parsed; latitude = coordinates[1]; longitude = coordinates[0]
            metadata = properties; format = "geojson"
        } else { return nil }
        guard date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 > 0,
              CLLocationCoordinate2DIsValid(.init(latitude: latitude, longitude: longitude)) else { return nil }
        let hash = SHA256.hash(data: Data(key.utf8)).prefix(8).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        let id = Int64.min + Int64(hash & 0x3fff_ffff_ffff_ffff)
        let payload = RecordedPayload(format: format, speed: (metadata["speed"] as? NSNumber)?.doubleValue,
            accuracy: ((metadata["horizontal_accuracy"] ?? metadata["acc"]) as? NSNumber)?.doubleValue,
            altitude: ((metadata["altitude"] ?? metadata["alt"]) as? NSNumber)?.doubleValue, device: nil, battery: nil, rawJSON: raw)
        return .init(location: .init(id: id, timestamp: date, latitude: latitude, longitude: longitude), payload: payload)
    }

    static func points(phone: [RecordedLocation], server: [RecordedLocation], queued: [RecordedLocation] = [],
                       retentionStart: Date) -> [RecordedLocation] {
        let boundary = phone.map(\.timestamp).min() ?? retentionStart
        var ids = Set<Int64>()
        var merged = phone.filter { ids.insert($0.id).inserted }
        let phoneTimes = Set(merged.map(\.timestamp))
        for point in queued where !phoneTimes.contains(point.timestamp) && ids.insert(point.id).inserted {
            merged.append(point)
        }
        let localTimes = Set(merged.map(\.timestamp))
        // A timestamp match selects the phone; distinct fixes within either source remain intact.
        for point in server where point.timestamp < boundary && !localTimes.contains(point.timestamp)
            && ids.insert(point.id).inserted { merged.append(point) }
        return merged.sorted { $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp }
    }
}
