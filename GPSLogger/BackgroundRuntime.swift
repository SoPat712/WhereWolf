import ActivityKit
import CoreLocation
import Observation
import UIKit
import UserNotifications

// Keep this type in the app target; no widget configuration registers its presentation.
struct IslandOnlyTrackingAttributes: ActivityAttributes {
    typealias ContentState = TrackingActivityAttributes.ContentState
    var startedAt: Date
}

@MainActor
private enum TrackingActivityHandle {
    case widget(Activity<TrackingActivityAttributes>)
    case islandOnly(Activity<IslandOnlyTrackingAttributes>)

    static var all: [Self] {
        Activity<TrackingActivityAttributes>.activities.map(Self.widget)
            + Activity<IslandOnlyTrackingAttributes>.activities.map(Self.islandOnly)
    }

    var id: String {
        switch self {
        case .widget(let activity): return activity.id
        case .islandOnly(let activity): return activity.id
        }
    }

    var state: ActivityState {
        switch self {
        case .widget(let activity): return activity.activityState
        case .islandOnly(let activity): return activity.activityState
        }
    }

    var isActive: Bool { state == .active || state == .stale }

    var isIslandOnly: Bool {
        if case .islandOnly = self { return true }
        return false
    }

    func update(_ content: ActivityContent<TrackingActivityAttributes.ContentState>) async {
        switch self {
        case .widget(let activity): await activity.update(content)
        case .islandOnly(let activity): await activity.update(content)
        }
    }

    func end() async {
        switch self {
        case .widget(let activity): await activity.end(nil, dismissalPolicy: .immediate)
        case .islandOnly(let activity): await activity.end(nil, dismissalPolicy: .immediate)
        }
    }
}

@Observable
@MainActor
@objc final class WhereBackgroundRuntime: NSObject {
    @objc static let shared = WhereBackgroundRuntime()

    static var hasActiveTrackingActivity: Bool { TrackingActivityHandle.all.contains { $0.isActive } }

    static var hasBackgroundLocationActivity: Bool {
        TrackingActivityHandle.all.contains { $0.isActive && !$0.isIslandOnly }
    }

    private enum Key {
        static let liveActivity = "WhereLiveActivityEnabled"
        static let appearance = "WhereLiveActivityAppearance"
        static let silentAudio = "WhereSilentAudioEnabled"
    }

    private(set) var activityStatus = "Waiting for tracking"
    private let audio = SilentAudioSession()
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var activity: TrackingActivityHandle?
    @ObservationIgnored private var activityObserver: Task<Void, Never>?
    @ObservationIgnored private var delayedUpdate: Task<Void, Never>?
    @ObservationIgnored private var updateTask: Task<Void, Never>?
    @ObservationIgnored private var reminderRevision = 0
    @ObservationIgnored private var reminderDeadline: Date?
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var suppressed = false
    @ObservationIgnored private var wasEligible = false
    @ObservationIgnored private var lastUpdate = Date.distantPast
    @ObservationIgnored private var lastContent: TrackingActivityAttributes.ContentState?

    private override init() {
        super.init()
        UserDefaults.standard.register(defaults: [Key.liveActivity: true,
                                                 Key.appearance: "minimal", Key.silentAudio: false])
    }

