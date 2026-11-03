import CoreLocation
import CryptoKit
import HealthKit
import Observation
import SQLite3
import UIKit

struct ImportWorkout: Codable, Equatable, Identifiable {
    let id: UUID
    let name: String
    let mode: String
    let source: String
    let sourceBundle: String
    let start: Date
    let end: Date
    let distance: Double
}

struct ImportedWorkout: Identifiable {
    let workout: ImportWorkout
    let count: Int
    let revision: String
    let queuedRevision: String?
    var id: UUID { workout.id }
    var needsQueue: Bool { queuedRevision != revision }
}

enum WorkoutImportError: LocalizedError {
    case unavailable, noRoute, storage, invalidWorkout
    var errorDescription: String? {
        switch self {
        case .unavailable: return "Apple Health is unavailable in this build."
        case .noRoute: return "No route is available yet. Allow route access in Health and try again after your watch has synced."
        case .storage: return "The imported route could not be saved. Your Health data is unchanged."
        case .invalidWorkout: return "The workout has no valid start and end time."
        }
    }
}

struct WorkoutRouteRead {
    let revision: String
    // Nil means the route samples have not changed since the saved revision.
    let locations: [CLLocation]?
}

protocol WorkoutImportHealthClient: AnyObject {
    var isAvailable: Bool { get }
    func authorize() async throws
    func workouts(since: Date) async throws -> [ImportWorkout]
    func route(for workout: UUID, knownRevision: String?) async throws -> WorkoutRouteRead
}

final class WorkoutImportHealthKitClient: WorkoutImportHealthClient {
    private lazy var health = HKHealthStore()
    var isAvailable: Bool { HealthBuildSupport.enabled && HKHealthStore.isHealthDataAvailable() }

    func authorize() async throws {
        guard isAvailable else { throw WorkoutImportError.unavailable }
        // Import needs read permission only; the result does not disclose whether reads were allowed.
        try await health.requestAuthorization(toShare: [], read: [HKObjectType.workoutType(), HKSeriesType.workoutRoute()])
    }

    func workouts(since: Date) async throws -> [ImportWorkout] {
        guard isAvailable else { throw WorkoutImportError.unavailable }
        let predicate = HKQuery.predicateForSamples(withStart: since, end: Date(), options: .strictEndDate)
        let samples = try await samples(type: HKObjectType.workoutType(), predicate: predicate, limit: 100,
                                        sort: [NSSortDescriptor(key: HKSampleSortIdentifierEndDate, ascending: false)])
        return samples.compactMap { sample in
            guard let workout = sample as? HKWorkout,
                  !Self.isWhereWolfExport(bundle: workout.sourceRevision.source.bundleIdentifier,
                                         syncIdentifier: workout.metadata?[HKMetadataKeySyncIdentifier] as? String),
                  workout.endDate > workout.startDate else { return nil }
            let kind = HealthWorkout.all.first { $0.activityType == workout.workoutActivityType }
            let mode = kind.flatMap { kind in TripModeStore.modes.first { $0.healthWorkout == kind.key } }
            return ImportWorkout(id: workout.uuid, name: kind?.name ?? "Workout", mode: mode?.id ?? "other",
                                 source: workout.sourceRevision.source.name,
                                 sourceBundle: workout.sourceRevision.source.bundleIdentifier,
                                 start: workout.startDate, end: workout.endDate,
                                 distance: workout.totalDistance?.doubleValue(for: .meter()) ?? 0)
        }
    }

    static func isWhereWolfExport(bundle: String, syncIdentifier: String?) -> Bool {
        bundle == Bundle.main.bundleIdentifier || syncIdentifier?.hasPrefix("wherewolf-trip-") == true
    }

