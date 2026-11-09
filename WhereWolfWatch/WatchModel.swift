import Foundation
import Observation
import WatchConnectivity

@Observable
@MainActor
final class WatchModel: NSObject {
    private static let replyTimeout: Duration = .seconds(15)

    private(set) var status: WatchStatus?
    private(set) var busy = false
    private(set) var unreachable = false
    @ObservationIgnored private var revision = 0
    @ObservationIgnored private var started = false
    @ObservationIgnored private var pending = false
    @ObservationIgnored private var active = false
    @ObservationIgnored private var retryTask: Task<Void, Never>?
    @ObservationIgnored private var retryDelay = 2.0

    func start() {
        guard !started, WCSession.isSupported() else { return }
        started = true
        active = true
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func setActive(_ active: Bool) {
        self.active = active
        retryTask?.cancel()
        retryTask = nil
        retryDelay = 2
        if active { send(.refresh) }
    }

    // Messaging from an open watch app can wake the phone app in the background, which restores tracking.
    func send(_ command: WatchCommand) { send(command, quietly: false) }

    private func send(_ command: WatchCommand, quietly: Bool) {
        let session = WCSession.default
        guard session.activationState == .activated else {
            unreachable = true
            session.activate()
            scheduleRetry()
            return
        }
        revision &+= 1
        let current = revision
        pending = true
        if !quietly { busy = true }
        session.sendMessage(command.message) { [weak self] reply in
            let status = WatchStatus(message: reply)
            Task { @MainActor in self?.finish(current, status: status, failed: status == nil) }
        } errorHandler: { [weak self] _ in
            Task { @MainActor in self?.finish(current, status: nil, failed: true) }
        }
        Task { [weak self] in
            try? await Task.sleep(for: Self.replyTimeout)
            self?.finish(current, status: nil, failed: true)
        }
    }

    private func finish(_ current: Int, status: WatchStatus?, failed: Bool) {
        guard current == revision, pending else { return }
        pending = false
        busy = false
        unreachable = failed
        if let status { self.status = status }
        if failed { scheduleRetry() } else { retryDelay = 2 }
    }

    // While the app is on screen it keeps looking for the iPhone, after 2, 4 and 8 seconds and then every 15,
    // without the progress indicator. Try Again still asks at once.
    private func scheduleRetry() {
        guard active, retryTask == nil else { return }
        let delay = retryDelay
        retryDelay = min(15, retryDelay * 2)
        retryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard !Task.isCancelled, let self else { return }
            self.retryTask = nil
            if self.active, self.unreachable, !self.pending { self.send(.refresh, quietly: true) }
        }
    }

    fileprivate func receive(_ status: WatchStatus) {
        self.status = status
        unreachable = false
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let saved = WatchStatus(message: session.receivedApplicationContext)
        Task { @MainActor in
            if let saved { self.status = saved }
            guard activationState == .activated else {
                self.unreachable = true
                return
            }
            self.send(.refresh)
        }
    }

    nonisolated func sessionReachabilityDidChange(_ session: WCSession) {
        guard session.isReachable else { return }
        Task { @MainActor in
            if self.active, self.unreachable || self.status == nil, !self.pending { self.send(.refresh, quietly: true) }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let status = WatchStatus(message: applicationContext) else { return }
        Task { @MainActor in self.receive(status) }
    }
}
