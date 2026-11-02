import SwiftUI
import UIKit
import CoreLocation

// One entry per HTTP send attempt, oldest first.
struct SendStatusEntry: Identifiable, Equatable {
    enum Kind: Int { case success = 0, server = 1, network = 2 }
    let id: Int
    let date: Date
    let kind: Kind
}

struct WifiZoneNetwork: Hashable, Identifiable {
    let name: String
    let bssid: String?
    var id: Self { self }

    init?(name: String, bssid: String? = nil) {
        guard !name.isEmpty, name.utf8.count <= 32 else { return nil }
        let address = (bssid ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if address.isEmpty {
            self.bssid = nil
        } else {
            guard let normalized = GLManager.normalizedWifiBSSID(address) else { return nil }
            if normalized == "00:00:00:00:00:00", ["wi-fi", "wlan"].contains(name.lowercased()) { return nil }
            self.bssid = normalized
        }
        self.name = name
    }

    init?(_ dictionary: [String: String]) {
        self.init(name: dictionary["name"] ?? dictionary["SSID"] ?? "",
                  bssid: dictionary["bssid"] ?? dictionary["BSSID"])
    }

    var dictionary: [String: String] {
        var result = ["name": name]
        if let bssid { result["bssid"] = bssid }
        return result
    }
}

// Notifications refresh SwiftUI's view of the Objective-C manager.
// Settings use its setters to preserve persistence and tracking changes.
@Observable
final class GLManagerBridge {
    static let shared = GLManagerBridge()

    private(set) var tripModes = TripModeStore.modes
    private(set) var tripModesRevision = 0
    private(set) var healthRequestInFlight = false
    private(set) var healthAuthorizationError: String?
    private(set) var latestSendError: String?

    func refreshTripModes() {
        tripModes = TripModeStore.modes
        tripModesRevision += 1
    }

    func saveTripModes(_ modes: [TripMode]) -> Bool {
        guard TripModeStore.save(modes) else { return false }
        refreshTripModes()
        refresh()
        return true
    }

    func restoreTripModes() -> Bool {
        guard TripModeStore.restoreDefaults() else { return false }
        refreshTripModes()
        refresh()
        return true
    }

    var savesToICloudDrive: Bool {
        get { _ = tick; return GLManager.shared().savesToICloudDrive }
        set { GLManager.shared().savesToICloudDrive = newValue; refresh() }
    }
    var sendOnlyOnWifi: Bool {
        get { _ = tick; return WifiOnlySending.shared.enabled }
        set { WifiOnlySending.shared.enabled = newValue; refresh() }
    }
    var cloudFileMode: Int {
        get { _ = tick; return GLManager.shared().cloudFileMode.rawValue }
        set { GLManager.shared().cloudFileMode = GLCloudFileMode(rawValue: newValue) ?? .daily; refresh() }
    }
    var cloudAvailable: Bool { GLCloudFileWriter.isAvailable() }
    var historyRetentionHours: Double {
        get { _ = tick; return Double(HistoryRetention.hours) }
        set {
            guard newValue.isFinite else { return }
            let hours = min(Double(HistoryRetention.maximumHours), max(Double(HistoryRetention.minimumHours), newValue))
            RecentLocationHistory.shared.setRetentionHours(Int(hours.rounded()))
            refresh()
        }
    }

    func loadHistoryStorageSummary() async -> HistoryStorageSummary {
        await withCheckedContinuation { continuation in
            RecentLocationHistory.shared.loadStorageSummary { continuation.resume(returning: $0) }
        }
    }