    func route(for workout: UUID, knownRevision: String?) async throws -> WorkoutRouteRead {
        guard isAvailable else { throw WorkoutImportError.unavailable }
        guard let saved = try await samples(type: HKObjectType.workoutType(),
            predicate: HKQuery.predicateForObject(with: workout), limit: 1).first as? HKWorkout else {
            throw WorkoutImportError.noRoute
        }
        let routes = try await samples(type: HKSeriesType.workoutRoute(),
            predicate: HKQuery.predicateForObjects(from: saved), limit: HKObjectQueryNoLimit)
            .compactMap { $0 as? HKWorkoutRoute }.sorted { $0.uuid.uuidString < $1.uuid.uuidString }
        guard !routes.isEmpty else { throw WorkoutImportError.noRoute }
        let revision = routes.map { $0.uuid.uuidString + ":" + String($0.endDate.timeIntervalSince1970) }.joined(separator: "|")
        if revision == knownRevision { return WorkoutRouteRead(revision: revision, locations: nil) }
        var points: [CLLocation] = []
        for route in routes {
            let batch: [CLLocation] = try await withCheckedThrowingContinuation { continuation in
                let accumulator = WorkoutRouteAccumulator()
                let query = HKWorkoutRouteQuery(route: route) { _, locations, done, error in
                    accumulator.receive(locations ?? [], done: done, error: error, continuation: continuation)
                }
                health.execute(query)
            }
            points.append(contentsOf: batch)
        }
        guard !points.isEmpty else { throw WorkoutImportError.noRoute }
        return WorkoutRouteRead(revision: revision, locations: points)
    }

    private func samples(type: HKSampleType, predicate: NSPredicate, limit: Int,
                         sort: [NSSortDescriptor]? = nil) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            health.execute(HKSampleQuery(sampleType: type, predicate: predicate, limit: limit,
                                         sortDescriptors: sort) { _, samples, error in
                if let error { continuation.resume(throwing: error) }
                else { continuation.resume(returning: samples ?? []) }
            })
        }
    }
}

private final class WorkoutRouteAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var points: [CLLocation] = []
    private var finished = false

    func receive(_ incoming: [CLLocation], done: Bool, error: Error?,
                 continuation: CheckedContinuation<[CLLocation], Error>) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        points.append(contentsOf: incoming)
        finished = done || error != nil
        let result = finished ? points : []
        lock.unlock()
        if let error { continuation.resume(throwing: error) }
        else if done { continuation.resume(returning: result) }
    }
}

