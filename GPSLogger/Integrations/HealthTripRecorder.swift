//
//  HealthTripRecorder.swift
//  Overland
//
//  Optional Apple Health export for trip modes that have a Health workout type. Route points are
//  copied only after GLManager commits an accepted location, and the copy is independent of the
//  upload queue, trip database and history archive.
//

import CoreLocation
import Foundation
import HealthKit

// The Apple Health workouts a trip mode can be saved as. Only outdoor workouts that can have a route.
struct HealthWorkout {
    // Stored in TripMode.healthWorkout, so it never changes.
    let key: String
    let name: String
    let activityType: HKWorkoutActivityType
    // The distance sample saved with the workout, or nil to save only the route.
    let distanceType: HKQuantityTypeIdentifier?

    static let all: [HealthWorkout] = {
        var all = [
            HealthWorkout(key: "walking", name: "Walking", activityType: .walking, distanceType: .distanceWalkingRunning),
            HealthWorkout(key: "running", name: "Running", activityType: .running, distanceType: .distanceWalkingRunning),
            HealthWorkout(key: "hiking", name: "Hiking", activityType: .hiking, distanceType: .distanceWalkingRunning),
            HealthWorkout(key: "cycling", name: "Cycling", activityType: .cycling, distanceType: .distanceCycling),
            HealthWorkout(key: "handCycling", name: "Hand Cycling", activityType: .handCycling, distanceType: .distanceCycling),
            HealthWorkout(key: "wheelchairWalkPace", name: "Wheelchair Walk Pace", activityType: .wheelchairWalkPace, distanceType: .distanceWheelchair),
            HealthWorkout(key: "wheelchairRunPace", name: "Wheelchair Run Pace", activityType: .wheelchairRunPace, distanceType: .distanceWheelchair),
            HealthWorkout(key: "paddleSports", name: "Paddling", activityType: .paddleSports, distanceType: nil),
            HealthWorkout(key: "rowing", name: "Rowing", activityType: .rowing, distanceType: nil),
            HealthWorkout(key: "sailing", name: "Sailing", activityType: .sailing, distanceType: nil),
            HealthWorkout(key: "surfing", name: "Surfing", activityType: .surfingSports, distanceType: nil),
            HealthWorkout(key: "crossCountrySkiing", name: "Cross-Country Skiing", activityType: .crossCountrySkiing, distanceType: nil),
            HealthWorkout(key: "downhillSkiing", name: "Downhill Skiing", activityType: .downhillSkiing, distanceType: .distanceDownhillSnowSports),
            HealthWorkout(key: "snowboarding", name: "Snowboarding", activityType: .snowboarding, distanceType: .distanceDownhillSnowSports),
            HealthWorkout(key: "skating", name: "Skating", activityType: .skatingSports, distanceType: nil),
            HealthWorkout(key: "equestrian", name: "Horseback Riding", activityType: .equestrianSports, distanceType: nil),
            HealthWorkout(key: "golf", name: "Golf", activityType: .golf, distanceType: nil),
            HealthWorkout(key: "climbing", name: "Climbing", activityType: .climbing, distanceType: nil),
            HealthWorkout(key: "other", name: "Other", activityType: .other, distanceType: nil),
        ]
        // Distance types added in iOS 18.
        if #available(iOS 18.0, *) {
            let distanceTypes: [String: HKQuantityTypeIdentifier] = [
                "paddleSports": .distancePaddleSports,
                "rowing": .distanceRowing,
                "crossCountrySkiing": .distanceCrossCountrySkiing,
                "skating": .distanceSkatingSports,
            ]
            all = all.map { workout in
                guard let distanceType = distanceTypes[workout.key] else { return workout }
                return HealthWorkout(key: workout.key, name: workout.name, activityType: workout.activityType,
                                     distanceType: distanceType)
            }
        }
        return all
    }()

    static func forKey(_ key: String?) -> HealthWorkout? {
        all.first { $0.key == key }
    }

    // The workout a trip in this mode is saved as, or nil if it isn't saved.
    static func forMode(_ mode: String) -> HealthWorkout? {
        forKey(TripModeStore.healthWorkout(mode))
    }
}
struct HealthRouteHeader: Codable, Equatable {
    let version: Int
    let tripID: String
    let mode: String
    let start: Date
    var end: Date?
    var distance: CLLocationDistance

