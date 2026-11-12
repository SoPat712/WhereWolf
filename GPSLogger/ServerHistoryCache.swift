import Foundation
import SQLite3

enum ServerHistoryCacheError: Error, LocalizedError {
    case storage, invalidSource, sourceNotSelected, invalidData
    var errorDescription: String? { "The downloaded server history cache is unavailable." }
}

/// A disposable, backup-excluded copy. Day metadata outlives point eviction;
/// there is no connection to LOLDatabase, RecentLocationHistory or Health.
actor ServerHistoryCache {
    private let directoryURL: URL?
    private let maximumPointDays: Int
    private var database: OpaquePointer?
    private var selectedSource: String?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(directoryURL: URL? = nil, maximumPointDays: Int = 90) {
        self.directoryURL = directoryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Server History", isDirectory: true)
        self.maximumPointDays = max(0, maximumPointDays)
    }

    deinit { if let database { sqlite3_close(database) } }

    /// The caller hashes configuration and timezone; never store a server URL,
    /// key or header here. A source change removes the preceding account's data.
    func selectSource(_ identity: String) throws {
        guard identity.count == 64, identity.allSatisfy({ $0.isASCII && $0.isHexDigit }) else {
            throw ServerHistoryCacheError.invalidSource
        }
        let handle = try open()
        let old = try statement(handle, "SELECT identity FROM source LIMIT 1") { statement -> String? in
            let status = sqlite3_step(statement)
            guard status == SQLITE_ROW || status == SQLITE_DONE else { throw ServerHistoryCacheError.storage }
            return status == SQLITE_ROW ? Self.string(statement, 0) : nil
        }
        if old != identity {
            try transaction(handle) {
                try execute(handle, "DELETE FROM points; DELETE FROM days; DELETE FROM stop_names; DELETE FROM source;")
                try statement(handle, "INSERT INTO source (identity) VALUES (?)") { statement in
                    try Self.bind(identity, to: statement, at: 1)
                    try Self.finish(statement)
                }
            }
            try compact(handle)
        }
        selectedSource = identity
    }

    func days() throws -> [ServerHistoryDay] {
        let handle = try selectedDatabase()
        return try statement(handle, "SELECT day, point_count, distance, first_timestamp, last_timestamp, state, stops, drives FROM days ORDER BY day") { statement in
            var values: [ServerHistoryDay] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return values }
                guard status == SQLITE_ROW else { throw ServerHistoryCacheError.storage }
                values.append(try Self.day(statement))
            }
        }
    }

    func firstPointDate() throws -> Date? {
        try statement(selectedDatabase(), "SELECT first_timestamp FROM source LIMIT 1") { statement in
            let status = sqlite3_step(statement)
            guard status == SQLITE_ROW || status == SQLITE_DONE else { throw ServerHistoryCacheError.storage }
            guard status == SQLITE_ROW, sqlite3_column_type(statement, 0) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(statement, 0))
        }
    }

    func setFirstPointDate(_ date: Date) throws {
        guard date.timeIntervalSince1970.isFinite, date.timeIntervalSince1970 >= 0 else { throw ServerHistoryCacheError.invalidData }
        try statement(selectedDatabase(), "UPDATE source SET first_timestamp = ?") { statement in
            sqlite3_bind_double(statement, 1, date.timeIntervalSince1970)
            try Self.finish(statement)
        }
    }

    func storeDays(_ values: [ServerHistoryDay]) throws {
        let handle = try selectedDatabase()
        try transaction(handle) {
            for value in values {
                guard value.day.timeIntervalSince1970.isFinite, value.pointCount >= 0,
                      value.distance.isFinite, value.distance >= 0 else { throw ServerHistoryCacheError.invalidData }
                let previous = try findDay(value.day, handle: handle)
                var value = value
                if let previous, previous.pointCount == value.pointCount {
                    value.firstTimestamp = value.firstTimestamp ?? previous.firstTimestamp
                    value.lastTimestamp = value.lastTimestamp ?? previous.lastTimestamp
                }
                // Network metadata cannot mark an undownloaded day as loaded.
                // A changed count invalidates its old geometry atomically.
                if let previous, previous.state == .loaded, previous.pointCount == value.pointCount {
                    value.state = .loaded
                } else {
                    if previous?.state == .loaded { try deletePoints(on: value.day, handle: handle) }
                    value.state = value.state == .unavailable ? .unavailable : .notDownloaded
                }
                try writeDay(value, handle: handle)
            }
        }
        try protectFiles()
    }

    func points(on day: Date, touch: Bool = true) throws -> [ServerHistoryPoint] {
        let handle = try selectedDatabase()
        guard try findDay(day, handle: handle)?.state == .loaded else { return [] }
        let result = try statement(handle, "SELECT id, timestamp, latitude, longitude, payload FROM points WHERE day = ? ORDER BY timestamp, id DESC") { statement in
            sqlite3_bind_double(statement, 1, day.timeIntervalSince1970)
            var result: [ServerHistoryPoint] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return result }
                guard status == SQLITE_ROW else { throw ServerHistoryCacheError.storage }
                let location = RecordedLocation(id: sqlite3_column_int64(statement, 0),
                                                timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 1)),
                                                latitude: sqlite3_column_double(statement, 2), longitude: sqlite3_column_double(statement, 3))
                let payload: RecordedPayload?
                if let data = Self.data(statement, 4) {
                    guard let decoded = try? JSONDecoder().decode(StoredPayload.self, from: data) else {
                        throw ServerHistoryCacheError.invalidData
                    }
                    payload = decoded.payload
                } else { payload = nil }
                result.append(ServerHistoryPoint(location: location, payload: payload))
            }
        }
        if touch { try markViewed(day, handle: handle) }
        return result
    }

    /// Refresh a day already held in memory without decoding its disk payloads.
    func touch(_ day: Date) throws {
        guard let database else { return }
        try markViewed(day, handle: database)
    }

    /// Called only after every page succeeds. One transaction replaces a day;
    /// failure or cancellation before this call leaves the existing day intact.
    func storePoints(_ points: [ServerHistoryPoint], on day: Date) throws {
        let handle = try selectedDatabase()
        try Task.checkCancellation()
        try transaction(handle) {
            try deletePoints(on: day, handle: handle)
            var seen = Set<Int64>()
            for point in points {
                try Task.checkCancellation()
                let location = point.location
                guard location.id < 0, location.id > -(1 << 62), seen.insert(location.id).inserted,
                      location.timestamp.timeIntervalSince1970.isFinite,
                      location.latitude.isFinite, (-90...90).contains(location.latitude),
                      location.longitude.isFinite, (-180...180).contains(location.longitude) else {
                    throw ServerHistoryCacheError.invalidData
                }
                let data: Data?
                if let payload = point.payload {
                    guard let encoded = try? JSONEncoder().encode(StoredPayload(payload)) else {
                        throw ServerHistoryCacheError.invalidData
                    }
                    data = encoded
                } else { data = nil }
                try statement(handle, "INSERT INTO points (day, id, timestamp, latitude, longitude, payload) VALUES (?, ?, ?, ?, ?, ?)") { statement in
                    sqlite3_bind_double(statement, 1, day.timeIntervalSince1970)
                    sqlite3_bind_int64(statement, 2, location.id)
                    sqlite3_bind_double(statement, 3, location.timestamp.timeIntervalSince1970)
                    sqlite3_bind_double(statement, 4, location.latitude)
                    sqlite3_bind_double(statement, 5, location.longitude)
                    try Self.bind(data, to: statement, at: 6)
                    try Self.finish(statement)
                }
            }
            var summary = try findDay(day, handle: handle) ?? ServerHistoryDay(day: day)
            summary.pointCount = points.count
            summary.firstTimestamp = points.map(\.location.timestamp).min()
            summary.lastTimestamp = points.map(\.location.timestamp).max()
            summary.state = .loaded
            try writeDay(summary, handle: handle)
            try markViewed(day, handle: handle)
            try evict(handle)
            try Task.checkCancellation()
        }
        try compact(handle)
        try protectFiles()
    }

    func clear() throws {
        if let database {
            guard sqlite3_close(database) == SQLITE_OK else { throw ServerHistoryCacheError.storage }
            self.database = nil
        }
        guard let directoryURL else { return }
        for name in Self.fileNames {
            let url = directoryURL.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                do { try FileManager.default.removeItem(at: url) }
                catch { throw ServerHistoryCacheError.storage }
            }
        }
    }

    func stopPlaces() throws -> [DawarichStopPlace] {
        try readStopNames(key: "places", as: [DawarichStopPlace].self) ?? []
    }

    func storeStopPlaces(_ places: [DawarichStopPlace]) throws {
        try writeStopNames(places, key: "places")
    }

    func stopVisits(on day: Date) throws -> [DawarichStopVisit]? {
        try readStopNames(key: "visits:\(day.timeIntervalSince1970)", as: [DawarichStopVisit].self)
    }

    func storeStopVisits(_ visits: [DawarichStopVisit], on day: Date) throws {
        try writeStopNames(visits, key: "visits:\(day.timeIntervalSince1970)")
    }

    private func readStopNames<T: Decodable>(key: String, as: T.Type) throws -> T? {
        let handle = try selectedDatabase()
        let value = try statement(handle, "SELECT body FROM stop_names WHERE key = ?") { statement -> T? in
            try Self.bind(key, to: statement, at: 1)
            let status = sqlite3_step(statement)
            guard status == SQLITE_ROW || status == SQLITE_DONE else { throw ServerHistoryCacheError.storage }
            guard status == SQLITE_ROW else { return nil }
            guard let data = Self.data(statement, 0), let value = try? JSONDecoder().decode(T.self, from: data) else {
                throw ServerHistoryCacheError.invalidData
            }
            return value
        }
        if value != nil {
            try statement(handle, "UPDATE stop_names SET viewed = (SELECT COALESCE(MAX(viewed), 0) + 1 FROM stop_names) WHERE key = ?") {
                try Self.bind(key, to: $0, at: 1)
                try Self.finish($0)
            }
        }
        return value
    }

    private func writeStopNames<T: Encodable>(_ value: T, key: String) throws {
        let handle = try selectedDatabase()
        let body = try JSONEncoder().encode(value)
        try Task.checkCancellation()
        try transaction(handle) {
            try statement(handle, """
                INSERT INTO stop_names (key, body, viewed) VALUES (?, ?, (SELECT COALESCE(MAX(viewed), 0) + 1 FROM stop_names))
                ON CONFLICT(key) DO UPDATE SET body=excluded.body, viewed=excluded.viewed
                """) {
                try Self.bind(key, to: $0, at: 1)
                try Self.bind(body, to: $0, at: 2)
                try Self.finish($0)
            }
            try statement(handle, "DELETE FROM stop_names WHERE key IN (SELECT key FROM stop_names WHERE key != 'places' ORDER BY viewed DESC LIMIT -1 OFFSET ?)") {
                sqlite3_bind_int64($0, 1, Int64(maximumPointDays))
                try Self.finish($0)
            }
            try Task.checkCancellation()
        }
        try compact(handle)
        try protectFiles()
    }

    func storageBytes() throws -> Int64 {
        guard let directoryURL else { return 0 }
        return try Self.fileNames.reduce(0) { sum, name in
            let url = directoryURL.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { return sum }
            do {
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                return sum + ((attributes[.size] as? NSNumber)?.int64Value ?? 0)
            } catch { throw ServerHistoryCacheError.storage }
        }
    }

    private static let fileNames = ["history.sqlite", "history.sqlite-wal", "history.sqlite-shm", "history.sqlite-journal"]

    private func selectedDatabase() throws -> OpaquePointer {
        guard let selectedSource else { throw ServerHistoryCacheError.sourceNotSelected }
        if let database { return database }
        try selectSource(selectedSource)
        guard let database else { throw ServerHistoryCacheError.storage }
        return database
    }

    private func open() throws -> OpaquePointer {
        if let database { return database }
        guard let directoryURL else { throw ServerHistoryCacheError.storage }
        do {
            try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true,
                                                   attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try protectFiles()
        } catch { throw ServerHistoryCacheError.storage }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(directoryURL.appendingPathComponent("history.sqlite").path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let handle else {
            if let handle { sqlite3_close(handle) }
            throw ServerHistoryCacheError.storage
        }
        do {
            sqlite3_busy_timeout(handle, 3000)
            try execute(handle, """
                PRAGMA auto_vacuum=INCREMENTAL;
                PRAGMA journal_mode=WAL;
                PRAGMA synchronous=NORMAL;
                PRAGMA secure_delete=ON;
                CREATE TABLE IF NOT EXISTS source (identity TEXT NOT NULL, first_timestamp REAL);
                CREATE TABLE IF NOT EXISTS days (
                    day REAL PRIMARY KEY, point_count INTEGER NOT NULL, distance REAL NOT NULL,
                    first_timestamp REAL, last_timestamp REAL, state TEXT NOT NULL,
                    stops BLOB NOT NULL, drives BLOB NOT NULL, last_viewed INTEGER NOT NULL DEFAULT 0
                );
                CREATE TABLE IF NOT EXISTS points (
                    day REAL NOT NULL, id INTEGER NOT NULL, timestamp REAL NOT NULL,
                    latitude REAL NOT NULL, longitude REAL NOT NULL, payload BLOB,
                    PRIMARY KEY (day, id)
                );
                CREATE INDEX IF NOT EXISTS points_day_time ON points(day, timestamp);
                CREATE TABLE IF NOT EXISTS stop_names (key TEXT PRIMARY KEY, body BLOB NOT NULL, viewed INTEGER NOT NULL);
                """)
            try protectFiles()
            database = handle
            return handle
        } catch {
            sqlite3_close(handle)
            throw ServerHistoryCacheError.storage
        }
    }

    private func protectFiles() throws {
        guard var directory = directoryURL else { throw ServerHistoryCacheError.storage }
        do {
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try directory.setResourceValues(values)
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
            for name in Self.fileNames {
                var url = directory.appendingPathComponent(name)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
                try url.setResourceValues(values)
            }
        } catch { throw ServerHistoryCacheError.storage }
    }

    private func evict(_ handle: OpaquePointer) throws {
        let expired = try statement(handle, "SELECT day FROM days WHERE state = 'loaded' ORDER BY last_viewed DESC, day DESC LIMIT -1 OFFSET ?") { statement -> [Double] in
            sqlite3_bind_int64(statement, 1, Int64(maximumPointDays))
            var days: [Double] = []
            while true {
                let status = sqlite3_step(statement)
                if status == SQLITE_DONE { return days }
                guard status == SQLITE_ROW else { throw ServerHistoryCacheError.storage }
                days.append(sqlite3_column_double(statement, 0))
            }
        }
        for timestamp in expired {
            try deletePoints(on: Date(timeIntervalSince1970: timestamp), handle: handle)
            try statement(handle, "UPDATE days SET state = 'notDownloaded' WHERE day = ?") { statement in
                sqlite3_bind_double(statement, 1, timestamp)
                try Self.finish(statement)
            }
        }
    }

    private func markViewed(_ day: Date, handle: OpaquePointer) throws {
        try statement(handle, "UPDATE days SET last_viewed = (SELECT COALESCE(MAX(last_viewed), 0) + 1 FROM days) WHERE day = ? AND state = 'loaded'") { statement in
            sqlite3_bind_double(statement, 1, day.timeIntervalSince1970)
            try Self.finish(statement)
        }
    }

    private func findDay(_ day: Date, handle: OpaquePointer) throws -> ServerHistoryDay? {
        try statement(handle, "SELECT day, point_count, distance, first_timestamp, last_timestamp, state, stops, drives FROM days WHERE day = ?") { statement in
            sqlite3_bind_double(statement, 1, day.timeIntervalSince1970)
            let status = sqlite3_step(statement)
            guard status == SQLITE_ROW || status == SQLITE_DONE else { throw ServerHistoryCacheError.storage }
            return status == SQLITE_ROW ? try Self.day(statement) : nil
        }
    }

    private static func day(_ statement: OpaquePointer) throws -> ServerHistoryDay {
        guard let stateString = string(statement, 5), let state = ServerHistoryDayState(rawValue: stateString),
              let stopData = data(statement, 6), let driveData = data(statement, 7),
              let stops = try? JSONDecoder().decode([ServerHistoryInterval].self, from: stopData),
              let drives = try? JSONDecoder().decode([ServerHistoryInterval].self, from: driveData) else {
            throw ServerHistoryCacheError.invalidData
        }
        func date(_ column: Int32) -> Date? {
            sqlite3_column_type(statement, column) == SQLITE_NULL ? nil : Date(timeIntervalSince1970: sqlite3_column_double(statement, column))
        }
        return ServerHistoryDay(day: Date(timeIntervalSince1970: sqlite3_column_double(statement, 0)),
                                pointCount: Int(sqlite3_column_int64(statement, 1)), distance: sqlite3_column_double(statement, 2),
                                firstTimestamp: date(3), lastTimestamp: date(4), state: state, stops: stops, drives: drives)
    }

    private func writeDay(_ day: ServerHistoryDay, handle: OpaquePointer) throws {
        guard let stops = try? JSONEncoder().encode(day.stops), let drives = try? JSONEncoder().encode(day.drives) else {
            throw ServerHistoryCacheError.invalidData
        }
        try statement(handle, """
            INSERT INTO days (day, point_count, distance, first_timestamp, last_timestamp, state, stops, drives)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(day) DO UPDATE SET point_count=excluded.point_count, distance=excluded.distance,
                first_timestamp=excluded.first_timestamp, last_timestamp=excluded.last_timestamp,
                state=excluded.state, stops=excluded.stops, drives=excluded.drives
            """) { statement in
            sqlite3_bind_double(statement, 1, day.day.timeIntervalSince1970)
            sqlite3_bind_int64(statement, 2, Int64(day.pointCount))
            sqlite3_bind_double(statement, 3, day.distance)
            if let date = day.firstTimestamp { sqlite3_bind_double(statement, 4, date.timeIntervalSince1970) }
            else { sqlite3_bind_null(statement, 4) }
            if let date = day.lastTimestamp { sqlite3_bind_double(statement, 5, date.timeIntervalSince1970) }
            else { sqlite3_bind_null(statement, 5) }
            try Self.bind(day.state.rawValue, to: statement, at: 6)
            try Self.bind(stops, to: statement, at: 7)
            try Self.bind(drives, to: statement, at: 8)
            try Self.finish(statement)
        }
    }

    private func deletePoints(on day: Date, handle: OpaquePointer) throws {
        try statement(handle, "DELETE FROM points WHERE day = ?") { statement in
            sqlite3_bind_double(statement, 1, day.timeIntervalSince1970)
            try Self.finish(statement)
        }
    }

    private func compact(_ handle: OpaquePointer) throws {
        try execute(handle, "PRAGMA incremental_vacuum(128); PRAGMA wal_checkpoint(TRUNCATE);")
    }

    private func execute(_ handle: OpaquePointer, _ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw ServerHistoryCacheError.storage }
    }

    private func transaction(_ handle: OpaquePointer, _ body: () throws -> Void) throws {
        try execute(handle, "BEGIN IMMEDIATE")
        do {
            try body()
            try execute(handle, "COMMIT")
        } catch {
            sqlite3_exec(handle, "ROLLBACK", nil, nil, nil)
            throw error
        }
    }

    private func statement<T>(_ handle: OpaquePointer, _ sql: String, _ body: (OpaquePointer) throws -> T) throws -> T {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
            throw ServerHistoryCacheError.storage
        }
        defer { sqlite3_finalize(prepared) }
        return try body(prepared)
    }

    private static func finish(_ statement: OpaquePointer) throws {
        guard sqlite3_step(statement) == SQLITE_DONE else { throw ServerHistoryCacheError.storage }
    }

    private static func bind(_ value: String, to statement: OpaquePointer, at column: Int32) throws {
        guard sqlite3_bind_text(statement, column, value, -1, transient) == SQLITE_OK else { throw ServerHistoryCacheError.storage }
    }

    private static func bind(_ value: Data?, to statement: OpaquePointer, at column: Int32) throws {
        let status = value.map { data in
            data.withUnsafeBytes { sqlite3_bind_blob(statement, column, $0.baseAddress, Int32(data.count), transient) }
        } ?? sqlite3_bind_null(statement, column)
        guard status == SQLITE_OK else { throw ServerHistoryCacheError.storage }
    }

    private static func string(_ statement: OpaquePointer, _ column: Int32) -> String? {
        sqlite3_column_text(statement, column).map { String(cString: $0) }
    }

    private static func data(_ statement: OpaquePointer, _ column: Int32) -> Data? {
        guard sqlite3_column_type(statement, column) != SQLITE_NULL,
              let bytes = sqlite3_column_blob(statement, column) else { return nil }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    private struct StoredPayload: Codable {
        let format: String
        let speed: Double?
        let accuracy: Double?
        let altitude: Double?
        let device: String?
        let battery: String?
        let rawJSON: Data
        let motion: [String]

        init(_ value: RecordedPayload) {
            format = value.format; speed = value.speed; accuracy = value.accuracy
            altitude = value.altitude; device = value.device; battery = value.battery
            rawJSON = value.rawJSON; motion = value.motion
        }

        var payload: RecordedPayload {
            RecordedPayload(format: format, speed: speed, accuracy: accuracy, altitude: altitude,
                            device: device, battery: battery, rawJSON: rawJSON, motion: motion)
        }
    }
}
