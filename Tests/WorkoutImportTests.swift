import CoreLocation
import Foundation
import XCTest
@testable import WhereWolf

@MainActor
final class WorkoutImportTests: XCTestCase {
    private final class FakeHealth: WorkoutImportHealthClient {
        var checks = 0
        var authorizations = 0
        var queries = 0
        var routeQueries = 0
        var items: [ImportWorkout] = []
        var points: [CLLocation] = []
        var revision = "route-1"
        var isAvailable: Bool { checks += 1; return true }
        func authorize() async throws { authorizations += 1 }
        func workouts(since: Date) async throws -> [ImportWorkout] { queries += 1; return items }
        func route(for workout: UUID, knownRevision: String?) async throws -> WorkoutRouteRead {
            routeQueries += 1
            if points.isEmpty { throw WorkoutImportError.noRoute }
            return WorkoutRouteRead(revision: revision, locations: knownRevision == revision ? nil : points)
        }
    }

    private var directory: URL!
    private var defaults: UserDefaults!
    private var suite: String!

    override func setUp() {
        super.setUp()
        suite = "WhereWolf.WorkoutImportTests.\(UUID().uuidString)"
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defaults = UserDefaults(suiteName: suite)!
    }
    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }
    private func store() -> WorkoutImportStore { WorkoutImportStore(url: directory.appendingPathComponent("routes.sqlite")) }
    private func workout() -> ImportWorkout {
        ImportWorkout(id: UUID(), name: "Running", mode: "run", source: "Watch Workout", sourceBundle: "example.workout",
                      start: Date(timeIntervalSince1970: 1_700_000_000), end: Date(timeIntervalSince1970: 1_700_000_100), distance: 300)
    }
    private func point(_ offset: Double = 0) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 45 + offset / 100_000, longitude: -122),
                   altitude: 12, horizontalAccuracy: 4, verticalAccuracy: 7, course: 42, courseAccuracy: 3,
                   speed: 3, speedAccuracy: 0.5, timestamp: Date(timeIntervalSince1970: 1_700_000_000.125 + offset))
    }

    func testDisabledImporterDoesNotProbeHealthOrRequestAccessAtLaunch() {
        let health = FakeHealth()
        let model = WorkoutRouteImporter(client: health, store: store(), defaults: defaults)
        model.start()
        XCTAssertFalse(model.automatic)
        XCTAssertFalse(model.connected)
        XCTAssertEqual(health.checks, 0)
        XCTAssertEqual(health.authorizations, 0)
        XCTAssertEqual(health.queries, 0)
    }

    func testExplicitReadConnectionDoesNotEnableAutomaticImportOrSaveRoutes() async {
        let health = FakeHealth(); health.items = [workout()]; health.points = [point()]
        let storage = store()
        let model = WorkoutRouteImporter(client: health, store: storage, defaults: defaults)
        await model.connect()
        XCTAssertTrue(model.connected)
        XCTAssertFalse(model.automatic)
        XCTAssertEqual(health.authorizations, 1)
        XCTAssertEqual(health.queries, 1)
        XCTAssertEqual(health.routeQueries, 0)
        XCTAssertTrue(model.imported.isEmpty)
    }

    func testSaveRetainsDensePointsSortsOutOfOrderBatchesAndDeduplicatesIdenticalPoints() async throws {
        let storage = store(); let item = workout()
        let points = (0..<1500).map { point(Double($0) / 20) }
        try await storage.save(item, locations: Array(points.reversed()) + [points[0]], revision: "1")
        let decoded = try await storage.locations(for: item.id)
        XCTAssertEqual(decoded.count, points.count)
        XCTAssertEqual(decoded.first?.timestamp, points.first?.timestamp)
        XCTAssertEqual(decoded.last?.timestamp, points.last?.timestamp)
        XCTAssertEqual(decoded[42].speedAccuracy, 0.5)
        XCTAssertEqual(decoded[42].courseAccuracy, 3)
        let rows = try await storage.saved()
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.count, points.count)
    }

    func testStablePointIDsSurviveRelaunchAndKeepOriginalTimestampsAndProvenance() async throws {
        let storage = store(); let item = workout()
        try await storage.save(item, locations: [point(), point(5)], revision: "1")
        let saved = try await storage.saved()[0]
        let first = try await storage.records(for: saved)
        let relaunched = store()
        let second = try await relaunched.records(for: saved)
        XCTAssertEqual(first.map { $0["id"] as? String }, second.map { $0["id"] as? String })
        let properties = try XCTUnwrap(first[0]["properties"] as? [String: Any])
        XCTAssertEqual(properties["recorded_timestamp"] as? Double, point().timestamp.timeIntervalSince1970)
        XCTAssertEqual(properties["source_app"] as? String, item.sourceBundle)
        XCTAssertEqual(properties["workout_id"] as? String, item.id.uuidString)
        XCTAssertEqual(properties["source"] as? String, "healthkit")
        XCTAssertTrue((properties["timestamp"] as? String)?.contains(".125") == true)
    }

    func testUpdatedHealthRouteReplacesLocalGeometryAndRequiresQueueingNewRevision() async throws {
        let storage = store(); let item = workout()
        try await storage.save(item, locations: [point(), point(5)], revision: "1")
        try await storage.markQueued(item.id, revision: "1")
        let before = try await storage.saved()[0]
        XCTAssertFalse(before.needsQueue)
        try await storage.save(item, locations: [point(), point(5), point(10)], revision: "2")
        // An acknowledgement for an older read cannot acknowledge a replacement route.
        try await storage.markQueued(item.id, revision: "1")
        let after = try await storage.saved()[0]
        XCTAssertEqual(after.count, 3)
        XCTAssertTrue(after.needsQueue)
        XCTAssertEqual(after.queuedRevision, "1")
    }

    func testMissingRouteRemainsRetryableAfterWatchSync() async {
        let health = FakeHealth(); let item = workout(); health.items = [item]
        let model = WorkoutRouteImporter(client: health, store: store(), defaults: defaults)
        await model.connect()
        await model.importWorkout(item)
        XCTAssertTrue(model.imported.isEmpty)
        XCTAssertNotNil(model.error)
        health.points = [point(), point(5)]
        await model.importWorkout(item)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.imported.first?.count, 2)
    }

    func testAutomaticImportSkipsRemovedRoutesUntilManuallyRestored() async throws {
        let storage = store(); let health = FakeHealth(); let item = workout()
        health.items = [item]; health.points = [point(), point(5)]
        let model = WorkoutRouteImporter(client: health, store: storage, defaults: defaults)
        await model.connect(); model.setAutomatic(true)
        await model.refresh(importAutomatically: true)
        XCTAssertEqual(model.imported.count, 1)
        await model.remove(item.id)
        await model.refresh(importAutomatically: true)
        XCTAssertTrue(model.imported.isEmpty)
        await model.importWorkout(item)
        let removed = try await storage.wasRemoved(item.id)
        XCTAssertFalse(removed)
        XCTAssertEqual(model.imported.count, 1)
    }

    func testWhereWolfExportsAreExcludedWithoutExcludingOtherWorkoutApps() {
        XCTAssertTrue(WorkoutImportHealthKitClient.isWhereWolfExport(bundle: "old.wherewolf.fork", syncIdentifier: "wherewolf-trip-1700"))
        XCTAssertTrue(WorkoutImportHealthKitClient.isWhereWolfExport(bundle: Bundle.main.bundleIdentifier!, syncIdentifier: nil))
        XCTAssertFalse(WorkoutImportHealthKitClient.isWhereWolfExport(bundle: "com.apple.workout", syncIdentifier: "a-workout"))
    }

    func testFailedLocalSaveDoesNotMarkRouteImported() async throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocked = directory.appendingPathComponent("blocked")
        try Data("file".utf8).write(to: blocked)
        let health = FakeHealth(); let item = workout(); health.points = [point()]
        let model = WorkoutRouteImporter(client: health, store: WorkoutImportStore(url: blocked.appendingPathComponent("routes.sqlite")), defaults: defaults)
        await model.importWorkout(item)
        XCTAssertTrue(model.imported.isEmpty)
        XCTAssertNotNil(model.error)
    }
}
