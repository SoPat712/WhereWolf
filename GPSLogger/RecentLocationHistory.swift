import Foundation
import MapKit
import SQLite3

struct RecordedLocation: Identifiable {
    let id: Int64
    let timestamp: Date
    let latitude: Double
    let longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}

struct RecordedPayload: Equatable {
    let format: String
    let speed: Double?
    let accuracy: Double?
    let altitude: Double?
    let device: String?
    let battery: String?
    let rawJSON: Data
    var motion: [String] = []

    var json: String {
        guard let value = try? JSONSerialization.jsonObject(with: rawJSON),
              let pretty = try? JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: pretty, encoding: .utf8) else { return "" }
        return text
    }
}

extension Notification.Name {
    static let recentLocationHistoryChanged = Notification.Name("RecentLocationHistoryChanged")
    static let recentLocationHistoryRetentionChanged = Notification.Name("RecentLocationHistoryRetentionChanged")
}

enum HistoryRetention {
    static let defaultHours = 24
    static let minimumHours = 24
    static let maximumHours = 168
    static let userDefaultsKey = "HistoryRetentionHours"

    static var hours: Int { hours(using: .standard) }
    static var duration: TimeInterval { duration(using: .standard) }

    static func hours(using defaults: UserDefaults) -> Int {
        let stored = (defaults.object(forKey: userDefaultsKey) as? NSNumber)?.intValue
        return validatedHours(stored ?? defaultHours)
    }

    static func hours(defaults: UserDefaults) -> Int {
        hours(using: defaults)
    }

    static func duration(using defaults: UserDefaults) -> TimeInterval {
        TimeInterval(hours(using: defaults)) * 60 * 60
    }

    static func duration(defaults: UserDefaults) -> TimeInterval {
        duration(using: defaults)
    }

    static func validatedHours(_ hours: Int) -> Int {
        min(maximumHours, max(minimumHours, hours))
    }
}

struct HistoryStorageSummary: Equatable {
    let pointCount: Int
    let storageBytes: Int64
    let averagePayloadBytes: Double
}

// A separate copy of accepted upload records. Sending and queue deletion do not use it.
@objc(RecentLocationHistory)
final class RecentLocationHistory: NSObject {
    static let shared = RecentLocationHistory()

    private struct Entry {
        let timestamp: Double
        let latitude: Double
        let longitude: Double
        let format: Int32
        let payload: Data

