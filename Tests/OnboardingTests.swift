import XCTest
@testable import WhereWolf

@MainActor
final class OnboardingTests: XCTestCase {
    @MainActor private final class Harness {
        let suite = "WhereWolf.OnboardingTests.\(UUID().uuidString)"
        let defaults: UserDefaults
        var status = OnboardingStatus()
        var requests: [OnboardingPermission] = []
        var destinations: [OnboardingDestination] = []
        var events: [String] = []
        var settingsOpened = 0
        var destinationValid = true
        var onRequest: (@MainActor (OnboardingPermission) async -> Void)?

        init() { defaults = UserDefaults(suiteName: suite)! }
        func clean() { defaults.removePersistentDomain(forName: suite) }
        func model() -> OnboardingModel {
            OnboardingModel(defaults: defaults, actions: OnboardingActions(
                loadStatus: { self.status },
                request: { self.requests.append($0); await self.onRequest?($0); return nil },
                openSettings: { self.settingsOpened += 1 },
                applyDestination: { self.destinations.append($0); return self.destinationValid },
                applyPreset: { self.events.append("preset:\($0)"); self.status.usagePreset = $0 },
                startTracking: {
                    XCTAssertTrue(self.defaults.bool(forKey: OnboardingModel.completedKey))
                    self.events.append("start")
                }
            ))
        }
    }

    func testEightStepsStayInMockupOrderWithOrWithoutHealth() async {
        let h = Harness(); defer { h.clean() }
        for health in [false, true] {
            h.status.healthAvailable = health
            let model = h.model(); await model.refresh()
            XCTAssertEqual(model.steps, [.welcome, .permissions, .destination, .tracking, .sending, .liveActivity, .stayingActive, .done])
            for step in model.steps { XCTAssertEqual(model.step, step); model.next() }
            XCTAssertEqual(model.stepNumber, 8)
            model.back(); XCTAssertEqual(model.step, .stayingActive)
        }
    }

    func testNavigationAndRefreshNeverRequestOrStart() async {
        let h = Harness(); defer { h.clean() }
        let model = h.model(); await model.refresh()
        for _ in model.steps { model.next(); await model.refresh() }
        model.back(); model.go(to: .permissions); model.reopen(); await model.refresh()
        XCTAssertTrue(h.requests.isEmpty)
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertFalse(model.completed)
    }

    func testLocationUsesSeparateExplicitWhileUsingAndAlwaysActions() async {
        let h = Harness(); defer { h.clean() }
        let model = h.model(); await model.refresh()
        await model.request(.always)
        XCTAssertTrue(h.requests.isEmpty)
        await model.request(.whileUsing)
        XCTAssertEqual(h.requests, [.whileUsing])
        h.status.location = .whileUsing
        await model.refresh()
        XCTAssertTrue(model.canRequestAlways)
        XCTAssertEqual(h.requests, [.whileUsing])
        await model.request(.always)
        XCTAssertEqual(h.requests, [.whileUsing, .always])
        XCTAssertTrue(model.opensSettings(for: .always))
        await model.request(.always)
        XCTAssertEqual(h.settingsOpened, 1)
        XCTAssertEqual(h.requests.count, 2)
    }