    init(version: Int = 2, tripID: String, mode: String, start: Date, end: Date? = nil,
         distance: CLLocationDistance = 0) {
        self.version = version
        self.tripID = tripID
        self.mode = mode
        self.start = start
        self.end = end
        self.distance = max(0, distance.isFinite ? distance : 0)
    }
}

struct HealthRouteFile {
    let header: HealthRouteHeader
    let locations: [CLLocation]
}

// Route JSON is intentionally small and line-oriented so a crash can lose at most the last line.
enum HealthRouteCodec {
    static func encode(_ location: CLLocation) -> Data? {
        guard isFinite(location) else { return nil }
        var values: [String: Double] = [
            "t": location.timestamp.timeIntervalSince1970,
            "lat": location.coordinate.latitude,
            "lon": location.coordinate.longitude,
        ]
        if location.altitude.isFinite { values["alt"] = location.altitude }
        if location.horizontalAccuracy.isFinite { values["hacc"] = location.horizontalAccuracy }
        if location.verticalAccuracy.isFinite { values["vacc"] = location.verticalAccuracy }
        if location.speed.isFinite { values["spd"] = location.speed }
        if location.course.isFinite { values["crs"] = location.course }
        if location.speedAccuracy.isFinite { values["sacc"] = location.speedAccuracy }
        if location.courseAccuracy.isFinite { values["cacc"] = location.courseAccuracy }
        return try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys])
    }

    static func decode(_ data: Data) -> CLLocation? {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let values = object as? [String: Any],
              let timestamp = finiteDouble(values["t"]),
              let latitude = finiteDouble(values["lat"]),
              let longitude = finiteDouble(values["lon"]) else { return nil }
        let coordinate = CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        guard CLLocationCoordinate2DIsValid(coordinate) else { return nil }
        return CLLocation(coordinate: coordinate,
                          altitude: finiteDouble(values["alt"]) ?? 0,
                          horizontalAccuracy: finiteDouble(values["hacc"]) ?? -1,
                          verticalAccuracy: finiteDouble(values["vacc"]) ?? -1,
                          course: finiteDouble(values["crs"]) ?? -1,
                          courseAccuracy: finiteDouble(values["cacc"]) ?? -1,
                          speed: finiteDouble(values["spd"]) ?? -1,
                          speedAccuracy: finiteDouble(values["sacc"]) ?? -1,
                          timestamp: Date(timeIntervalSince1970: timestamp))
    }

    static func encodeHeader(_ header: HealthRouteHeader) -> Data? {
        try? JSONEncoder().encode(header)
    }

    static func decodeHeader(_ data: Data, fallbackTripID: String? = nil,
                             fallbackStart: Date? = nil) -> HealthRouteHeader? {
        if let header = try? JSONDecoder().decode(HealthRouteHeader.self, from: data) {
            return header
        }
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let values = object as? [String: Any],
              let mode = values["mode"] as? String else { return nil }
        let tripID = fallbackTripID ?? "overland-trip-\(Int((fallbackStart ?? Date.distantPast).timeIntervalSince1970))"
        let start = finiteDouble(values["start"]).map(Date.init(timeIntervalSince1970:)) ?? fallbackStart
        guard let start else { return nil }
        let end = finiteDouble(values["end"]).map(Date.init(timeIntervalSince1970:))
        let distance = finiteDouble(values["distance"]) ?? 0
        return HealthRouteHeader(version: 1, tripID: tripID, mode: mode, start: start, end: end,
                                 distance: distance)
    }

    static func encodeFile(header: HealthRouteHeader, locations: [CLLocation]) -> Data? {
        guard let headerData = encodeHeader(header) else { return nil }
        var data = headerData + Data("\n".utf8)
        for location in locations {
            guard let line = encode(location) else { continue }
            data.append(line)
            data.append(Data("\n".utf8))
        }
        return data
    }

    static func decodeFile(_ data: Data, fallbackTripID: String? = nil,
                           fallbackStart: Date? = nil) -> HealthRouteFile? {
        let lines = data.split(separator: 10, omittingEmptySubsequences: true)
        guard let first = lines.first,
              let header = decodeHeader(Data(first), fallbackTripID: fallbackTripID,
                                        fallbackStart: fallbackStart) else { return nil }
        let locations = lines.dropFirst().compactMap { decode(Data($0)) }
        return HealthRouteFile(header: header, locations: locations)
    }

    static func isFinite(_ location: CLLocation) -> Bool {
        let coordinate = location.coordinate
        return coordinate.latitude.isFinite && coordinate.longitude.isFinite
            && CLLocationCoordinate2DIsValid(coordinate)
            && location.timestamp.timeIntervalSince1970.isFinite
    }

    private static func finiteDouble(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let value = number.doubleValue
        return value.isFinite ? value : nil
    }
}

