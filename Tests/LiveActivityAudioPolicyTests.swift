import CoreLocation
import XCTest
@testable import WhereWolf

final class LiveActivityAudioPolicyTests: XCTestCase {
    func testOtherAudioHidesEveryActivityType() {
        for kind in LiveActivityAudioPolicy.Kind.allCases {
            var policy = playingAudio()
            XCTAssertEqual(request(&policy, for: kind, eligible: true, hasActivity: true, scene: .background), .hide)
        }
    }

    func testSettingOffKeepsEveryActivityType() {
        var policy = LiveActivityAudioPolicy()
        for time in [0.0, 15, 30] {
            policy.sample(enabled: false, otherAudioPlaying: true, authorization: .authorizedAlways, at: time)
        }
        for kind in LiveActivityAudioPolicy.Kind.allCases {
            XCTAssertEqual(request(&policy, for: kind, eligible: true, hasActivity: true, scene: .background), .keep)
        }
    }

    func testOnlyAlwaysAccessCanHideActivities() {
        for authorization in [CLAuthorizationStatus.notDetermined, .restricted, .denied, .authorizedWhenInUse] {
            var policy = LiveActivityAudioPolicy()
            for time in [0.0, 15, 30] {
                policy.sample(enabled: true, otherAudioPlaying: true, authorization: authorization, at: time)
            }
            for kind in LiveActivityAudioPolicy.Kind.allCases {
                XCTAssertEqual(request(&policy, for: kind, eligible: true, hasActivity: true, scene: .background), .keep)
            }
        }
    }

    func testBriefSoundsResetConfirmation() {
        var policy = LiveActivityAudioPolicy()
        for (time, playing) in [(0.0, true), (3, false), (15, true), (29, true), (30, false)] {
            policy.sample(enabled: true, otherAudioPlaying: playing, authorization: .authorizedAlways, at: time)
            XCTAssertFalse(policy.isHiding)
        }
    }

    func testDuplicateEventsCannotConfirmABlip() {
        var policy = LiveActivityAudioPolicy()
        for _ in 0..<10 {
            policy.sample(enabled: true, otherAudioPlaying: true, authorization: .authorizedAlways, at: 0)
        }
        XCTAssertFalse(policy.isHiding)
    }

    func testLocationSamplesWaitFifteenSecondsAfterAnySample() {
        var policy = LiveActivityAudioPolicy()
        XCTAssertTrue(policy.shouldSampleLocation(at: 0))
        policy.sample(enabled: true, otherAudioPlaying: false, authorization: .authorizedAlways, at: 0)
        XCTAssertFalse(policy.shouldSampleLocation(at: 14.9))
        XCTAssertTrue(policy.shouldSampleLocation(at: 15))
    }

    func testBackgroundRestorationTriesOnceThenRestoresOnForeground() {
        for kind in LiveActivityAudioPolicy.Kind.allCases {
            var policy = hiddenActivity(kind)
            stoppedAudio(&policy)
            XCTAssertEqual(request(&policy, for: kind, eligible: true, hasActivity: false, scene: .background), .restore)
            for _ in 0..<100 {
                XCTAssertEqual(request(&policy, for: kind, eligible: true, hasActivity: false, scene: .background), .waitForForeground)
            }
            policy.foregroundOrRetry()
            XCTAssertEqual(request(&policy, for: kind, eligible: true, hasActivity: false, scene: .foreground), .restore)
            policy.restored(kind)
            XCTAssertEqual(request(&policy, for: kind, eligible: true, hasActivity: true, scene: .foreground), .keep)
        }
    }

    func testForegroundRefusalCannotLoop() {
        var policy = hiddenActivity(.status)
        stoppedAudio(&policy)
        XCTAssertEqual(request(&policy, for: .status, eligible: true, hasActivity: false, scene: .foreground), .restore)
        for scene in [LiveActivityAudioPolicy.Scene.foreground, .background, .inactive] {
            for _ in 0..<10 {
                XCTAssertEqual(request(&policy, for: .status, eligible: true, hasActivity: false, scene: scene), .waitForForeground)
            }
        }
    }

    func testPreparingRestoreDoesNotSpendAttemptBeforeRequest() {
        var policy = hiddenActivity(.minimal)
        stoppedAudio(&policy)
        for _ in 0..<2 {
            XCTAssertEqual(policy.action(for: .minimal, eligible: true, hasActivity: false, scene: .background), .restore)
        }
        policy.willRequest(.minimal, scene: .background)
        XCTAssertEqual(policy.action(for: .minimal, eligible: true, hasActivity: false, scene: .background), .waitForForeground)
    }

    func testInactiveSceneWaitsWithoutConsumingBackgroundAttempt() {
        var policy = hiddenActivity(.blank)
        stoppedAudio(&policy)
        XCTAssertEqual(request(&policy, for: .blank, eligible: true, hasActivity: false, scene: .inactive), .waitForForeground)
        XCTAssertEqual(request(&policy, for: .blank, eligible: true, hasActivity: false, scene: .background), .restore)
    }

