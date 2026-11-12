import ActivityKit
import UIKit

@MainActor
@objc final class TripLiveActivityController: NSObject {
    @objc static let shared = TripLiveActivityController()

    private struct Trip {
        var start: Date
        var mode: String
        var distance: Double
        var speed: Double
    }

    private var trip: Trip?
    private var endingTripStart: Date?
    private var currentActivity: Activity<TripActivityAttributes>?
    private var activityObserver: Task<Void, Never>?
    private(set) var endingActivities = false
    private var finalContent: ActivityContent<TripActivityAttributes.ContentState>?
    private var lastUpdate = Date.distantPast
    private var forceUpdate = false
    private var requestPending = false
    private var revision = 0
    private var updateTask: Task<Void, Never>?
    private enum IntentOperation { case start, end }
    private struct IntentRequest {
        let id: UUID
        let operation: IntentOperation
        var allowance: TripLiveActivityRequestPolicy.IntentAllowance?
        let completion: CheckedContinuation<Void, Never>
    }
    private var intentRequest: IntentRequest?
    private var intentTimeout: Task<Void, Never>?

    // Only LiveActivityIntent.perform() may lend background-start permission to the reconciler.
    func requestFromIntent(tripStart: Date?) async {
        guard let tripStart, trip?.start == tripStart, !Task.isCancelled else { return }
        await requestFromIntent(tripStart: tripStart, operation: .start)
    }

    func restoreTrackingFromIntent(tripStart: Date?) async {
        guard let tripStart, !Task.isCancelled,
              trip?.start == tripStart || (trip == nil && endingTripStart == tripStart) else { return }
        await requestFromIntent(tripStart: tripStart, operation: .end)
    }

    var trackingRestoreIntent: TripLiveActivityRequestPolicy.IntentAllowance? {
        guard intentRequest?.operation == .end, !GLManager.shared().tripInProgress() else { return nil }
        return intentRequest?.allowance
    }

