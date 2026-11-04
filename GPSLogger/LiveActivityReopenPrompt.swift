import CoreLocation
import UserNotifications

@MainActor
protocol LiveActivityReopenNotificationCenter {
    func authorizationStatus() async -> UNAuthorizationStatus
    func add(_ request: UNNotificationRequest) async throws
    func removePendingNotificationRequests(withIdentifiers identifiers: [String])
    func removeDeliveredNotifications(withIdentifiers identifiers: [String])
}

extension UNUserNotificationCenter: LiveActivityReopenNotificationCenter {
    func authorizationStatus() async -> UNAuthorizationStatus {
        await notificationSettings().authorizationStatus
    }
}

@MainActor
final class LiveActivityReopenPrompt {
    static let notificationID = "WhereWolfLiveActivityAudioReopen"
    // Long enough that pausing a song or switching tracks never sends it.
    static let delay: TimeInterval = 300

    struct State {
        var hideWhileAudioPlays = false
        var askToReopen = false
        var authorization = CLAuthorizationStatus.notDetermined
        var trackingEligible = false
        var hasPendingRestore = false
        var isHiding = false
        var otherAudioPlaying = false
        var scene = LiveActivityAudioPolicy.Scene.foreground

        var canSchedule: Bool {
            hideWhileAudioPlays && askToReopen && authorization == .authorizedAlways
                && trackingEligible && hasPendingRestore && !isHiding && !otherAudioPlaying
                && scene != .foreground
        }
    }

    private let center: LiveActivityReopenNotificationCenter
    private var state = State()
    private var requested = false
    private var wanted = false
    private var revision = 0
    private var task: Task<Void, Never>?

    init(center: LiveActivityReopenNotificationCenter = UNUserNotificationCenter.current()) {
        self.center = center
    }

    func update(_ state: State) {
        self.state = state
        if state.otherAudioPlaying {
            reset()
        } else if !state.canSchedule {
            withdraw()
        }
    }

    func schedule() {
        guard state.canSchedule, !requested else { return }
        requested = true
        wanted = true
        revision += 1
        reconcile()
    }

    func withdraw() {
        wanted = false
        revision += 1
        remove()
    }

    func dismiss() {
        withdraw()
        requested = true
    }

    func reset() {
        withdraw()
        requested = false
    }

    private func remove() {
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
    }

    private func reconcile() {
        guard task == nil else { return }
        task = Task { [self] in
            while true {
                let current = revision
                if wanted {
                    let authorization = await center.authorizationStatus()
                    if current == revision, wanted,
                       [.authorized, .provisional, .ephemeral].contains(authorization) {
                        let content = UNMutableNotificationContent()
                        content.title = "Music stopped"
                        content.body = "Open WhereWolf to bring back its Live Activity."
                        content.interruptionLevel = .passive
                        let request = UNNotificationRequest(identifier: Self.notificationID, content: content,
                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: Self.delay, repeats: false))
                        try? await center.add(request)
                        // An add already handed to iOS can finish after a withdrawal.
                        if current != revision { remove() }
                    }
                }
                if current == revision { break }
            }
            task = nil
        }
    }
}
