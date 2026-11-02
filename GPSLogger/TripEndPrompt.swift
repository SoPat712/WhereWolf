import CoreLocation
import CoreMotion
import Foundation
import UserNotifications

// Decides when the phone has stopped during a trip. The thresholds are fixed, so the setting is one switch.
struct StopDetector {
    // How far the phone can wander and still count as stopped, such as walking around a house.
    static let radius: CLLocationDistance = 75
    static let maxAccuracy: CLLocationAccuracy = 100
    static let stopDuration: TimeInterval = 5 * 60
    // Without motion data a stop looks like a traffic jam, so it waits longer.
    static let stopDurationWithoutMotion: TimeInterval = 10 * 60

    enum Result: Equatable {
        case none
        case stopped(CLLocation)
        // The phone moved on after a stop it was asked about.
        case movedOn
    }

    private(set) var start: CLLocation?
    private var sawStationary = false
    private var prompted = false

    // stationary: motion reports only stationary. inVehicle: driving or cycling above low confidence.
    mutating func update(location: CLLocation?, now: Date, hasMotion: Bool,
                         stationary: Bool, inVehicle: Bool) -> Result {
        guard let location, location.horizontalAccuracy >= 0,
              location.horizontalAccuracy <= Self.maxAccuracy else { return .none }
        guard let start, location.distance(from: start) <= Self.radius else {
            let wasPrompted = prompted
            start = location
            sawStationary = stationary
            prompted = false
            return wasPrompted ? .movedOn : .none
        }
        if stationary { sawStationary = true }
        if prompted { return .none }
        // Fixes arrive rarely once the phone is still, so the clock times the stop.
        let stoppedFor = now.timeIntervalSince(start.timestamp)
        let stopped = hasMotion
            ? stoppedFor >= Self.stopDuration && sawStationary && !inVehicle
            : stoppedFor >= Self.stopDurationWithoutMotion
        guard stopped else { return .none }
        prompted = true
        return .stopped(start)
    }

    mutating func reset() {
        start = nil
        sawStationary = false
        prompted = false
    }
}

// "Ask to End Trip When Stopped": sends one prompt per stop. Its End Trip action, handled in
// GLManager, ends the trip when the phone stopped rather than when the action is tapped.
@objc(GLTripEndPrompt) final class TripEndPrompt: NSObject {
    @objc static let shared = TripEndPrompt()

    static let notificationID = "GLLocalNotificationEndTripWhenStopped"
    private static let checkInterval: TimeInterval = 30

    private var detector = StopDetector()
    private var timer: Timer?
    private var started = false

    @objc var enabled: Bool {
        get { UserDefaults.standard.bool(forKey: GLTripAskToEndWhenStoppedDefaultsName) }
        set {
            UserDefaults.standard.set(newValue, forKey: GLTripAskToEndWhenStoppedDefaultsName)
            // The prompt needs notification permission, not the routine notification setting.
            if newValue {
                UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
            }
            update()
        }
    }

    // Called at launch. Watching starts and stops with trips, from location callbacks in the background too.
    @objc func start() {
        guard !started else { return }
        started = true
        UserDefaults.standard.addObserver(self, forKeyPath: GLTripStartTimeDefaultsName, options: [], context: nil)
        UserDefaults.standard.addObserver(self, forKeyPath: GLTripAskToEndWhenStoppedDefaultsName, options: [], context: nil)
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(check), name: Notification.Name(GLNewDataNotification), object: nil)
        center.addObserver(self, selector: #selector(check), name: Notification.Name(GLNewActivityNotification), object: nil)
        update()
    }

    override func observeValue(forKeyPath keyPath: String?, of object: Any?,
                               change: [NSKeyValueChangeKey: Any]?, context: UnsafeMutableRawPointer?) {
        DispatchQueue.main.async { [self] in update() }
    }

    private var watching: Bool {
        let manager: GLManager = GLManager.shared()
        return enabled && manager.tripInProgress()
    }

    private func update() {
        if watching {
            guard timer == nil else { return }
            detector.reset()
            timer = Timer.scheduledTimer(withTimeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
                self?.check()
            }
            timer?.tolerance = 5
        } else if timer != nil {
            timer?.invalidate()
            timer = nil
            detector.reset()
            withdrawPrompt()
        }
    }

    @objc private func check() {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { [self] in check() }
            return
        }
        guard watching else { return }
        let manager: GLManager = GLManager.shared()
        // Motion is used only when already authorized; its permission is requested elsewhere.
        let motion = CMMotionActivityManager.isActivityAvailable()
            && CMMotionActivityManager.authorizationStatus() == .authorized ? manager.lastMotion : nil
        let stationary = motion.map { $0.stationary && !$0.walking && !$0.running && !$0.cycling && !$0.automotive } ?? false
        let inVehicle = motion.map { ($0.automotive || $0.cycling) && $0.confidence != .low } ?? false
        switch detector.update(location: manager.lastReceivedLocation, now: Date(), hasMotion: motion != nil,
                               stationary: stationary, inVehicle: inVehicle) {
        case .stopped(let location):
            sendPrompt(stoppedAt: location, tripStart: manager.currentTripStart())
        case .movedOn:
            withdrawPrompt()
        case .none:
            break
        }
    }

    private func sendPrompt(stoppedAt location: CLLocation, tripStart: Date?) {
        guard let tripStart else { return }
        let content = UNMutableNotificationContent()
        content.title = "End Trip?"
        content.body = "It looks like you stopped at \(location.timestamp.formatted(date: .omitted, time: .shortened)). End the trip then?"
        content.sound = .default
        content.categoryIdentifier = GLNotificationCategoryTripName
        content.userInfo = Self.userInfo(tripStart: tripStart, stoppedAt: location)
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: Self.notificationID, content: content, trigger: nil))
    }

    static func userInfo(tripStart: Date, stoppedAt location: CLLocation) -> [String: Double] {
        [GLEndTripPromptTripStartKey: tripStart.timeIntervalSince1970,
         GLEndTripPromptStoppedAtKey: location.timestamp.timeIntervalSince1970,
         GLEndTripPromptLatitudeKey: location.coordinate.latitude,
         GLEndTripPromptLongitudeKey: location.coordinate.longitude,
         GLEndTripPromptAccuracyKey: location.horizontalAccuracy]
    }

    // The phone moved on or the trip ended another way, so a stale prompt cannot end a later trip early.
    private func withdrawPrompt() {
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.notificationID])
        center.removePendingNotificationRequests(withIdentifiers: [Self.notificationID])
    }
}