    func testDeniedLimitedAndReducedAccuracyOfferSettings() async {
        let h = Harness(); defer { h.clean() }
        h.status.location = .denied; h.status.motion = .limited; h.status.notifications = .denied
        h.status.healthAvailable = true; h.status.healthWrite = .denied
        let model = h.model(); await model.refresh()
        for permission in [OnboardingPermission.whileUsing, .always, .motion, .notifications, .healthWrite] {
            await model.request(permission)
        }
        XCTAssertEqual(h.settingsOpened, 5)
        h.status.location = .always; h.status.preciseLocation = false
        await model.refresh(); await model.request(.always)
        XCTAssertEqual(h.settingsOpened, 6)
        XCTAssertTrue(model.locationSummary.contains("Reduced Accuracy"))
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testOptionalAccessUsesInjectedActionsAndHealthReadStaysPrivate() async {
        let h = Harness(); defer { h.clean() }
        h.status.healthAvailable = true
        let model = h.model(); await model.refresh()
        for permission in [OnboardingPermission.motion, .notifications, .healthWrite, .healthRead] {
            await model.request(permission)
        }
        XCTAssertEqual(h.requests, [.motion, .notifications, .healthWrite, .healthRead])
        h.status.healthReadReviewed = true
        await model.refresh()
        XCTAssertEqual(model.healthSummary, "Access reviewed")
        XCTAssertEqual(model.status.permission(.healthRead), .notDetermined)
        XCTAssertTrue(h.events.isEmpty)
    }

    func testUnavailablePermissionsDoNotRequest() async {
        let h = Harness(); defer { h.clean() }
        h.status.motion = .unavailable
        let model = h.model(); await model.refresh()
        for permission in [OnboardingPermission.motion, .healthWrite, .healthRead] { await model.request(permission) }
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testPresetAppliesThroughBridgeActionAndEditsRefreshToCustom() async {
        let h = Harness(); defer { h.clean() }
        let model = h.model(); await model.refresh()
        XCTAssertEqual(model.selectedPreset, 6)
        XCTAssertEqual(UsagePreset.values, [6, 1, 3, 2, 4, 5])
        await model.choosePreset(4)
        XCTAssertEqual(h.events, ["preset:4"])
        XCTAssertEqual(model.selectedPreset, 4)
        h.status.usagePreset = 0
        await model.refresh()
        XCTAssertEqual(model.selectedPreset, 0)
        XCTAssertEqual(model.summary(for: .tracking), "Custom")
        model.go(to: .done); model.finish(startTracking: false)
        XCTAssertEqual(h.events, ["preset:4"], "Finishing must not overwrite edited settings")
    }

    func testActiveTripRejectsPresetChanges() async {
        let h = Harness(); defer { h.clean() }
        h.status.tripActive = true; h.status.usagePreset = 0
        let model = h.model(); await model.refresh()
        await model.choosePreset(6)
        XCTAssertEqual(model.selectedPreset, 0)
        XCTAssertTrue(h.events.isEmpty)
    }

    func testOnlyFinalStartStartsAndOnlyOnceAfterCompletionFlag() async {
        let h = Harness(); defer { h.clean() }
        h.status.location = .whileUsing
        let model = h.model(); await model.refresh()
        for step in model.steps where step != .done {
            model.go(to: step); model.finish(startTracking: true); model.finish(startTracking: false)
        }
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertFalse(model.completed)
        model.go(to: .done); model.finish(startTracking: true); model.finish(startTracking: true)
        XCTAssertEqual(h.events, ["start"])
        XCTAssertTrue(model.completed)
        XCTAssertFalse(model.isPresented)
    }

    func testMissingLocationCannotPromptFromFinalStart() async {
        let h = Harness(); defer { h.clean() }
        let model = h.model(); await model.refresh(); model.go(to: .done)
        model.finish(startTracking: true)
        XCTAssertTrue(h.events.isEmpty); XCTAssertTrue(h.requests.isEmpty); XCTAssertFalse(model.completed)
        model.finish(startTracking: false)
        XCTAssertTrue(model.completed)
        XCTAssertTrue(h.events.isEmpty)
    }

    func testSkipAllCompletesWithoutApplyingOrStartingAndCanReopen() async {
        let h = Harness(); defer { h.clean() }
        let model = h.model(); await model.refresh(); model.skipAll()
        XCTAssertTrue(model.completed); XCTAssertFalse(model.isPresented)
        XCTAssertTrue(h.events.isEmpty); XCTAssertTrue(h.requests.isEmpty)
        XCTAssertTrue(h.model().completed)
        h.status.usagePreset = 5
        model.reopen(); await model.refresh()
        XCTAssertTrue(model.isPresented); XCTAssertEqual(model.step, .welcome)
        XCTAssertEqual(model.selectedPreset, 5)
    }

    func testSummaryEditsReturnDirectlyToDoneAndUseLiveStatus() async {
        let h = Harness(); defer { h.clean() }
        h.status.destination = "wherewolf.test"; h.status.sendInterval = "1 min"
        h.status.activeHelpers = 3; h.status.hideForAudio = true
        let model = h.model(); await model.refresh()
        XCTAssertEqual(model.summary(for: .destination), "wherewolf.test · 1 min")
        XCTAssertEqual(model.summary(for: .stayingActive), "3 of 5 on")
        XCTAssertEqual(model.summary(for: .liveActivity), "Blank · hides for music")
        for step in model.steps where step != .done && step != .welcome {
            model.go(to: .done); model.go(to: step)
            XCTAssertTrue(model.fixingSummary); model.next()
            XCTAssertEqual(model.step, .done); XCTAssertFalse(model.fixingSummary)
        }
    }

    func testDestinationsUseInjectedValidationWithoutStarting() async {
        let h = Harness(); defer { h.clean() }
        let model = h.model(); await model.refresh(); model.go(to: .destination)
        let choices: [OnboardingDestination] = [.setupLink("wherewolf://setup?url=https%3A%2F%2Fwherewolf.test"),
            .server(endpoint: "https://wherewolf.test", token: "test", ownTracks: true), .iCloud, .device]
        for choice in choices { await model.chooseDestination(choice) }
        XCTAssertEqual(h.destinations, choices)
        XCTAssertTrue(h.events.isEmpty)
        h.destinationValid = false
        await model.chooseDestination(.setupLink("invalid"))
        XCTAssertNotNil(model.error); XCTAssertEqual(model.step, .destination)
    }

    func testInFlightPermissionCannotBeSkippedOrRequestedTwice() async throws {
        let h = Harness(); defer { h.clean() }
        var pending: CheckedContinuation<Void, Never>?
        h.onRequest = { _ in await withCheckedContinuation { pending = $0 } }
        let model = h.model(); await model.refresh()
        let request = Task { await model.request(.motion) }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let continuation = try XCTUnwrap(pending)
        model.skipAll(); model.next(); await model.request(.motion)
        XCTAssertTrue(model.busy); XCTAssertFalse(model.completed)
        XCTAssertEqual(model.step, .welcome)
        continuation.resume(); await request.value
        XCTAssertEqual(h.requests, [.motion])
    }
}

@MainActor
final class OnboardingDestinationTests: XCTestCase {
    private func preservingSettings(_ action: (GLManagerBridge, GLManager) -> Void) {
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier!
        let saved = defaults.persistentDomain(forName: domain) ?? [:]
        defer { defaults.setPersistentDomain(saved, forName: domain); GLManagerBridge.shared.refresh() }
        action(GLManagerBridge.shared, GLManager.shared())
    }

    func testBridgeSavesManualServerAndFormatWithoutStartingTracking() {
        preservingSettings { bridge, manager in
            let tracking = manager.trackingEnabled
            XCTAssertTrue(bridge.applyOnboardingDestination(.server(endpoint: "https://wherewolf.test/onboarding", token: "test-token", ownTracks: true)))
            XCTAssertEqual(manager.apiEndpointURL(), "https://wherewolf.test/onboarding")
            XCTAssertEqual(manager.apiAccessToken(), "test-token")
            XCTAssertTrue(manager.usesOwntracksFormat())
            XCTAssertFalse(bridge.savesToICloudDrive)
            XCTAssertTrue(bridge.endpointSet)
            XCTAssertEqual(manager.trackingEnabled, tracking)
            XCTAssertTrue(bridge.applyOnboardingDestination(.server(endpoint: "https://wherewolf.test/onboarding", token: "", ownTracks: false)))
            XCTAssertFalse(manager.usesOwntracksFormat())
        }
    }

    func testBothSetupSchemesUseSharedHandlerAndPreserveFields() {
        preservingSettings { bridge, manager in
            for scheme in ["wherewolf", "overland"] {
                let text = "\(scheme)://setup?url=https%3A%2F%2Fwherewolf.test%2Fonboarding&token=secret&device_id=phone&unique_id=yes&header_X-Test=value"
                XCTAssertTrue(WhereWolfSetupURLHandler.apply(URL(string: text)!))
                XCTAssertEqual(manager.apiEndpointURL(), "https://wherewolf.test/onboarding")
                XCTAssertEqual(manager.apiAccessToken(), "secret")
                XCTAssertEqual(manager.deviceId(), "phone")
                XCTAssertTrue(UserDefaults.standard.bool(forKey: GLIncludeUniqueIdDefaultsName))
                XCTAssertEqual(manager.customHTTPHeaders["X-Test"], "value")
                bridge.savesToICloudDrive = true
                XCTAssertTrue(bridge.applyOnboardingDestination(.setupLink(text)))
                XCTAssertFalse(bridge.savesToICloudDrive)
            }
        }
    }

    func testInvalidSetupAndEndpointLeaveDestinationUnchanged() {
        preservingSettings { bridge, manager in
            let original = manager.apiEndpointURL()
            let cloud = bridge.savesToICloudDrive
            for text in ["https://setup?url=https%3A%2F%2Fwherewolf.test", "wherewolf://setup?url=file%3A%2F%2Ftmp", "wherewolf://tracker", "overland://setup?token=secret"] {
                XCTAssertFalse(bridge.applyOnboardingDestination(.setupLink(text)))
                XCTAssertEqual(manager.apiEndpointURL(), original)
                XCTAssertEqual(bridge.savesToICloudDrive, cloud)
            }
            XCTAssertFalse(bridge.applyOnboardingDestination(.server(endpoint: "invalid", token: "", ownTracks: false)))
            XCTAssertEqual(manager.apiEndpointURL(), original)
        }
    }

    func testCloudAndDeviceChoicesUseExistingDestinationSetters() {
        preservingSettings { bridge, manager in
            let tracking = manager.trackingEnabled
            XCTAssertTrue(bridge.applyOnboardingDestination(.server(endpoint: "https://wherewolf.test/onboarding", token: "test", ownTracks: false)))
            XCTAssertTrue(bridge.applyOnboardingDestination(.iCloud))
            XCTAssertTrue(manager.savesToICloudDrive)
            XCTAssertNotNil(manager.apiEndpointURL())
            XCTAssertTrue(bridge.applyOnboardingDestination(.device))
            XCTAssertFalse(manager.savesToICloudDrive)
            XCTAssertTrue((manager.apiEndpointURL() ?? "").isEmpty)
            XCTAssertFalse(bridge.destinationSet)
            XCTAssertEqual(manager.trackingEnabled, tracking)
        }
    }
}
