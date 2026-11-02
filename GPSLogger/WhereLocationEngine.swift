import ActivityKit
import CoreLocation
import Foundation
import UIKit

@MainActor
protocol _WhereLocationBackgroundSession: AnyObject {
    func invalidate()
}

@MainActor
final class SystemLocationBackgroundSession: _WhereLocationBackgroundSession {
    private let session = CLBackgroundActivitySession()

    func invalidate() {
        session.invalidate()
    }
}

@MainActor
@objc final class WhereLocationEngine: NSObject {
    @objc static let shared = WhereLocationEngine()

    typealias LiveUpdatesProvider = @MainActor (CLLocationUpdate.LiveConfiguration) -> AsyncThrowingStream<CLLocationUpdate, Error>
    typealias Sleeper = @MainActor (Duration) async throws -> Void

    struct Dependencies {
        let liveUpdates: LiveUpdatesProvider
        let sleep: Sleeper
        let trackingEnabled: @MainActor () -> Bool
        let didPauseByRadius: @MainActor () -> Bool
        let hasBackgroundLocationActivity: @MainActor () -> Bool
        let processLocation: @MainActor (CLLocation) -> Void
        let processStationary: @MainActor (Bool) -> Void
        let makeBackgroundSession: @MainActor () -> _WhereLocationBackgroundSession

        init(
            liveUpdates: @escaping LiveUpdatesProvider = WhereLocationEngine.makeLiveUpdates,
            sleep: @escaping Sleeper = { duration in try await Task.sleep(for: duration) },
            trackingEnabled: @escaping @MainActor () -> Bool = { GLManager.shared().trackingEnabled },
            didPauseByRadius: @escaping @MainActor () -> Bool = { GLManager.shared().didPauseByRadius },
            hasBackgroundLocationActivity: @escaping @MainActor () -> Bool = { WhereBackgroundRuntime.hasBackgroundLocationActivity },
            processLocation: @escaping @MainActor (CLLocation) -> Void = { GLManager.shared().processEngineLocation($0) },
            processStationary: @escaping @MainActor (Bool) -> Void = { GLManager.shared().processEngineStationary($0) },
            makeBackgroundSession: @escaping @MainActor () -> _WhereLocationBackgroundSession = { SystemLocationBackgroundSession() }
        ) {
            self.liveUpdates = liveUpdates
            self.sleep = sleep
            self.trackingEnabled = trackingEnabled
            self.didPauseByRadius = didPauseByRadius
            self.hasBackgroundLocationActivity = hasBackgroundLocationActivity
            self.processLocation = processLocation
            self.processStationary = processStationary
            self.makeBackgroundSession = makeBackgroundSession
        }
    }

    private var backgroundSession: _WhereLocationBackgroundSession?
    private var liveTask: Task<Void, Never>?
    private var runningActivity: UInt?
    private var generation = 0
    private var reportedState = "unavailable"
    private var authorization = CLAuthorizationStatus.notDetermined
    private var accuracyAuthorization = CLAccuracyAuthorization.fullAccuracy
    private var liveUpdatesFailureLatched = false
    private let dependencies: Dependencies
    private var authorizationSession: AnyObject?
    private static let authorizationSessionKey = "GLAuthorizationSessionActive"

    init(dependencies: Dependencies = Dependencies(), authorization: CLAuthorizationStatus = .notDetermined) {
        self.dependencies = dependencies
        self.authorization = authorization
        super.init()
    }

    @objc var usingLiveUpdates: Bool {
        runningActivity != nil && liveTask != nil && liveTask?.isCancelled == false
    }

    var hasBackgroundSession: Bool { backgroundSession != nil }

    @objc var liveUpdatesFailed: Bool { liveUpdatesFailureLatched }

    @objc var state: String {
        if authorization != .authorizedAlways && authorization != .authorizedWhenInUse { return "authorization-limited" }
        if accuracyAuthorization == .reducedAccuracy { return "accuracy-limited" }
        return reportedState
    }