struct HealthTripExportState: Codable, Equatable {
    let version: Int
    let tripID: String
    var mode: String
    var start: Date
    var end: Date?
    var distance: CLLocationDistance
    var workoutUUID: UUID?
    var workoutSaved: Bool
    var routeSaved: Bool
    var routeSkipped: Bool

    init(version: Int = 1, tripID: String, mode: String, start: Date, end: Date? = nil,
         distance: CLLocationDistance = 0, workoutUUID: UUID? = nil, workoutSaved: Bool = false,
         routeSaved: Bool = false, routeSkipped: Bool = false) {
        self.version = version
        self.tripID = tripID
        self.mode = mode
        self.start = start
        self.end = end
        self.distance = max(0, distance.isFinite ? distance : 0)
        self.workoutUUID = workoutUUID
        self.workoutSaved = workoutSaved
        self.routeSaved = routeSaved
        self.routeSkipped = routeSkipped
    }
}

enum HealthTripRecoveryStep: Equatable {
    case waitForEnablement
    case saveWorkout
    case saveRoute
    case markRouteUnavailable
    case complete
}

struct HealthWorkoutReference: Equatable {
    let uuid: UUID
}

protocol HealthTripHealthClient: AnyObject {
    var isAvailable: Bool { get }
    func requestAuthorization(completion: @escaping (String?) -> Void)
    func existingWorkout(syncIdentifier: String) async throws -> HealthWorkoutReference?
    func createWorkout(_ workout: HealthWorkout, tripID: String, start: Date, end: Date,
                       distance: CLLocationDistance, locations: [CLLocation]) async throws -> HealthWorkoutReference
    func routeExists(for workout: HealthWorkoutReference, syncIdentifier: String) async throws -> Bool
    func createRoute(for workout: HealthWorkoutReference, syncIdentifier: String,
                     locations: [CLLocation]) async throws
}

private enum HealthTripRecorderError: LocalizedError {
    case invalidTrip
    case workoutMissing
    case healthUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidTrip: return "The trip has no valid start, end or route."
        case .workoutMissing: return "The Apple Health workout could not be found."
        case .healthUnavailable: return "Apple Health is unavailable on this device."
        }
    }
}

enum HealthBuildSupport {
    static var enabled: Bool {
        guard let value = Bundle.main.object(forInfoDictionaryKey: "OverlandHealthKitEnabled") else { return true }
        if let number = value as? NSNumber { return number.boolValue }
        return (value as? NSString)?.boolValue ?? false
    }
}

private final class HealthKitTripHealthClient: HealthTripHealthClient {
    private lazy var store = HKHealthStore()

    init() {}

    var isAvailable: Bool {
        HealthBuildSupport.enabled && HKHealthStore.isHealthDataAvailable()
    }