    var tripLiveActivityEnabled: Bool {
        get { _ = tick; return GLManager.shared().tripLiveActivityEnabled }
        set { GLManager.shared().tripLiveActivityEnabled = newValue; refresh() }
    }
    var tripAskToEndWhenStopped: Bool {
        get { _ = tick; return TripEndPrompt.shared.enabled }
        set { TripEndPrompt.shared.enabled = newValue; refresh() }
    }
    var discardWithoutGPS: Bool {
        get { _ = tick; return GLManager.shared().discardPointsWithoutGPS }
        set { GLManager.shared().discardPointsWithoutGPS = newValue; refresh() }
    }
    var tripDiscardWithoutGPS: Bool {
        get { _ = tick; return GLManager.shared().discardPointsWithoutGPSDuringTrip }
        set { GLManager.shared().discardPointsWithoutGPSDuringTrip = newValue; refresh() }
    }
    var discardStationary: Bool {
        get { _ = tick; return GLManager.shared().discardPointsWhileStationary }
        set { GLManager.shared().discardPointsWhileStationary = newValue; refresh() }
    }
    var tripDiscardStationary: Bool {
        get { _ = tick; return GLManager.shared().discardPointsWhileStationaryDuringTrip }
        set { GLManager.shared().discardPointsWhileStationaryDuringTrip = newValue; refresh() }
    }
    var healthAvailable: Bool { HealthTripRecorder.isAvailable }
    @MainActor var workoutImporter: WorkoutRouteImporter { .shared }
    @MainActor func setAutomaticWorkoutImport(_ enabled: Bool) { WorkoutRouteImporter.shared.setAutomatic(enabled) }
    @MainActor func setWorkoutImportDays(_ days: Int) { WorkoutRouteImporter.shared.setDays(days) }
    var healthEnabled: Bool { _ = tick; return HealthTripRecorder.shared.isEnabled }
    var healthLastError: String? { _ = tick; return HealthTripRecorder.shared.lastError }

    func setHealthEnabled(_ enabled: Bool) {
        guard !healthRequestInFlight else { return }
        healthAuthorizationError = nil
        guard enabled else {
            HealthTripRecorder.shared.isEnabled = false
            refresh()
            return
        }
        healthRequestInFlight = true
        HealthTripRecorder.shared.requestAuthorization { [weak self] error in
            guard let self else { return }
            healthRequestInFlight = false
            healthAuthorizationError = error
            if error == nil { HealthTripRecorder.shared.isEnabled = true }
            refresh()
        }
    }

    static var activityTypes: [CLActivityType] {
        var types: [CLActivityType] = [.other, .automotiveNavigation, .fitness, .otherNavigation, .airborne]
        if #available(iOS 27.0, *) { types.append(.maritime) }
        return types
    }

    private(set) var tick = 0
    private(set) var clockTick = 0
    private(set) var trackingEnabled = false
    private(set) var engineStatus = "Unavailable"
    private(set) var authorizationStatus = "Not Determined"
    private(set) var queueCount = 0
    private(set) var lastLocationAge = "–"
    private(set) var lastLocationText = "–"
    private(set) var lastAccuracyText = "No location yet"
    private(set) var speed = 0
    private(set) var tripInProgress = false
    private(set) var sending = false
    private(set) var endpointSet = false
    private(set) var destinationSet = false
    private(set) var speedUnit = "MPH"
    private(set) var lastSentText = "–"
    private(set) var sendHistory: [SendStatusEntry] = []
    private(set) var adaptiveTrackingStatus = "Off"
    private(set) var motionAuthorizationStatus = "Unavailable"
    private(set) var motionSummary = "Motion activity is unavailable."
    private(set) var lastReceivedLocation: CLLocation?
    private(set) var lastReceivedLocationText = "–"
    private(set) var lastReceivedLocationAge = "–"
    private(set) var lastReceivedAccuracyText = "No location yet"
    private(set) var rejectedJumpCount: UInt = 0
    private(set) var pendingUploads = false
    private(set) var uploadsBlocked = false
    private(set) var uploadRetryDate: Date?
    private(set) var waitingForWifi = false

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var activeScenes: Set<UUID> = []

    private init() {
        let nc = NotificationCenter.default
        for name in [GLNewDataNotification, GLSendingStartedNotification, GLSendingFinishedNotification,
                     GLSettingsChangedNotification, GLAuthorizationStatusChangedNotification, GLNewActivityNotification,
                     GLTrackingStateChangedNotification, GLUploadStateChangedNotification,
                     "WhereEngineStateChanged", "WhereLiveUpdatesFailed", "WhereUploadSchedulerStateChanged",
                     "WhereLocationHealthChanged"] {
            observers.append(nc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.activeScenes.isEmpty else { return }
                self.refresh()
            })
        }
        refresh()
    }