actor WorkoutImportStore {
    private let url: URL
    private var database: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL? = nil) {
        self.url = url ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Workout Imports/routes.sqlite")
    }

    deinit { if let database { sqlite3_close(database) } }

    private func open() throws -> OpaquePointer {
        if let database { return database }
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var directoryValues = URLResourceValues()
        directoryValues.isExcludedFromBackup = true
        var protectedDirectory = directory
        try protectedDirectory.setResourceValues(directoryValues)
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw WorkoutImportError.storage
        }
        guard sqlite3_exec(handle, "CREATE TABLE IF NOT EXISTS workouts (id TEXT PRIMARY KEY, summary BLOB NOT NULL, route BLOB NOT NULL, revision TEXT NOT NULL, queued_revision TEXT, count INTEGER NOT NULL); CREATE TABLE IF NOT EXISTS removed (id TEXT PRIMARY KEY)", nil, nil, nil) == SQLITE_OK else {
            sqlite3_close(handle); throw WorkoutImportError.storage
        }
        do {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        } catch { sqlite3_close(handle); throw error }
        database = handle
        return handle
    }

    private func statement(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(try open(), sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw WorkoutImportError.storage
        }
        return statement
    }

    private func text(_ value: String, at index: Int32, in statement: OpaquePointer) {
        _ = value.withCString { sqlite3_bind_text(statement, index, $0, -1, Self.transient) }
    }

    private func blob(_ value: Data, at index: Int32, in statement: OpaquePointer) {
        _ = value.withUnsafeBytes { sqlite3_bind_blob(statement, index, $0.baseAddress, Int32(value.count), Self.transient) }
    }

    private func data(_ statement: OpaquePointer, column: Int32) -> Data {
        guard let bytes = sqlite3_column_blob(statement, column) else { return Data() }
        return Data(bytes: bytes, count: Int(sqlite3_column_bytes(statement, column)))
    }

    func saved() throws -> [ImportedWorkout] {
        let query = try statement("SELECT summary,count,revision,queued_revision FROM workouts")
        defer { sqlite3_finalize(query) }
        var result: [ImportedWorkout] = []
        var status = sqlite3_step(query)
        while status == SQLITE_ROW {
            let summary = try JSONDecoder().decode(ImportWorkout.self, from: data(query, column: 0))
            let revision = String(cString: sqlite3_column_text(query, 2))
            let queued = sqlite3_column_text(query, 3).map { String(cString: $0) }
            result.append(ImportedWorkout(workout: summary, count: Int(sqlite3_column_int64(query, 1)),
                                          revision: revision, queuedRevision: queued))
            status = sqlite3_step(query)
        }
        guard status == SQLITE_DONE else { throw WorkoutImportError.storage }
        return result.sorted { $0.workout.start > $1.workout.start }
    }

    func save(_ workout: ImportWorkout, locations: [CLLocation], revision: String) throws {
        guard workout.start.timeIntervalSince1970.isFinite, workout.end.timeIntervalSince1970.isFinite,
              workout.end > workout.start else { throw WorkoutImportError.invalidWorkout }
        let route = Self.normalized(locations)
        guard !route.isEmpty else { throw WorkoutImportError.noRoute }
        let header = HealthRouteHeader(tripID: workout.id.uuidString, mode: workout.mode,
                                      start: workout.start, end: workout.end, distance: workout.distance)
        guard let encoded = HealthRouteCodec.encodeFile(header: header, locations: route) else { throw WorkoutImportError.storage }
        let summary = try JSONEncoder().encode(workout)
        let query = try statement("INSERT INTO workouts (id,summary,route,revision,count) VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET summary=excluded.summary,route=excluded.route,revision=excluded.revision,count=excluded.count")
        defer { sqlite3_finalize(query) }
        text(workout.id.uuidString, at: 1, in: query)
        blob(summary, at: 2, in: query)
        blob(encoded, at: 3, in: query)
        text(revision, at: 4, in: query)
        sqlite3_bind_int64(query, 5, Int64(route.count))
        guard sqlite3_step(query) == SQLITE_DONE else { throw WorkoutImportError.storage }
    }

    func locations(for id: UUID) throws -> [CLLocation] {
        let query = try statement("SELECT route FROM workouts WHERE id=?")
        defer { sqlite3_finalize(query) }
        text(id.uuidString, at: 1, in: query)
        guard sqlite3_step(query) == SQLITE_ROW,
              let file = HealthRouteCodec.decodeFile(data(query, column: 0)) else { throw WorkoutImportError.storage }
        return file.locations
    }

    func markQueued(_ id: UUID, revision: String) throws {
        let query = try statement("UPDATE workouts SET queued_revision=? WHERE id=? AND revision=?")
        defer { sqlite3_finalize(query) }
        text(revision, at: 1, in: query); text(id.uuidString, at: 2, in: query); text(revision, at: 3, in: query)
        guard sqlite3_step(query) == SQLITE_DONE else { throw WorkoutImportError.storage }
    }

    func remove(_ id: UUID) throws {
        let query = try statement("INSERT OR IGNORE INTO removed (id) VALUES (?)")
        defer { sqlite3_finalize(query) }
        text(id.uuidString, at: 1, in: query)
        guard sqlite3_step(query) == SQLITE_DONE else { throw WorkoutImportError.storage }
        let deletion = try statement("DELETE FROM workouts WHERE id=?")
        defer { sqlite3_finalize(deletion) }
        text(id.uuidString, at: 1, in: deletion)
        guard sqlite3_step(deletion) == SQLITE_DONE else { throw WorkoutImportError.storage }
    }

    func wasRemoved(_ id: UUID) throws -> Bool {
        let query = try statement("SELECT 1 FROM removed WHERE id=?")
        defer { sqlite3_finalize(query) }
        text(id.uuidString, at: 1, in: query)
        let status = sqlite3_step(query)
        guard status == SQLITE_ROW || status == SQLITE_DONE else { throw WorkoutImportError.storage }
        return status == SQLITE_ROW
    }

    func allowAutomaticUpdates(_ id: UUID) throws {
        let query = try statement("DELETE FROM removed WHERE id=?")
        defer { sqlite3_finalize(query) }
        text(id.uuidString, at: 1, in: query)
        guard sqlite3_step(query) == SQLITE_DONE else { throw WorkoutImportError.storage }
    }

    func records(for item: ImportedWorkout) throws -> [[String: Any]] {
        let points = try locations(for: item.id)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return points.map { point in
            let encoded = HealthRouteCodec.encode(point)!
            let fingerprint = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
            let identifier = "healthkit:\(item.id.uuidString.lowercased()):\(fingerprint)"
            var properties: [String: Any] = [
                "timestamp": formatter.string(from: point.timestamp),
                "recorded_timestamp": point.timestamp.timeIntervalSince1970,
                "source": "healthkit", "source_app": item.workout.sourceBundle,
                "source_name": item.workout.source, "workout_id": item.id.uuidString,
                "trip_id": formatter.string(from: item.workout.start), "trip_mode": TripModeStore.serverValue(item.workout.mode),
                "horizontal_accuracy": point.horizontalAccuracy.isFinite ? point.horizontalAccuracy : -1,
            ]
            if point.altitude.isFinite { properties["altitude"] = point.altitude }
            if point.verticalAccuracy.isFinite { properties["vertical_accuracy"] = point.verticalAccuracy }
            if point.speed.isFinite { properties["speed"] = point.speed }
            if point.course.isFinite { properties["course"] = point.course }
            if point.speedAccuracy.isFinite { properties["speed_accuracy"] = point.speedAccuracy }
            if point.courseAccuracy.isFinite { properties["course_accuracy"] = point.courseAccuracy }
            return ["type": "Feature", "id": identifier, "geometry": [
                "type": "Point", "coordinates": [point.coordinate.longitude, point.coordinate.latitude]
            ], "properties": properties]
        }
    }

    static func normalized(_ locations: [CLLocation]) -> [CLLocation] {
        var seen = Set<Data>()
        return locations.filter { point in
            guard let encoded = HealthRouteCodec.encode(point) else { return false }
            return seen.insert(encoded).inserted
        }.sorted {
            if $0.timestamp != $1.timestamp { return $0.timestamp < $1.timestamp }
            if $0.coordinate.latitude != $1.coordinate.latitude { return $0.coordinate.latitude < $1.coordinate.latitude }
            return $0.coordinate.longitude < $1.coordinate.longitude
        }
    }
}

