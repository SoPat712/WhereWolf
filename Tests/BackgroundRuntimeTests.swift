import ActivityKit
import AVFoundation
import CoreLocation
import UserNotifications
import XCTest
@testable import Where

final class BackgroundRuntimeTests: XCTestCase {
    @MainActor func testSilentAudioStartsOnlyWhenEnabledAndStops() async throws {
        let audio = SilentAudioSession()
        audio.refresh()
        XCTAssertFalse(audio.isPlaying)
        audio.setEnabled(true)
        try await waitUntil { audio.isPlaying }
        XCTAssertTrue(audio.isPlaying, audio.status)
        audio.setEnabled(false)
        try await waitUntil { audio.status == "Off" }
        XCTAssertFalse(audio.isPlaying)
        audio.refresh()
        XCTAssertFalse(audio.isPlaying)
    }

    @MainActor func testInterruptionRequiresResumePermission() async throws {
        let audio = SilentAudioSession()
        defer { audio.setEnabled(false) }
        audio.setEnabled(true)
        try await waitUntil { audio.isPlaying }
        XCTAssertTrue(audio.isPlaying, audio.status)
        interrupt(.began)
        try await waitUntil { !audio.isPlaying }
        XCTAssertFalse(audio.isPlaying)
        audio.refresh()
        XCTAssertFalse(audio.isPlaying)
        interrupt(.ended)
        try await waitUntil { audio.status == "Silent audio paused after an interruption" }
        audio.refresh()
        XCTAssertFalse(audio.isPlaying)
        audio.retry()
        try await waitUntil { audio.isPlaying }
        XCTAssertTrue(audio.isPlaying, audio.status)
        audio.setEnabled(false)
        try await waitUntil { audio.status == "Off" }
    }

    @MainActor func testAuthorizedResumeRestartsEnabledAudio() async throws {
        let audio = SilentAudioSession()
        defer { audio.setEnabled(false) }
        audio.setEnabled(true)
        try await waitUntil { audio.isPlaying }
        interrupt(.began)
        try await waitUntil { !audio.isPlaying }
        interrupt(.ended, options: .shouldResume)
        try await waitUntil { audio.isPlaying }
        XCTAssertTrue(audio.isPlaying, audio.status)
        audio.setEnabled(false)
        try await waitUntil { audio.status == "Off" }
    }

    @MainActor func testStoppingDuringInterruptionPreventsResume() async throws {
        let audio = SilentAudioSession()
        audio.setEnabled(true)
        try await waitUntil { audio.isPlaying }
        interrupt(.began)
        try await waitUntil { !audio.isPlaying }
        audio.setEnabled(false)
        try await waitUntil { audio.status == "Off" }
        interrupt(.ended, options: .shouldResume)
        audio.retry()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(audio.isPlaying)
    }

    @MainActor func testExplicitRetryRecoversFromMissingInterruptionEnd() async throws {
        let audio = SilentAudioSession()
        defer { audio.setEnabled(false) }
        audio.setEnabled(true)
        try await waitUntil { audio.isPlaying }
        interrupt(.began)
        try await waitUntil { !audio.isPlaying }
        audio.refresh()
        XCTAssertFalse(audio.isPlaying)
        audio.retry()
        try await waitUntil { audio.isPlaying }
        XCTAssertTrue(audio.isPlaying, audio.status)
        audio.setEnabled(false)
        try await waitUntil { audio.status == "Off" }
    }

    @MainActor func testLiveActivityAndAudioFollowTracking() async throws {
        try await withTrackingActivity { activity in
            let runtime = WhereBackgroundRuntime.shared
            runtime.appearance = "blank"
            try await waitUntil {
                Activity<IslandOnlyTrackingAttributes>.activities.contains {
                    $0.activityState == .active && $0.content.state.appearance == .blank
                } && Activity<TrackingActivityAttributes>.activities.isEmpty
            }
            XCTAssertTrue(activity.activityState == .ended || activity.activityState == .dismissed)
            runtime.silentAudioEnabled = true
            try await waitUntil { runtime.audioStatus == "Silent audio active" }
        }
    }