    func setSceneActive(_ active: Bool, id: UUID) {
        if active { activeScenes.insert(id) } else { activeScenes.remove(id) }
        if activeScenes.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.refreshClock()
            }
            timer?.tolerance = 0.25
        }
    }

    private func refreshClock() {
        guard let gl = GLManager.shared() else { return }
        clockTick += 1
        lastLocationAge = gl.lastLocation.map { Self.timeFormatted(max(0, Int(-$0.timestamp.timeIntervalSinceNow))) } ?? "–"
        lastSentText = gl.lastSentDate.map { Self.timeFormatted(max(0, Int(-$0.timeIntervalSinceNow))) + " ago" } ?? "–"
        updateReceivedLocation(gl.lastReceivedLocation)
        rejectedJumpCount = gl.rejectedJumpCount
    }

    func refresh() {
        guard let gl = GLManager.shared() else { return }
        tick += 1
        let catalog = TripModeStore.modes
        if tripModes != catalog { tripModes = catalog; tripModesRevision += 1 }
        latestSendError = gl.lastSendErrorMessage
        trackingEnabled = gl.trackingEnabled
        engineStatus = ["receiving": "Receiving", "stationary": "Stationary", "authorization-limited": "Location access limited",
                        "accuracy-limited": "Accuracy limited", "unavailable": "Unavailable", "failed": "Engine failed"][gl.engineState] ?? "Unavailable"
        authorizationStatus = gl.authorizationStatusAsString()
        queueCount = Int(gl.currentPointsInQueue)
        tripInProgress = gl.tripInProgress()
        sending = gl.sendInProgress
        endpointSet = !(gl.apiEndpointURL() ?? "").isEmpty
        destinationSet = gl.hasDestination()
        speedUnit = (Locale.current.measurementSystem == .metric) ? "KM/H" : "MPH"
        adaptiveTrackingStatus = gl.adaptiveTrackingStatus
        motionAuthorizationStatus = gl.motionAuthorizationStatus
        motionSummary = gl.motionSummary
        rejectedJumpCount = gl.rejectedJumpCount
        pendingUploads = gl.pendingUploads
        uploadsBlocked = gl.uploadsBlocked
        uploadRetryDate = gl.uploadRetryDate
        waitingForWifi = gl.waitingForWifi

        refreshClock()

        let results = (gl.recentSendResults() as? [[String: NSNumber]]) ?? []
        sendHistory = results.enumerated().map { idx, entry in
            SendStatusEntry(
                id: idx,
                date: Date(timeIntervalSince1970: entry["ts"]?.doubleValue ?? 0),
                kind: SendStatusEntry.Kind(rawValue: entry["status"]?.intValue ?? SendStatusEntry.Kind.network.rawValue) ?? .network
            )
        }

        if let loc = gl.lastLocation {
            lastLocationText = String(format: "%.4f\n%.4f", loc.coordinate.latitude, loc.coordinate.longitude)
            lastAccuracyText = String(format: "±%.0f m", loc.horizontalAccuracy)
            let age = max(0, Int(-loc.timestamp.timeIntervalSinceNow))
            lastLocationAge = Self.timeFormatted(age)
            let metric = (Locale.current.measurementSystem == .metric)
            let raw = metric ? loc.speed * 3.6 : loc.speed * 2.23694
            speed = max(0, Int(raw.rounded()))
        } else {
            lastLocationAge = "–"
            lastLocationText = "–"
            lastAccuracyText = "No location yet"
            speed = 0
        }

    }

    func saveServer(url: String, token: String, deviceId: String, uniqueId: Bool, acceptHTTP: Bool, headers: [String: String]) {
        guard let gl = GLManager.shared() else { return }
        gl.saveNewDeviceId(deviceId)
        gl.customHTTPHeaders = headers
        UserDefaults.standard.set(uniqueId, forKey: GLIncludeUniqueIdDefaultsName)
        UserDefaults.standard.set(acceptHTTP, forKey: GLConsiderHTTP200SuccessDefaultsName)
        gl.saveNewAPIEndpoint(url, andAccessToken: token)
        refresh()
    }

    func clearServer() {
        GLManager.shared().saveNewAPIEndpoint(nil, andAccessToken: nil)
        refresh()
    }

    var wifiZones: [[String: String]] {
        _ = tick
        return (GLManager.shared().wifiZones ?? []).map { $0.compactMapValues { $0 as? String } }
    }

    func wifiNetworkSnapshot() -> (current: WifiZoneNetwork?, known: [WifiZoneNetwork], location: CLLocation?) {
        let info = (GLManager.currentWifiNetworkInfo() as? [String: String]) ?? [:]
        let current = WifiZoneNetwork(info)
        let gl = GLManager.shared()!
        let known = (gl.knownWifiNetworks(includingSavedZones: true) ?? []).compactMap(WifiZoneNetwork.init)
        return (current, known, wifiZoneLocation)
    }

    var wifiZoneLocation: CLLocation? {
        _ = clockTick
        guard let gl = GLManager.shared(), let location = gl.lastReceivedLocation ?? gl.lastLocation,
              CLLocationCoordinate2DIsValid(location.coordinate), abs(location.timestamp.timeIntervalSinceNow) <= 60 else { return nil }
        return location
    }

    func saveWifiNetworks(_ networks: [WifiZoneNetwork], latitude: String, longitude: String) -> Bool {
        let saved = GLManager.shared().addWifiNetworks(networks.map(\.dictionary), latitude: latitude, longitude: longitude)
        if saved { refresh() }
        return saved
    }

    func removeWifiZones(at offsets: IndexSet) {
        for index in offsets.sorted(by: >) { GLManager.shared().removeWifiZone(at: index) }
        refresh()
    }

    private static func timeFormatted(_ totalSeconds: Int) -> String {
        let seconds = totalSeconds % 60
        let minutes = (totalSeconds / 60) % 60
        let hours = totalSeconds / 3600
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, seconds)
        }
        return String(format: "%d:%02d", minutes, seconds)
    }

    private func updateReceivedLocation(_ location: CLLocation?) {
        lastReceivedLocation = location
        guard let location else {
            lastReceivedLocationText = "–"
            lastReceivedLocationAge = "–"
            lastReceivedAccuracyText = "No location yet"
            return
        }
        lastReceivedLocationText = String(format: "%.4f\n%.4f", location.coordinate.latitude, location.coordinate.longitude)
        lastReceivedLocationAge = Self.timeFormatted(max(0, Int(-location.timestamp.timeIntervalSinceNow)))
        lastReceivedAccuracyText = String(format: "±%.0f m", location.horizontalAccuracy)
    }

    // MARK: Settings

    var usageProfile: Int {
        get {
            _ = tick
            return GLManager.shared().usageProfile()
        }
        set {
            GLManager.shared().applyUsageProfile(newValue)
            refresh()
        }
    }

    var trackingOn: Bool {
        get {
            _ = tick
            return trackingEnabled
        }
        set {
            newValue ? GLManager.shared().startAllUpdates() : GLManager.shared().stopAllUpdates()
            IntentDonations.trackingChanged(enabled: newValue)
            refresh()
        }
    }

    var useNewLocationEngine: Bool {
        get { _ = tick; return GLManager.shared().useNewLocationEngine }
        set { GLManager.shared().useNewLocationEngine = newValue; refresh() }
    }

    func advancedBool(_ key: String) -> Bool {
        _ = tick
        return GLManager.shared().advancedTrackingOptions[key]?.boolValue ?? false
    }

    func setAdvancedBool(_ value: Bool, forKey key: String) {
        GLManager.shared().setAdvancedTrackingOption(NSNumber(value: value), forKey: key)
        refresh()
    }

    func advancedValue(_ key: String) -> Double {
        _ = tick
        return GLManager.shared().advancedTrackingOptions[key]?.doubleValue ?? 0
    }

    func setAdvancedValue(_ value: Double, forKey key: String) {
        GLManager.shared().setAdvancedTrackingOption(NSNumber(value: value), forKey: key)
        refresh()
    }

    var hasContinuousUpdates: Bool {
        _ = tick
        return GLManager.shared().hasContinuousUpdates
    }

    var backgroundRefreshStatus: String {
        _ = tick
        switch UIApplication.shared.backgroundRefreshStatus {
        case .available: return "Available"
        case .denied: return "Off or Limited by Low Power Mode"
        case .restricted: return "Restricted by iOS"
        @unknown default: return "Unavailable"
        }
    }

    var locationHealth: [String: Any] {
        _ = tick
        _ = clockTick
        return GLManager.shared().locationUpdateHealth
    }

    func loadLocationHealthLog() async -> [LocationHealthEntry] {
        await withCheckedContinuation { continuation in
            GLManager.shared().loadLocationHealthLog { entries in
                continuation.resume(returning: (entries ?? []).compactMap(LocationHealthEntry.init))
            }
        }
    }

    func clearLocationHealthLog() async {
        await withCheckedContinuation { continuation in
            GLManager.shared().clearLocationHealthLog { continuation.resume() }
        }
    }

    func retryLocationUpdates() {
        GLManager.shared().refreshLocation()
        refresh()
    }

    var trackingModeIndex: Int {
        get {
            _ = tick
            return Int(GLManager.shared().trackingMode.rawValue)
        }
        set {
            GLManager.shared().trackingMode = GLTrackingMode(rawValue: UInt32(newValue))
            if newValue != 3 {
                GLManager.shared().stopsAutomaticallyRadius = -1
            }
            refresh()
        }
    }

    var visitTracking: Bool {
        get {
            _ = tick
            return GLManager.shared().visitTrackingEnabled
        }
        set {
            GLManager.shared().visitTrackingEnabled = newValue
            refresh()
        }
    }

    // Accuracy: Custom (meters via slider), Best, or Navigation-grade.
    var accuracyPreset: Int {
        get {
            _ = tick
            switch GLManager.shared().desiredAccuracy {
            case kCLLocationAccuracyBestForNavigation: return 2
            case kCLLocationAccuracyBest: return 1
            default: return 0
            }
        }
        set {
            switch newValue {
            case 2: GLManager.shared().desiredAccuracy = kCLLocationAccuracyBestForNavigation
            case 1: GLManager.shared().desiredAccuracy = kCLLocationAccuracyBest
            default: GLManager.shared().desiredAccuracy = accuracyMeters
            }
            refresh()
        }
    }

    var accuracyMeters: Double {
        get {
            _ = tick
            let v = GLManager.shared().desiredAccuracy
            return v > 0 ? v : 100
        }
        set {
            GLManager.shared().desiredAccuracy = newValue.rounded()
            refresh()
        }
    }

    var activityIndex: Int {
        get { _ = tick; return Self.activityTypes.firstIndex(of: GLManager.shared().activityType) ?? 0 }
        set {
            guard Self.activityTypes.indices.contains(newValue) else { return }
            GLManager.shared().activityType = Self.activityTypes[newValue]
            refresh()
        }
    }

    @MainActor var liveActivityEnabled: Bool {
        get {
            _ = tick
            return WhereBackgroundRuntime.shared.liveActivityEnabled
        }
        set { WhereBackgroundRuntime.shared.liveActivityEnabled = newValue; refresh() }
    }

    @MainActor var liveActivityAppearance: String {
        get {
            _ = tick
            return WhereBackgroundRuntime.shared.appearance
        }
        set { WhereBackgroundRuntime.shared.appearance = newValue; refresh() }
    }

    @MainActor var hideLiveActivityWhileAudioPlays: Bool {
        get {
            _ = tick
            return WhereBackgroundRuntime.shared.hideWhileAudioPlays
        }
        set { WhereBackgroundRuntime.shared.hideWhileAudioPlays = newValue; refresh() }
    }

    @MainActor var silentAudioEnabled: Bool {
        get {
            _ = tick
            return WhereBackgroundRuntime.shared.silentAudioEnabled
        }
        set { WhereBackgroundRuntime.shared.silentAudioEnabled = newValue; refresh() }
    }

    @MainActor var liveActivityStatus: String { WhereBackgroundRuntime.shared.activityStatus }
    @MainActor var silentAudioStatus: String { WhereBackgroundRuntime.shared.audioStatus }

    @MainActor var actualLocationEngine: String {
        _ = tick
        let gl = GLManager.shared()!
        guard trackingEnabled else { return "Stopped" }
        let authorization = gl.locationManager.authorizationStatus
        guard authorization == .authorizedAlways || authorization == .authorizedWhenInUse else { return "Waiting for location access" }
        if gl.didPauseByRadius { return "Paused within radius" }
        if !gl.hasContinuousUpdates { return "Event-based updates" }
        return WhereLocationEngine.shared.usingLiveUpdates ? "New · live updates" : "Original · location manager"
    }

    @MainActor var locationEngineReason: String {
        _ = tick
        let gl = GLManager.shared()!
        guard trackingEnabled, gl.hasContinuousUpdates, !gl.didPauseByRadius else { return "" }
        let authorization = gl.locationManager.authorizationStatus
        guard authorization == .authorizedAlways || authorization == .authorizedWhenInUse else {
            return "Allow location access to resume tracking."
        }
        if WhereLocationEngine.shared.liveUpdatesFailed {
            return "The new location engine stopped after repeated failures; the original location manager is collecting fixes. Tap Retry Background Helpers to try the new engine again."
        }
        let adaptiveStatus = gl.adaptiveTrackingStatus.lowercased()
        if adaptiveStatus.contains("quiet") || adaptiveStatus.contains("stationary") || adaptiveStatus.contains("lower accuracy") {
            return "Adaptive tracking is quiet after a confirmed stop; it is using a coarser request while watching for movement."
        }
        if WhereLocationEngine.shared.usingLiveUpdates { return "iOS chooses accuracy and automatic pause timing." }
        let indicator = gl.tripInProgress() ? gl.showBackgroundLocationIndicatorDuringTrip : gl.showBackgroundLocationIndicator
        if !indicator, gl.locationManager.authorizationStatus == .authorizedAlways,
           !WhereBackgroundRuntime.hasBackgroundLocationActivity {
            return WhereBackgroundRuntime.shared.appearance == "blank"
                && WhereBackgroundRuntime.hasActiveTrackingActivity
                ? "Blank Island with the indicator off uses the original engine for background tracking."
                : "The original engine keeps background tracking available without a supporting Live Activity."
        }
        return "Using your saved accuracy and automatic-pause settings."
    }

    @MainActor func retryBackgroundRuntime() {
        WhereLocationEngine.shared.resetLiveUpdatesFailure()
        GLManager.shared()?.updateLocationEngine()
        WhereBackgroundRuntime.shared.retry()
        refresh()
    }

    @MainActor var uploadSchedulerStatus: String {
        _ = tick
        return WhereUploadScheduler.shared.status
    }

    func requestMotionPermission() {
        GLManager.shared().requestMotionPermission()
        refresh()
    }

    func retryPendingUpload() {
        GLManager.shared().sendQueueNow()
        refresh()
    }

    var backgroundIndicator: Bool {
        get {
            _ = tick
            return GLManager.shared().showBackgroundLocationIndicator
        }
        set {
            GLManager.shared().showBackgroundLocationIndicator = newValue
            refresh()
        }
    }

    var locationPermission: String {
        _ = tick
        return GLManager.shared().authorizationStatusAsString()
    }

    func requestLocationPermission() {
        GLManager.shared().requestAuthorizationPermission()
        refresh()
    }

    var resumeDistanceMeters: Double {
        get {
            _ = tick
            return max(0, GLManager.shared().resumesAfterDistance)
        }
        set {
            GLManager.shared().resumesAfterDistance = newValue < 1 ? -1 : newValue
            refresh()
        }
    }

    var pausesAutomatically: Bool {
        get {
            _ = tick
            return GLManager.shared().pausesAutomatically
        }
        set {
            GLManager.shared().pausesAutomatically = newValue
            if newValue {
                GLManager.shared().stopsAutomaticallyRadius = -1
            } else {
                GLManager.shared().resumesAfterDistance = -1
            }
            refresh()
        }
    }

    var loggingModeIndex: Int {
        get {
            _ = tick
            return Int(GLManager.shared().loggingMode.rawValue)
        }
        set {
            GLManager.shared().loggingMode = GLLoggingMode(rawValue: UInt32(newValue))
            refresh()
        }
    }

    var batchValue: Double {
        get {
            _ = tick
            return Double(GLManager.shared().pointsPerBatch)
        }
        set {
            GLManager.shared().pointsPerBatch = Int32(newValue.rounded())
            refresh()
        }
    }

    // Discard filters. Values <= 0 are stored as -1 ("Off").
    var discardDistanceMeters: Double {
        get {
            _ = tick
            let v = GLManager.shared().discardPointsWithinDistance
            return v > 0 ? v : 0
        }
        set {
            GLManager.shared().discardPointsWithinDistance = newValue < 1 ? -1 : newValue.rounded()
            refresh()
        }
    }

    var discardSecondsValue: Double {
        get {
            _ = tick
            return Double(max(GLManager.shared().discardPointsWithinSeconds, 0))
        }
        set {
            GLManager.shared().discardPointsWithinSeconds = Int32(newValue.rounded())
            refresh()
        }
    }

    var discardAccuracyMeters: Double {
        get {
            _ = tick
            let v = GLManager.shared().discardPointsOutsideAccuracy
            return v > 0 ? v : 0
        }
        set {
            GLManager.shared().discardPointsOutsideAccuracy = newValue < 1 ? -1 : newValue.rounded()
            refresh()
        }
    }

    var stopRadiusMeters: Double {
        get {
            _ = tick
            let v = GLManager.shared().stopsAutomaticallyRadius
            return v > 0 ? v : 0
        }
        set {
            let radius = newValue < 1 ? -1 : newValue.rounded()
            GLManager.shared().stopsAutomaticallyRadius = radius
            if radius > 0 {
                GLManager.shared().pausesAutomatically = false
                GLManager.shared().resumesAfterDistance = -1
            }
            refresh()
        }
    }

    var stopAfterValue: Double {
        get {
            _ = tick
            return Double(GLManager.shared().stopsAutomaticallyAfterSeconds)
        }
        set {
            GLManager.shared().stopsAutomaticallyAfterSeconds = Int32(newValue.rounded())
            refresh()
        }
    }

    var sendIntervalValue: Double {
        get {
            _ = tick
            return max(0, GLManager.shared().sendingInterval.doubleValue)
        }
        set {
            GLManager.shared().sendingInterval = NSNumber(value: newValue < 1 ? -1 : Int(newValue.rounded()))
            refresh()
        }
    }

    var notifications: Bool {
        get {
            _ = tick
            return GLManager.shared().notificationsEnabled
        }
        set {
            GLManager.shared().notificationsEnabled = newValue
            refresh()
        }
    }

    var includeTrackingStats: Bool {
        get { _ = tick; return GLManager.shared().includeTrackingStats }
        set { GLManager.shared().includeTrackingStats = newValue; refresh() }
    }

    func deletePendingUploads() -> Bool {
        let deleted = GLManager.shared().deleteAllData()
        refresh()
        return deleted
    }

    var problemNotificationsOnly: Bool {
        get { _ = tick; return GLManager.shared().problemNotificationsOnly }
        set { GLManager.shared().problemNotificationsOnly = newValue; refresh() }
    }

    // MARK: Trip Settings (applied only while a trip is in progress)

    var tripAccuracyPreset: Int {
        get {
            _ = tick
            switch GLManager.shared().desiredAccuracyDuringTrip {
            case kCLLocationAccuracyBestForNavigation: return 2
            case kCLLocationAccuracyBest: return 1
            default: return 0
            }
        }
        set {
            switch newValue {
            case 2: GLManager.shared().desiredAccuracyDuringTrip = kCLLocationAccuracyBestForNavigation
            case 1: GLManager.shared().desiredAccuracyDuringTrip = kCLLocationAccuracyBest
            default: GLManager.shared().desiredAccuracyDuringTrip = tripAccuracyMeters
            }
            refresh()
        }
    }

    var tripAccuracyMeters: Double {
        get {
            _ = tick
            let v = GLManager.shared().desiredAccuracyDuringTrip
            return v > 0 ? v : 100
        }
        set {
            GLManager.shared().desiredAccuracyDuringTrip = newValue.rounded()
            refresh()
        }
    }

    var tripMode: String {
        get {
            _ = tick
            return GLManager.shared().currentTripMode ?? "walk"
        }
        set {
            GLManager.shared().currentTripMode = newValue
            refresh()
        }
    }

    var tripDistance: Double {
        _ = tick
        return max(0, GLManager.shared().currentTripDistance())
    }

    var tripDuration: Double {
        _ = clockTick
        return max(0, GLManager.shared().currentTripDuration())
    }

    var tripBatchValue: Double {
        get {
            _ = tick
            return Double(GLManager.shared().pointsPerBatchDuringTrip)
        }
        set {
            GLManager.shared().pointsPerBatchDuringTrip = Int32(newValue.rounded())
            refresh()
        }
    }

    var tripDiscardDistanceMeters: Double {
        get {
            _ = tick
            let v = GLManager.shared().discardPointsWithinDistanceDuringTrip
            return v > 0 ? v : 0
        }
        set {
            GLManager.shared().discardPointsWithinDistanceDuringTrip = newValue < 1 ? -1 : newValue.rounded()
            refresh()
        }
    }

    var tripDiscardSecondsValue: Double {
        get {
            _ = tick
            return Double(max(GLManager.shared().discardPointsWithinSecondsDuringTrip, 0))
        }
        set {
            GLManager.shared().discardPointsWithinSecondsDuringTrip = Int32(newValue.rounded())
            refresh()
        }
    }

    var tripActivityIndex: Int {
        get { _ = tick; return Self.activityTypes.firstIndex(of: GLManager.shared().activityTypeDuringTrip) ?? 0 }
        set {
            guard Self.activityTypes.indices.contains(newValue) else { return }
            GLManager.shared().activityTypeDuringTrip = Self.activityTypes[newValue]
            refresh()
        }
    }

    var tripLoggingModeIndex: Int {
        get {
            _ = tick
            return Int(GLManager.shared().loggingModeDuringTrip.rawValue)
        }
        set {
            GLManager.shared().loggingModeDuringTrip = GLLoggingMode(rawValue: UInt32(newValue))
            refresh()
        }
    }

    var tripBackgroundIndicator: Bool {
        get {
            _ = tick
            return GLManager.shared().showBackgroundLocationIndicatorDuringTrip
        }
        set {
            GLManager.shared().showBackgroundLocationIndicatorDuringTrip = newValue
            refresh()
        }
    }

    var tripPausesAutomatically: Bool {
        get {
            _ = tick
            return GLManager.shared().pausesAutomaticallyDuringTrip
        }
        set {
            GLManager.shared().pausesAutomaticallyDuringTrip = newValue
            if !newValue {
                GLManager.shared().resumesAfterDistance = -1
            }
            refresh()
        }
    }

    var screenLock: Bool {
        get {
            _ = tick
            return UserDefaults.standard.bool(forKey: GLScreenLockEnabledDefaultsName)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: GLScreenLockEnabledDefaultsName)
            UIApplication.shared.isIdleTimerDisabled = newValue && tripInProgress
            refresh()
        }
    }
}

extension View {
    func confirmStopTracking(_ presented: Binding<Bool>, action: @escaping () -> Void) -> some View {
        alert("Stop location tracking?", isPresented: presented) {
            Button("Stop Tracking", role: .destructive, action: action)
            Button("Keep Tracking", role: .cancel) { }
        } message: {
            Text("New locations will stop recording. Queued locations stay saved for sending later.")
        }
    }
}
