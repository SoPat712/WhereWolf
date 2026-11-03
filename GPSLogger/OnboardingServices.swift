import ActivityKit
import CoreLocation
import CoreMotion
import HealthKit
import UIKit
import UserNotifications
import WatchConnectivity

enum WhereWolfLinks {
    static let privacy = URL(string: "https://sopat712.github.io/WhereWolf/privacy/")!
}

extension GLManagerBridge {
    func requestWhenInUsePermission() {
        let gl = GLManager.shared()!
        guard gl.locationManager.authorizationStatus == .notDetermined else { return }
        gl.requestAuthorizationPermission()
    }

    func requestAlwaysPermission() {
        let gl = GLManager.shared()!
        guard gl.locationManager.authorizationStatus == .authorizedWhenInUse else { return }
        gl.requestAuthorizationPermission()
    }

    @MainActor func requestOnboardingNotifications() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            GLManager.shared().requestNotificationPermission { _ in
                self.refresh()
                continuation.resume()
            }
        }
    }

    @MainActor func requestOnboardingHealth() async -> String? {
        await withCheckedContinuation { continuation in
            setHealthEnabled(true) { continuation.resume(returning: $0) }
        }
    }

    @MainActor func requestWorkoutImportAccess() async -> String? {
        await workoutImporter.connect()
        refresh()
        return workoutImporter.error
    }

    func applySetupURL(_ url: URL) -> Bool {
        guard ["wherewolf", "overland"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.lowercased() == "setup",
              let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems else { return false }
        func value(_ key: String) -> String? { items.first { $0.name == key }?.value }
        guard let endpoint = value("url"), GLManager.isValidEndpoint(endpoint) else { return false }
        let gl = GLManager.shared()!
        var headers: [String: String] = [:]
        for item in items where item.name.hasPrefix("header_") && item.name.count > 7 {
            if let value = item.value { headers[String(item.name.dropFirst(7))] = value }
        }
        return saveServer(url: endpoint, token: value("token") ?? "", deviceId: value("device_id") ?? "",
                   uniqueId: value("unique_id") == "yes",
                   acceptHTTP: UserDefaults.standard.bool(forKey: GLConsiderHTTP200SuccessDefaultsName),
                   headers: headers.isEmpty ? gl.customHTTPHeaders : headers)
    }

    func applyOnboardingDestination(_ destination: OnboardingDestination) -> Bool {
        switch destination {
        case .setupLink(let text):
            guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
                  applySetupURL(url) else { return false }
            savesToICloudDrive = false
        case .server(let endpoint, let token, let ownTracks):
            let endpoint = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            guard GLManager.isValidEndpoint(endpoint) else { return false }
            let gl = GLManager.shared()!
            guard saveServer(url: endpoint, token: token, deviceId: gl.deviceId() ?? "",
                       uniqueId: UserDefaults.standard.bool(forKey: GLIncludeUniqueIdDefaultsName),
                       acceptHTTP: ownTracks || UserDefaults.standard.bool(forKey: GLConsiderHTTP200SuccessDefaultsName),
                       headers: gl.customHTTPHeaders) else { return false }
            loggingModeIndex = ownTracks ? 2 : (loggingModeIndex == 2 ? 0 : loggingModeIndex)
            savesToICloudDrive = false
        case .iCloud:
            savesToICloudDrive = true
        case .device:
            guard clearServer() else { return false }
            savesToICloudDrive = false
        }
        refresh()
        return true
    }

    @MainActor func onboardingStatus() async -> OnboardingStatus {
        refresh()
        let gl = GLManager.shared()!
        var result = OnboardingStatus()
        switch gl.locationManager.authorizationStatus {
        case .notDetermined: result.location = .notDetermined
        case .authorizedWhenInUse: result.location = .whileUsing
        case .authorizedAlways: result.location = .always
        case .denied: result.location = .denied
        case .restricted: result.location = .restricted
        @unknown default: result.location = .restricted
        }
        result.preciseLocation = gl.locationManager.accuracyAuthorization == .fullAccuracy
        if !CMMotionActivityManager.isActivityAvailable() {
            result.motion = .unavailable
        } else {
            switch CMMotionActivityManager.authorizationStatus() {
            case .notDetermined: result.motion = .notDetermined
            case .authorized: result.motion = .granted
            case .denied: result.motion = .denied
            case .restricted: result.motion = .limited
            @unknown default: result.motion = .unavailable
            }
        }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: result.notifications = .notDetermined
        case .authorized: result.notifications = .granted
        case .denied: result.notifications = .denied
        case .provisional, .ephemeral: result.notifications = .limited
        @unknown default: result.notifications = .unavailable
        }
        result.notificationsEnabled = notifications
        result.healthAvailable = healthAvailable
        if healthAvailable {
            switch HKHealthStore().authorizationStatus(for: HKObjectType.workoutType()) {
            case .notDetermined: result.healthWrite = .notDetermined
            case .sharingAuthorized: result.healthWrite = .granted
            case .sharingDenied: result.healthWrite = .denied
            @unknown default: result.healthWrite = .unavailable
            }
            result.healthEnabled = healthEnabled
            result.healthReadReviewed = workoutImporter.connected
        } else { result.healthWrite = .unavailable }
        result.cloudSelected = savesToICloudDrive
        result.serverConfigured = endpointSet
        result.destination = savesToICloudDrive ? (cloudAvailable ? "iCloud Drive" : "iCloud Drive · Unavailable")
            : endpointSet ? (URL(string: gl.apiEndpointURL() ?? "")?.host ?? "Your server") : "This iPhone"
        result.usagePreset = usageProfile
        result.tracking = trackingOn
        result.tripActive = tripInProgress
        result.liveActivity = liveActivityEnabled ? liveActivityAppearance.capitalized : "Off"
        if liveActivityEnabled && !ActivityAuthorizationInfo().areActivitiesEnabled {
            result.liveActivity += " · Disabled in iOS Settings"
        }
        result.hideForAudio = hideLiveActivityWhileAudioPlays
        result.askToReopen = askToReopenAfterAudio
        result.backgroundRefresh = backgroundRefreshStatus
        result.lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        result.watchPaired = WCSession.isSupported() && WCSession.default.isPaired
        result.activeHelpers = [backgroundIndicator, advancedBool("background_recovery"),
                                advancedBool("explicit_service_session"), advancedBool("automatic_location_retry"),
                                silentAudioEnabled].filter { $0 }.count
        result.sendInterval = sendIntervalValue < 1 ? "Manual" : SettingFormat.seconds(sendIntervalValue)
        result.silentAudio = silentAudioEnabled
        return result
    }
}

extension OnboardingModel {
    static func live() -> OnboardingModel {
        let bridge = GLManagerBridge.shared
        return OnboardingModel(defaults: .standard, actions: OnboardingActions(
            loadStatus: { await bridge.onboardingStatus() },
            request: { permission in
                switch permission {
                case .whileUsing: bridge.requestWhenInUsePermission()
                case .always: bridge.requestAlwaysPermission()
                case .motion: bridge.requestMotionPermission()
                case .notifications: await bridge.requestOnboardingNotifications()
                case .healthWrite: return await bridge.requestOnboardingHealth()
                case .healthRead: return await bridge.requestWorkoutImportAccess()
                }
                return nil
            },
            openSettings: { UIApplication.shared.open(URL(string: UIApplication.openSettingsURLString)!) },
            applyDestination: { bridge.applyOnboardingDestination($0) },
            applyPreset: { bridge.usageProfile = $0 },
            startTracking: { bridge.trackingOn = true }
        ))
    }
}

// Both scene setup links and pasted links use the bridge's validated configuration path.
@objc final class WhereWolfSetupURLHandler: NSObject {
    @objc static func apply(_ url: URL) -> Bool { GLManagerBridge.shared.applySetupURL(url) }
}