    @MainActor func testAudioWaitsForMediaServiceReset() async throws {
        let audio = SilentAudioSession()
        defer { audio.setEnabled(false) }
        audio.setEnabled(true)
        try await waitUntil { audio.isPlaying }
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereLostNotification,
                                        object: AVAudioSession.sharedInstance())
        try await waitUntil { audio.status == "Waiting for the audio service" }
        audio.retry()
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertFalse(audio.isPlaying)
        NotificationCenter.default.post(name: AVAudioSession.mediaServicesWereResetNotification,
                                        object: AVAudioSession.sharedInstance())
        try await waitUntil { audio.isPlaying }
    }

    @MainActor func testBlankActivityUsesLegacyUntilWidgetAppearanceIsRestored() async throws {
        try await withTrackingActivity { _ in
            let manager = GLManager.shared()!
            let runtime = WhereBackgroundRuntime.shared
            let engine = WhereLocationEngine.shared
            manager.showBackgroundLocationIndicator = false
            manager.useNewLocationEngine = true
            runtime.appearance = "blank"
            try await waitUntil {
                !Activity<IslandOnlyTrackingAttributes>.activities.isEmpty
                    && Activity<TrackingActivityAttributes>.activities.isEmpty
                    && !engine.usingLiveUpdates && !engine.hasBackgroundSession
            }
            XCTAssertTrue(WhereBackgroundRuntime.hasActiveTrackingActivity)
            XCTAssertFalse(WhereBackgroundRuntime.hasBackgroundLocationActivity)
            runtime.appearance = "status"
            try await waitUntil {
                Activity<IslandOnlyTrackingAttributes>.activities.isEmpty
                    && Activity<TrackingActivityAttributes>.activities.contains {
                        $0.activityState == .active && $0.content.state.appearance == .status
                    } && engine.usingLiveUpdates && !engine.hasBackgroundSession
            }
        }
    }

    @MainActor func testIndicatorToggleAndLiveActivityControlBackgroundSession() async throws {
        try await withTrackingActivity { _ in
            let manager = GLManager.shared()!
            let runtime = WhereBackgroundRuntime.shared
            let engine = WhereLocationEngine.shared
            manager.pausesAutomatically = false
            manager.showBackgroundLocationIndicator = false
            manager.useNewLocationEngine = true
            try await waitUntil { engine.usingLiveUpdates && !engine.hasBackgroundSession }

            manager.showBackgroundLocationIndicator = true
            XCTAssertTrue(engine.hasBackgroundSession)
            manager.showBackgroundLocationIndicator = false
            XCTAssertFalse(engine.hasBackgroundSession)
            XCTAssertTrue(engine.usingLiveUpdates)

            runtime.liveActivityEnabled = false
            try await waitUntil {
                Activity<TrackingActivityAttributes>.activities.isEmpty && !engine.usingLiveUpdates
            }
            XCTAssertFalse(engine.hasBackgroundSession)
            XCTAssertTrue(manager.trackingEnabled)
            XCTAssertTrue(manager.useNewLocationEngine)

            runtime.liveActivityEnabled = true
            try await waitUntil { engine.usingLiveUpdates && !engine.hasBackgroundSession }
            manager.useNewLocationEngine = false
            XCTAssertFalse(engine.usingLiveUpdates)
            manager.showBackgroundLocationIndicator = true
            XCTAssertTrue(manager.locationManager.showsBackgroundLocationIndicator)
            XCTAssertFalse(engine.hasBackgroundSession)
            manager.showBackgroundLocationIndicator = false
            XCTAssertFalse(manager.locationManager.showsBackgroundLocationIndicator)
        }
    }

    @MainActor func testEndedActivityFallsBackWithoutEnablingIndicator() async throws {
        try await withTrackingActivity { activity in
            let manager = GLManager.shared()!
            let engine = WhereLocationEngine.shared
            manager.showBackgroundLocationIndicator = false
            manager.useNewLocationEngine = true
            try await waitUntil { engine.usingLiveUpdates && !engine.hasBackgroundSession }
            await activity.end(nil, dismissalPolicy: .immediate)
            try await waitUntil { !engine.usingLiveUpdates }
            XCTAssertFalse(engine.hasBackgroundSession)
            XCTAssertFalse(manager.locationManager.showsBackgroundLocationIndicator)
            XCTAssertTrue(manager.trackingEnabled)
        }
    }

    @MainActor func testEndedBlankActivityFallsBackWithoutEnablingIndicator() async throws {
        try await withTrackingActivity { _ in
            let manager = GLManager.shared()!
            let engine = WhereLocationEngine.shared
            manager.showBackgroundLocationIndicator = false
            manager.useNewLocationEngine = true
            WhereBackgroundRuntime.shared.appearance = "blank"
            try await waitUntil {
                Activity<IslandOnlyTrackingAttributes>.activities.contains { $0.activityState == .active }
                    && !engine.usingLiveUpdates && !engine.hasBackgroundSession
            }
            let activity = try XCTUnwrap(Activity<IslandOnlyTrackingAttributes>.activities.first)
            await activity.end(nil, dismissalPolicy: .immediate)
            try await waitUntil { !engine.usingLiveUpdates && !WhereBackgroundRuntime.hasActiveTrackingActivity }
            XCTAssertFalse(engine.hasBackgroundSession)
            XCTAssertFalse(manager.locationManager.showsBackgroundLocationIndicator)
            XCTAssertTrue(manager.trackingEnabled)
        }
    }

    @MainActor func testAudioHidingReconcilesEngineAndRestoresEveryTrackingAppearance() async throws {
        try await withTrackingActivity { _ in
            let runtime = WhereBackgroundRuntime.shared
            let saved = runtime.audioDependencies
            var playing = false
            var uptime: TimeInterval = 0
            runtime.audioDependencies = .init(otherAudioPlaying: { playing }, uptime: { uptime })
            defer { runtime.audioDependencies = saved; runtime.hideWhileAudioPlays = false }
            let manager = GLManager.shared()!
            let engine = WhereLocationEngine.shared
            manager.showBackgroundLocationIndicator = false
            manager.useNewLocationEngine = true
            for appearance in ["status", "minimal", "blank"] {
                runtime.appearance = appearance
                try await waitUntil {
                    if appearance == "blank" {
                        return runtime.activityStatus == "Active"
                            && Activity<IslandOnlyTrackingAttributes>.activities.contains { $0.activityState == .active }
                            && Activity<TrackingActivityAttributes>.activities.isEmpty
                    }
                    return Activity<TrackingActivityAttributes>.activities.contains {
                        $0.activityState == .active && $0.content.state.appearance.rawValue == appearance
                    } && Activity<IslandOnlyTrackingAttributes>.activities.isEmpty
                }
                playing = true
                runtime.hideWhileAudioPlays = true
                uptime += 15
                runtime.checkAudioFromLocation()
                try await waitUntil { runtime.activityStatus == "Hidden while other audio plays" }
                XCTAssertFalse(WhereBackgroundRuntime.hasActiveTrackingActivity)
                XCTAssertFalse(engine.usingLiveUpdates)
                XCTAssertFalse(engine.hasBackgroundSession)
                XCTAssertTrue(manager.trackingEnabled)
                XCTAssertFalse(manager.showBackgroundLocationIndicator)
                playing = false
                uptime += 15
                runtime.checkAudioFromLocation()
                try await waitUntil {
                    runtime.activityStatus == "Active" && WhereBackgroundRuntime.hasActiveTrackingActivity
                        && engine.usingLiveUpdates == (appearance != "blank")
                }
                XCTAssertFalse(engine.hasBackgroundSession)
                runtime.hideWhileAudioPlays = false
            }
        }
    }

    @MainActor func testOwnSilentAudioDoesNotHideActivityOrStopWhenHidden() async throws {
        try await withTrackingActivity { _ in
            let runtime = WhereBackgroundRuntime.shared
            runtime.silentAudioEnabled = true
            try await waitUntil { runtime.audioStatus == "Silent audio active" }
            XCTAssertFalse(AVAudioSession.sharedInstance().isOtherAudioPlaying)
            let saved = runtime.audioDependencies
            var playing = false
            var uptime: TimeInterval = 0
            runtime.audioDependencies = .init(otherAudioPlaying: { playing }, uptime: { uptime })
            defer { runtime.audioDependencies = saved; runtime.hideWhileAudioPlays = false }
            runtime.hideWhileAudioPlays = true
            uptime = 15
            runtime.checkAudioFromLocation()
            try await Task.sleep(for: .milliseconds(100))
            XCTAssertTrue(WhereBackgroundRuntime.hasActiveTrackingActivity)
            playing = true
            uptime = 30
            runtime.checkAudioFromLocation()
            uptime = 45
            runtime.checkAudioFromLocation()
            try await waitUntil { runtime.activityStatus == "Hidden while other audio plays" }
            XCTAssertEqual(runtime.audioStatus, "Silent audio active")
            runtime.hideWhileAudioPlays = false
            try await waitUntil { WhereBackgroundRuntime.hasActiveTrackingActivity }
            XCTAssertEqual(runtime.audioStatus, "Silent audio active")
        }
    }

    @MainActor func testAudioHidesAndRestoresSeparateTripActivityWithoutEndingTrip() async throws {
        try await withTrackingActivity { _ in
            let runtime = WhereBackgroundRuntime.shared
            let saved = runtime.audioDependencies
            let manager = GLManager.shared()!
            let defaults = UserDefaults.standard
            let start = Date()
            var playing = true
            var uptime: TimeInterval = 0
            runtime.audioDependencies = .init(otherAudioPlaying: { playing }, uptime: { uptime })
            defer {
                runtime.audioDependencies = saved
                runtime.hideWhileAudioPlays = false
                defaults.removeObject(forKey: GLTripStartTimeDefaultsName)
                manager.tripLiveActivityEnabled = false
            }
            defaults.set(start, forKey: GLTripStartTimeDefaultsName)
            manager.tripLiveActivityEnabled = true
            try await waitUntil { Activity<TripActivityAttributes>.activities.contains { $0.activityState == .active } }
            runtime.hideWhileAudioPlays = true
            uptime = 15
            runtime.checkAudioFromLocation()
            try await waitUntil {
                Activity<TripActivityAttributes>.activities.isEmpty && !WhereBackgroundRuntime.hasActiveTrackingActivity
            }
            XCTAssertEqual(manager.currentTripStart(), start)
            XCTAssertTrue(manager.trackingEnabled)
            playing = false
            uptime = 30
            runtime.checkAudioFromLocation()
            try await waitUntil {
                Activity<TripActivityAttributes>.activities.contains { $0.activityState == .active }
                    && WhereBackgroundRuntime.hasActiveTrackingActivity
            }
            XCTAssertEqual(manager.currentTripStart(), start)
            defaults.removeObject(forKey: GLTripStartTimeDefaultsName)
            manager.syncTripLiveActivity()
            try await waitUntil { Activity<TripActivityAttributes>.activities.isEmpty }
        }
    }

    @MainActor func testLiveActivityFollowsScheduledReminder() async throws {
        guard ProcessInfo.processInfo.environment["WHERE_NOTIFICATION_INTEGRATION"] == "1" else {
            throw XCTSkip("Enable WHERE_NOTIFICATION_INTEGRATION with notifications approved to test the system reminder service.")
        }
        try await withTrackingActivity { activity in
            let center = UNUserNotificationCenter.current()
            let notification = UNMutableNotificationContent()
            notification.body = "Location updates were stopped. Launch the app to resume."
            try await center.add(UNNotificationRequest(identifier: "reminder", content: notification,
                                 trigger: UNTimeIntervalNotificationTrigger(timeInterval: 60, repeats: false)))
            NotificationCenter.default.post(name: Notification.Name(GLReminderChangedNotification), object: nil)
            try await waitUntil { activity.content.staleDate != nil }
            let requests = await center.pendingNotificationRequests()
            let trigger = try XCTUnwrap(requests.first { $0.identifier == "reminder" }?.trigger as? UNTimeIntervalNotificationTrigger)
            let deadline = try XCTUnwrap(trigger.nextTriggerDate())
            XCTAssertEqual(try XCTUnwrap(activity.content.staleDate).timeIntervalSince1970,
                           deadline.timeIntervalSince1970, accuracy: 1)
            center.removePendingNotificationRequests(withIdentifiers: ["reminder"])
            NotificationCenter.default.post(name: Notification.Name(GLReminderChangedNotification), object: nil)
            try await waitUntil { activity.content.staleDate == nil }
        }
    }

    @MainActor private func withTrackingActivity(_ body: (Activity<TrackingActivityAttributes>) async throws -> Void) async throws {
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier!
        let saved = defaults.persistentDomain(forName: domain) ?? [:]
        let manager = GLManager.shared()!
        let runtime = WhereBackgroundRuntime.shared
        manager.stopAllUpdates()
        defer {
            manager.stopAllUpdates()
            defaults.setPersistentDomain(saved, forName: domain)
        }
        guard manager.locationManager.authorizationStatus == .authorizedAlways else {
            throw XCTSkip("Grant location-always on the disposable test simulator before this integration test.")
        }
        defaults.set(false, forKey: "GLNotificationsEnabledDefaults")
        defaults.set(1, forKey: "GLSignificantLocationModeDefaults")
        defaults.set(-1, forKey: "GLSendIntervalDefaults")
        runtime.silentAudioEnabled = false
        runtime.hideWhileAudioPlays = false
        runtime.appearance = "minimal"
        runtime.liveActivityEnabled = true
        manager.startAllUpdates()
        try await waitUntil { !Activity<TrackingActivityAttributes>.activities.isEmpty }
        let activity = try XCTUnwrap(Activity<TrackingActivityAttributes>.activities.first)
        try await body(activity)
        manager.stopAllUpdates()
        try await waitUntil {
            Activity<TrackingActivityAttributes>.activities.isEmpty && Activity<IslandOnlyTrackingAttributes>.activities.isEmpty
        }
        try await waitUntil { runtime.audioStatus == "Off" }
    }

    @MainActor func testReminderOffersAResumeActionThatRunsInTheBackground() async throws {
        let manager = GLManager.shared()!
        XCTAssertEqual(manager.reminderContent().categoryIdentifier, "REMINDER")
        let categories = await UNUserNotificationCenter.current().notificationCategories()
        let category = try XCTUnwrap(categories.first { $0.identifier == "REMINDER" })
        let action = try XCTUnwrap(category.actions.first { $0.identifier == "RESUME_TRACKING" })
        XCTAssertFalse(action.options.contains(.foreground), "A foreground action would not run from a watch")
        XCTAssertTrue(categories.contains { $0.identifier == "TRIP" }, "End Trip must keep working")
    }

    @MainActor func testResumeFromReminderNeverOverridesStop() {
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier!
        let saved = defaults.persistentDomain(forName: domain) ?? [:]
        let manager = GLManager.shared()!
        defer {
            manager.stopAllUpdates()
            defaults.setPersistentDomain(saved, forName: domain)
        }
        defaults.set(true, forKey: "GLNotificationsEnabledDefaults")
        manager.stopAllUpdates()
        XCTAssertFalse(manager.resumeTrackingFromReminder())
        XCTAssertFalse(manager.trackingEnabled)
        XCTAssertFalse(defaults.bool(forKey: GLTrackingStateDefaultsName))
    }

    @MainActor private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Timed out waiting for background runtime state")
        throw NSError(domain: "BackgroundRuntimeTests", code: 1)
    }

    @MainActor private func interrupt(_ type: AVAudioSession.InterruptionType,
                                      options: AVAudioSession.InterruptionOptions = []) {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                                        object: AVAudioSession.sharedInstance(),
                                        userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue,
                                                   AVAudioSessionInterruptionOptionKey: options.rawValue])
    }
}
