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

struct UploadPresentation {
    var sending = false
    var retryDate: Date?
    var blocked = false
    var failureReason: String?
    var queued = 0
    var batchesCompleted = 0
    var savesToCloud = false
    var destinationSet = true
    var waitingForWifi = false
    var now = Date()

    var waitingToRetry: Bool { !sending && retryDate.map { $0 > now } == true }
    var canSend: Bool { destinationSet && queued > 0 && !sending }
    var buttonTitle: String {
        if sending { return savesToCloud ? "Saving" : "Sending" }
        if waitingToRetry || blocked { return "Retry Now" }
        return savesToCloud ? "Save Now" : "Send Now"
    }
    var showsStatus: Bool { queued > 0 && (sending || waitingToRetry || blocked || waitingForWifi || failureReason != nil) }
    var statusText: String {
        if sending {
            let completed = savesToCloud ? "saved" : "sent"
            return "\(buttonTitle) · \(batchesCompleted.formatted()) batch\(batchesCompleted == 1 ? "" : "es") \(completed) · \(queued.formatted()) points left"
        }
        var status: String
        if waitingToRetry, let retryDate {
            status = "Waiting to retry, next attempt at \(retryDate.formatted(date: .abbreviated, time: .shortened))"
        } else if blocked {
            status = "Waiting for you to retry"
        } else if waitingForWifi && !savesToCloud {
            status = "Waiting for Wi-Fi to send"
        } else {
            status = "\(queued.formatted()) points waiting"
        }
        if let failureReason { status += ". \(failureReason)" }
        return status
    }
}

// Notifications refresh SwiftUI's view of the Objective-C manager.
// Settings use its setters to preserve persistence and tracking changes.
@Observable
final class GLManagerBridge {
    static let shared = GLManagerBridge()
    typealias ProbeDawarich = (DawarichServer, [String: String], @escaping (DawarichStatus, Bool) -> Void) -> DawarichProbe

