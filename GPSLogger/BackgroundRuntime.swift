import ActivityKit
import AVFoundation
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
@objc final class WhereWolfBackgroundRuntime: NSObject {
    @objc static let shared = WhereWolfBackgroundRuntime()

    static var hasActiveTrackingActivity: Bool { TrackingActivityHandle.all.contains { $0.isActive } }

    static var hasBackgroundLocationActivity: Bool {
        TrackingActivityHandle.all.contains { $0.isActive && !$0.isIslandOnly }
    }

    private enum Key {
        static let liveActivity = "WhereWolfLiveActivityEnabled"
        static let lockScreenCard = "LiveActivityLockScreenCard"
        static let appearance = "WhereWolfLiveActivityAppearance"
        static let hideWhileAudioPlays = "WhereWolfLiveActivityHideWhileAudioPlays"
        static let askToReopenAfterAudio = "WhereWolfLiveActivityAskToReopenAfterAudio"
        static let silentAudio = "WhereWolfSilentAudioEnabled"
    }

    struct AudioDependencies {
        var otherAudioPlaying: () -> Bool = { AVAudioSession.sharedInstance().isOtherAudioPlaying }
        var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var authorization: () -> CLAuthorizationStatus = { GLManager.shared().locationManager.authorizationStatus }
        var scene: () -> LiveActivityAudioPolicy.Scene = {
            switch UIApplication.shared.applicationState {
            case .active: return .foreground
            case .background: return .background
            default: return .inactive
            }
        }
        var schedule: (TimeInterval, DispatchWorkItem) -> Void = { delay, work in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
        }
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
    @ObservationIgnored var audioDependencies = AudioDependencies() {
        didSet { resetAudioPolicy() }
    }
    @ObservationIgnored private var audioPolicy = LiveActivityAudioPolicy()
    @ObservationIgnored var reopenPrompt = LiveActivityReopenPrompt() {
        willSet { reopenPrompt.reset() }
    }
    @ObservationIgnored private var otherAudioPlaying = false
    @ObservationIgnored private var audioFollowUp: DispatchWorkItem?
    @ObservationIgnored private var audioFollowUpDeadline: TimeInterval?
    @ObservationIgnored private var audioFollowUpRevision = 0

    private override init() {
        super.init()
        UserDefaults.standard.register(defaults: [Key.liveActivity: true,
                                                 Key.appearance: "blank", Key.lockScreenCard: false, Key.silentAudio: false,
                                                 Key.hideWhileAudioPlays: false,
                                                 Key.askToReopenAfterAudio: false])
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
        get { UserDefaults.standard.string(forKey: Key.appearance) ?? "blank" }
        set {
            guard TrackingActivityAttributes.Appearance(rawValue: newValue) != nil else { return }
            UserDefaults.standard.set(newValue, forKey: Key.appearance)
            suppressed = false
            refresh()
        }
    }

    var lockScreenCard: Bool {
        get { UserDefaults.standard.bool(forKey: Key.lockScreenCard) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.lockScreenCard)
            suppressed = false
            refresh()
        }
    }

    var presentation: TrackingActivityPresentation {
        .init(enabled: liveActivityEnabled,
              appearance: TrackingActivityAttributes.Appearance(rawValue: appearance) ?? .blank,
              lockScreenCard: lockScreenCard)
    }

    // App Store builds leave silent audio out, along with the audio background mode it needs.
    nonisolated static var silentAudioAvailable: Bool {
#if WHEREWOLF_SILENT_AUDIO
        true
#else
        false
#endif
    }

