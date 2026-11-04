import CoreLocation
import UserNotifications
import XCTest
@testable import WhereWolf

@MainActor
final class LiveActivityReopenPromptTests: XCTestCase {
    func testConfirmedAudioStopSchedulesOnceAfterRefusedOrDeferredRestore() async throws {
        for kind in LiveActivityAudioPolicy.Kind.allCases {
            for scene in [LiveActivityAudioPolicy.Scene.background, .inactive] {
                let center = ReopenNotificationCenter()
                let prompt = LiveActivityReopenPrompt(center: center)
                defer { prompt.reset() }
                var policy = LiveActivityAudioPolicy()
                policy.sample(enabled: true, otherAudioPlaying: true, authorization: .authorizedAlways, at: 0)
                policy.sample(enabled: true, otherAudioPlaying: true, authorization: .authorizedAlways, at: 15)
                XCTAssertEqual(policy.action(for: kind, eligible: true, hasActivity: true, scene: scene), .hide)
                policy.sample(enabled: true, otherAudioPlaying: false, authorization: .authorizedAlways, at: 30)
                policy.sample(enabled: true, otherAudioPlaying: false, authorization: .authorizedAlways, at: 44.9)
                var state = waitingState(scene: scene)
                state.isHiding = policy.isHiding
                prompt.update(state)
                prompt.schedule()
                XCTAssertTrue(center.additions.isEmpty)
                policy.sample(enabled: true, otherAudioPlaying: false, authorization: .authorizedAlways, at: 45)
                let action = policy.action(for: kind, eligible: true, hasActivity: false, scene: scene)
                XCTAssertEqual(action, scene == .background ? .restore : .waitForForeground)
                if action == .restore { policy.willRequest(kind, scene: scene) }
                state.isHiding = policy.isHiding
                state.hasPendingRestore = policy.hasPendingRestore
                prompt.update(state)
                // A refused request and a deferred request both need the foreground.
                prompt.schedule()
                try await settle { center.additions.count == 1 }
                for _ in 0..<20 {
                    XCTAssertEqual(policy.action(for: kind, eligible: true, hasActivity: false, scene: scene), .waitForForeground)
                    prompt.update(state)
                    prompt.schedule()
                }
                await Task.yield()
                XCTAssertEqual(center.additions.count, 1)
                let request = try XCTUnwrap(center.additions.first)
                XCTAssertEqual(request.identifier, LiveActivityReopenPrompt.notificationID)
                XCTAssertEqual(request.content.title, "Music stopped")
                XCTAssertEqual(request.content.body, "Open WhereWolf to bring back its Live Activity.")
                XCTAssertTrue(request.content.categoryIdentifier.isEmpty)
                XCTAssertNil(request.content.sound)
                XCTAssertEqual(request.content.interruptionLevel, .passive)
                let trigger = try XCTUnwrap(request.trigger as? UNTimeIntervalNotificationTrigger)
                XCTAssertEqual(trigger.timeInterval, 300)
                XCTAssertFalse(trigger.repeats)
            }
        }
    }

    func testFixedIdentifierReplacesExistingRequestAndPreservesReminder() async throws {
        let center = ReopenNotificationCenter()
        let prompt = LiveActivityReopenPrompt(center: center)
        defer { prompt.reset() }
        let reminder = UNNotificationRequest(identifier: "reminder", content: UNMutableNotificationContent(),
            trigger: UNTimeIntervalNotificationTrigger(timeInterval: 600, repeats: false))
        center.pending["reminder"] = reminder
        center.pending[LiveActivityReopenPrompt.notificationID] = UNNotificationRequest(
            identifier: LiveActivityReopenPrompt.notificationID, content: UNMutableNotificationContent(), trigger: nil)
        prompt.update(waitingState())
        prompt.schedule()
        try await settle { center.additions.count == 1 }
        XCTAssertEqual(center.pending.count, 2)
        XCTAssertTrue(center.pending["reminder"] === reminder)
        var playing = waitingState()
        playing.otherAudioPlaying = true
        center.delivered.insert(LiveActivityReopenPrompt.notificationID)
        prompt.update(playing)
        XCTAssertFalse(center.delivered.contains(LiveActivityReopenPrompt.notificationID))
        prompt.update(waitingState())
        prompt.schedule()
        try await settle { center.additions.count == 2 }
        XCTAssertEqual(Set(center.additions.map(\.identifier)), [LiveActivityReopenPrompt.notificationID])
        XCTAssertEqual(center.pending.count, 2)
        XCTAssertTrue(center.pending["reminder"] === reminder)
        XCTAssertFalse(center.pendingRemovals.contains("reminder"))
        XCTAssertFalse(center.deliveredRemovals.contains("reminder"))
    }

