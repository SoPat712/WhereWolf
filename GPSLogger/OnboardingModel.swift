import Foundation
import Observation

enum OnboardingStep: CaseIterable, Identifiable, Hashable {
    case welcome, whileUsing, always, motion, notifications, destination, preset, liveActivity, health, goodToKnow, done

    var id: Self { self }

    var title: String {
        switch self {
        case .welcome: return "Welcome to WhereWolf"
        case .whileUsing: return "Location While Using"
        case .always: return "Background Location"
        case .motion: return "Motion & Fitness"
        case .notifications: return "Notifications"
        case .destination: return "Choose a Destination"
        case .preset: return "Tracking Preset"
        case .liveActivity: return "Dynamic Island & Live Activity"
        case .health: return "Apple Health"
        case .goodToKnow: return "Good to Know"
        case .done: return "Ready When You Are"
        }
    }
}

enum OnboardingPermission: CaseIterable, Equatable {
    case whileUsing, always, motion, notifications, healthWrite, healthRead
}

enum OnboardingPermissionStatus: String {
    case notDetermined = "Not Determined"
    case granted = "Granted"
    case denied = "Denied"
    case limited = "Limited"
    case unavailable = "Unavailable"
}

enum OnboardingLocationAccess: Equatable {
    case notDetermined, denied, restricted, whileUsing, always
    var allowed: Bool { self == .whileUsing || self == .always }
}

enum OnboardingDestination: Equatable {
    case setupLink(String)
    case server(endpoint: String, token: String, ownTracks: Bool)
    case iCloud
    case device
}

struct OnboardingStatus {
    var location = OnboardingLocationAccess.notDetermined
    var preciseLocation = true
    var motion = OnboardingPermissionStatus.notDetermined
    var notifications = OnboardingPermissionStatus.notDetermined
    var notificationsEnabled = false
    var healthAvailable = false
    var healthWrite = OnboardingPermissionStatus.notDetermined
    var healthEnabled = false
    // HealthKit deliberately does not reveal read authorization.
    var healthReadReviewed = false
    var destination = "Keep on device for now"
    var cloudSelected = false
    var serverConfigured = false
    var usagePreset = 0
    var tracking = false
    var tripActive = false
    var liveActivity = "Blank"
    var hideForAudio = false
    var askToReopen = true
    var backgroundRefresh = "Unavailable"
    var lowPower = false
    var watchPaired = false
    var silentAudio = false

    func permission(_ permission: OnboardingPermission) -> OnboardingPermissionStatus {
        switch permission {
        case .whileUsing:
            switch location {
            case .notDetermined: return .notDetermined
            case .denied: return .denied
            case .restricted: return .limited
            case .whileUsing, .always: return .granted
            }
        case .always:
            if !preciseLocation && location.allowed { return .limited }
            switch location {
            case .always: return .granted
            case .notDetermined, .whileUsing: return .notDetermined
            case .denied: return .denied
            case .restricted: return .limited
            }
        case .motion: return motion
        case .notifications: return notifications
        case .healthWrite: return healthAvailable ? healthWrite : .unavailable
        case .healthRead: return healthAvailable ? .notDetermined : .unavailable
        }
    }
}

@MainActor
struct OnboardingActions {
    var loadStatus: @MainActor () async -> OnboardingStatus
    var request: @MainActor (OnboardingPermission) async -> String?
    var openSettings: @MainActor () -> Void
    var applyDestination: @MainActor (OnboardingDestination) -> Bool
    var applyPreset: @MainActor (Int) -> Void
    var startTracking: @MainActor () -> Void
}

@Observable @MainActor
final class OnboardingModel {
    static let completedKey = "WhereWolfOnboardingCompleted"

    private(set) var completed: Bool
    var isPresented: Bool
    private(set) var step = OnboardingStep.welcome
    private(set) var status = OnboardingStatus()
    private(set) var loaded = false
    private(set) var busy = false
    private(set) var error: String?
    var selectedPreset = 0
    private(set) var fixingSummary = false
    private(set) var alwaysRequested = false
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let actions: OnboardingActions
    @ObservationIgnored private var refreshRevision = 0

    init(defaults: UserDefaults, actions: OnboardingActions) {
        self.defaults = defaults
        self.actions = actions
        let done = defaults.bool(forKey: Self.completedKey)
        completed = done
        isPresented = !done
    }

    var steps: [OnboardingStep] {
        OnboardingStep.allCases.filter { $0 != .health || status.healthAvailable }
    }
    var stepNumber: Int { (steps.firstIndex(of: step) ?? 0) + 1 }
    var canRequestAlways: Bool { status.location == .whileUsing }
    var canStartTracking: Bool { loaded && status.location.allowed && !busy }

    func refresh() async {
        refreshRevision += 1
        let revision = refreshRevision
        let latest = await actions.loadStatus()
        guard revision == refreshRevision else { return }
        status = latest
        if !loaded { selectedPreset = latest.usagePreset }
        loaded = true
        if step == .health && !status.healthAvailable { step = .goodToKnow }
    }