    func requestAuthorization(completion: @escaping (String?) -> Void) {
        guard isAvailable else { completion("Apple Health is unavailable in this build."); return }
        var types: Set<HKSampleType> = [HKObjectType.workoutType(), HKSeriesType.workoutRoute()]
        for case let distanceType? in HealthWorkout.all.map(\.distanceType) {
            types.insert(HKQuantityType(distanceType))
        }
        let readTypes: Set<HKObjectType> = Set(types.map { $0 as HKObjectType })
        // Read access lets recovery find a workout created just before a crash and attach its route
        // instead of creating a duplicate.
        store.requestAuthorization(toShare: types, read: readTypes) { [store = self.store] _, error in
            DispatchQueue.main.async {
                if let error {
                    completion(error.localizedDescription)
                } else if store.authorizationStatus(for: HKObjectType.workoutType()) != .sharingAuthorized {
                    completion("Overland isn't allowed to save workouts. You can allow it in the Health app, under Profile → Apps → Overland.")
                } else {
                    completion(nil)
                }
            }
        }
    }

    func existingWorkout(syncIdentifier: String) async throws -> HealthWorkoutReference? {
        let predicate = HKQuery.predicateForObjects(withMetadataKey: HKMetadataKeySyncIdentifier,
                                                    operatorType: .equalTo, value: syncIdentifier)
        let workouts = try await queryWorkouts(predicate: predicate, limit: 1)
        return workouts.first.map { HealthWorkoutReference(uuid: $0.uuid) }
    }

    func createWorkout(_ workout: HealthWorkout, tripID: String, start: Date, end: Date,
                       distance: CLLocationDistance, locations: [CLLocation]) async throws -> HealthWorkoutReference {
        guard end > start else { throw HealthTripRecorderError.invalidTrip }
        let configuration = HKWorkoutConfiguration()
        configuration.activityType = workout.activityType
        configuration.locationType = .outdoor

        let builder = HKWorkoutBuilder(healthStore: store, configuration: configuration, device: .local())
        try await builder.beginCollection(at: start)
        if distance > 0, let identifier = workout.distanceType,
           store.authorizationStatus(for: HKQuantityType(identifier)) == .sharingAuthorized {
            let sample = HKQuantitySample(type: HKQuantityType(identifier),
                                          quantity: HKQuantity(unit: .meter(), doubleValue: distance),
                                          start: start, end: end)
            try await builder.addSamples([sample])
        }
        try await builder.addMetadata([
            HKMetadataKeySyncIdentifier: tripID,
            HKMetadataKeySyncVersion: 1,
            HKMetadataKeyExternalUUID: tripID,
            HKMetadataKeyIndoorWorkout: false,
        ])
        try await builder.endCollection(at: end)
        guard let saved = try await builder.finishWorkout() else {
            throw HealthTripRecorderError.invalidTrip
        }
        return HealthWorkoutReference(uuid: saved.uuid)
    }

    func routeExists(for workout: HealthWorkoutReference, syncIdentifier: String) async throws -> Bool {
        guard let savedWorkout = try await self.workout(with: workout.uuid) else { return false }
        let routes = try await querySamples(predicate: HKQuery.predicateForObjects(from: savedWorkout),
                                             type: HKSeriesType.workoutRoute(), limit: 1)
        return !routes.isEmpty
    }

    func createRoute(for workout: HealthWorkoutReference, syncIdentifier: String,
                     locations: [CLLocation]) async throws {
        guard let savedWorkout = try await self.workout(with: workout.uuid) else {
            throw HealthTripRecorderError.workoutMissing
        }
        let route = locations.filter(HealthRouteCodec.isFinite)
        guard route.count >= 2 else { return }
        let builder = HKWorkoutRouteBuilder(healthStore: store, device: .local())
        for chunkStart in stride(from: 0, to: route.count, by: 200) {
            try await builder.insertRouteData(Array(route[chunkStart..<min(chunkStart + 200, route.count)]))
        }
        try await builder.finishRoute(with: savedWorkout, metadata: [
            HKMetadataKeySyncIdentifier: syncIdentifier,
            HKMetadataKeySyncVersion: 1,
        ])
    }

    private func workout(with uuid: UUID) async throws -> HKWorkout? {
        let samples = try await querySamples(predicate: HKQuery.predicateForObject(with: uuid),
                                              type: HKObjectType.workoutType(), limit: 1)
        return samples.first as? HKWorkout
    }