    func testTrackingAppearanceChangesShareOneRestorationAttempt() {
        var policy = hiddenActivity(.status)
        stoppedAudio(&policy)
        XCTAssertEqual(request(&policy, for: .blank, eligible: true, hasActivity: false, scene: .background), .restore)
        XCTAssertEqual(request(&policy, for: .minimal, eligible: true, hasActivity: false, scene: .background), .waitForForeground)
    }

    func testTrackingAndTripRestoreIndependently() {
        var policy = hiddenActivity(.minimal)
        XCTAssertEqual(request(&policy, for: .trip, eligible: true, hasActivity: true, scene: .background), .hide)
        stoppedAudio(&policy)
        for kind in [LiveActivityAudioPolicy.Kind.minimal, .trip] {
            XCTAssertEqual(request(&policy, for: kind, eligible: true, hasActivity: false, scene: .background), .restore)
            XCTAssertEqual(request(&policy, for: kind, eligible: true, hasActivity: false, scene: .background), .waitForForeground)
        }
    }

    func testStopOrPauseClearsRecoveryWithoutStartingAnything() {
        for kind in LiveActivityAudioPolicy.Kind.allCases {
            var policy = hiddenActivity(kind)
            XCTAssertEqual(request(&policy, for: kind, eligible: false, hasActivity: false, scene: .background), .keep)
            stoppedAudio(&policy)
            policy.foregroundOrRetry()
            XCTAssertEqual(request(&policy, for: kind, eligible: false, hasActivity: false, scene: .foreground), .keep)
        }
    }

    func testDisablingSettingRestoresHiddenActivity() {
        var policy = hiddenActivity(.minimal)
        policy.sample(enabled: false, otherAudioPlaying: true, authorization: .authorizedAlways, at: 16)
        XCTAssertEqual(request(&policy, for: .minimal, eligible: true, hasActivity: false, scene: .foreground), .restore)
    }

    func testLosingAlwaysAccessNeverEndsAnActivity() {
        var policy = hiddenActivity(.minimal)
        policy.sample(enabled: true, otherAudioPlaying: true, authorization: .authorizedWhenInUse, at: 16)
        XCTAssertEqual(request(&policy, for: .minimal, eligible: true, hasActivity: false, scene: .foreground), .restore)
        policy.restored(.minimal)
        XCTAssertEqual(request(&policy, for: .minimal, eligible: true, hasActivity: true, scene: .background), .keep)
    }

    func testRetryGrantsOneMoreAttempt() {
        var policy = hiddenActivity(.trip)
        stoppedAudio(&policy)
        XCTAssertEqual(request(&policy, for: .trip, eligible: true, hasActivity: false, scene: .foreground), .restore)
        policy.foregroundOrRetry()
        XCTAssertEqual(request(&policy, for: .trip, eligible: true, hasActivity: false, scene: .foreground), .restore)
        XCTAssertEqual(request(&policy, for: .trip, eligible: true, hasActivity: false, scene: .foreground), .waitForForeground)
    }

    func testNoAudioLeavesActivitiesVisible() {
        var policy = LiveActivityAudioPolicy()
        for time in [0.0, 15, 30] {
            policy.sample(enabled: true, otherAudioPlaying: false, authorization: .authorizedAlways, at: time)
        }
        XCTAssertEqual(request(&policy, for: .minimal, eligible: true, hasActivity: true, scene: .background), .keep)
    }

    private func request(_ policy: inout LiveActivityAudioPolicy, for kind: LiveActivityAudioPolicy.Kind,
                         eligible: Bool, hasActivity: Bool, scene: LiveActivityAudioPolicy.Scene) -> LiveActivityAudioPolicy.Action {
        let action = policy.action(for: kind, eligible: eligible, hasActivity: hasActivity, scene: scene)
        if action == .restore { policy.willRequest(kind, scene: scene) }
        return action
    }

    private func playingAudio() -> LiveActivityAudioPolicy {
        var policy = LiveActivityAudioPolicy()
        policy.sample(enabled: true, otherAudioPlaying: true, authorization: .authorizedAlways, at: 0)
        policy.sample(enabled: true, otherAudioPlaying: true, authorization: .authorizedAlways, at: 15)
        return policy
    }

    private func hiddenActivity(_ kind: LiveActivityAudioPolicy.Kind) -> LiveActivityAudioPolicy {
        var policy = playingAudio()
        XCTAssertEqual(request(&policy, for: kind, eligible: true, hasActivity: true, scene: .background), .hide)
        return policy
    }

    private func stoppedAudio(_ policy: inout LiveActivityAudioPolicy) {
        policy.sample(enabled: true, otherAudioPlaying: false, authorization: .authorizedAlways, at: 30)
    }
}