    private(set) var tripModes = TripModeStore.modes
    private(set) var tripModesRevision = 0
    private(set) var recentTrips: [TripSummary] = []
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
    var tripMapOnLockScreen: Bool {
        get { _ = tick; return TripActivityMapSettings.showsOnLockScreen() }
        set {
            UserDefaults.standard.set(newValue, forKey: TripActivityMapSettings.lockScreenKey)
            GLManager.shared().syncTripLiveActivity()
            refresh()
        }
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

    func setHealthEnabled(_ enabled: Bool, completion: ((String?) -> Void)? = nil) {
        guard !healthRequestInFlight else { completion?("A Health access request is already in progress."); return }
        healthAuthorizationError = nil
        guard enabled else {
            HealthTripRecorder.shared.isEnabled = false
            refresh()
            completion?(nil)
            return
        }
        healthRequestInFlight = true
        HealthTripRecorder.shared.requestAuthorization { [weak self] error in
            guard let self else { return }
            healthRequestInFlight = false
            healthAuthorizationError = error
            if error == nil { HealthTripRecorder.shared.isEnabled = true }
            refresh()
            completion?(error)
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
    private(set) var dawarich: DawarichStatus = .unknown
    private(set) var dawarichConfigurationRevision = 0
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
    private(set) var uploadFailureReason: String?
    private(set) var uploadBatchesCompleted = 0
    private(set) var uploadDraining = false
    private(set) var waitingForWifi = false

    var uploadPresentation: UploadPresentation {
        UploadPresentation(sending: sending || uploadDraining, retryDate: uploadRetryDate,
                           blocked: uploadsBlocked, failureReason: uploadFailureReason,
                           queued: queueCount, batchesCompleted: uploadBatchesCompleted,
                           savesToCloud: savesToICloudDrive, destinationSet: destinationSet,
                           waitingForWifi: waitingForWifi)
    }

    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var activeScenes: Set<UUID> = []
    @ObservationIgnored private var recordedTrips: [TripSummary] = []
    @ObservationIgnored private var loadingRecordedTrips = false
    @ObservationIgnored private var dawarichProbe: DawarichProbe?
    @ObservationIgnored private var dawarichProbeID = UUID()
    @ObservationIgnored private var dawarichServer: DawarichServer?
    @ObservationIgnored private var dawarichHeaders: [String: String] = [:]
    @ObservationIgnored private let probeDawarich: ProbeDawarich

    init(probeDawarich: @escaping ProbeDawarich = { server, headers, completion in
        server.probeForHistory(headers: headers, completion: completion)
    }) {
        self.probeDawarich = probeDawarich
        let nc = NotificationCenter.default
        for name in [GLNewDataNotification, GLSendingStartedNotification, GLSendingFinishedNotification,
                     GLSettingsChangedNotification, GLAuthorizationStatusChangedNotification, GLNewActivityNotification,
                     GLTrackingStateChangedNotification, GLUploadStateChangedNotification,
                     "WhereWolfEngineStateChanged", "WhereWolfLiveUpdatesFailed", "WhereWolfUploadSchedulerStateChanged",
                     "WhereWolfLocationHealthChanged", TripLog.changed.rawValue,
                     UIApplication.significantTimeChangeNotification.rawValue] {
            observers.append(nc.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                guard let self, !self.activeScenes.isEmpty else { return }
                self.refresh()
                // Compare with the configuration this bridge last checked: saves already re-check, and the history
                // store learns of them only later on the main queue, so comparing with it probed every save twice.
                if name == UIApplication.significantTimeChangeNotification.rawValue
                    || (name == GLSettingsChangedNotification && self.dawarichConfigurationChanged()) {
                    self.refreshDawarich()
                }
            })
        }
        refresh()
    }

    deinit {
        timer?.invalidate()
        dawarichProbe?.cancel()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func setSceneActive(_ active: Bool, id: UUID) {
        if active { activeScenes.insert(id) } else { activeScenes.remove(id) }
        if activeScenes.isEmpty {
            timer?.invalidate()
            timer = nil
        } else if timer == nil {
            refresh()
            refreshDawarich()
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                self?.refreshClock()
            }
            timer?.tolerance = 0.25
        }
    }

    // Trips rebuilt from retained history list the ones whose summaries were never saved, and complete ones are
    // saved. Reading every trip fix waits for the Trip tab rather than running on each refresh.
    func loadRecordedTrips() {
        guard !loadingRecordedTrips else { return }
        loadingRecordedTrips = true
        RecentLocationHistory.shared.loadTripFixes { [weak self] fixes in
            guard let self else { return }
            self.loadingRecordedTrips = false
            let current = GLManager.shared().flatMap { $0.tripInProgress() ? $0.currentTripStart() : nil }
            let rebuilt = TripLog.rebuiltTrips(fixes, excluding: current)
            self.recordedTrips = rebuilt.map(\.trip)
            TripLog.save(rebuilt.filter(\.complete).map(\.trip))
            self.refresh()
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
        validateDawarichConfiguration(gl)
        tick += 1
        let catalog = TripModeStore.modes
        if tripModes != catalog { tripModes = catalog; tripModesRevision += 1 }
        let trips = TripLog.merged(TripLog.trips, recorded: recordedTrips)
        if recentTrips != trips { recentTrips = trips }
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
        uploadFailureReason = gl.uploadFailureReason
        uploadBatchesCompleted = Int(gl.uploadBatchesCompleted)
        uploadDraining = gl.uploadDraining
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

    @discardableResult
    func saveServer(url: String, token: String, deviceId: String, uniqueId: Bool, acceptHTTP: Bool, headers: [String: String]) -> Bool {
        guard let gl = GLManager.shared(), GLManager.isValidEndpoint(url),
              SettingsSchema.validHeaders(headers) != nil else { return false }
        var saved = false
        gl.performSettingsBatch {
            saved = gl.saveNewAPIEndpoint(url, andAccessToken: token)
            guard saved else { return }
            gl.saveNewDeviceId(deviceId)
            gl.customHTTPHeaders = headers
            UserDefaults.standard.set(uniqueId, forKey: GLIncludeUniqueIdDefaultsName)
            UserDefaults.standard.set(acceptHTTP, forKey: GLConsiderHTTP200SuccessDefaultsName)
        }
        refresh()
        if saved { refreshDawarich() }
        return saved
    }

    @discardableResult func clearServer() -> Bool {
        let saved = GLManager.shared().saveNewAPIEndpoint(nil, andAccessToken: nil)
        refresh()
        if saved { refreshDawarich() }
        return saved
    }

    func refreshDawarich() {
        if let gl = GLManager.shared() { validateDawarichConfiguration(gl) }
        dawarichProbeID = UUID()
        let probeID = dawarichProbeID
        dawarichProbe?.cancel()
        dawarichProbe = nil
        guard let gl = GLManager.shared(),
              let server = DawarichServer(endpoint: gl.apiEndpointURL() ?? "", token: gl.apiAccessToken() ?? "") else {
            dawarich = .unknown
            updateServerHistory(endpoint: "", token: "", headers: [:], status: .unknown)
            return
        }
        let endpoint = gl.apiEndpointURL() ?? "", token = gl.apiAccessToken() ?? ""
        let headers: [String: String] = gl.customHTTPHeaders ?? [:]
        updateServerHistory(endpoint: endpoint, token: token, headers: headers, status: .checking)
        // Rechecking unchanged credentials must keep Insights and its cached content available.
        let authenticated: DawarichStatus?
        if case .dawarich(_, true, _) = dawarich { authenticated = dawarich }
        else { authenticated = nil }
        dawarich = authenticated ?? .checking
        dawarichProbe = probeDawarich(server, headers) { [weak self] status, rejected in
            DispatchQueue.main.async {
                guard let self, self.dawarichProbeID == probeID else { return }
                self.dawarich = status == .notDawarich && !rejected ? authenticated ?? status : status
                self.dawarichProbe = nil
                ServerHistoryStore.shared.configure(endpoint: endpoint, token: token, headers: headers,
                    status: rejected ? .dawarich(version: nil, authenticated: false, account: nil) : status)
            }
        }
    }

    private func dawarichConfigurationChanged() -> Bool {
        guard let gl = GLManager.shared() else { return false }
        return DawarichServer(endpoint: gl.apiEndpointURL() ?? "", token: gl.apiAccessToken() ?? "") != dawarichServer
            || (gl.customHTTPHeaders ?? [:]) != dawarichHeaders
    }

    private func validateDawarichConfiguration(_ gl: GLManager) {
        let server = DawarichServer(endpoint: gl.apiEndpointURL() ?? "", token: gl.apiAccessToken() ?? "")
        let headers = gl.customHTTPHeaders ?? [:]
        guard server != dawarichServer || headers != dawarichHeaders else { return }
        dawarichServer = server
        dawarichHeaders = headers
        dawarichProbeID = UUID()
        dawarichProbe?.cancel()
        dawarichProbe = nil
        dawarich = .unknown
        dawarichConfigurationRevision &+= 1
    }

    private func updateServerHistory(endpoint: String, token: String, headers: [String: String], status: DawarichStatus) {
        DispatchQueue.main.async {
            ServerHistoryStore.shared.configure(endpoint: endpoint, token: token, headers: headers, status: status)
        }
    }

    var wifiPlaces: [WifiPlace] {
        _ = tick
        return (GLManager.shared().wifiPlaces ?? []).compactMap(WifiPlace.init)
    }

    var observedWifiNetworks: [WifiObservedNetwork] {
        _ = tick
        return (GLManager.knownWifiNetworks() ?? []).compactMap(WifiObservedNetwork.init)
    }

    var frequentWifiNetworks: [WifiObservedNetwork] {
        _ = tick
        return Array((GLManager.frequentWifiNetworks() ?? []).compactMap(WifiObservedNetwork.init).prefix(3))
    }

    var currentWifiSSID: String? {
        _ = tick
        let info = GLManager.currentWifiNetworkInfo() as? [String: Any]
        guard let name = info?["SSID"] as? String, !name.isEmpty, name.utf8.count <= 32 else { return nil }
        return name
    }

    // Matching uses the received fix, before a place can replace its coordinates.
    var matchedWifiPlace: WifiPlace? {
        _ = tick
        _ = clockTick
        guard let gl = GLManager.shared(), let ssid = currentWifiSSID,
              let fix = gl.lastReceivedLocation,
              Self.isUsableWifiPlaceLocation(fix, maximumAge: 20),
              let value = gl.matchingWifiPlace(forSSID: ssid, location: fix) as? [String: Any] else { return nil }
        return WifiPlace(value)
    }

    var wifiPlaceLocation: CLLocation? {
        _ = clockTick
        guard let gl = GLManager.shared() else { return nil }
        if let raw = gl.lastReceivedLocation, Self.isUsableWifiPlaceLocation(raw, maximumAge: 60) { return raw }
        guard let fallback = gl.lastLocation,
              Self.isUsableWifiPlaceLocation(fallback, maximumAge: 60) else { return nil }
        return fallback
    }

    private static func isUsableWifiPlaceLocation(_ location: CLLocation, maximumAge: TimeInterval) -> Bool {
        let age = -location.timestamp.timeIntervalSinceNow
        return CLLocationCoordinate2DIsValid(location.coordinate) && location.horizontalAccuracy >= 0 &&
            location.horizontalAccuracy.isFinite && age.isFinite && (0...maximumAge).contains(age)
    }

    @discardableResult
    func saveWifiPlace(_ place: WifiPlace) -> Bool {
        guard let place = WifiPlace(place.dictionary) else { return false }
        var values = wifiPlaces
        if let index = values.firstIndex(where: { $0.id == place.id }) { values[index] = place }
        else { values.append(place) }
        let saved = GLManager.shared().replaceWifiPlaces(values.map(\.dictionary))
        if saved { refresh() }
        return saved
    }

    @discardableResult
    func removeWifiPlace(_ place: WifiPlace) -> Bool {
        let saved = GLManager.shared().replaceWifiPlaces(wifiPlaces.filter { $0.id != place.id }.map(\.dictionary))
        if saved { refresh() }
        return saved
    }

    // Screens refresh on appearance and when returning from iOS Wi-Fi settings.
    func refreshCurrentWifiNetwork(_ completion: @escaping (String?) -> Void) {
        GLManager.refreshCurrentWifiNetwork { [weak self] info in
            let name = (info as? [String: Any])?["SSID"] as? String
            self?.refresh()
            completion(name.flatMap { !$0.isEmpty && $0.utf8.count <= 32 ? $0 : nil })
        }
    }

    func refreshWifiNetwork() async -> String? {
        await withCheckedContinuation { continuation in
            refreshCurrentWifiNetwork { continuation.resume(returning: $0) }
        }
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

    var usesRecommendedSettings: Bool {
        _ = tick
        guard let gl = GLManager.shared() else { return false }
        let options = gl.advancedTrackingOptions ?? [:]
        return gl.usageProfile() == 6 && gl.discardPointsWithoutGPS
            && gl.desiredAccuracyDuringTrip == kCLLocationAccuracyBest && gl.discardPointsWithoutGPSDuringTrip
            && GLManager.recommendedTrackingOptions().allSatisfy { options[$0]?.boolValue == true }
    }

    func applyRecommendedSettings() {
        GLManager.shared().applyRecommendedSettings()
        refresh()
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
            return WhereWolfBackgroundRuntime.shared.liveActivityEnabled
        }
        set { WhereWolfBackgroundRuntime.shared.liveActivityEnabled = newValue; refresh() }
    }

    @MainActor var liveActivityAppearance: String {
        get {
            _ = tick
            return WhereWolfBackgroundRuntime.shared.appearance
        }
        set { WhereWolfBackgroundRuntime.shared.appearance = newValue; refresh() }
    }

    @MainActor var liveActivityLockScreenCard: Bool {
        get { _ = tick; return WhereWolfBackgroundRuntime.shared.lockScreenCard }
        set { WhereWolfBackgroundRuntime.shared.lockScreenCard = newValue; refresh() }
    }

    @MainActor var liveActivityPresentation: TrackingActivityPresentation {
        _ = tick
        return WhereWolfBackgroundRuntime.shared.presentation
    }

    @MainActor var hideLiveActivityWhileAudioPlays: Bool {
        get {
            _ = tick
            return WhereWolfBackgroundRuntime.shared.hideWhileAudioPlays
        }
        set { WhereWolfBackgroundRuntime.shared.hideWhileAudioPlays = newValue; refresh() }
    }

    @MainActor var askToReopenAfterAudio: Bool {
        get {
            _ = tick
            return WhereWolfBackgroundRuntime.shared.askToReopenAfterAudio
        }
        set { WhereWolfBackgroundRuntime.shared.askToReopenAfterAudio = newValue; refresh() }
    }

    @MainActor var silentAudioEnabled: Bool {
        get {
            _ = tick
            return WhereWolfBackgroundRuntime.shared.silentAudioEnabled
        }
        set { WhereWolfBackgroundRuntime.shared.silentAudioEnabled = newValue; refresh() }
    }

    @MainActor var liveActivityStatus: String { WhereWolfBackgroundRuntime.shared.activityStatus }
    @MainActor var silentAudioStatus: String { WhereWolfBackgroundRuntime.shared.audioStatus }

    @MainActor var actualLocationEngine: String {
        _ = tick
        let gl = GLManager.shared()!
        guard trackingEnabled else { return "Stopped" }
        let authorization = gl.locationManager.authorizationStatus
        guard authorization == .authorizedAlways || authorization == .authorizedWhenInUse else { return "Waiting for location access" }
        if gl.didPauseByRadius { return "Paused within radius" }
        if !gl.hasContinuousUpdates { return "Event-based updates" }
        return WhereWolfLocationEngine.shared.usingLiveUpdates ? "New · live updates" : "Original · location manager"
    }

    @MainActor var locationEngineReason: String {
        _ = tick
        let gl = GLManager.shared()!
        guard trackingEnabled, gl.hasContinuousUpdates, !gl.didPauseByRadius else { return "" }
        let authorization = gl.locationManager.authorizationStatus
        guard authorization == .authorizedAlways || authorization == .authorizedWhenInUse else {
            return "Allow location access to resume tracking."
        }
        if WhereWolfLocationEngine.shared.liveUpdatesFailed {
            return "The new location engine stopped after repeated failures; the original location manager is collecting fixes. Tap Restart Background Features in Background Reliability to try the new engine again."
        }
        let adaptiveStatus = gl.adaptiveTrackingStatus.lowercased()
        if adaptiveStatus.contains("quiet") || adaptiveStatus.contains("stationary") || adaptiveStatus.contains("lower accuracy") {
            return "Adaptive tracking is quiet after a confirmed stop; it is using a coarser request while watching for movement."
        }
        if WhereWolfLocationEngine.shared.usingLiveUpdates { return "iOS chooses accuracy and automatic pause timing." }
        let indicator = gl.tripInProgress() ? gl.showBackgroundLocationIndicatorDuringTrip : gl.showBackgroundLocationIndicator
        if !indicator, gl.locationManager.authorizationStatus == .authorizedAlways,
           !WhereWolfBackgroundRuntime.hasBackgroundLocationActivity {
            return WhereWolfBackgroundRuntime.shared.appearance == "blank"
                && WhereWolfBackgroundRuntime.hasActiveTrackingActivity
                ? "Blank Island with the indicator off uses the original engine for background tracking."
                : "The original engine keeps background tracking available without a supporting Live Activity."
        }
        return "Using your saved accuracy and automatic-pause settings."
    }

    @MainActor func retryBackgroundRuntime() {
        WhereWolfLocationEngine.shared.resetLiveUpdatesFailure()
        GLManager.shared()?.updateLocationEngine()
        WhereWolfBackgroundRuntime.shared.retry()
        refresh()
    }

    @MainActor var uploadSchedulerStatus: String {
        _ = tick
        return WhereWolfUploadScheduler.shared.status
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

    var hasLocationAccess: Bool {
        _ = tick
        let status = GLManager.shared().locationManager.authorizationStatus
        return status == .authorizedAlways || status == .authorizedWhenInUse
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

    var tripStart: Date? {
        _ = tick
        guard let gl = GLManager.shared(), gl.tripInProgress() else { return nil }
        return gl.currentTripStart()
    }

    var tripTopSpeed: Double {
        _ = tick
        return GLManager.shared().currentTripTopSpeed()
    }

    var tripClimb: Double {
        _ = tick
        return GLManager.shared().currentTripClimb()
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