    func reopen() {
        guard !busy else { return }
        step = .welcome
        fixingSummary = false
        error = nil
        loaded = false
        isPresented = true
    }

    func go(to target: OnboardingStep) {
        guard !busy, steps.contains(target) else { return }
        fixingSummary = target != .done && (fixingSummary || step == .done)
        step = target
        error = nil
    }

    func next() {
        guard !busy else { return }
        error = nil
        if fixingSummary {
            step = .done
            fixingSummary = false
            return
        }
        guard let index = steps.firstIndex(of: step), index + 1 < steps.count else { return }
        step = steps[index + 1]
    }

    func back() {
        guard !busy, let index = steps.firstIndex(of: step), index > 0 else { return }
        fixingSummary = false
        error = nil
        step = steps[index - 1]
    }

    func opensSettings(for permission: OnboardingPermission) -> Bool {
        let value = status.permission(permission)
        return value == .denied || value == .limited
            || (permission == .always && alwaysRequested && status.location == .whileUsing)
    }

    func request(_ permission: OnboardingPermission) async {
        guard isPresented, loaded, !busy else { return }
        if opensSettings(for: permission) {
            actions.openSettings()
            return
        }
        // The first authorization must come from the separate While Using action.
        if permission == .always && !status.location.allowed { return }
        let value = status.permission(permission)
        guard value != .unavailable else { return }
        guard value != .granted || permission == .notifications || permission == .healthWrite else { return }
        if permission == .always {
            guard canRequestAlways else { return }
            alwaysRequested = true
        }
        busy = true
        error = await actions.request(permission)
        await refresh()
        busy = false
    }

    func chooseDestination(_ destination: OnboardingDestination) async {
        guard isPresented, loaded, !busy else { return }
        busy = true
        defer { busy = false }
        guard actions.applyDestination(destination) else {
            error = "Enter a valid HTTP or HTTPS endpoint, or a wherewolf://setup or overland://setup link."
            return
        }
        error = nil
        await refresh()
    }

    func finish(startTracking: Bool) {
        guard isPresented, step == .done, loaded, !busy else { return }
        guard !startTracking || canStartTracking else { return }
        if !status.tripActive && (1...5).contains(selectedPreset) { actions.applyPreset(selectedPreset) }
        complete()
        if startTracking { actions.startTracking() }
    }

    func skipAll() {
        guard !busy else { return }
        complete()
    }

    private func complete() {
        defaults.set(true, forKey: Self.completedKey)
        completed = true
        isPresented = false
    }

    func summary(for step: OnboardingStep) -> String {
        switch step {
        case .welcome: return "Your data, your destination"
        case .whileUsing: return status.permission(.whileUsing).rawValue
        case .always:
            let access = status.location == .always ? "Always" : status.location == .whileUsing ? "While Using only" : status.permission(.always).rawValue
            return access + (status.location.allowed ? (status.preciseLocation ? " · Precise" : " · Reduced Accuracy") : "")
        case .motion: return status.motion.rawValue
        case .notifications: return status.notifications.rawValue + (status.notificationsEnabled ? " · App alerts on" : " · App alerts off")
        case .destination: return status.destination
        case .preset: return UsagePreset.name(selectedPreset)
        case .liveActivity: return "\(status.liveActivity) · Hide for Audio \(status.hideForAudio ? "On" : "Off") · Ask to Reopen \(status.askToReopen ? "On" : "Off")"
        case .health:
            return "Save workouts: \(status.healthWrite.rawValue) · \(status.healthEnabled ? "On" : "Off"). Import: \(status.healthReadReviewed ? "Access reviewed" : "Not set up")."
        case .goodToKnow: return "Background Refresh: \(status.backgroundRefresh) · Low Power Mode \(status.lowPower ? "On" : "Off")"
        case .done: return status.tracking ? "Tracking is already on" : "Tracking is off"
        }
    }
}

enum UsagePreset {
    static let values = Array(1...5)
    static func name(_ value: Int) -> String {
        switch value {
        case 1: return "High Resolution"
        case 2: return "Low Power"
        case 3: return "Balanced"
        case 4: return "Walking / Running"
        case 5: return "Driving"
        default: return "Custom"
        }
    }
    static func description(_ value: Int) -> String {
        switch value {
        case 1: return "Detailed routes: Standard, Best accuracy, no automatic pausing."
        case 2: return "Coarse history: significant changes controlled by iOS."
        case 3: return "Everyday history: Both, 100 m accuracy, stop within 50 m after 3 minutes."
        case 4: return "Walking or running: Standard, Best accuracy, Fitness activity."
        case 5: return "Detailed driving: Standard, Navigation accuracy, Automotive activity."
        default: return "Your current combination of settings."
        }
    }
}
