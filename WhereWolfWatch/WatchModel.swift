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

    func start() {
        guard !started, WCSession.isSupported() else { return }
        started = true
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    // Messaging from an open watch app can wake the phone app in the background, which restores tracking.
    func send(_ command: WatchCommand) {
        let session = WCSession.default
        guard session.activationState == .activated else {
            unreachable = true
            session.activate()
            return
        }
        revision &+= 1
        let current = revision
        busy = true
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
        guard current == revision, busy else { return }
        busy = false
        unreachable = failed
        if let status { self.status = status }
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

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        guard let status = WatchStatus(message: applicationContext) else { return }
        Task { @MainActor in self.receive(status) }
    }
}