    var silentAudioEnabled: Bool {
        get { Self.silentAudioAvailable && UserDefaults.standard.bool(forKey: Key.silentAudio) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.silentAudio)
            refresh()
        }
    }

    var hideWhileAudioPlays: Bool {
        get { UserDefaults.standard.bool(forKey: Key.hideWhileAudioPlays) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.hideWhileAudioPlays)
            refresh()
        }
    }

    var audioStatus: String { audio.status }

    var askToReopenAfterAudio: Bool {
        get { UserDefaults.standard.bool(forKey: Key.askToReopenAfterAudio) }
        set {
            UserDefaults.standard.set(newValue, forKey: Key.askToReopenAfterAudio)
            refresh()
        }
    }

    @objc func start() {
        guard !started else { return }
        started = true
        let center = NotificationCenter.default
        for name in [GLTrackingStateChangedNotification, GLSettingsChangedNotification,
                     GLAuthorizationStatusChangedNotification, GLSendingFinishedNotification,
                     GLNewDataNotification, GLNewActivityNotification, GLUploadStateChangedNotification,
                     "WhereWolfEngineStateChanged"] {
            observers.append(center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            })
        }
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification,
                                            object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.suppressed = false
                self.reopenPrompt.dismiss()
                self.audioPolicy.foregroundOrRetry()
                GLManager.shared().reconcileTracking()
                self.refresh()
                GLManager.shared().syncTripLiveActivity()
                self.audio.refresh()
                self.reloadReminder()
            }
        })
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification,
                     UIApplication.willEnterForegroundNotification, UIScene.didActivateNotification,
                     UIScene.willDeactivateNotification, UIScene.didEnterBackgroundNotification,
                     UIScene.willEnterForegroundNotification, AVAudioSession.silenceSecondaryAudioHintNotification,
                     AVAudioSession.interruptionNotification, AVAudioSession.routeChangeNotification,
                     AVAudioSession.mediaServicesWereLostNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    if name == UIApplication.willEnterForegroundNotification || name == UIScene.willEnterForegroundNotification {
                        self?.reopenPrompt.dismiss()
                    }
                    self?.refresh()
                }
            })
        }
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
        reopenPrompt.dismiss()
        suppressed = false
        audioPolicy.foregroundOrRetry()
        refresh()
        GLManager.shared().syncTripLiveActivity()
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
        sampleOtherAudio()
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

    @objc func checkAudioFromLocation() {
        guard hideWhileAudioPlays,
              audioPolicy.shouldSampleLocation(at: audioDependencies.uptime()) else { return }
        refresh()
    }

    private func sampleOtherAudio() {
        let wasHiding = audioPolicy.isHiding
        let enabled = hideWhileAudioPlays && eligible
        let authorization = audioDependencies.authorization()
        otherAudioPlaying = enabled && authorization == .authorizedAlways && audioDependencies.otherAudioPlaying()
        audioPolicy.sample(enabled: enabled,
                           otherAudioPlaying: otherAudioPlaying,
                           authorization: authorization,
                           at: audioDependencies.uptime())
        scheduleAudioFollowUp()
        updateReopenPrompt()
        if wasHiding != audioPolicy.isHiding { GLManager.shared().syncTripLiveActivity() }
    }

    private func scheduleAudioFollowUp() {
        let deadline = audioPolicy.confirmationDeadline
        guard deadline != audioFollowUpDeadline else { return }
        cancelAudioFollowUp()
        guard let deadline else { return }
        audioFollowUpDeadline = deadline
        let current = audioFollowUpRevision
        let work = DispatchWorkItem { [weak self] in
            guard let self, current == self.audioFollowUpRevision else { return }
            self.audioFollowUp = nil
            self.audioFollowUpDeadline = nil
            self.refresh()
        }
        audioFollowUp = work
        // This only confirms a pending change; it cannot wake a suspended process.
        audioDependencies.schedule(max(0, deadline - audioDependencies.uptime()) + 0.1, work)
    }

    private func cancelAudioFollowUp() {
        audioFollowUp?.cancel()
        audioFollowUp = nil
        audioFollowUpDeadline = nil
        audioFollowUpRevision += 1
    }

    func resetAudioPolicy() {
        // Deadlines and sampling history belong to the clock that created them.
        cancelAudioFollowUp()
        audioPolicy = LiveActivityAudioPolicy()
        otherAudioPlaying = false
        reopenPrompt.reset()
    }

    func audioAction(for kind: LiveActivityAudioPolicy.Kind, eligible: Bool,
                     hasActivity: Bool) -> LiveActivityAudioPolicy.Action {
        if audioPolicy.isHiding && (!hideWhileAudioPlays || audioDependencies.authorization() != .authorizedAlways) {
            sampleOtherAudio()
        }
        let pending = audioPolicy.hasPendingRestore(for: kind)
        let action = audioPolicy.action(for: kind, eligible: eligible, hasActivity: hasActivity, scene: audioScene)
        updateReopenPrompt()
        if action == .waitForForeground { reopenPrompt.schedule() }
        if pending && hasActivity && action == .keep { reopenPrompt.dismiss() }
        return action
    }

    private var audioScene: LiveActivityAudioPolicy.Scene {
        audioDependencies.scene()
    }

    func willRestoreAfterAudio(_ kind: LiveActivityAudioPolicy.Kind) { audioPolicy.willRequest(kind, scene: audioScene) }
    func restoredAfterAudio(_ kind: LiveActivityAudioPolicy.Kind) {
        audioPolicy.restored(kind)
        reopenPrompt.dismiss()
    }

    func restoreAfterAudioFailed() {
        updateReopenPrompt()
        reopenPrompt.schedule()
    }

    private func updateReopenPrompt() {
        reopenPrompt.update(.init(hideWhileAudioPlays: hideWhileAudioPlays,
                                  askToReopen: askToReopenAfterAudio,
                                  authorization: audioDependencies.authorization(),
                                  trackingEligible: eligible,
                                  hasPendingRestore: audioPolicy.hasPendingRestore,
                                  isHiding: audioPolicy.isHiding,
                                  otherAudioPlaying: otherAudioPlaying, scene: audioScene))
    }

    private func updateActivity() async {
        let current = revision
        let kind: LiveActivityAudioPolicy.Kind = appearance == "blank" ? .blank : appearance == "status" ? .status : .minimal
        let audioAction = audioAction(for: kind, eligible: eligible && liveActivityEnabled,
                                      hasActivity: Self.hasActiveTrackingActivity)
        guard eligible && liveActivityEnabled else {
            await endActivities()
            activityStatus = liveActivityEnabled ? "Waiting for tracking and location access" : "Off"
            return
        }
        if audioAction == .hide {
            if activity != nil || Self.hasActiveTrackingActivity { await endActivities() }
            activityStatus = "Hidden while other audio plays"
            return
        }
        if audioAction == .waitForForeground {
            activityStatus = "Open WhereWolf to restore the Live Activity"
            return
        }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            await endActivities()
            activityStatus = "Live Activities are disabled in iOS Settings"
            return
        }
        let islandOnly = presentation.kind == .appOnly
        let replacingCurrent = activity.map { $0.isIslandOnly != islandOnly } ?? false
        if replacingCurrent || TrackingActivityHandle.all.contains(where: { $0.isIslandOnly != islandOnly }) {
            await endActivities()
        }
        guard revision == current, eligible, liveActivityEnabled else { return }
        if activity == nil, let existing = TrackingActivityHandle.all.first(where: { $0.isActive }) {
            observe(existing)
        }
        let state = cardState()
        let content = ActivityContent(state: state, staleDate: reminderDeadline, relevanceScore: 0)
        if let activity {
            let delay = lastContent.flatMap { state.updateDelay(from: $0, elapsed: Date().timeIntervalSince(lastUpdate)) } ?? 0
            if lastContent != state && delay == 0 {
                await activity.update(content)
                guard self.activity?.id == activity.id else { return }
                lastContent = state
                lastUpdate = Date()
                delayedUpdate?.cancel()
                delayedUpdate = nil
            } else if lastContent != state && delayedUpdate == nil {
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
        guard !suppressed || audioAction == .restore else {
            activityStatus = "Ended or dismissed · reopen the app or retry"
            return
        }
        guard UIApplication.shared.applicationState == .active || audioAction == .restore else {
            activityStatus = "Open WhereWolf to start the Live Activity"
            return
        }
        if audioAction == .restore { willRestoreAfterAudio(kind) }
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
            restoredAfterAudio(kind)
        } catch {
            if audioAction == .restore {
                activityStatus = "Open WhereWolf to restore the Live Activity"
                restoreAfterAudioFailed()
            } else {
                suppressed = true
                activityStatus = "Could not start: \(error.localizedDescription)"
            }
        }
    }

    func cardState() -> TrackingActivityAttributes.ContentState {
        let gl = GLManager.shared()!
        let trip = gl.tripInProgress()
        let distance = gl.currentTripDistance()
        let paused = gl.didPauseByRadius || WhereWolfLocationEngine.shared.state == "stationary"
        return .init(isTrip: trip, lastSent: gl.lastSentDate,
                     appearance: TrackingActivityAttributes.Appearance(rawValue: appearance) ?? .blank,
                     reminderDeadline: reminderDeadline, lastFix: gl.lastLocation?.timestamp,
                     queuedCount: max(0, Int(gl.currentPointsInQueue)),
                     trackingStatus: !gl.trackingEnabled ? .stopped : paused ? .paused : .tracking,
                     tripModeName: trip ? TripModeStore.name(gl.currentTripMode) : nil,
                     tripStart: gl.currentTripStart(), tripDistance: trip && distance.isFinite ? max(0, distance) : nil,
                     separateTripActivity: Activity<TripActivityAttributes>.activities.contains {
                         $0.activityState == .active || $0.activityState == .stale
                     })
    }

    func tripActivityChanged() { refresh() }

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