@Observable @MainActor
final class WorkoutRouteImporter: NSObject {
    @objc static let shared = WorkoutRouteImporter()
    private(set) var workouts: [ImportWorkout] = []
    private(set) var imported: [ImportedWorkout] = []
    private(set) var busy = false
    private(set) var error: String?
    private(set) var message: String?
    private(set) var connected: Bool
    private(set) var automatic: Bool
    private(set) var days: Int
    private let client: WorkoutImportHealthClient
    let store: WorkoutImportStore
    private let defaults: UserDefaults
    private var started = false
    private var rerun = false
    @ObservationIgnored nonisolated(unsafe) private var observer: NSObjectProtocol?
    static let automaticKey = "WorkoutImportAutomatic"
    static let connectedKey = "WorkoutImportReadRequested"
    static let daysKey = "WorkoutImportDays"

    init(client: WorkoutImportHealthClient = WorkoutImportHealthKitClient(), store: WorkoutImportStore = WorkoutImportStore(),
         defaults: UserDefaults = .standard) {
        self.client = client; self.store = store; self.defaults = defaults
        connected = defaults.bool(forKey: Self.connectedKey)
        automatic = defaults.bool(forKey: Self.automaticKey)
        let storedDays = defaults.integer(forKey: Self.daysKey)
        days = [1, 7, 30].contains(storedDays) ? storedDays : 7
        super.init()
    }

