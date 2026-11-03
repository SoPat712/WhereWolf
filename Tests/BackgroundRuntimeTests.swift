import ActivityKit
import AVFoundation
import CoreLocation
import UIKit
import UserNotifications
import XCTest
@testable import WhereWolf

final class BackgroundRuntimeTests: XCTestCase {
    @MainActor func testBlankAppearanceDefaultPreservesSavedChoices() {
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier!
        let saved = defaults.persistentDomain(forName: domain) ?? [:]
        let runtime = WhereWolfBackgroundRuntime.shared
        let key = "WhereWolfLiveActivityAppearance"
        defer { defaults.setPersistentDomain(saved, forName: domain) }
        defaults.removeObject(forKey: key)
        XCTAssertEqual(runtime.appearance, "blank")
        XCTAssertNil(defaults.persistentDomain(forName: domain)?[key])
        for appearance in ["status", "minimal", "blank"] {
            defaults.set(appearance, forKey: key)
            XCTAssertEqual(runtime.appearance, appearance)
        }
    }

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
            let runtime = WhereWolfBackgroundRuntime.shared
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
            let runtime = WhereWolfBackgroundRuntime.shared
            let engine = WhereWolfLocationEngine.shared
            manager.showBackgroundLocationIndicator = false
            manager.useNewLocationEngine = true
            runtime.appearance = "blank"
            try await waitUntil {
                !Activity<IslandOnlyTrackingAttributes>.activities.isEmpty
                    && Activity<TrackingActivityAttributes>.activities.isEmpty
                    && !engine.usingLiveUpdates && !engine.hasBackgroundSession
            }
            XCTAssertTrue(WhereWolfBackgroundRuntime.hasActiveTrackingActivity)
            XCTAssertFalse(WhereWolfBackgroundRuntime.hasBackgroundLocationActivity)
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
            let runtime = WhereWolfBackgroundRuntime.shared
            let engine = WhereWolfLocationEngine.shared
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
            let engine = WhereWolfLocationEngine.shared
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
            let engine = WhereWolfLocationEngine.shared
            manager.showBackgroundLocationIndicator = false
            manager.useNewLocationEngine = true
            WhereWolfBackgroundRuntime.shared.appearance = "blank"
            try await waitUntil {
                Activity<IslandOnlyTrackingAttributes>.activities.contains { $0.activityState == .active }
                    && !engine.usingLiveUpdates && !engine.hasBackgroundSession
            }
            let activity = try XCTUnwrap(Activity<IslandOnlyTrackingAttributes>.activities.first)
            await activity.end(nil, dismissalPolicy: .immediate)
            try await waitUntil { !engine.usingLiveUpdates && !WhereWolfBackgroundRuntime.hasActiveTrackingActivity }
            XCTAssertFalse(engine.hasBackgroundSession)
            XCTAssertFalse(manager.locationManager.showsBackgroundLocationIndicator)
            XCTAssertTrue(manager.trackingEnabled)
        }
    }

    @MainActor func testAudioHidingReconcilesEngineAndRestoresEveryTrackingAppearance() async throws {
        try await withTrackingActivity { _ in
            let runtime = WhereWolfBackgroundRuntime.shared
            let saved = runtime.audioDependencies
            let clock = AudioClock()
            runtime.audioDependencies = clock.dependencies
            defer { runtime.hideWhileAudioPlays = false; runtime.audioDependencies = saved }
            let manager = GLManager.shared()!
            let engine = WhereWolfLocationEngine.shared
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
                clock.playing = true
                runtime.hideWhileAudioPlays = true
                XCTAssertEqual(clock.pendingCount, 1)
                XCTAssertTrue(WhereWolfBackgroundRuntime.hasActiveTrackingActivity)
                try clock.fireNext()
                try await waitUntil { runtime.activityStatus == "Hidden while other audio plays" }
                XCTAssertEqual(clock.pendingCount, 0)
                XCTAssertFalse(WhereWolfBackgroundRuntime.hasActiveTrackingActivity)
                XCTAssertFalse(engine.usingLiveUpdates)
                XCTAssertFalse(engine.hasBackgroundSession)
                XCTAssertTrue(manager.trackingEnabled)
                XCTAssertFalse(manager.showBackgroundLocationIndicator)
                clock.playing = false
                clock.uptime += 15
                runtime.checkAudioFromLocation()
                XCTAssertEqual(clock.pendingCount, 1)
                XCTAssertEqual(runtime.activityStatus, "Hidden while other audio plays")
                try clock.fireNext()
                try await waitUntil {
                    runtime.activityStatus == "Active" && WhereWolfBackgroundRuntime.hasActiveTrackingActivity
                        && engine.usingLiveUpdates == (appearance != "blank")
                }
                XCTAssertEqual(clock.pendingCount, 0)
                XCTAssertFalse(engine.hasBackgroundSession)
                runtime.hideWhileAudioPlays = false
            }
        }
    }

    @MainActor func testDisablingAudioHidingCancelsFollowUp() async throws {
        try await withTrackingActivity { _ in
            let runtime = WhereWolfBackgroundRuntime.shared
            let saved = runtime.audioDependencies
            defer { runtime.hideWhileAudioPlays = false; runtime.audioDependencies = saved }
            for hidden in [false, true] {
                let clock = AudioClock()
                clock.playing = true
                runtime.audioDependencies = clock.dependencies
                runtime.hideWhileAudioPlays = true
                if hidden {
                    try clock.fireNext()
                    try await waitUntil { runtime.activityStatus == "Hidden while other audio plays" }
                    clock.playing = false
                    clock.uptime += 15
                    runtime.checkAudioFromLocation()
                }
                let work = try XCTUnwrap(clock.scheduled.last?.work)
                XCTAssertEqual(clock.pendingCount, 1)
                let time = clock.uptime
                runtime.hideWhileAudioPlays = false
                XCTAssertTrue(work.isCancelled)
                XCTAssertEqual(clock.pendingCount, 0)
                try await waitUntil { runtime.activityStatus == "Active" }
                XCTAssertEqual(clock.uptime, time)
                XCTAssertEqual(clock.scheduledCount, hidden ? 2 : 1)
            }
        }
    }

    @MainActor func testLosingAlwaysAccessCancelsAudioFollowUp() async throws {
        try await withTrackingActivity { _ in
            let runtime = WhereWolfBackgroundRuntime.shared
            let saved = runtime.audioDependencies
            defer { runtime.hideWhileAudioPlays = false; runtime.audioDependencies = saved }
            for hidden in [false, true] {
                let clock = AudioClock()
                clock.playing = true
                runtime.audioDependencies = clock.dependencies
                runtime.hideWhileAudioPlays = true
                if hidden {
                    try clock.fireNext()
                    try await waitUntil { runtime.activityStatus == "Hidden while other audio plays" }
                    clock.playing = false
                    clock.uptime += 15
                    runtime.checkAudioFromLocation()
                }
                let work = try XCTUnwrap(clock.scheduled.last?.work)
                let time = clock.uptime
                clock.authorization = .authorizedWhenInUse
                NotificationCenter.default.post(name: Notification.Name(GLAuthorizationStatusChangedNotification), object: nil)
                try await waitUntil { work.isCancelled && runtime.activityStatus == "Active" }
                XCTAssertEqual(clock.pendingCount, 0)
                XCTAssertEqual(clock.uptime, time)
                XCTAssertEqual(clock.scheduledCount, hidden ? 2 : 1)
                runtime.hideWhileAudioPlays = false
            }
        }
    }

    @MainActor func testStoppingTrackingCancelsAudioFollowUp() async throws {
        try await withTrackingActivity { _ in
            let runtime = WhereWolfBackgroundRuntime.shared
            let saved = runtime.audioDependencies
            let clock = AudioClock()
            clock.playing = true
            runtime.audioDependencies = clock.dependencies
            defer { runtime.hideWhileAudioPlays = false; runtime.audioDependencies = saved }
            runtime.hideWhileAudioPlays = true
            let work = try XCTUnwrap(clock.scheduled.first?.work)
            GLManager.shared().stopAllUpdates()
            try await waitUntil { work.isCancelled && !WhereWolfBackgroundRuntime.hasActiveTrackingActivity }
            XCTAssertEqual(clock.pendingCount, 0)
            XCTAssertFalse(GLManager.shared().trackingEnabled)
        }
    }

    @MainActor func testRepeatedAudioReadingsKeepOneFollowUpAndLateExecutionConfirms() async throws {
        try await withTrackingActivity { _ in
            let runtime = WhereWolfBackgroundRuntime.shared
            let saved = runtime.audioDependencies
            let clock = AudioClock()
            clock.playing = true
            runtime.audioDependencies = clock.dependencies
            defer { runtime.hideWhileAudioPlays = false; runtime.audioDependencies = saved }
            for time in 0..<15 {
                clock.uptime = TimeInterval(time)
                runtime.hideWhileAudioPlays = true
                XCTAssertEqual(clock.pendingCount, 1)
                XCTAssertEqual(clock.scheduledCount, 1)
                XCTAssertEqual(try XCTUnwrap(clock.scheduled.first?.deadline), 15.1, accuracy: 0.001)
            }
            try clock.fireNext(lateBy: 60)
            try await waitUntil { runtime.activityStatus == "Hidden while other audio plays" }
            XCTAssertEqual(clock.pendingCount, 0)
            XCTAssertEqual(clock.scheduledCount, 1)
            clock.playing = false
            clock.uptime += 15
            for _ in 0..<15 { runtime.hideWhileAudioPlays = true }
            XCTAssertEqual(clock.pendingCount, 1)
            XCTAssertEqual(clock.scheduledCount, 2)
            try clock.fireNext()
            try await waitUntil { runtime.activityStatus == "Active" }
            XCTAssertEqual(clock.pendingCount, 0)
            XCTAssertEqual(clock.scheduledCount, 2)
        }
    }

    @MainActor func testResolvedAudioReadingCancelsAndReplacesFollowUp() async throws {
        try await withTrackingActivity { _ in
            let runtime = WhereWolfBackgroundRuntime.shared
            let saved = runtime.audioDependencies
            let clock = AudioClock()
            clock.playing = true
            runtime.audioDependencies = clock.dependencies
            defer { runtime.hideWhileAudioPlays = false; runtime.audioDependencies = saved }
            runtime.hideWhileAudioPlays = true
            let first = try XCTUnwrap(clock.scheduled.first?.work)
            clock.uptime = 5
            clock.playing = false
            runtime.hideWhileAudioPlays = true
            XCTAssertTrue(first.isCancelled)
            XCTAssertEqual(clock.pendingCount, 0)
            clock.uptime = 10
            clock.playing = true
            runtime.hideWhileAudioPlays = true
            XCTAssertEqual(clock.pendingCount, 1)
            XCTAssertEqual(clock.scheduledCount, 2)
            XCTAssertEqual(try XCTUnwrap(clock.scheduled.last?.deadline), 25.1, accuracy: 0.001)
            clock.uptime = 15.1
            first.perform()
            XCTAssertTrue(WhereWolfBackgroundRuntime.hasActiveTrackingActivity)
            XCTAssertEqual(clock.pendingCount, 1)
            try clock.fireNext()
            try await waitUntil { runtime.activityStatus == "Hidden while other audio plays" }
            XCTAssertEqual(clock.pendingCount, 0)
        }
    }

    @MainActor func testReplacingAudioDependenciesClearsPendingAndHiddenState() async throws {
        try await withTrackingActivity { _ in
            let runtime = WhereWolfBackgroundRuntime.shared
            let saved = runtime.audioDependencies
            defer { runtime.hideWhileAudioPlays = false; runtime.audioDependencies = saved }
            for phase in 0..<3 {
                let clock = AudioClock()
                clock.playing = true
                runtime.audioDependencies = clock.dependencies
                runtime.hideWhileAudioPlays = true
                let hiding = try XCTUnwrap(clock.scheduled.first?.work)
                if phase > 0 {
                    try clock.fireNext()
                    try await waitUntil { runtime.activityStatus == "Hidden while other audio plays" }
                }
                if phase == 2 {
                    clock.playing = false
                    clock.uptime += 15
                    runtime.checkAudioFromLocation()
                    XCTAssertEqual(clock.pendingCount, 1)
                }
                let pending = clock.scheduled.last?.work
                runtime.willRestoreAfterAudio(.trip)
                runtime.audioDependencies = saved
                XCTAssertEqual(clock.pendingCount, 0)
                if phase == 0 { XCTAssertTrue(hiding.isCancelled) }
                if phase == 2 { XCTAssertTrue(try XCTUnwrap(pending).isCancelled) }
                for kind in LiveActivityAudioPolicy.Kind.allCases {
                    XCTAssertEqual(runtime.audioAction(for: kind, eligible: true, hasActivity: false), .keep)
                }
                runtime.hideWhileAudioPlays = false
                try await waitUntil { runtime.activityStatus == "Active" }
            }
        }
    }

    @MainActor func testOwnSilentAudioDoesNotHideActivityOrStopWhenHidden() async throws {
        try await withTrackingActivity { _ in
            let runtime = WhereWolfBackgroundRuntime.shared
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
            XCTAssertTrue(WhereWolfBackgroundRuntime.hasActiveTrackingActivity)
            playing = true
            uptime = 30
            runtime.checkAudioFromLocation()
            uptime = 45
            runtime.checkAudioFromLocation()
            try await waitUntil { runtime.activityStatus == "Hidden while other audio plays" }
            XCTAssertEqual(runtime.audioStatus, "Silent audio active")
            runtime.hideWhileAudioPlays = false
            try await waitUntil { WhereWolfBackgroundRuntime.hasActiveTrackingActivity }
            XCTAssertEqual(runtime.audioStatus, "Silent audio active")
        }
    }

    @MainActor func testAudioHidesAndRestoresSeparateTripActivityWithoutEndingTrip() async throws {
        try await withTrackingActivity { _ in
            let runtime = WhereWolfBackgroundRuntime.shared
            let saved = runtime.audioDependencies
            let manager = GLManager.shared()!
            let defaults = UserDefaults.standard
            let start = Date()
            let clock = AudioClock()
            clock.playing = true
            runtime.audioDependencies = clock.dependencies
            defer {
                runtime.hideWhileAudioPlays = false
                runtime.audioDependencies = saved
                defaults.removeObject(forKey: GLTripStartTimeDefaultsName)
                manager.tripLiveActivityEnabled = false
            }
            defaults.set(start, forKey: GLTripStartTimeDefaultsName)
            manager.tripLiveActivityEnabled = true
            try await waitUntil { Activity<TripActivityAttributes>.activities.contains { $0.activityState == .active } }
            runtime.hideWhileAudioPlays = true
            try clock.fireNext()
            try await waitUntil {
                Activity<TripActivityAttributes>.activities.isEmpty && !WhereWolfBackgroundRuntime.hasActiveTrackingActivity
            }
            XCTAssertEqual(manager.currentTripStart(), start)
            XCTAssertTrue(manager.trackingEnabled)
            clock.playing = false
            clock.uptime += 15
            runtime.checkAudioFromLocation()
            try clock.fireNext()
            try await waitUntil {
                Activity<TripActivityAttributes>.activities.contains { $0.activityState == .active }
                    && WhereWolfBackgroundRuntime.hasActiveTrackingActivity
            }
            XCTAssertEqual(manager.currentTripStart(), start)
            defaults.removeObject(forKey: GLTripStartTimeDefaultsName)
            manager.syncTripLiveActivity()
            try await waitUntil { Activity<TripActivityAttributes>.activities.isEmpty }
        }
    }

    @MainActor func testLiveActivityFollowsScheduledReminder() async throws {
        guard ProcessInfo.processInfo.environment["WHEREWOLF_NOTIFICATION_INTEGRATION"] == "1" else {
            throw XCTSkip("Enable WHEREWOLF_NOTIFICATION_INTEGRATION with notifications approved to test the system reminder service.")
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
        let runtime = WhereWolfBackgroundRuntime.shared
        let savedAudioDependencies = runtime.audioDependencies
        manager.stopAllUpdates()
        runtime.audioDependencies = .init()
        defer {
            manager.stopAllUpdates()
            runtime.audioDependencies = savedAudioDependencies
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
        do {
            manager.startAllUpdates()
            runtime.retry()
            try await waitUntil("initial tracking activity") {
                runtime.activityStatus == "Active" && WhereWolfBackgroundRuntime.hasBackgroundLocationActivity
            }
            let activity = try XCTUnwrap(Activity<TrackingActivityAttributes>.activities.first { $0.activityState == .active })
            try await body(activity)
        } catch {
            try? await stopBackgroundHelpers()
            throw error
        }
        try await stopBackgroundHelpers()
    }

    @MainActor private func stopBackgroundHelpers() async throws {
        let runtime = WhereWolfBackgroundRuntime.shared
        GLManager.shared().stopAllUpdates()
        runtime.hideWhileAudioPlays = false
        runtime.silentAudioEnabled = false
        runtime.liveActivityEnabled = false
        runtime.resetAudioPolicy()
        try await waitUntil("background helper cleanup") {
            Activity<TrackingActivityAttributes>.activities.isEmpty
                && Activity<IslandOnlyTrackingAttributes>.activities.isEmpty
                && Activity<TripActivityAttributes>.activities.isEmpty && runtime.audioStatus == "Off"
        }
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

    @MainActor private func waitUntil(_ description: String = "background runtime state",
                                      file: StaticString = #filePath, line: UInt = #line,
                                      _ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        let runtime = WhereWolfBackgroundRuntime.shared
        let manager = GLManager.shared()!
        XCTFail("Timed out waiting for \(description): activity=\(runtime.activityStatus), audio=\(runtime.audioStatus), appState=\(UIApplication.shared.applicationState.rawValue), tracking=\(manager.trackingEnabled), authorization=\(manager.locationManager.authorizationStatus.rawValue), appearance=\(runtime.appearance), hideForAudio=\(runtime.hideWhileAudioPlays), widgetActivities=\(Activity<TrackingActivityAttributes>.activities.count), blankActivities=\(Activity<IslandOnlyTrackingAttributes>.activities.count)", file: file, line: line)
        throw NSError(domain: "BackgroundRuntimeTests", code: 1)
    }

    @MainActor private final class AudioClock {
        var playing = false
        var uptime: TimeInterval = 0
        var authorization = CLAuthorizationStatus.authorizedAlways
        var scheduled: [(deadline: TimeInterval, work: DispatchWorkItem)] = []
        var scheduledCount = 0

        var pendingCount: Int { scheduled.filter { !$0.work.isCancelled }.count }

        var dependencies: WhereWolfBackgroundRuntime.AudioDependencies {
            .init(otherAudioPlaying: { self.playing }, uptime: { self.uptime },
                  authorization: { self.authorization }, schedule: { delay, work in
                self.scheduled.append((self.uptime + delay, work))
                self.scheduledCount += 1
            })
        }

        func fireNext(lateBy delay: TimeInterval = 0) throws {
            scheduled.removeAll { $0.work.isCancelled }
            let next = try XCTUnwrap(scheduled.first)
            scheduled.removeFirst()
            uptime = max(uptime, next.deadline) + delay
            next.work.perform()
        }
    }

    @MainActor private func interrupt(_ type: AVAudioSession.InterruptionType,
                                      options: AVAudioSession.InterruptionOptions = []) {
        NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
                                        object: AVAudioSession.sharedInstance(),
                                        userInfo: [AVAudioSessionInterruptionTypeKey: type.rawValue,
                                                   AVAudioSessionInterruptionOptionKey: options.rawValue])
    }
}