    private func queryWorkouts(predicate: NSPredicate, limit: Int) async throws -> [HKWorkout] {
        let samples = try await querySamples(predicate: predicate, type: HKObjectType.workoutType(), limit: limit)
        return samples.compactMap { $0 as? HKWorkout }
    }

    private func querySamples(predicate: NSPredicate, type: HKSampleType, limit: Int) async throws -> [HKSample] {
        try await withCheckedThrowingContinuation { continuation in
            let query = HKSampleQuery(sampleType: type, predicate: predicate, limit: limit,
                                      sortDescriptors: nil) { _, samples, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: samples ?? [])
                }
            }
            store.execute(query)
        }
    }
}

struct HealthTripRecorderDependencies {
    let defaults: UserDefaults
    let directory: URL
    let fileManager: FileManager
    let now: () -> Date
    let health: HealthTripHealthClient

    init(defaults: UserDefaults = .standard, directory: URL? = nil,
         fileManager: FileManager = .default, now: @escaping () -> Date = Date.init,
         health: HealthTripHealthClient? = nil) {
        self.defaults = defaults
        self.fileManager = fileManager
        self.now = now
        self.health = health ?? HealthKitTripHealthClient()
        if let directory {
            self.directory = directory
        } else {
            let support = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            self.directory = support.appendingPathComponent("HealthTrips", isDirectory: true)
        }
    }
}

@objc final class HealthTripRecorder: NSObject {
    @objc static let shared = HealthTripRecorder(dependencies: HealthTripRecorderDependencies())

    private static let enabledDefaultsKey = "HealthTripRecorderEnabled"
    private static let lastErrorDefaultsKey = "HealthTripRecorderLastError"
    private static let savedTripsDefaultsKey = "HealthTripRecorderSavedTrips"
    private static let stateExtension = "state.json"

    private let dependencies: HealthTripRecorderDependencies
    private let queue: DispatchQueue
    private var started = false
    private var activeTrip: ActiveTrip?
    private var processingTripIDs = Set<String>()
    private var lastRecordedTimestamp: Date?
    private var kvoContext = 0
    private var observedDefaults: UserDefaults?

    private struct ActiveTrip {
        var state: HealthTripExportState
        let routeURL: URL
        var lastLocation: CLLocation?
    }

    private struct TripSnapshot {
        let start: Date?
        let mode: String
        let distance: CLLocationDistance
    }

    init(dependencies: HealthTripRecorderDependencies) {
        self.dependencies = dependencies
        self.queue = DispatchQueue(label: "com.aaronpk.overland.healthtrips", qos: .utility)
        super.init()
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
        if started, let observedDefaults {
            observedDefaults.removeObserver(self, forKeyPath: GLTripStartTimeDefaultsName,
                                             context: &kvoContext)
        }
    }

    @objc static var isAvailable: Bool {
        HealthBuildSupport.enabled && HKHealthStore.isHealthDataAvailable()
    }

    @objc var isEnabled: Bool {
        get { dependencies.defaults.bool(forKey: Self.enabledDefaultsKey) }
        set {
            dependencies.defaults.set(newValue, forKey: Self.enabledDefaultsKey)
            guard newValue else { return }
            syncWithTrip()
        }
    }

    @objc var lastError: String? {
        dependencies.defaults.string(forKey: Self.lastErrorDefaultsKey)
    }

    // Explicit UI action only. Starting the recorder never requests Health permission.
    @objc func requestAuthorization(completion: @escaping (String?) -> Void) {
        dependencies.health.requestAuthorization(completion: completion)
    }

    @objc func start() {
        guard !started else { return }
        started = true
        NotificationCenter.default.addObserver(self, selector: #selector(syncNotification),
                                               name: Notification.Name(GLSettingsChangedNotification), object: nil)
        observedDefaults = dependencies.defaults
        observedDefaults?.addObserver(self, forKeyPath: GLTripStartTimeDefaultsName,
                                      options: [.new, .old], context: &kvoContext)
        guard isEnabled, dependencies.health.isAvailable else { return }
        syncWithTrip()
    }