    var available: Bool { client.isAvailable }

    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }

    @objc func start() {
        guard !started else { return }
        started = true
        observer = NotificationCenter.default.addObserver(forName: UIScene.didActivateNotification,
                                                           object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.automatic, self.connected else { return }
                await self.refresh(importAutomatically: true)
            }
        }
        // No Health query or authorization prompt until the user opts in.
    }

    func setAutomatic(_ value: Bool) {
        automatic = value
        defaults.set(value, forKey: Self.automaticKey)
    }

    func setDays(_ value: Int) {
        guard [1, 7, 30].contains(value) else { return }
        days = value; defaults.set(value, forKey: Self.daysKey)
    }

    func connect() async {
        guard !busy else { return }
        busy = true; error = nil
        do {
            try await client.authorize()
            connected = true; defaults.set(true, forKey: Self.connectedKey)
        } catch { self.error = error.localizedDescription }
        busy = false
        if connected { await refresh() }
    }

    func loadSaved() async {
        do { imported = try await store.saved() }
        catch { self.error = error.localizedDescription }
    }

    func refresh(importAutomatically: Bool = false) async {
        guard !busy else { rerun = rerun || importAutomatically; return }
        guard connected else { await loadSaved(); return }
        busy = true; error = nil; message = nil
        do {
            imported = try await store.saved()
            workouts = try await client.workouts(since: Date().addingTimeInterval(-Double(days) * 86400))
            if importAutomatically && automatic {
                for workout in workouts {
                    guard automatic else { break }
                    if try await store.wasRemoved(workout.id) { continue }
                    do { try await save(workout, automaticOnly: true) }
                    catch WorkoutImportError.noRoute { continue }
                }
                imported = try await store.saved()
            }
        } catch { self.error = error.localizedDescription }
        busy = false
        if rerun { rerun = false; await refresh(importAutomatically: true) }
    }

    private func save(_ workout: ImportWorkout, automaticOnly: Bool = false) async throws {
        let known = imported.first { $0.id == workout.id }?.revision
        let read = try await client.route(for: workout.id, knownRevision: known)
        if automaticOnly && !automatic { return }
        if let locations = read.locations {
            try await store.save(workout, locations: locations, revision: read.revision)
        }
    }

    func importWorkout(_ workout: ImportWorkout) async {
        guard !busy else { return }
        busy = true; error = nil; message = nil
        do {
            try await save(workout)
            try await store.allowAutomaticUpdates(workout.id)
            imported = try await store.saved()
            message = "Route saved on this phone."
        } catch { self.error = error.localizedDescription }
        busy = false
    }

    func queue(_ item: ImportedWorkout) async {
        guard !busy else { return }
        busy = true; error = nil; message = nil
        do {
            let records = try await store.records(for: item)
            let count: UInt = try await withCheckedThrowingContinuation { continuation in
                GLManager.shared().enqueueWorkoutImportRecords(records) { count, error in
                    if let error { continuation.resume(throwing: NSError(domain: "WorkoutImport", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: error])) }
                    else { continuation.resume(returning: count) }
                }
            }
            try await store.markQueued(item.id, revision: item.revision)
            imported = try await store.saved()
            message = count == 0 ? "These points were already queued." : "\(count.formatted()) points added to the send queue."
        } catch { self.error = error.localizedDescription }
        busy = false
    }

    func remove(_ id: UUID) async {
        guard !busy else { return }
        do {
            try await store.remove(id)
            imported = try await store.saved()
        } catch { self.error = error.localizedDescription }
    }
}
