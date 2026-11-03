import Foundation
import WatchConnectivity

// Lets the watch app read status and use the phone's own controls. Tracking never depends on it.
// Commands are live only: a queued Stop or End Trip arriving later would do the wrong thing.
@objc final class WhereWolfWatchLink: NSObject {
    @objc static let shared = WhereWolfWatchLink()

    struct Actions {
        var setTracking: (Bool) -> Void = { GLManagerBridge.shared.trackingOn = $0 }
        var retryUpdates: () -> Void = { GLManagerBridge.shared.retryLocationUpdates() }
        var startTrip: (String?) -> Void = { GLTripActions.startTrip(withMode: $0) }
        var endTrip: () -> Void = { GLTripActions.endTripRestoringTracking() }
        var sendNow: () -> Void = { GLManagerBridge.shared.retryPendingUpload() }
        var setPreset: (Int) -> Void = { GLManagerBridge.shared.usageProfile = $0 }
        var tripInProgress: () -> Bool = { GLManager.shared().tripInProgress() }
    }

    // Trips start and end through these defaults rather than a notification.
    private static let watchedDefaults = [GLTrackingStateDefaultsName, GLTripStartTimeDefaultsName,
                                          GLTripModeDefaultsName, GLLastSentDateDefaultsName]
    private static let locationUpdateDelay: TimeInterval = 60
    private static let stateChangeDelay: TimeInterval = 1

    private let actions: Actions
    private var lastPushed: WatchStatus?
    private var pendingPush: DispatchWorkItem?
    private var pendingPushTime = DispatchTime.distantFuture

    init(actions: Actions = Actions()) {
        self.actions = actions
    }

    @objc func start() {
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        session.delegate = self
        session.activate()
        let center = NotificationCenter.default
        for name in [GLTrackingStateChangedNotification, GLSettingsChangedNotification,
                     GLSendingFinishedNotification, GLUploadStateChangedNotification] {
            center.addObserver(forName: Notification.Name(name), object: nil, queue: .main) { [weak self] _ in
                self?.schedulePush(after: Self.stateChangeDelay)
            }
        }
        center.addObserver(forName: Notification.Name(GLNewDataNotification), object: nil, queue: .main) { [weak self] _ in
            self?.schedulePush(after: Self.locationUpdateDelay)
        }
        for key in Self.watchedDefaults {
            UserDefaults.standard.addObserver(self, forKeyPath: key, options: [], context: nil)
        }
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { self.schedulePush(after: Self.stateChangeDelay) }
    }

    // The same limits as the phone's controls: Settings disables Usage Preset during a trip.
    func perform(_ command: WatchCommand) {
        switch command {
        case .refresh: break
        case .setTracking(let enabled): actions.setTracking(enabled)
        case .retryUpdates: actions.retryUpdates()
        case .startTrip(let mode): actions.startTrip(mode)
        case .endTrip: actions.endTrip()
        case .sendNow: actions.sendNow()
        case .setPreset(let preset):
            if !actions.tripInProgress() { actions.setPreset(preset) }
        }
    }

    private func loadStatus(_ completion: @escaping (WatchStatus) -> Void) {
        let manager = GLManager.shared()!
        let tripActive = manager.tripInProgress()
        let duration = tripActive ? manager.currentTripDuration() : 0
        var status = WatchStatus(
            tracking: manager.trackingEnabled,
            tripActive: tripActive,
            tripMode: tripActive ? TripModeStore.mode(manager.currentTripMode)?.name : nil,
            tripStart: tripActive ? Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - duration).rounded()) : nil,
            tripDistance: tripActive ? max(0, manager.currentTripDistance()) : 0,
            lastFix: manager.lastLocation?.timestamp,
            queued: 0,
            preset: manager.usageProfile(),
            metric: GLManagerBridge.shared.speedUnit == "KM/H",
            modes: TripModeStore.modes.map { WatchTripMode(id: $0.id, name: $0.name) })
        manager.numberOfLocations(inQueue: { count in
            DispatchQueue.main.async {
                status.queued = count
                completion(status)
            }
        })
    }

    private func schedulePush(after delay: TimeInterval) {
        let time = DispatchTime.now() + delay
        if pendingPush != nil, pendingPushTime <= time { return }
        pendingPush?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.pendingPush = nil
            self?.pushStatus()
        }
        pendingPush = work
        pendingPushTime = time
        DispatchQueue.main.asyncAfter(deadline: time, execute: work)
    }

    private func pushStatus() {
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        loadStatus { [weak self] status in
            guard let self, status != self.lastPushed else { return }
            do {
                try session.updateApplicationContext(status.message)
                self.lastPushed = status
            } catch {
                NSLog("Watch status update failed: %@", error.localizedDescription)
            }
        }
    }
}

extension WhereWolfWatchLink: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        if let error { NSLog("Watch session activation failed: %@", error.localizedDescription) }
        DispatchQueue.main.async { self.schedulePush(after: Self.stateChangeDelay) }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    // Runs when the phone switches to another watch.
    func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        DispatchQueue.main.async { self.schedulePush(after: Self.stateChangeDelay) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any],
                 replyHandler: @escaping ([String: Any]) -> Void) {
        DispatchQueue.main.async {
            if let command = WatchCommand(message: message) { self.perform(command) }
            self.loadStatus { replyHandler($0.message) }
        }
    }
}
