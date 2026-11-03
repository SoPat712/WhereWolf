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
    private var currentActivity: Activity<TripActivityAttributes>?
    private var finalContent: ActivityContent<TripActivityAttributes.ContentState>?
    private var lastUpdate = Date.distantPast
    private var forceUpdate = false
    private var requestPending = false
    private var revision = 0
    private var updateTask: Task<Void, Never>?

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
        trip = nil
        finalContent = content(mode: mode, distance: distance, speed: speed)
        refresh(force: true)
    }

    @objc(syncWithTripStart:mode:distance:speed:)
    func sync(tripStart: Date?, mode: String, distance: Double, speed: Double) {
        if trip?.start != tripStart { WhereWolfBackgroundRuntime.shared.restoredAfterAudio(.trip) }
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
                await updateActivity()
                if current == revision { break }
            }
            updateTask = nil
        }
    }

    private func updateActivity() async {
        let runtime = WhereWolfBackgroundRuntime.shared
        let activities = Activity<TripActivityAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
        let action = runtime.audioAction(for: .trip, eligible: trip != nil, hasActivity: !activities.isEmpty)
        guard let trip else {
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
        for old in activities where old.id != existing?.id {
            await old.end(nil, dismissalPolicy: .immediate)
        }
        guard revision == current else { return }
        currentActivity = existing
        let nextContent = content(mode: trip.mode, distance: trip.distance, speed: trip.speed)
        if let existing {
            // Location callbacks can arrive every second; the elapsed-time display ticks on its own.
            guard forceUpdate || Date().timeIntervalSince(lastUpdate) >= 15 else { return }
            forceUpdate = false
            lastUpdate = Date()
            await existing.update(nextContent)
            return
        }
        guard requestPending || action == .restore else { return }
        guard UIApplication.shared.applicationState == .active || action == .restore else { return }
        requestPending = false
        forceUpdate = false
        if action == .restore { runtime.willRestoreAfterAudio(.trip) }
        do {
            currentActivity = try Activity.request(attributes: TripActivityAttributes(tripStart: trip.start),
                                                   content: nextContent, pushType: nil)
            lastUpdate = Date()
            runtime.restoredAfterAudio(.trip)
            GLManager.shared().updateLocationEngine()
        } catch {
            if action == .restore { runtime.restoreAfterAudioFailed() }
            if action != .restore { NSLog("Couldn't start the trip Live Activity: %@", error.localizedDescription) }
        }
    }

    private func content(mode: String, distance: Double, speed: Double) -> ActivityContent<TripActivityAttributes.ContentState> {
        let state = TripActivityAttributes.ContentState(mode: mode, distance: distance.isFinite ? max(distance, 0) : 0,
                                                        speed: speed.isFinite ? max(speed, 0) : 0)
        return ActivityContent(state: state, staleDate: nil, relevanceScore: 0)
    }

    private func endActivities(content: ActivityContent<TripActivityAttributes.ContentState>?) async {
        currentActivity = nil
        // An ended activity must leave immediately rather than keep a running trip timer on the Lock Screen.
        for activity in Activity<TripActivityAttributes>.activities {
            await activity.end(content, dismissalPolicy: .immediate)
        }
        GLManager.shared().updateLocationEngine()
    }
}