    @objc func updateAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        accuracyAuthorization = manager.accuracyAuthorization
        if authorization != .authorizedAlways { clearAuthorizationSession() }
        publishState()
    }

    private func publishState() {
        NotificationCenter.default.post(name: Notification.Name("WhereEngineStateChanged"), object: self)
    }

    private func setState(_ value: String) {
        guard reportedState != value else { return }
        reportedState = value
        publishState()
    }

    @objc func recordStandardLocation() {
        if runningActivity == nil { setState("receiving") }
    }

    @objc func recordStationary(_ stationary: Bool) {
        setState(stationary ? "stationary" : "receiving")
    }

    @objc func recordFailure(_ error: NSError) {
        setState(error.code == CLError.locationUnknown.rawValue ? "unavailable" : "failed")
    }

    @objc(prepareLiveUpdatesWithBackgroundIndicator:)
    func prepareLiveUpdates(backgroundIndicator: Bool) -> Bool {
        if liveUpdatesFailureLatched {
            endBackgroundSession()
            return false
        }
        let hasActivity = dependencies.hasBackgroundLocationActivity()
        let authorized = authorization == .authorizedAlways || authorization == .authorizedWhenInUse
        let useLiveUpdates = authorized && (backgroundIndicator || hasActivity || authorization == .authorizedWhenInUse)
        if useLiveUpdates && (backgroundIndicator || !hasActivity) {
            if backgroundSession == nil { backgroundSession = dependencies.makeBackgroundSession() }
        } else {
            endBackgroundSession()
        }
        return useLiveUpdates
    }

    @objc func endBackgroundSession() {
        backgroundSession?.invalidate()
        backgroundSession = nil
    }

    @objc(runLiveUpdatesWithActivityType:)
    func runLiveUpdates(activityType: UInt) {
        guard !liveUpdatesFailureLatched else { return }
        if runningActivity == activityType, let task = liveTask, !task.isCancelled { return }
        stopLiveUpdates()
        runningActivity = activityType
        let current = generation
        let config = liveConfiguration(activityType: activityType)
        let dependencies = self.dependencies
        liveTask = Task { [weak self] in
            var terminalFailure = false
            defer {
                // A canceled task must not clear the task that replaced it.
                if let self, self.generation == current {
                    self.liveTask = nil
                    self.runningActivity = nil
                    if terminalFailure, !self.liveUpdatesFailureLatched {
                        self.liveUpdatesFailureLatched = true
                        self.setState("failed")
                        NotificationCenter.default.post(name: Notification.Name("WhereLiveUpdatesFailed"), object: self)
                    }
                }
            }
            for attempt in 0...3 {
                guard let self, self.wantsUpdates(generation: current) else { return }
                do {
                    for try await update in dependencies.liveUpdates(config) {
                        guard self.wantsUpdates(generation: current) else { return }
                        if let loc = update.location { dependencies.processLocation(loc) }
                        guard self.wantsUpdates(generation: current) else { return }
                        let stationary: Bool
                        if #available(iOS 18.0, *) {
                            stationary = update.stationary
                            if update.authorizationDenied || update.authorizationDeniedGlobally || update.authorizationRestricted
                                || update.insufficientlyInUse || update.serviceSessionRequired || update.authorizationRequestInProgress {
                                self.setState("authorization-limited")
                            } else if update.accuracyLimited {
                                self.setState("accuracy-limited")
                            } else if update.locationUnavailable {
                                self.setState("unavailable")
                            } else {
                                self.setState(stationary ? "stationary" : update.location == nil ? "unavailable" : "receiving")
                            }
                        } else {
                            stationary = update.isStationary
                            self.setState(stationary ? "stationary" : update.location == nil ? "unavailable" : "receiving")
                        }
                        let diagnosticState = self.reportedState
                        dependencies.processStationary(stationary)
                        guard self.wantsUpdates(generation: current) else { return }
                        self.setState(diagnosticState)
                    }
                } catch {
                    guard self.wantsUpdates(generation: current) else { return }
                    NSLog("Location updates ended: %@", error.localizedDescription)
                }
                guard self.wantsUpdates(generation: current) else { return }
                self.setState("failed")
                guard self.authorization == .authorizedAlways || self.authorization == .authorizedWhenInUse else { return }
                guard attempt < 3 else {
                    terminalFailure = true
                    return
                }
                do { try await dependencies.sleep(.seconds(pow(2, Double(attempt)))) } catch { return }
            }
        }
    }

    private func wantsUpdates(generation: Int) -> Bool {
        !Task.isCancelled && self.generation == generation && dependencies.trackingEnabled()
            && !dependencies.didPauseByRadius()
            && (authorization == .authorizedAlways || authorization == .authorizedWhenInUse)
    }

    @objc func resetLiveUpdatesFailure() {
        liveUpdatesFailureLatched = false
    }

    @objc(configureAuthorizationSessionWithEnabled:tracking:)
    func configureAuthorizationSession(enabled: Bool, tracking: Bool) {
        guard #available(iOS 18.0, *) else { return }
        guard enabled, tracking, authorization == .authorizedAlways else {
            clearAuthorizationSession()
            return
        }
        guard authorizationSession == nil else { return }
        let restoring = UserDefaults.standard.bool(forKey: Self.authorizationSessionKey)
        guard UIApplication.shared.applicationState != .background || restoring else { return }
        authorizationSession = CLServiceSession(authorization: .always)
        UserDefaults.standard.set(true, forKey: Self.authorizationSessionKey)
    }

    private func clearAuthorizationSession() {
        if #available(iOS 18.0, *) { (authorizationSession as? CLServiceSession)?.invalidate() }
        authorizationSession = nil
        UserDefaults.standard.removeObject(forKey: Self.authorizationSessionKey)
    }

    @objc func stopLiveUpdates() {
        generation += 1
        liveTask?.cancel()
        liveTask = nil
        runningActivity = nil
        setState("unavailable")
    }

    private func liveConfiguration(activityType: UInt) -> CLLocationUpdate.LiveConfiguration {
        if #available(iOS 27.0, *), CLActivityType(rawValue: Int(activityType)) == .maritime { return .maritime }
        switch CLActivityType(rawValue: Int(activityType)) ?? .other {
        case .automotiveNavigation: return .automotiveNavigation
        case .fitness: return .fitness
        case .otherNavigation: return .otherNavigation
        case .airborne: return .airborne
        default: return .default
        }
    }

    static func makeLiveUpdates(_ configuration: CLLocationUpdate.LiveConfiguration) -> AsyncThrowingStream<CLLocationUpdate, Error> {
        AsyncThrowingStream { continuation in
            let producer = Task {
                do {
                    for try await update in CLLocationUpdate.liveUpdates(configuration) {
                        continuation.yield(update)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in producer.cancel() }
        }
    }
}