        init?(_ update: NSDictionary) {
            guard let data = try? JSONSerialization.data(withJSONObject: update),
                  let value = update as? [String: Any] else { return nil }
            if let geometry = value["geometry"] as? [String: Any],
               let coords = geometry["coordinates"] as? [NSNumber], coords.count >= 2,
               let properties = value["properties"] as? [String: Any],
               let date = properties["timestamp"] as? String,
               let parsed = ISO8601DateFormatter().date(from: date) {
                timestamp = parsed.timeIntervalSince1970
                latitude = coords[1].doubleValue
                longitude = coords[0].doubleValue
                format = 0
            } else if let latitude = value["lat"] as? NSNumber,
                      let longitude = value["lon"] as? NSNumber,
                      let timestamp = value["tst"] as? NSNumber,
                      value["_type"] as? String == "location" {
                self.timestamp = timestamp.doubleValue
                self.latitude = latitude.doubleValue
                self.longitude = longitude.doubleValue
                format = 1
            } else {
                return nil
            }
            guard CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: latitude, longitude: longitude)),
                  timestamp.isFinite, timestamp > 0 else { return nil }
            payload = data
        }
    }

    private let queue = DispatchQueue(label: "me.joshpatra.WhereWolf.recent-location-history")
    private let directoryURL: URL?
    private let defaults: UserDefaults
    private let clock: () -> Date
    private var database: OpaquePointer?
    private var lastPrune = 0.0
    private var pruningRevision = 0
    private var todayCache = TodayHistoryCache()
    private let retentionLock = NSLock()
    private var retentionGeneration = 0
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directoryURL: URL? = nil, defaults: UserDefaults = .standard,
         clock: @escaping () -> Date = { Date() }) {
        self.directoryURL = directoryURL
        self.defaults = defaults
        self.clock = clock
        super.init()
    }

    convenience init(directory: URL, defaults: UserDefaults = .standard,
                     clock: @escaping () -> Date = { Date() }) {
        self.init(directoryURL: directory, defaults: defaults, clock: clock)
    }

    @objc(recordUpdate:)
    static func recordUpdate(_ update: NSDictionary) {
        shared.recordUpdate(update)
    }

    @objc(finishPendingWrites:)
    static func finishPendingWrites(_ completion: @escaping () -> Void) {
        shared.queue.async { DispatchQueue.main.async(execute: completion) }
    }

    func recordUpdate(_ update: NSDictionary) {
        guard let entry = Entry(update) else { return }
        queue.async {
            guard self.insert(entry) else { return }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .recentLocationHistoryChanged, object: nil)
            }
        }
    }

    func record(_ update: NSDictionary) {
        recordUpdate(update)
    }

    @objc(setRetentionHours:)
    func setRetentionHours(_ hours: Int) {
        let validated = HistoryRetention.validatedHours(hours)
        let previous = (defaults.object(forKey: HistoryRetention.userDefaultsKey) as? NSNumber)?.intValue
        defaults.set(validated, forKey: HistoryRetention.userDefaultsKey)
        guard previous != validated else { return }
        TrackingTransitionLog.prune()

        retentionLock.lock()
        retentionGeneration &+= 1
        let generation = retentionGeneration
        retentionLock.unlock()
        queue.async {
            guard self.isCurrentRetentionRequest(generation, hours: validated) else { return }
            self.pruneForCurrentRetention()
            guard self.isCurrentRetentionRequest(generation, hours: validated) else { return }
            DispatchQueue.main.async {
                guard self.isCurrentRetentionRequest(generation, hours: validated) else { return }
                NotificationCenter.default.post(name: .recentLocationHistoryRetentionChanged, object: nil)
            }
        }
    }

    func loadTimestamps(completion: @escaping ([Date]) -> Void) {
        queue.async(qos: .utility) {
            var timestamps: [Date] = []
            if let database = self.open() {
                var statement: OpaquePointer?
                if sqlite3_prepare_v2(database, "SELECT timestamp FROM points WHERE timestamp >= ? ORDER BY timestamp, id", -1, &statement, nil) == SQLITE_OK {
                    sqlite3_bind_double(statement, 1, self.clock().timeIntervalSince1970 - self.retentionDuration())
                    while sqlite3_step(statement) == SQLITE_ROW {
                        timestamps.append(Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)))
                    }
                }
                sqlite3_finalize(statement)
            }
            DispatchQueue.main.async { completion(timestamps) }
        }
    }

    func loadStorageSummary(completion: @escaping (HistoryStorageSummary) -> Void) {
        queue.async(qos: .utility) {
            let summary = self.storageSummary()
            DispatchQueue.main.async { completion(summary) }
        }
    }

    func loadTodaySummary(calendar: Calendar = .current, completion: @escaping (TodayHistorySummary?) -> Void) {
        queue.async(qos: .utility) {
            let summary = self.todaySummary(calendar: calendar)
            DispatchQueue.main.async { completion(summary) }
        }
    }

    func load(after id: Int64, completion: @escaping ([RecordedLocation]) -> Void) {
        queue.async(qos: .userInitiated) {
            let points = self.fetch(after: id).sorted {
                $0.timestamp == $1.timestamp ? $0.id < $1.id : $0.timestamp < $1.timestamp
            }
            DispatchQueue.main.async { completion(points) }
        }
    }

    func loadPayload(id: Int64, completion: @escaping (RecordedPayload?) -> Void) {
        loadPayloads(ids: [id]) { completion($0[id]) }
    }

    func loadPayloads(ids: [Int64], completion: @escaping ([Int64: RecordedPayload]) -> Void) {
        queue.async(qos: .userInitiated) {
            let payloads = self.fetchPayloads(ids: ids)
            DispatchQueue.main.async { completion(payloads) }
        }
    }

    func loadTripFixes(completion: @escaping ([RecordedTripFix]) -> Void) {
        queue.async(qos: .utility) {
            let fixes = self.fetchTripFixes()
            DispatchQueue.main.async { completion(fixes) }
        }
    }

    private func isCurrentRetentionRequest(_ generation: Int, hours: Int) -> Bool {
        retentionLock.lock()
        let currentGeneration = retentionGeneration
        retentionLock.unlock()
        return currentGeneration == generation && HistoryRetention.hours(using: defaults) == hours
    }

    private func retentionDuration() -> TimeInterval {
        HistoryRetention.duration(using: defaults)
    }

    private func storageDirectoryURL() -> URL? {
        if let directoryURL { return directoryURL }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Recent Locations", isDirectory: true)
    }

    private func databaseURL() -> URL? {
        storageDirectoryURL()?.appendingPathComponent("history.sqlite")
    }

    private func open() -> OpaquePointer? {
        if let database { return database }
        let manager = FileManager.default
        guard let directory = storageDirectoryURL() else { return nil }
        do {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                      ofItemAtPath: directory.path)
        } catch {
            NSLog("Recent location storage unavailable: %@", error.localizedDescription)
            return nil
        }
        let url = directory.appendingPathComponent("history.sqlite")
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            return nil
        }
        sqlite3_busy_timeout(handle, 3000)
        // The incremental loader needs IDs to remain unique after all old rows expire.
        let table = """
        CREATE TABLE IF NOT EXISTS points (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            timestamp REAL NOT NULL,
            latitude REAL NOT NULL,
            longitude REAL NOT NULL,
            format INTEGER NOT NULL,
            payload BLOB NOT NULL
        );
        """
        let schema = """
        PRAGMA journal_mode=WAL;
        PRAGMA synchronous=NORMAL;
        \(table)
        CREATE INDEX IF NOT EXISTS points_timestamp ON points(timestamp);
        """
        guard sqlite3_exec(handle, schema, nil, nil, nil) == SQLITE_OK else {
            NSLog("Recent location schema failed: %s", sqlite3_errmsg(handle))
            sqlite3_close(handle)
            return nil
        }
        var autoincrement: Int32 = 0
        guard sqlite3_table_column_metadata(handle, nil, "points", "id", nil, nil,
                                            nil, nil, &autoincrement) == SQLITE_OK else {
            sqlite3_close(handle)
            return nil
        }
        if autoincrement == 0 {
            let migration = """
            BEGIN IMMEDIATE;
            ALTER TABLE points RENAME TO legacy_points;
            \(table)
            INSERT INTO points SELECT * FROM legacy_points;
            DROP TABLE legacy_points;
            CREATE INDEX points_timestamp ON points(timestamp);
            COMMIT;
            """
            guard sqlite3_exec(handle, migration, nil, nil, nil) == SQLITE_OK else {
                NSLog("Recent location migration failed: %s", sqlite3_errmsg(handle))
                sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
                sqlite3_close(handle)
                return nil
            }
        }
        database = handle
        return handle
    }

    private func insert(_ entry: Entry) -> Bool {
        guard let database = open() else { return false }
        let sql = "INSERT INTO points (timestamp, latitude, longitude, format, payload) VALUES (?, ?, ?, ?, ?)"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        let payloadStatus = entry.payload.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, 5, bytes.baseAddress, Int32(bytes.count), Self.transient)
        }
        guard sqlite3_bind_double(statement, 1, entry.timestamp) == SQLITE_OK,
              sqlite3_bind_double(statement, 2, entry.latitude) == SQLITE_OK,
              sqlite3_bind_double(statement, 3, entry.longitude) == SQLITE_OK,
              sqlite3_bind_int(statement, 4, entry.format) == SQLITE_OK,
              payloadStatus == SQLITE_OK else {
            NSLog("Recent location bind failed: %s", sqlite3_errmsg(database))
            return false
        }
        guard sqlite3_step(statement) == SQLITE_DONE else {
            NSLog("Recent location insert failed: %s", sqlite3_errmsg(database))
            return false
        }
        let now = clock().timeIntervalSince1970
        if now - lastPrune > 3600 {
            if prune(database, before: now - retentionDuration()) { lastPrune = now }
        }
        return true
    }

    @discardableResult
    private func prune(_ database: OpaquePointer, before cutoff: Double) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM points WHERE timestamp < ?", -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_double(statement, 1, cutoff) == SQLITE_OK else { return false }
        guard sqlite3_step(statement) == SQLITE_DONE else { return false }
        if sqlite3_changes(database) > 0,
           todayCache.oldestTimestamp.map({ $0.timeIntervalSince1970 < cutoff }) == true {
            pruningRevision &+= 1
        }
        return true
    }

    private func pruneForCurrentRetention() {
        guard let database = open() else { return }
        let now = clock().timeIntervalSince1970
        if prune(database, before: now - retentionDuration()) { lastPrune = now }
    }

    private func fetch(after id: Int64) -> [RecordedLocation] {
        guard let database = open() else { return [] }
        let now = clock().timeIntervalSince1970
        let cutoff = now - retentionDuration()
        if now - lastPrune >= 3600 {
            if prune(database, before: cutoff) { lastPrune = now }
        }
        let sql = "SELECT id, timestamp, latitude, longitude FROM points WHERE id > ? AND timestamp >= ? ORDER BY id"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, id)
        sqlite3_bind_double(statement, 2, cutoff)
        var points: [RecordedLocation] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            points.append(RecordedLocation(
                id: sqlite3_column_int64(statement, 0),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                latitude: sqlite3_column_double(statement, 2),
                longitude: sqlite3_column_double(statement, 3)
            ))
        }
        return points
    }

    private func todaySummary(calendar: Calendar) -> TodayHistorySummary? {
        guard let database = open() else { return nil }
        let now = clock()
        let cutoff = now.addingTimeInterval(-retentionDuration())
        if now.timeIntervalSince1970 - lastPrune >= 3600 {
            if prune(database, before: cutoff.timeIntervalSince1970) { lastPrune = now.timeIntervalSince1970 }
        }
        todayCache.prepare(now: now, calendar: calendar, pruningRevision: pruningRevision, cutoff: cutoff)
        let day = TodayWindow(containing: now, calendar: calendar)
        // The second range admits future-dated rows as the clock reaches them, even when a
        // later ID has already been counted. Both ranges load geometry only within today.
        let sql = """
        SELECT id, timestamp, latitude, longitude FROM points
        WHERE id > ? AND timestamp >= ? AND timestamp < ? AND timestamp <= ?
        UNION ALL
        SELECT id, timestamp, latitude, longitude FROM points
        WHERE id <= ? AND timestamp >= ? AND timestamp < ? AND timestamp <= ? AND timestamp > ?
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return nil }
        defer { sqlite3_finalize(statement) }
        let start = max(day.start, cutoff).timeIntervalSince1970
        sqlite3_bind_int64(statement, 1, todayCache.lastArchivedID)
        sqlite3_bind_double(statement, 2, start)
        sqlite3_bind_double(statement, 3, day.end.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, now.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 5, todayCache.lastArchivedID)
        sqlite3_bind_double(statement, 6, start)
        sqlite3_bind_double(statement, 7, day.end.timeIntervalSince1970)
        sqlite3_bind_double(statement, 8, now.timeIntervalSince1970)
        sqlite3_bind_double(statement, 9, todayCache.readThrough.timeIntervalSince1970)
        var additions: [RecordedLocation] = []
        var result = sqlite3_step(statement)
        while result == SQLITE_ROW {
            additions.append(RecordedLocation(
                id: sqlite3_column_int64(statement, 0),
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                latitude: sqlite3_column_double(statement, 2), longitude: sqlite3_column_double(statement, 3)))
            result = sqlite3_step(statement)
        }
        guard result == SQLITE_DONE else { return nil }

        var latest: OpaquePointer?
        guard sqlite3_prepare_v2(database,
                                "SELECT timestamp FROM points WHERE timestamp >= ? AND timestamp <= ? ORDER BY timestamp DESC LIMIT 1",
                                -1, &latest, nil) == SQLITE_OK, let latest else { return nil }
        defer { sqlite3_finalize(latest) }
        sqlite3_bind_double(latest, 1, cutoff.timeIntervalSince1970)
        sqlite3_bind_double(latest, 2, now.timeIntervalSince1970)
        let latestResult = sqlite3_step(latest)
        guard latestResult == SQLITE_ROW || latestResult == SQLITE_DONE else { return nil }
        let lastFix = latestResult == SQLITE_ROW
            ? Date(timeIntervalSince1970: sqlite3_column_double(latest, 0)) : nil
        todayCache.extend(additions, through: now)
        return todayCache.summary(lastFixDate: lastFix)
    }

    private func storageSummary() -> HistoryStorageSummary {
        guard let database = open() else { return HistoryStorageSummary(pointCount: 0, storageBytes: 0, averagePayloadBytes: 0) }
        let now = clock().timeIntervalSince1970
        if prune(database, before: now - retentionDuration()) {
            lastPrune = now
        }

        var statement: OpaquePointer?
        var pointCount = 0
        var averagePayloadBytes = 0.0
        if sqlite3_prepare_v2(database,
                              "SELECT COUNT(*), COALESCE(AVG(length(payload)), 0) FROM points",
                              -1, &statement, nil) == SQLITE_OK,
           let statement {
            if sqlite3_step(statement) == SQLITE_ROW {
                pointCount = Int(sqlite3_column_int64(statement, 0))
                averagePayloadBytes = sqlite3_column_double(statement, 1)
            }
            sqlite3_finalize(statement)
        }

        let manager = FileManager.default
        let urls: [URL] = databaseURL().map { database in
            [database,
             URL(fileURLWithPath: database.path + "-wal"),
             URL(fileURLWithPath: database.path + "-shm")]
        } ?? []
        let storageBytes = urls.reduce(Int64(0)) { total, url in
            let attributes = try? manager.attributesOfItem(atPath: url.path)
            return total + ((attributes?[.size] as? NSNumber)?.int64Value ?? 0)
        }
        return HistoryStorageSummary(pointCount: pointCount, storageBytes: storageBytes,
                                      averagePayloadBytes: averagePayloadBytes.isFinite ? averagePayloadBytes : 0)
    }

    private func fetchPayloads(ids: [Int64]) -> [Int64: RecordedPayload] {
        guard !ids.isEmpty, let database = open() else { return [:] }
        let parameters = Array(repeating: "?", count: ids.count).joined(separator: ",")
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT id, format, payload FROM points WHERE id IN (\(parameters))", -1, &statement, nil) == SQLITE_OK,
              let statement else { return [:] }
        defer { sqlite3_finalize(statement) }
        for (index, id) in ids.enumerated() { sqlite3_bind_int64(statement, Int32(index + 1), id) }
        var result: [Int64: RecordedPayload] = [:]
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(statement, 2) else { continue }
            let data = Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 2)))
            if let payload = decodePayload(data, format: sqlite3_column_int(statement, 1)) {
                result[sqlite3_column_int64(statement, 0)] = payload
            }
        }
        return result
    }

    // Only GeoJSON records carry a trip tag; the text match skips decoding every other payload.
    private func fetchTripFixes() -> [RecordedTripFix] {
        guard let database = open() else { return [] }
        let sql = """
        SELECT timestamp, latitude, longitude, payload FROM points
        WHERE timestamp >= ? AND format != 1 AND CAST(payload AS TEXT) LIKE '%"trip_id"%' ORDER BY timestamp, id
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, clock().timeIntervalSince1970 - retentionDuration())
        var fixes: [RecordedTripFix] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let blob = sqlite3_column_blob(statement, 3),
                  let value = try? JSONSerialization.jsonObject(
                      with: Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 3)))) as? [String: Any],
                  let properties = value["properties"] as? [String: Any],
                  let trip = properties["trip_id"] as? String else { continue }
            func number(_ key: String, _ fallback: Double) -> Double {
                (properties[key] as? NSNumber)?.doubleValue ?? fallback
            }
            fixes.append(RecordedTripFix(
                trip: trip, mode: properties["trip_mode"] as? String ?? "",
                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                latitude: sqlite3_column_double(statement, 1), longitude: sqlite3_column_double(statement, 2),
                speed: number("speed", -1), speedAccuracy: number("speed_accuracy", -1),
                altitude: number("altitude", 0), verticalAccuracy: number("vertical_accuracy", -1)))
        }
        return fixes
    }

    // A negative vertical accuracy means CoreLocation has no valid altitude for the fix.
    private static func altitude(_ properties: [String: Any]) -> Double? {
        if let accuracy = (properties["vertical_accuracy"] as? NSNumber)?.doubleValue, accuracy < 0 { return nil }
        return (properties["altitude"] as? NSNumber)?.doubleValue
    }

    func decodePayload(_ data: Data, format: Int32) -> RecordedPayload? {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if format == 1 {
            let battery = (value["batt"] as? NSNumber)?.intValue
            return RecordedPayload(
                format: "OwnTracks",
                speed: nil,
                accuracy: Self.nonnegative(value["acc"]),
                altitude: nil,
                device: (value["topic"] as? String).flatMap { $0.isEmpty ? nil : $0 },
                battery: battery.flatMap { $0 >= 0 ? "\($0)%" : nil },
                rawJSON: data
            )
        }
        let properties = value["properties"] as? [String: Any] ?? [:]
        let battery = Self.nonnegative(properties["battery_level"])
        return RecordedPayload(
            format: "GeoJSON",
            speed: Self.nonnegative(properties["speed"]),
            accuracy: Self.nonnegative(properties["horizontal_accuracy"]),
            altitude: Self.altitude(properties),
            device: (properties["device_id"] as? String).flatMap { $0.isEmpty ? nil : $0 },
            battery: battery.map { "\(Int(($0 * 100).rounded()))%" },
            rawJSON: data,
            motion: properties["motion"] as? [String] ?? []
        )
    }

    private static func nonnegative(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }

    deinit {
        if let database { sqlite3_close(database) }
    }
}