    private func requestFromIntent(tripStart: Date, operation: IntentOperation) async {
        let id = UUID()
        let timeout = operation == .end ? TripLiveActivityRequestPolicy.intentEndTimeout : TripLiveActivityRequestPolicy.intentTimeout
        await withTaskCancellationHandler {
            await withCheckedContinuation { completion in
                guard !Task.isCancelled else { completion.resume(); return }
                if let previous = intentRequest { finishIntentRequest(id: previous.id) }
                intentRequest = IntentRequest(id: id, operation: operation,
                    allowance: .init(tripStart: tripStart, now: ProcessInfo.processInfo.systemUptime, timeout: timeout),
                    completion: completion)
                intentTimeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                    self?.finishIntentRequest(id: id)
                }
                refresh(force: true)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finishIntentRequest(id: id) }
        }
    }

    private func finishIntentRequest(id: UUID) {
        guard let request = intentRequest, request.id == id else { return }
        intentRequest = nil
        intentTimeout?.cancel()
        intentTimeout = nil
        request.completion.resume()
    }

    @objc(startTripAt:mode:distance:speed:)
    func startTrip(at start: Date, mode: String, distance: Double, speed: Double) {
        sync(tripStart: start, mode: mode, distance: distance, speed: speed)
    }

    @objc(updateWithMode:distance:speed:force:)
    func update(mode: String, distance: Double, speed: Double, force: Bool) {
        guard trip != nil else { return }
        trip?.mode = mode
        trip?.distance = distance
        trip?.speed = speed
        guard force || (currentActivity != nil && Date().timeIntervalSince(lastUpdate) >= 15) else { return }
        refresh(force: force)
    }

    @objc(endTripWithMode:distance:speed:)
    func endTrip(mode: String, distance: Double, speed: Double) {
        endingTripStart = trip?.start
        trip = nil
        finalContent = content(mode: mode, distance: distance, speed: speed)
        refresh(force: true)
    }

    @objc(syncWithTripStart:mode:distance:speed:)
    func sync(tripStart: Date?, mode: String, distance: Double, speed: Double) {
        if trip?.start != tripStart { WhereWolfBackgroundRuntime.shared.restoredAfterAudio(.trip) }
        if let previous = trip?.start, tripStart == nil { endingTripStart = previous }
        if tripStart != nil { endingTripStart = nil }
        trip = tripStart.map { Trip(start: $0, mode: mode, distance: distance, speed: speed) }
        finalContent = nil
        requestPending = trip != nil
        refresh(force: true)
    }

    private func refresh(force: Bool) {
        forceUpdate = forceUpdate || force
        revision += 1
        guard updateTask == nil else { return }
        updateTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let current = revision
                let intentID = intentRequest?.id
                await updateActivity()
                if current == revision {
                    if let intentID, intentRequest?.operation == .start || (trip == nil && !GLManager.shared().tripInProgress()) {
                        finishIntentRequest(id: intentID)
                    }
                    break
                }
            }
            updateTask = nil
        }
    }

    private func updateActivity() async {
        let runtime = WhereWolfBackgroundRuntime.shared
        defer { runtime.tripActivityChanged() }
        let activities = Activity<TripActivityAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
        let action = runtime.audioAction(for: .trip, eligible: trip != nil, hasActivity: !activities.isEmpty)
        guard let trip else {
            let current = revision
            await runtime.prepareForTripActivityEnd(tripStart: endingTripStart)
            defer { runtime.finishTripActivityEnd() }
            guard revision == current, self.trip == nil else { return }
            await endActivities(content: finalContent)
            return
        }
        if action == .hide {
            if !activities.isEmpty || currentActivity != nil { await endActivities(content: nil) }
            return
        }
        if action == .waitForForeground { return }
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            await endActivities(content: nil)
            return
        }
        let current = revision
        let existing = activities.first { abs($0.attributes.tripStart.timeIntervalSince(trip.start)) < 1 }
        let obsolete = activities.filter { $0.id != existing?.id }
        if !obsolete.isEmpty { await endActivities(obsolete, content: nil) }
        guard revision == current else { return }
        if let existing {
            observe(existing)
        } else {
            activityObserver?.cancel()
            activityObserver = nil
            currentActivity = nil
        }
        let nextContent = content(mode: trip.mode, distance: trip.distance, speed: trip.speed)
        if let existing {
            // Location callbacks can arrive every second; the elapsed-time display ticks on its own.
            guard forceUpdate || Date().timeIntervalSince(lastUpdate) >= 15 else { return }
            forceUpdate = false
            lastUpdate = Date()
            await existing.update(nextContent)
            return
        }
        let manager = GLManager.shared()!
        let decision = TripLiveActivityRequestPolicy.decision(tripStart: trip.start,
            enabled: manager.tripLiveActivityEnabled && manager.trackingEnabled,
            authorized: ActivityAuthorizationInfo().areActivitiesEnabled, requestPending: requestPending,
            isActive: UIApplication.shared.applicationState == .active, audioAction: action,
            intentStart: intentRequest?.operation == .start ? intentRequest?.allowance : nil,
            now: ProcessInfo.processInfo.systemUptime)
        guard decision != .deferRequest else { return }
        if intentRequest?.operation == .start { intentRequest?.allowance = nil }
        requestPending = false
        forceUpdate = false
        if action == .restore { runtime.willRestoreAfterAudio(.trip) }
        do {
            let activity = try Activity.request(attributes: TripActivityAttributes(tripStart: trip.start),
                                                content: nextContent, pushType: nil)
            observe(activity)
            lastUpdate = Date()
            runtime.restoredAfterAudio(.trip)
            // A missing custom sound can fall back to the system sound. Omit the alert in that case.
            if decision == .requestAndAlert,
               Bundle.main.url(forResource: TripLiveActivityRequestPolicy.silentSoundName, withExtension: nil) != nil {
                await activity.update(nextContent, alertConfiguration: AlertConfiguration(
                    title: "Trip started", body: "WhereWolf is recording your trip.",
                    sound: .named(TripLiveActivityRequestPolicy.silentSoundName)))
            }
        } catch {
            if action == .restore { runtime.restoreAfterAudioFailed() }
            if action != .restore { NSLog("Couldn't start the trip Live Activity: %@", error.localizedDescription) }
        }
    }

    private func content(mode: String, distance: Double, speed: Double) -> ActivityContent<TripActivityAttributes.ContentState> {
        let state = TripActivityAttributes.ContentState(mode: mode, distance: distance.isFinite ? max(distance, 0) : 0,
                                                        speed: speed.isFinite ? max(speed, 0) : 0)
        return ActivityContent(state: state, staleDate: nil, relevanceScore: TripLiveActivityRequestPolicy.relevanceScore)
    }

    private func endActivities(_ activities: [Activity<TripActivityAttributes>]? = nil,
                               content: ActivityContent<TripActivityAttributes.ContentState>?) async {
        activityObserver?.cancel()
        activityObserver = nil
        currentActivity = nil
        // Reconcile without the outgoing support before ActivityKit's asynchronous end.
        endingActivities = true
        GLManager.shared().updateLocationEngine()
        defer {
            endingActivities = false
            GLManager.shared().updateLocationEngine()
        }
        // An ended activity must leave immediately rather than keep a running trip timer on the Lock Screen.
        for activity in activities ?? Activity<TripActivityAttributes>.activities {
            await activity.end(content, dismissalPolicy: .immediate)
        }
    }

    private func observe(_ activity: Activity<TripActivityAttributes>) {
        guard currentActivity?.id != activity.id else { return }
        currentActivity = activity
        GLManager.shared().updateLocationEngine()
        WhereWolfBackgroundRuntime.shared.tripActivityChanged()
        activityObserver?.cancel()
        activityObserver = Task { [weak self] in
            for await state in activity.activityStateUpdates {
                guard !Task.isCancelled, let self, self.currentActivity?.id == activity.id else { return }
                GLManager.shared().updateLocationEngine()
                WhereWolfBackgroundRuntime.shared.tripActivityChanged()
                if state == .ended || state == .dismissed {
                    self.currentActivity = nil
                    return
                }
            }
        }
    }
}