    // Parent callers can use this after a persisted trip-state transition; it is also called by KVO.
    @objc func syncWithTrip() {
        let capture = { [weak self] in
            guard let self else { return }
            let manager: GLManager = GLManager.shared()
            let start = manager.tripInProgress() ? manager.currentTripStart() : nil
            let snapshot = TripSnapshot(start: start,
                                        mode: start == nil ? "" : (manager.currentTripMode ?? ""),
                                        distance: start == nil ? 0 : max(0, manager.currentTripDistance()))
            self.queue.async { [weak self] in
                self?.apply(snapshot: snapshot)
            }
        }
        if Thread.isMainThread {
            capture()
        } else {
            DispatchQueue.main.async(execute: capture)
        }
    }

    @objc(finishPendingWrites:)
    func finishPendingWrites(_ completion: @escaping () -> Void) {
        queue.async { DispatchQueue.main.async(execute: completion) }
    }

    @objc(recordAcceptedLocation:)
    func recordAcceptedLocation(_ location: CLLocation) {
        guard isEnabled else { return }
        queue.async { [weak self] in
            guard let self, self.isEnabled, var active = self.activeTrip,
                  active.state.end == nil,
                  location.timestamp >= active.state.start,
                  HealthRouteCodec.isFinite(location) else { return }
            if let last = self.lastRecordedTimestamp, location.timestamp <= last { return }
            guard let line = HealthRouteCodec.encode(location) else { return }
            self.ensureDirectory()
            guard self.append(line, to: active.routeURL) else { return }
            self.lastRecordedTimestamp = location.timestamp
            active.lastLocation = location
            self.activeTrip = active
        }
    }

    // A pure decision boundary keeps recovery tests independent of HealthKit and permission state.
    static func recoveryStep(enabled: Bool, workoutSaved: Bool, routeSaved: Bool,
                             routeSkipped: Bool, pointCount: Int) -> HealthTripRecoveryStep {
        guard enabled else { return .waitForEnablement }
        if workoutSaved && (routeSaved || routeSkipped) { return .complete }
        if !workoutSaved { return .saveWorkout }
        if pointCount < 2 { return .markRouteUnavailable }
        return .saveRoute
    }

    @objc private func syncNotification() {
        guard isEnabled else { return }
        syncWithTrip()
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        guard context == &kvoContext else { return }
        syncWithTrip()
    }

    private func apply(snapshot: TripSnapshot) {
        if let active = activeTrip, active.state.start != snapshot.start {
            var state = active.state
            state.end = state.end ?? dependencies.now()
            if let route = readRoute(active.routeURL) {
                state.distance = max(state.distance, distance(of: route.locations))
            }
            writeState(state)
            activeTrip = nil
            if isEnabled {
                processPending(excluding: state.tripID)
            }
        }

        if activeTrip == nil, let start = snapshot.start, isEnabled {
            beginOrRestore(start: start, mode: snapshot.mode, distance: snapshot.distance)
        } else if var active = activeTrip, active.state.start == snapshot.start,
                  snapshot.distance > active.state.distance {
            active.state.distance = snapshot.distance
            activeTrip = active
            writeState(active.state)
        }

        guard isEnabled, dependencies.health.isAvailable else { return }
        processPending(excluding: activeTrip?.state.tripID)
    }

    private func beginOrRestore(start: Date, mode: String, distance: CLLocationDistance) {
        let tripID = Self.tripID(start: start)
        let routeURL = routeURL(for: tripID)
        guard HealthWorkout.forMode(mode) != nil
                || dependencies.fileManager.fileExists(atPath: routeURL.path) else { return }
        let fallbackHeader = HealthRouteHeader(tripID: tripID, mode: mode, start: start, distance: distance)
        if !dependencies.fileManager.fileExists(atPath: routeURL.path) {
            guard let data = HealthRouteCodec.encodeFile(header: fallbackHeader, locations: []) else { return }
            ensureDirectory()
            guard atomicWrite(data, to: routeURL) else { return }
        }

        let route = readRoute(routeURL)
        let header = route?.header ?? fallbackHeader
        var state = readState(for: tripID)
            ?? HealthTripExportState(tripID: tripID, mode: header.mode, start: header.start,
                                     end: header.end, distance: max(header.distance, distance))
        state.end = nil
        state.mode = header.mode
        state.distance = max(state.distance, distance)
        state.workoutSaved = false
        state.routeSaved = false
        state.routeSkipped = false
        writeState(state)
        activeTrip = ActiveTrip(state: state, routeURL: routeURL, lastLocation: route?.locations.last)
        lastRecordedTimestamp = route?.locations.last?.timestamp
    }

