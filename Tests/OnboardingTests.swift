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
        var requestError: String?
        var onRequest: (@MainActor (OnboardingPermission) async -> Void)?

        init() { defaults = UserDefaults(suiteName: suite)! }

        func model() -> OnboardingModel {
            OnboardingModel(defaults: defaults, actions: OnboardingActions(
                loadStatus: { self.status },
                request: {
                    self.requests.append($0)
                    await self.onRequest?($0)
                    return self.requestError
                },
                openSettings: { self.settingsOpened += 1 },
                applyDestination: {
                    self.destinations.append($0)
                    return self.destinationValid
                },
                applyPreset: { self.events.append("preset:\($0)") },
                startTracking: {
                    XCTAssertTrue(self.defaults.bool(forKey: OnboardingModel.completedKey))
                    self.events.append("start")
                }
            ))
        }

        func clean() { defaults.removePersistentDomain(forName: suite) }
    }

    func testStepOrderIncludesHealthWhenAvailable() async {
        let h = Harness(); defer { h.clean() }
        h.status.healthAvailable = true
        let model = h.model()
        await model.refresh()
        XCTAssertEqual(model.steps, [.welcome, .whileUsing, .always, .motion, .notifications,
                                     .destination, .preset, .liveActivity, .health, .goodToKnow, .done])
        for step in model.steps {
            XCTAssertEqual(model.step, step)
            model.next()
        }
        XCTAssertEqual(model.stepNumber, 11)
    }

    func testUnavailableHealthIsSkippedInBothDirections() async {
        let h = Harness(); defer { h.clean() }
        let model = h.model(); await model.refresh()
        XCTAssertEqual(model.steps.count, 10)
        model.go(to: .liveActivity); model.next()
        XCTAssertEqual(model.step, .goodToKnow)
        model.back()
        XCTAssertEqual(model.step, .liveActivity)
        model.go(to: .health)
        XCTAssertEqual(model.step, .liveActivity)
    }

    func testLaunchRefreshAndNavigationNeverRequestOrStart() async {
        let h = Harness(); defer { h.clean() }
        h.status.healthAvailable = true
        let model = h.model()
        XCTAssertTrue(model.isPresented)
        XCTAssertFalse(model.completed)
        await model.refresh()
        for _ in model.steps { model.next(); await model.refresh() }
        model.back(); model.go(to: .motion); model.reopen(); await model.refresh()
        XCTAssertTrue(h.requests.isEmpty)
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertFalse(h.defaults.bool(forKey: OnboardingModel.completedKey))
    }

    func testAlwaysRequestIsGatedOnWhileUsing() async {
        let h = Harness(); defer { h.clean() }
        let model = h.model(); await model.refresh()
        for location in [OnboardingLocationAccess.notDetermined, .denied, .restricted] {
            h.status.location = location
            await model.refresh(); await model.request(.always)
            XCTAssertFalse(model.canRequestAlways)
        }
        XCTAssertTrue(h.requests.isEmpty)
        h.status.location = .whileUsing
        await model.refresh()
        XCTAssertTrue(model.canRequestAlways)
        await model.request(.always)
        XCTAssertEqual(h.requests, [.always])
    }

    func testWhileUsingAndAlwaysAreSeparateExplicitActions() async {
        let h = Harness(); defer { h.clean() }
        let model = h.model(); await model.refresh()
        await model.request(.whileUsing)
        XCTAssertEqual(h.requests, [.whileUsing])
        h.status.location = .whileUsing
        await model.refresh(); model.go(to: .always)
        XCTAssertEqual(h.requests, [.whileUsing])
        await model.request(.always)
        XCTAssertEqual(h.requests, [.whileUsing, .always])
        XCTAssertTrue(h.events.isEmpty)
    }

    func testDeferredAlwaysChoiceOffersSettingsInsteadOfRepeatedRequests() async {
        let h = Harness(); defer { h.clean() }
        h.status.location = .whileUsing
        let model = h.model(); await model.refresh()
        await model.request(.always)
        XCTAssertTrue(model.opensSettings(for: .always))
        await model.request(.always)
        XCTAssertEqual(h.requests, [.always])
        XCTAssertEqual(h.settingsOpened, 1)
    }

    func testReducedAccuracyAlwaysActionOpensSettings() async {
        let h = Harness(); defer { h.clean() }
        h.status.location = .always; h.status.preciseLocation = false
        let model = h.model(); await model.refresh()
        XCTAssertEqual(model.status.permission(.always), .limited)
        XCTAssertTrue(model.summary(for: .always).contains("Reduced Accuracy"))
        await model.request(.always)
        XCTAssertEqual(h.settingsOpened, 1)
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testDeniedAndLimitedPermissionActionsOpenSettings() async {
        let h = Harness(); defer { h.clean() }
        h.status.location = .denied
        h.status.motion = .limited
        h.status.notifications = .denied
        h.status.healthAvailable = true; h.status.healthWrite = .denied
        let model = h.model(); await model.refresh()
        for permission in [OnboardingPermission.whileUsing, .always, .motion, .notifications, .healthWrite] {
            await model.request(permission)
        }
        XCTAssertEqual(h.settingsOpened, 5)
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testOptionalRequestsUseOnlyInjectedActions() async {
        let h = Harness(); defer { h.clean() }
        h.status.healthAvailable = true
        let model = h.model(); await model.refresh()
        for permission in [OnboardingPermission.motion, .notifications, .healthWrite, .healthRead] {
            await model.request(permission)
        }
        XCTAssertEqual(h.requests, [.motion, .notifications, .healthWrite, .healthRead])
        XCTAssertTrue(h.events.isEmpty)
    }

    func testUnavailableOptionalPermissionsNeverRequest() async {
        let h = Harness(); defer { h.clean() }
        h.status.motion = .unavailable
        h.status.healthWrite = .unavailable
        let model = h.model(); await model.refresh()
        for permission in [OnboardingPermission.motion, .healthWrite, .healthRead] { await model.request(permission) }
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testHealthReadReviewNeverClaimsPermissionWasGranted() async {
        let h = Harness(); defer { h.clean() }
        h.status.healthAvailable = true; h.status.healthReadReviewed = true
        let model = h.model(); await model.refresh()
        XCTAssertEqual(model.status.permission(.healthRead), .notDetermined)
        XCTAssertTrue(model.summary(for: .health).contains("Access reviewed"))
    }

    func testRefreshReadsChangedPermissionsWithoutRequestingAgain() async {
        let h = Harness(); defer { h.clean() }
        let model = h.model(); await model.refresh()
        h.status.location = .always; h.status.notifications = .granted
        h.status.motion = .granted; h.status.lowPower = true
        await model.refresh()
        XCTAssertEqual(model.status.permission(.always), .granted)
        XCTAssertEqual(model.status.notifications, .granted)
        XCTAssertTrue(model.summary(for: .goodToKnow).contains("On"))
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testPresetSelectionIsStagedAndRefreshPreservesIt() async {
        let h = Harness(); defer { h.clean() }
        h.status.usagePreset = 3
        let model = h.model(); await model.refresh()
        XCTAssertEqual(model.selectedPreset, 3)
        model.selectedPreset = 4
        await model.refresh()
        XCTAssertEqual(model.selectedPreset, 4)
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertEqual(UsagePreset.values, [1, 2, 3, 4, 5])
    }

    func testNoTrackingStartBeforeDoneEvenWithLocationAccess() async {
        let h = Harness(); defer { h.clean() }
        h.status.location = .always
        let model = h.model(); await model.refresh()
        for step in model.steps where step != .done {
            model.go(to: step)
            model.finish(startTracking: true)
            model.finish(startTracking: false)
        }
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertFalse(model.completed)
    }

    func testFinalStartAppliesPresetThenStartsAndCompletesOnce() async {
        let h = Harness(); defer { h.clean() }
        h.status.location = .whileUsing; h.status.usagePreset = 3
        let model = h.model(); await model.refresh(); model.go(to: .done)
        model.finish(startTracking: true)
        model.finish(startTracking: true)
        XCTAssertEqual(h.events, ["preset:3", "start"])
        XCTAssertTrue(model.completed)
        XCTAssertFalse(model.isPresented)
        XCTAssertTrue(h.model().completed)
    }

    func testFinalStartWithoutLocationCannotCauseAnImplicitPrompt() async {
        let h = Harness(); defer { h.clean() }
        let model = h.model(); await model.refresh(); model.go(to: .done)
        model.finish(startTracking: true)
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertTrue(h.requests.isEmpty)
        XCTAssertFalse(model.completed)
        model.finish(startTracking: false)
        XCTAssertTrue(model.completed)
    }

    func testFinishWithoutTrackingSavesPresetAndCompletionOnly() async {
        let h = Harness(); defer { h.clean() }
        let model = h.model(); await model.refresh()
        model.selectedPreset = 2; model.go(to: .done)
        model.finish(startTracking: false)
        XCTAssertEqual(h.events, ["preset:2"])
        XCTAssertTrue(h.defaults.bool(forKey: OnboardingModel.completedKey))
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testCustomPresetAndActiveTripArePreserved() async {
        let h = Harness(); defer { h.clean() }
        for trip in [false, true] {
            h.status.tripActive = trip
            let model = h.model(); model.reopen(); await model.refresh()
            model.selectedPreset = trip ? 5 : 0
            model.go(to: .done); model.finish(startTracking: false)
        }
        XCTAssertTrue(h.events.isEmpty)
    }

    func testSkipAllSetsFlagWithoutApplyingPresetRequestingOrStarting() async {
        let h = Harness(); defer { h.clean() }
        let model = h.model(); await model.refresh()
        model.selectedPreset = 1; model.skipAll()
        XCTAssertTrue(h.defaults.bool(forKey: OnboardingModel.completedKey))
        XCTAssertFalse(model.isPresented)
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testSetupGuideReopensCompletedGuideAndLoadsCurrentPreset() async {
        let h = Harness(); defer { h.clean() }
        h.defaults.set(true, forKey: OnboardingModel.completedKey)
        let model = h.model()
        XCTAssertFalse(model.isPresented)
        model.reopen(); h.status.usagePreset = 5; await model.refresh()
        XCTAssertTrue(model.isPresented)
        XCTAssertTrue(model.completed)
        XCTAssertEqual(model.step, .welcome)
        XCTAssertEqual(model.selectedPreset, 5)
        XCTAssertTrue(h.requests.isEmpty)
        XCTAssertTrue(h.events.isEmpty)
    }

    func testSummaryFixReturnsDirectlyToDone() async {
        let h = Harness(); defer { h.clean() }
        let model = h.model(); await model.refresh()
        model.go(to: .done); model.go(to: .destination)
        XCTAssertTrue(model.fixingSummary)
        model.next()
        XCTAssertEqual(model.step, .done)
        XCTAssertFalse(model.fixingSummary)
        XCTAssertFalse(model.completed)
    }

    func testAllDestinationChoicesGoThroughInjectedBridgeAction() async {
        let h = Harness(); defer { h.clean() }
        let model = h.model(); await model.refresh()
        let choices: [OnboardingDestination] = [.setupLink("wherewolf://setup?url=https%3A%2F%2Fwherewolf.test"),
            .server(endpoint: "https://wherewolf.test", token: "test", ownTracks: true), .iCloud, .device]
        for choice in choices { await model.chooseDestination(choice) }
        XCTAssertEqual(h.destinations, choices)
        XCTAssertTrue(h.events.isEmpty)
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testInvalidDestinationStaysOnStepWithError() async {
        let h = Harness(); defer { h.clean() }
        h.destinationValid = false
        let model = h.model(); await model.refresh(); model.go(to: .destination)
        await model.chooseDestination(.setupLink("invalid"))
        XCTAssertNotNil(model.error)
        XCTAssertEqual(model.step, .destination)
        XCTAssertFalse(model.completed)
    }

    func testInFlightPermissionCannotBeSkippedOrRequestedTwice() async throws {
        let h = Harness(); defer { h.clean() }
        var pending: CheckedContinuation<Void, Never>?
        h.onRequest = { _ in
            await withCheckedContinuation { pending = $0 }
        }
        let model = h.model(); await model.refresh()
        let request = Task { await model.request(.motion) }
        for _ in 0..<100 where pending == nil { await Task.yield() }
        let continuation = try XCTUnwrap(pending)
        model.skipAll(); model.next()
        await model.request(.motion)
        XCTAssertTrue(model.busy)
        XCTAssertFalse(model.completed)
        XCTAssertEqual(model.step, .welcome)
        continuation.resume()
        await request.value
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