    func testTrackingAndTripRestoresShareOnePrompt() async throws {
        let center = ReopenNotificationCenter()
        let prompt = LiveActivityReopenPrompt(center: center)
        defer { prompt.reset() }
        var policy = LiveActivityAudioPolicy()
        policy.sample(enabled: true, otherAudioPlaying: true, authorization: .authorizedAlways, at: 0)
        policy.sample(enabled: true, otherAudioPlaying: true, authorization: .authorizedAlways, at: 15)
        for kind in [LiveActivityAudioPolicy.Kind.minimal, .trip] {
            XCTAssertEqual(policy.action(for: kind, eligible: true, hasActivity: true, scene: .background), .hide)
        }
        policy.sample(enabled: true, otherAudioPlaying: false, authorization: .authorizedAlways, at: 30)
        policy.sample(enabled: true, otherAudioPlaying: false, authorization: .authorizedAlways, at: 45)
        prompt.update(waitingState())
        for kind in [LiveActivityAudioPolicy.Kind.blank, .trip] {
            XCTAssertEqual(policy.action(for: kind, eligible: true, hasActivity: false, scene: .background), .restore)
            policy.willRequest(kind, scene: .background)
            prompt.schedule()
        }
        try await settle { center.additions.count == 1 }
        for kind in LiveActivityAudioPolicy.Kind.allCases {
            XCTAssertEqual(policy.action(for: kind, eligible: true, hasActivity: false, scene: .background), .waitForForeground)
            prompt.schedule()
        }
        await Task.yield()
        XCTAssertEqual(center.additions.count, 1)
    }

    func testEveryIneligibleStateWithdrawsPendingAndDeliveredPrompt() async throws {
        let changes: [(String, (inout LiveActivityReopenPrompt.State) -> Void)] = [
            ("other audio detected", { $0.otherAudioPlaying = true }),
            ("hidden again", { $0.isHiding = true }),
            ("foreground", { $0.scene = .foreground }),
            ("Hide While Audio Plays off", { $0.hideWhileAudioPlays = false }),
            ("Ask to Reopen off", { $0.askToReopen = false }),
            ("Always access lost", { $0.authorization = .authorizedWhenInUse }),
            ("tracking stopped", { $0.trackingEligible = false }),
            ("nothing to restore", { $0.hasPendingRestore = false })
        ]
        for (name, change) in changes {
            let center = ReopenNotificationCenter()
            let prompt = LiveActivityReopenPrompt(center: center)
            defer { prompt.reset() }
            var state = waitingState()
            prompt.update(state)
            prompt.schedule()
            try await settle { center.additions.count == 1 }
            center.delivered.insert(LiveActivityReopenPrompt.notificationID)
            change(&state)
            prompt.update(state)
            prompt.schedule()
            await Task.yield()
            XCTAssertNil(center.pending[LiveActivityReopenPrompt.notificationID], name)
            XCTAssertFalse(center.delivered.contains(LiveActivityReopenPrompt.notificationID), name)
            XCTAssertEqual(center.additions.count, 1, name)
        }
    }

    func testNoPostingWithoutNotificationAuthorization() async throws {
        for status in [UNAuthorizationStatus.notDetermined, .denied] {
            let center = ReopenNotificationCenter()
            center.status = status
            let prompt = LiveActivityReopenPrompt(center: center)
            defer { prompt.reset() }
            prompt.update(waitingState())
            prompt.schedule()
            try await settle { center.authorizationReads == 1 }
            await Task.yield()
            XCTAssertTrue(center.additions.isEmpty)
            prompt.schedule()
            XCTAssertEqual(center.authorizationReads, 1)
        }
    }

    func testExistingProvisionalOrEphemeralAuthorizationCanPost() async throws {
        for status in [UNAuthorizationStatus.provisional, .ephemeral] {
            let center = ReopenNotificationCenter()
            center.status = status
            let prompt = LiveActivityReopenPrompt(center: center)
            defer { prompt.reset() }
            prompt.update(waitingState())
            prompt.schedule()
            try await settle { center.additions.count == 1 }
        }
    }

