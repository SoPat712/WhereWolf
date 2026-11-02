import CoreLocation
import Foundation
import XCTest
@testable import Where

final class HealthTripRecorderTests: XCTestCase {
    private final class FakeHealthClient: HealthTripHealthClient {
        var workoutCreates = 0
        var workoutEnd: Date?
        var workoutDistance: CLLocationDistance?
        var workoutLocations = 0
        var routeCreates = 0
        var existing: HealthWorkoutReference?
        var routeCreated: (() -> Void)?
        var availabilityChecks = 0
        var authorizationRequests = 0
        var isAvailable: Bool {
            availabilityChecks += 1
            return true
        }

        func requestAuthorization(completion: @escaping (String?) -> Void) {
            authorizationRequests += 1
            completion(nil)
        }

        func existingWorkout(syncIdentifier: String) async throws -> HealthWorkoutReference? { existing }

        func createWorkout(_ workout: HealthWorkout, tripID: String, start: Date, end: Date,
                           distance: CLLocationDistance, locations: [CLLocation]) async throws -> HealthWorkoutReference {
            workoutCreates += 1
            workoutEnd = end
            workoutDistance = distance
            workoutLocations = locations.count
            return HealthWorkoutReference(uuid: UUID())
        }

        func routeExists(for workout: HealthWorkoutReference, syncIdentifier: String) async throws -> Bool {
            false
        }

        func createRoute(for workout: HealthWorkoutReference, syncIdentifier: String,
                         locations: [CLLocation]) async throws {
            routeCreates += 1
            routeCreated?()
        }
    }