    private func processPending(excluding activeID: String?) {
        guard isEnabled, dependencies.health.isAvailable else { return }
        ensureDirectory()
        guard let files = try? dependencies.fileManager.contentsOfDirectory(at: dependencies.directory,
                                                                               includingPropertiesForKeys: nil) else { return }
        var started = 0
        var inspected = 0
        for url in files where url.pathExtension == "jsonl" {
            if started >= 8 || inspected >= 32 { break }
            inspected += 1
            let tripID = url.deletingPathExtension().lastPathComponent
            if tripID == activeID { continue }
            guard let route = readRoute(url) else { continue }
            var state = readState(for: route.header.tripID)
                ?? HealthTripExportState(tripID: route.header.tripID, mode: route.header.mode,
                                         start: route.header.start, end: route.header.end,
                                         distance: max(route.header.distance, distance(of: route.locations)))
            if state.end == nil {
                state.end = route.header.end ?? route.locations.last?.timestamp ?? dependencies.now()
            }
            state.mode = route.header.mode
            state.distance = max(state.distance, distance(of: route.locations))
            writeState(state)
            guard HealthWorkout.forMode(state.mode) != nil else { continue }
            started += 1
            enqueue(state: state, locations: route.locations)
        }
    }

    private func enqueue(state: HealthTripExportState, locations: [CLLocation]) {
        guard !processingTripIDs.contains(state.tripID) else { return }
        processingTripIDs.insert(state.tripID)
        let health = dependencies.health
        let routePoints = locations
        Task { [weak self] in
            guard let self else { return }
            do {
                let finalState = try await self.export(state: state, locations: routePoints, health: health)
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.processingTripIDs.remove(state.tripID)
                    self.writeState(finalState)
                    if finalState.workoutSaved && (finalState.routeSaved || finalState.routeSkipped) {
                        self.removePendingFiles(for: finalState.tripID)
                        self.dependencies.defaults.removeObject(forKey: Self.lastErrorDefaultsKey)
                        self.rememberSavedTrip(finalState.tripID)
                    }
                }
            } catch {
                self.queue.async { [weak self] in
                    guard let self else { return }
                    self.processingTripIDs.remove(state.tripID)
                    self.dependencies.defaults.set("Couldn't save a trip to Apple Health: \(error.localizedDescription)",
                                                   forKey: Self.lastErrorDefaultsKey)
                }
            }
        }
    }

    private func export(state: HealthTripExportState, locations: [CLLocation],
                        health: HealthTripHealthClient) async throws -> HealthTripExportState {
        var state = state
        guard let workout = HealthWorkout.forMode(state.mode), let end = state.end, end > state.start else {
            throw HealthTripRecorderError.invalidTrip
        }
        let routeLocations = locations.filter {
            $0.timestamp >= state.start && $0.timestamp <= end && HealthRouteCodec.isFinite($0)
        }

        let reference: HealthWorkoutReference
        if let uuid = state.workoutUUID {
            reference = HealthWorkoutReference(uuid: uuid)
        } else if let existing = try await health.existingWorkout(syncIdentifier: state.tripID) {
            reference = existing
        } else {
            reference = try await health.createWorkout(workout, tripID: state.tripID, start: state.start,
                                                       end: end, distance: state.distance, locations: routeLocations)
        }
        state.workoutUUID = reference.uuid
        state.workoutSaved = true
        try persistState(state)

        switch Self.recoveryStep(enabled: true, workoutSaved: true, routeSaved: state.routeSaved,
                                 routeSkipped: state.routeSkipped, pointCount: routeLocations.count) {
        case .complete:
            return state
        case .markRouteUnavailable:
            state.routeSkipped = true
            try persistState(state)
            return state
        case .saveRoute:
            if try await health.routeExists(for: reference, syncIdentifier: state.tripID) {
                state.routeSaved = true
                try persistState(state)
                return state
            }
            try await health.createRoute(for: reference, syncIdentifier: state.tripID,
                                         locations: routeLocations)
            state.routeSaved = true
            try persistState(state)
            return state
        case .waitForEnablement, .saveWorkout:
            throw HealthTripRecorderError.invalidTrip
        }
    }

    private func readRoute(_ url: URL) -> HealthRouteFile? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let name = url.deletingPathExtension().lastPathComponent
        let seconds = TimeInterval(name)
        let fallbackStart = seconds.map(Date.init(timeIntervalSince1970:))
        let fallbackID = seconds.map { Self.tripID(start: Date(timeIntervalSince1970: $0)) } ?? name
        return HealthRouteCodec.decodeFile(data, fallbackTripID: fallbackID, fallbackStart: fallbackStart)
    }

    private func stateURL(for tripID: String) -> URL {
        dependencies.directory.appendingPathComponent("\(tripID).\(Self.stateExtension)")
    }

    private func routeURL(for tripID: String) -> URL {
        dependencies.directory.appendingPathComponent("\(tripID).jsonl")
    }

    private func readState(for tripID: String) -> HealthTripExportState? {
        guard let data = try? Data(contentsOf: stateURL(for: tripID)) else { return nil }
        return try? JSONDecoder().decode(HealthTripExportState.self, from: data)
    }

    private func writeState(_ state: HealthTripExportState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        ensureDirectory()
        _ = atomicWrite(data, to: stateURL(for: state.tripID))
    }

    private func persistState(_ state: HealthTripExportState) throws {
        try queue.sync {
            guard let data = try? JSONEncoder().encode(state) else {
                throw HealthTripRecorderError.invalidTrip
            }
            ensureDirectory()
            guard atomicWrite(data, to: stateURL(for: state.tripID)) else {
                throw HealthTripRecorderError.invalidTrip
            }
        }
    }

    private func append(_ line: Data, to url: URL) -> Bool {
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        handle.seekToEndOfFile()
        handle.write(line)
        handle.write(Data("\n".utf8))
        try? handle.close()
        protect(url)
        return true
    }

    private func atomicWrite(_ data: Data, to url: URL) -> Bool {
        ensureDirectory()
        do {
            try data.write(to: url, options: .atomic)
            protect(url)
            return true
        } catch {
            dependencies.defaults.set("Couldn't write an Apple Health route: \(error.localizedDescription)",
                                      forKey: Self.lastErrorDefaultsKey)
            return false
        }
    }

    private func ensureDirectory() {
        try? dependencies.fileManager.createDirectory(at: dependencies.directory,
                                                       withIntermediateDirectories: true)
        protect(dependencies.directory)
    }

    private func protect(_ url: URL) {
        try? dependencies.fileManager.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedURL = url
        try? protectedURL.setResourceValues(values)
    }

    private func removePendingFiles(for tripID: String) {
        try? dependencies.fileManager.removeItem(at: routeURL(for: tripID))
        try? dependencies.fileManager.removeItem(at: stateURL(for: tripID))
    }

    private func rememberSavedTrip(_ tripID: String) {
        var ids = dependencies.defaults.stringArray(forKey: Self.savedTripsDefaultsKey) ?? []
        if !ids.contains(tripID) { ids.append(tripID) }
        dependencies.defaults.set(Array(ids.suffix(50)), forKey: Self.savedTripsDefaultsKey)
    }

    private static func tripID(start: Date) -> String {
        "overland-trip-\(Int(start.timeIntervalSince1970))"
    }

    private func distance(of locations: [CLLocation]) -> CLLocationDistance {
        zip(locations, locations.dropFirst()).reduce(0) { total, pair in
            let value = pair.1.distance(from: pair.0)
            return total + (value.isFinite ? max(0, value) : 0)
        }
    }
}