    var liveActivityEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.liveActivity) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.liveActivity)
            suppressed = false
            refresh()
        }
    }

    var appearance: String {
        get { UserDefaults.standard.string(forKey: Key.appearance) ?? "minimal" }
        set {
            guard TrackingActivityAttributes.Appearance(rawValue: newValue) != nil else { return }
            UserDefaults.standard.set(newValue, forKey: Key.appearance)
            suppressed = false
            refresh()
        }
    }

    var silentAudioEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Key.silentAudio) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.silentAudio)
            refresh()
        }
    }

    var audioStatus: String { audio.status }

    @objc func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        for name in [GLTrackingStateChangedNotification, GLSettingsChangedNotification,
                     GLAuthorizationStatusChangedNotification, GLSendingFinishedNotification] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.suppressed = false
                GLManager.shared().reconcileTracking()
                self.refresh()
                self.audio.refresh()
                self.reloadReminder()
            }
        })
        observers.append(center.addObserver(forName: Notification.Name(GLReminderChangedNotification),
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.reloadReminder() }
        })
        reloadReminder()
        refresh()
    }

    private func reloadReminder() {
        reminderRevision += 1
        let current = reminderRevision
        Task { [weak self] in
            let requests = await UNUserNotificationCenter.current().pendingNotificationRequests()
            guard let self, current == self.reminderRevision else { return }
            // Use the existing reminder's deadline, including its cancellation and suppression rules.
            self.reminderDeadline = (requests.first { $0.identifier == "reminder" }?.trigger as? UNTimeIntervalNotificationTrigger)?.nextTriggerDate()
            self.refresh()
        }
    }

    func retry() {
        suppressed = false
        refresh()
        audio.retry()
        reloadReminder()
    }

    private var eligible: Bool {
        guard let gl = GLManager.shared(), gl.trackingEnabled else { return false }
        let authorization = gl.locationManager.authorizationStatus
        guard authorization == .authorizedAlways || authorization == .authorizedWhenInUse else { return false }
        return gl.tripInProgress() || gl.trackingMode.rawValue != 0 || gl.visitTrackingEnabled
    }

    private func refresh() {
        let allowed = eligible
        if allowed && !wasEligible { suppressed = false }
        wasEligible = allowed
        audio.setEnabled(allowed && silentAudioEnabled)
        revision += 1
        guard updateTask == nil else { return }
        updateTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let current = revision
                await updateActivity()
                if current == revision { break }
            }
            updateTask = nil
        }
    }

    private func updateActivity() async {
        guard eligible && liveActivityEnabled else {
            await endActivities()
            activityStatus = liveActivityEnabled ? "Waiting for tracking and location access" : "Off"
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            await endActivities()
            activityStatus = "Live Activities are disabled in iOS Settings"
            return
        }
        let islandOnly = appearance == "blank"
        let replacingCurrent = activity.map { $0.isIslandOnly != islandOnly } ?? false
        if replacingCurrent || TrackingActivityHandle.all.contains(where: { $0.isIslandOnly != islandOnly }) {
            await endActivities()
        }
        if activity == nil, let existing = TrackingActivityHandle.all.first(where: { $0.isActive }) {
            observe(existing)
        }
        let gl = GLManager.shared()!
        let state = TrackingActivityAttributes.ContentState(
            isTrip: gl.tripInProgress(), lastSent: gl.lastSentDate,
            appearance: TrackingActivityAttributes.Appearance(rawValue: appearance) ?? .minimal,
            reminderDeadline: reminderDeadline
        )
        let content = ActivityContent(state: state, staleDate: reminderDeadline, relevanceScore: 0)
        if let activity {
            let structuralChange = lastContent?.appearance != state.appearance || lastContent?.isTrip != state.isTrip
                || (lastContent?.reminderDeadline == nil) != (state.reminderDeadline == nil)
            // Send Every can be one second; the status surface does not need that update rate.
            if lastContent != state && (structuralChange || Date().timeIntervalSince(lastUpdate) >= 30) {
                await activity.update(content)
                guard self.activity?.id == activity.id else { return }
                lastContent = state
                lastUpdate = Date()
                delayedUpdate?.cancel()
                delayedUpdate = nil
            } else if lastContent != state && delayedUpdate == nil {
                let delay = max(0, 30 - Date().timeIntervalSince(lastUpdate))
                delayedUpdate = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                    guard let self else { return }
                    self.delayedUpdate = nil
                    self.refresh()
                }
            }
            activityStatus = "Active"
            return
        }
        guard !suppressed else {
            activityStatus = "Ended or dismissed · reopen the app or retry"
            return
        }
        guard UIApplication.shared.applicationState == .active else {
            activityStatus = "Open Where to start the Live Activity"
            return
        }
        do {
            let newActivity: TrackingActivityHandle
            if islandOnly {
                newActivity = .islandOnly(try Activity.request(attributes: IslandOnlyTrackingAttributes(startedAt: Date()),
                                                              content: content, pushType: nil))
            } else {
                newActivity = .widget(try Activity.request(attributes: TrackingActivityAttributes(startedAt: Date()),
                                                          content: content, pushType: nil))
            }
            observe(newActivity)
            lastContent = state
            lastUpdate = Date()
            activityStatus = "Active"
        } catch {
            suppressed = true
            activityStatus = "Could not start: \(error.localizedDescription)"
        }
    }

    private func endActivities() async {
        delayedUpdate?.cancel()
        delayedUpdate = nil
        activityObserver?.cancel()
        activityObserver = nil
        activity = nil
        lastContent = nil
        for old in TrackingActivityHandle.all { await old.end() }
        GLManager.shared().updateLocationEngine()
    }

    private func observe(_ activity: TrackingActivityHandle) {
        self.activity = activity
        GLManager.shared().updateLocationEngine()
        activityObserver?.cancel()
        switch activity {
        case .widget(let activity): activityObserver = observeStates(activity)
        case .islandOnly(let activity): activityObserver = observeStates(activity)
        }
    }

    private func observeStates<Attributes: ActivityAttributes>(_ activity: Activity<Attributes>) -> Task<Void, Never> {
        Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled, let self, self.activity?.id == activity.id else { return }
                GLManager.shared().updateLocationEngine()
                if state == .dismissed || state == .ended {
                    self.activity = nil
                    self.suppressed = true
                    self.activityStatus = "Ended or dismissed · reopen the app or retry"
                    return
                }
            }
        }
    }
}