    func testToggleOffNeverChecksAuthorizationOrPosts() async {
        let center = ReopenNotificationCenter()
        let prompt = LiveActivityReopenPrompt(center: center)
        defer { prompt.reset() }
        var state = waitingState()
        state.askToReopen = false
        prompt.update(state)
        for _ in 0..<10 { prompt.schedule() }
        await Task.yield()
        XCTAssertEqual(center.authorizationReads, 0)
        XCTAssertTrue(center.additions.isEmpty)
    }

    func testWithdrawalDuringAuthorizationLookupPreventsPosting() async throws {
        let center = ReopenNotificationCenter()
        center.holdAuthorization = true
        let prompt = LiveActivityReopenPrompt(center: center)
        defer { prompt.reset(); center.finishAuthorization() }
        prompt.update(waitingState())
        prompt.schedule()
        try await settle { center.authorizationGate != nil }
        prompt.dismiss()
        center.finishAuthorization()
        await Task.yield()
        await Task.yield()
        XCTAssertTrue(center.additions.isEmpty)
    }

    func testWithdrawalDuringAddRemovesLateRequest() async throws {
        let center = ReopenNotificationCenter()
        center.holdAdd = true
        let prompt = LiveActivityReopenPrompt(center: center)
        defer { prompt.reset(); center.finishAdd() }
        prompt.update(waitingState())
        prompt.schedule()
        try await settle { center.addGate != nil }
        center.delivered.insert(LiveActivityReopenPrompt.notificationID)
        prompt.dismiss()
        center.finishAdd()
        try await settle { center.additions.count == 1 && center.pending.isEmpty }
        XCTAssertTrue(center.delivered.isEmpty)
        prompt.schedule()
        XCTAssertEqual(center.additions.count, 1, "Retry or restore must not rearm the same prompt")
    }

    func testNewAudioEpisodeWaitsForOldAddBeforeReplacingIt() async throws {
        let center = ReopenNotificationCenter()
        center.holdAdd = true
        let prompt = LiveActivityReopenPrompt(center: center)
        defer { prompt.reset(); center.finishAdd() }
        prompt.update(waitingState())
        prompt.schedule()
        try await settle { center.addGate != nil }
        var playing = waitingState()
        playing.otherAudioPlaying = true
        prompt.update(playing)
        prompt.update(waitingState())
        prompt.schedule()
        center.holdAdd = false
        center.finishAdd()
        try await settle { center.additions.count == 2 }
        XCTAssertEqual(center.pending.count, 1)
        XCTAssertTrue(center.pending[LiveActivityReopenPrompt.notificationID] === center.additions.last)
    }

    private func waitingState(scene: LiveActivityAudioPolicy.Scene = .background) -> LiveActivityReopenPrompt.State {
        .init(hideWhileAudioPlays: true, askToReopen: true, authorization: .authorizedAlways,
              trackingEligible: true, hasPendingRestore: true, scene: scene)
    }

    private func settle(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTFail("Timed out waiting for the injected notification center")
        throw NSError(domain: "LiveActivityReopenPromptTests", code: 1)
    }
}

@MainActor
final class ReopenNotificationCenter: LiveActivityReopenNotificationCenter {
    var status = UNAuthorizationStatus.authorized
    var authorizationReads = 0
    var additions: [UNNotificationRequest] = []
    var pending: [String: UNNotificationRequest] = [:]
    var delivered: Set<String> = []
    var pendingRemovals: [String] = []
    var deliveredRemovals: [String] = []
    var holdAuthorization = false
    var holdAdd = false
    var authorizationGate: CheckedContinuation<UNAuthorizationStatus, Never>?
    var addGate: CheckedContinuation<Void, Never>?

    func authorizationStatus() async -> UNAuthorizationStatus {
        authorizationReads += 1
        if holdAuthorization {
            return await withCheckedContinuation { authorizationGate = $0 }
        }
        return status
    }

    func add(_ request: UNNotificationRequest) async throws {
        if holdAdd { await withCheckedContinuation { addGate = $0 } }
        additions.append(request)
        pending[request.identifier] = request
    }

    func removePendingNotificationRequests(withIdentifiers identifiers: [String]) {
        pendingRemovals += identifiers
        for id in identifiers { pending.removeValue(forKey: id) }
    }

    func removeDeliveredNotifications(withIdentifiers identifiers: [String]) {
        deliveredRemovals += identifiers
        delivered.subtract(identifiers)
    }

    func finishAuthorization() {
        let gate = authorizationGate
        authorizationGate = nil
        holdAuthorization = false
        gate?.resume(returning: status)
    }

    func finishAdd() {
        let gate = addGate
        addGate = nil
        gate?.resume()
    }
}
