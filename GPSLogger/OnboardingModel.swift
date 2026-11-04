import Foundation
import Observation

enum OnboardingStep: CaseIterable, Identifiable, Hashable {
    case welcome, permissions, destination, tracking, fineTune, sending, liveActivity, stayingActive, done

    var id: Self { self }

    var title: String {
        switch self {
        case .welcome: return "Welcome to WhereWolf"
        case .permissions: return "Permissions"
        case .destination: return "Where Should It Send?"
        case .tracking: return "Tracking"
        case .fineTune: return "Fine-Tune"
        case .sending: return "Sending"
        case .liveActivity: return "Live Activity"
        case .stayingActive: return "Staying Active"
        case .done: return "You’re All Set"
        }
    }
}

enum OnboardingPermission: CaseIterable, Equatable {
    case whileUsing, always, motion, notifications, health
}

enum OnboardingPermissionStatus: String {
    case notDetermined = "Not Determined"
    case granted = "Granted"
    case denied = "Denied"
    case limited = "Limited"
    case reviewed = "Reviewed"
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
    // This describes whether Health's request was answered, never read approval.
    var health = OnboardingPermissionStatus.notDetermined
    var healthAppAvailable = false
    var destination = "Keep on device for now"
    var cloudSelected = false
    var serverConfigured = false
    var usagePreset = 6
    var requestedAccuracy = "Best"
    var minimumDistance = "10 m"
    var minimumTime = "5 s"
    var tracking = false
    var tripActive = false
    var liveActivity = "Blank"
    var hideForAudio = false
    var askToReopen = false
    var backgroundRefresh = "Unavailable"
    var lowPower = false
    var watchPaired = false
    var silentAudio = false
    var activeHelpers = 0
    var sendInterval = "Manual"

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
        case .health: return healthAvailable ? health : .unavailable
        }
    }
}

@MainActor
struct OnboardingActions {
    var loadStatus: @MainActor () async -> OnboardingStatus
    var request: @MainActor (OnboardingPermission) async -> String?
    var openSettings: @MainActor () -> Void
    var openHealth: @MainActor () -> Void
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
    private(set) var selectedPreset = 6
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
        OnboardingStep.allCases
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
        selectedPreset = latest.usagePreset
        loaded = true
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
        guard permission != .health else { return false }
        let value = status.permission(permission)
        return value == .denied || value == .limited
            || (permission == .always && alwaysRequested && status.location == .whileUsing)
    }

    func request(_ permission: OnboardingPermission) async {
        guard isPresented, loaded, !busy else { return }
        if permission == .health && status.permission(.health) == .reviewed {
            if status.healthAppAvailable { actions.openHealth() }
            return
        }
        if opensSettings(for: permission) {
            actions.openSettings()
            return
        }
        // The first authorization must come from the separate While Using action.
        if permission == .always && !status.location.allowed { return }
        let value = status.permission(permission)
        guard value != .unavailable else { return }
        guard value != .granted || permission == .notifications else { return }
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

    func choosePreset(_ value: Int) async {
        guard isPresented, loaded, !busy, !status.tripActive, UsagePreset.values.contains(value) else { return }
        actions.applyPreset(value)
        await refresh()
    }

    func openSettings() { actions.openSettings() }

    var locationSummary: String {
        let access = status.location == .always ? "Always" : status.location == .whileUsing ? "While Using" : status.permission(.whileUsing).rawValue
        return access + (status.location.allowed ? (status.preciseLocation ? " · Precise" : " · Reduced Accuracy") : "")
    }

    var healthSummary: String {
        status.permission(.health).rawValue
    }

    var healthActionTitle: String? {
        switch status.permission(.health) {
        case .notDetermined: return "Allow"
        case .reviewed: return status.healthAppAvailable ? "Manage in Health" : nil
        default: return nil
        }
    }

    func summary(for step: OnboardingStep) -> String {
        switch step {
        case .welcome: return "Your data, your destination"
        case .permissions: return locationSummary
        case .destination: return status.destination + " · " + status.sendInterval
        case .tracking: return UsagePreset.name(selectedPreset)
        case .fineTune: return status.requestedAccuracy + " · " + status.minimumDistance + " · " + status.minimumTime
        case .sending: return status.sendInterval
        case .liveActivity: return status.liveActivity + (status.hideForAudio ? " · hides for music" : "")
        case .stayingActive: return "\(status.activeHelpers) of 5 on"
        case .done: return status.tracking ? "Tracking is already on" : "Tracking is off"
        }
    }
}

enum UsagePreset {
    static let values = [6, 1, 3, 2, 4, 5]
    static func name(_ value: Int) -> String {
        switch value {
        case 6: return "Everyday Detailed"
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
        case 6: return "Detailed tracks without the location arrow. Ignores points within 10 m or 5 s of the last, so standing still stays quiet. Visits off."
        case 1: return "Detailed routes: Standard, Best accuracy, no automatic pausing."
        case 2: return "Coarse history: significant changes controlled by iOS."
        case 3: return "Everyday history: Both, 100 m accuracy, stop within 50 m after 3 minutes."
        case 4: return "Walking or running: Standard, Best accuracy, Fitness activity."
        case 5: return "Detailed driving: Standard, Navigation accuracy, Automotive activity."
        default: return "Custom · Your current combination of settings."
        }
    }
    static func setupDescription(_ value: Int) -> String {
        switch value {
        case 6: return "Detailed tracks, quiet when still"
        case 1: return "Every GPS point, no automatic pausing"
        case 3: return "Everyday history, stops when still"
        case 2: return "Coarse history, lower battery use"
        case 4: return "Detailed routes for outdoor exercise"
        case 5: return "Navigation accuracy for driving"
        default: return "Your current settings"
        }
    }
}