    private func location(latitude: Double, longitude: Double, seconds: TimeInterval) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                   altitude: 12, horizontalAccuracy: 8, verticalAccuracy: 10,
                   course: 42, speed: 3, timestamp: Date(timeIntervalSince1970: seconds))
    }

    func testRouteCodecRoundTripsFiniteLocationsAndHeaders() throws {
        let point = location(latitude: 45.5152, longitude: -122.6784, seconds: 1_700_000_000)
        let header = HealthRouteHeader(tripID: "overland-trip-1700000000", mode: "walk",
                                       start: point.timestamp, distance: 123.5)
        let data = try XCTUnwrap(HealthRouteCodec.encodeFile(header: header, locations: [point]))
        let decoded = try XCTUnwrap(HealthRouteCodec.decodeFile(data))

        XCTAssertEqual(decoded.header, header)
        XCTAssertEqual(decoded.locations.count, 1)
        XCTAssertEqual(decoded.locations[0].coordinate.latitude, point.coordinate.latitude, accuracy: 0.000001)
        XCTAssertEqual(decoded.locations[0].coordinate.longitude, point.coordinate.longitude, accuracy: 0.000001)
        XCTAssertEqual(decoded.locations[0].timestamp, point.timestamp)
    }

    func testRouteCodecRejectsNonFiniteOrInvalidCoordinates() throws {
        let invalid = CLLocation(coordinate: CLLocationCoordinate2D(latitude: .nan, longitude: -122),
                                 altitude: 0, horizontalAccuracy: 10, verticalAccuracy: 10,
                                 course: -1, speed: -1, timestamp: Date())
        XCTAssertNil(HealthRouteCodec.encode(invalid))

        let malformed = try JSONSerialization.data(withJSONObject: [
            "t": 1_700_000_000,
            "lat": 91,
            "lon": -122,
        ])
        XCTAssertNil(HealthRouteCodec.decode(malformed))
        XCTAssertNil(HealthRouteCodec.decode(Data("not json".utf8)))
    }

    func testRecoveryDecisionIsBoundedAndRetriesMissingRouteWithoutDuplicateWorkout() {
        XCTAssertEqual(HealthTripRecorder.recoveryStep(enabled: false, workoutSaved: false,
                                                        routeSaved: false, routeSkipped: false,
                                                        pointCount: 10), .waitForEnablement)
        XCTAssertEqual(HealthTripRecorder.recoveryStep(enabled: true, workoutSaved: false,
                                                        routeSaved: false, routeSkipped: false,
                                                        pointCount: 10), .saveWorkout)
        XCTAssertEqual(HealthTripRecorder.recoveryStep(enabled: true, workoutSaved: true,
                                                        routeSaved: false, routeSkipped: false,
                                                        pointCount: 10), .saveRoute)
        XCTAssertEqual(HealthTripRecorder.recoveryStep(enabled: true, workoutSaved: true,
                                                        routeSaved: true, routeSkipped: false,
                                                        pointCount: 10), .complete)
        XCTAssertEqual(HealthTripRecorder.recoveryStep(enabled: true, workoutSaved: true,
                                                        routeSaved: false, routeSkipped: false,
                                                        pointCount: 1), .markRouteUnavailable)
    }

    func testDisabledRecorderDoesNotProbeHealthOrRequestPermission() {
        let fake = FakeHealthClient()
        let defaults = UserDefaults(suiteName: "Overland.HealthTripRecorderTests.\(UUID().uuidString)")!
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Overland.HealthTripRecorderTests.\(UUID().uuidString)", isDirectory: true)
        let recorder = HealthTripRecorder(dependencies: HealthTripRecorderDependencies(
            defaults: defaults, directory: directory, health: fake))

        recorder.start()
        XCTAssertEqual(fake.availabilityChecks, 0)
        XCTAssertEqual(fake.authorizationRequests, 0)
    }

    func testExportStatePersistsWorkoutUUIDAndRouteProgress() throws {
        let uuid = UUID()
        let state = HealthTripExportState(tripID: "overland-trip-1", mode: "walk",
                                           start: Date(timeIntervalSince1970: 1),
                                           end: Date(timeIntervalSince1970: 2), distance: 10,
                                           workoutUUID: uuid, workoutSaved: true, routeSaved: false)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(HealthTripExportState.self, from: data)
        XCTAssertEqual(decoded, state)
        XCTAssertEqual(decoded.workoutUUID, uuid)
        XCTAssertTrue(decoded.workoutSaved)
        XCTAssertFalse(decoded.routeSaved)
    }

    @MainActor private func exerciseCompletedExport(existing: HealthWorkoutReference?,
                                                    endedAfter: TimeInterval? = nil) async throws -> FakeHealthClient {
        let main = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier!
        let original = main.persistentDomain(forName: domain) ?? [:]
        let suite = "Overland.HealthTripRecorderTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        defer {
            main.setPersistentDomain(original, forName: domain)
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let start = Date().addingTimeInterval(-600)
        main.set(start, forKey: GLTripStartTimeDefaultsName)
        main.set("walk", forKey: GLTripModeDefaultsName)
        let fake = FakeHealthClient()
        fake.existing = existing
        let route = expectation(description: "Committed Health route exported")
        fake.routeCreated = { route.fulfill() }
        let recorder = HealthTripRecorder(dependencies: HealthTripRecorderDependencies(
            defaults: defaults, directory: directory, health: fake))
        recorder.isEnabled = true
        recorder.recordAcceptedLocation(location(latitude: 45, longitude: -122, seconds: start.timeIntervalSince1970 + 10))
        recorder.recordAcceptedLocation(location(latitude: 45.001, longitude: -122, seconds: start.timeIntervalSince1970 + 20))
        recorder.recordAcceptedLocation(location(latitude: 45.002, longitude: -122, seconds: start.timeIntervalSince1970 + 300))
        if let endedAfter { defaults.set(start.addingTimeInterval(endedAfter), forKey: GLLastTripEndDefaultsName) }
        main.removeObject(forKey: GLTripStartTimeDefaultsName)
        recorder.syncWithTrip()
        await fulfillment(of: [route], timeout: 5)
        let cleaned = XCTNSPredicateExpectation(predicate: NSPredicate { _, _ in
            (try? FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty) == true
        }, object: nil)
        await fulfillment(of: [cleaned], timeout: 5)
        recorder.isEnabled = false
        return fake
    }

    @MainActor func testAcceptedRouteAndCommittedTripEndExportOneWorkoutAndRoute() async throws {
        let fake = try await exerciseCompletedExport(existing: nil)
        XCTAssertEqual(fake.workoutCreates, 1)
        XCTAssertEqual(fake.routeCreates, 1)
        XCTAssertEqual(fake.workoutLocations, 3)
    }

    @MainActor func testTripEndedAtTheStopEndsTheWorkoutAndRouteThere() async throws {
        let fake = try await exerciseCompletedExport(existing: nil, endedAfter: 30)
        let start = try XCTUnwrap(fake.workoutEnd).addingTimeInterval(-30)
        XCTAssertLessThan(abs(start.timeIntervalSinceNow + 600), 5)
        XCTAssertEqual(fake.workoutLocations, 2)
        XCTAssertEqual(fake.workoutDistance ?? 0, 111, accuracy: 2)
    }

    @MainActor func testRecoveryAttachesTheRouteToAnExistingWorkoutWithoutCreatingAnother() async throws {
        let fake = try await exerciseCompletedExport(existing: HealthWorkoutReference(uuid: UUID()))
        XCTAssertEqual(fake.workoutCreates, 0)
        XCTAssertEqual(fake.routeCreates, 1)
    }
}
