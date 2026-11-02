import Foundation
import Network

// "Send Only on Wi-Fi": GLManager holds the sends it starts itself while the phone is on cellular or
// a personal hotspot. Sends the user asks for always go out.
@objc(GLWifiOnlySending) final class WifiOnlySending: NSObject {
    @objc static let shared = WifiOnlySending()
    @objc static let changedNotification = Notification.Name("GLWifiOnlySendingChanged")
    static let defaultsKey = "GLSendOnlyOnWifiDefaults"

    private var monitor: NWPathMonitor?
    // Nil until the first path update arrives.
    private var expensive: Bool?

    private override init() {
        super.init()
        updateMonitor()
    }

    @objc var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.defaultsKey) }
        set {
            let changed = newValue != enabled
            UserDefaults.standard.set(newValue, forKey: Self.defaultsKey)
            updateMonitor()
            if changed { NotificationCenter.default.post(name: Self.changedNotification, object: nil) }
        }
    }

    // Cellular and hotspots are expensive; Wi-Fi in Low Data Mode is only constrained, so it sends.
    // Before the first path update a send waits rather than risk going out over cellular.
    @objc var waitsOnCurrentPath: Bool { enabled && (expensive ?? true) }

    // Silent, so only the GLManager under test reacts, not the app host's own manager.
    @objc func setForTesting(enabled value: Bool, expensive path: NSNumber?) {
        monitor?.cancel()
        monitor = nil
        UserDefaults.standard.set(value, forKey: Self.defaultsKey)
        expensive = path?.boolValue
    }

    private func receive(expensive value: Bool?) {
        guard value != expensive else { return }
        expensive = value
        NotificationCenter.default.post(name: Self.changedNotification, object: nil)
    }

    // The monitor runs only while the setting is on.
    private func updateMonitor() {
        guard enabled else {
            monitor?.cancel()
            monitor = nil
            expensive = nil
            return
        }
        guard monitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in self?.receive(expensive: path.isExpensive) }
        monitor.start(queue: .main)
        self.monitor = monitor
    }
}
