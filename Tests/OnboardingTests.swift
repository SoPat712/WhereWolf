import XCTest
import CoreLocation
import HealthKit
import UIKit
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
        var healthOpened = 0
        var destinationValid = true
        var onRequest: (@MainActor (OnboardingPermission) async -> Void)?

        init() { defaults = UserDefaults(suiteName: suite)! }
        func clean() { defaults.removePersistentDomain(forName: suite) }
        func model() -> OnboardingModel {
            OnboardingModel(defaults: defaults, actions: OnboardingActions(
                loadStatus: { self.status },
                request: { self.requests.append($0); await self.onRequest?($0); return nil },
                openSettings: { self.settingsOpened += 1 },
                openHealth: { self.healthOpened += 1 },
                applyDestination: { self.destinations.append($0); return self.destinationValid },
                applyPreset: { self.events.append("preset:\($0)"); self.status.usagePreset = $0 },
                startTracking: {
                    XCTAssertTrue(self.defaults.bool(forKey: OnboardingModel.completedKey))
                    self.events.append("start")
                }
            ))
        }
    }

    func testNineStepsKeepFineTuneAfterTrackingWithOrWithoutHealth() async {
        let h = Harness(); defer { h.clean() }
        for health in [false, true] {
            h.status.healthAvailable = health
            let model = h.model(); await model.refresh()
            XCTAssertEqual(model.steps, [.welcome, .permissions, .destination, .tracking, .fineTune, .sending, .liveActivity, .stayingActive, .done])
            for step in model.steps { XCTAssertEqual(model.step, step); model.next() }
            XCTAssertEqual(model.stepNumber, 9)
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
        let model = h.model(); await model.refresh()
        for permission in [OnboardingPermission.whileUsing, .always, .motion, .notifications] {
            XCTAssertTrue(model.opensSettings(for: permission))
            await model.request(permission)
        }
        XCTAssertEqual(h.settingsOpened, 4)
        model.openSettings() // The separate Precise Location button uses this action.
        XCTAssertEqual(h.settingsOpened, 5)
        h.status.location = .always; h.status.preciseLocation = false
        await model.refresh(); await model.request(.always)
        XCTAssertEqual(h.settingsOpened, 6)
        XCTAssertTrue(model.locationSummary.contains("Reduced Accuracy"))
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testOptionalAccessUsesInjectedActions() async {
        let h = Harness(); defer { h.clean() }
        h.status.healthAvailable = true
        let model = h.model(); await model.refresh()
        for permission in [OnboardingPermission.motion, .notifications, .health] {
            await model.request(permission)
        }
        XCTAssertEqual(h.requests, [.motion, .notifications, .health])
        XCTAssertTrue(h.events.isEmpty)
    }

    func testHealthRequestStatusOffersAllowUntilAnswered() async {
        let h = Harness(); defer { h.clean() }
        h.status.healthAvailable = true
        let model = h.model()
        for status in [HKAuthorizationRequestStatus.shouldRequest, .unknown] {
            h.status.health = OnboardingPermissionStatus(healthRequestStatus: status)
            await model.refresh()
            XCTAssertEqual(model.status.permission(.health), .notDetermined)
            XCTAssertEqual(model.healthActionTitle, "Allow")
            XCTAssertFalse(model.opensSettings(for: .health))
            await model.request(.health)
        }
        XCTAssertEqual(h.requests, [.health, .health])
        XCTAssertEqual(h.settingsOpened, 0)
        XCTAssertEqual(h.healthOpened, 0)
    }

    func testAnsweredHealthRequestIsReviewedAndOpensHealthWhenAvailable() async {
        let h = Harness(); defer { h.clean() }
        h.status.healthAvailable = true
        h.status.healthAppAvailable = true
        h.status.health = OnboardingPermissionStatus(healthRequestStatus: .unnecessary)
        let model = h.model(); await model.refresh()
        XCTAssertEqual(model.healthSummary, "Reviewed")
        XCTAssertEqual(model.healthActionTitle, "Manage in Health")
        XCTAssertFalse(model.opensSettings(for: .health))
        await model.request(.health)
        XCTAssertEqual(h.healthOpened, 1)
        XCTAssertEqual(h.settingsOpened, 0)
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testReviewedHealthKeepsStatusWhenHealthCannotOpen() async {
        let h = Harness(); defer { h.clean() }
        h.status.healthAvailable = true
        h.status.health = .reviewed
        let model = h.model(); await model.refresh()
        XCTAssertEqual(model.healthSummary, "Reviewed")
        XCTAssertNil(model.healthActionTitle)
        await model.request(.health)
        XCTAssertEqual(h.healthOpened, 0)
        XCTAssertEqual(h.settingsOpened, 0)
        XCTAssertTrue(h.requests.isEmpty)
    }

    func testHealthNeverOffersSettingsForAnyPermissionStatus() async {
        let h = Harness(); defer { h.clean() }
        h.status.healthAvailable = true
        let model = h.model()
        for status in [OnboardingPermissionStatus.notDetermined, .granted, .denied, .limited, .reviewed, .unavailable] {
            h.status.health = status; await model.refresh()
            XCTAssertFalse(model.opensSettings(for: .health))
            XCTAssertNotEqual(model.healthActionTitle, "Open Settings")
            await model.request(.health)
        }
        XCTAssertEqual(h.settingsOpened, 0)
    }

    func testHealthRequestFinishesAsReviewedWithoutClaimingReadApproval() async {
        let h = Harness(); defer { h.clean() }
        h.status.healthAvailable = true
        h.onRequest = { permission in
            if permission == .health { h.status.health = .reviewed }
        }
        let model = h.model(); await model.refresh()
        await model.request(.health)
        XCTAssertEqual(model.healthSummary, "Reviewed")
        XCTAssertNotEqual(model.status.permission(.health), .granted)
        XCTAssertEqual(h.requests, [.health])
    }

    func testHealthRequestTypesCoverExportAndImport() {
        let share = HealthAuthorizationTypes.share
        let read = HealthAuthorizationTypes.read
        XCTAssertTrue(share.contains(HKObjectType.workoutType()))
        XCTAssertTrue(share.contains(HKSeriesType.workoutRoute()))
        XCTAssertTrue(read.contains(HKObjectType.workoutType()))
        XCTAssertTrue(read.contains(HKSeriesType.workoutRoute()))
        for case let distance? in HealthWorkout.all.map(\.distanceType) {
            XCTAssertTrue(share.contains(HKQuantityType(distance)))
            XCTAssertTrue(read.contains(HKQuantityType(distance)))
        }
    }

    func testLiveSettingsActionUsesInjectedURLOpenerOnMainActor() {
        var opened: [URL] = []
        let model = OnboardingModel.live(openURL: {
            XCTAssertTrue(Thread.isMainThread)
            opened.append($0)
        }, canOpenURL: { _ in false })
        model.openSettings()
        XCTAssertEqual(opened, [URL(string: UIApplication.openSettingsURLString)!])
    }

    func testUnavailablePermissionsDoNotRequest() async {
        let h = Harness(); defer { h.clean() }
        h.status.motion = .unavailable
        let model = h.model(); await model.refresh()
        h.status.health = .reviewed; h.status.healthAppAvailable = true
        await model.refresh()
        XCTAssertEqual(model.status.permission(.health), .unavailable)
        XCTAssertNil(model.healthActionTitle)
        for permission in [OnboardingPermission.motion, .health] { await model.request(permission) }
        XCTAssertTrue(h.requests.isEmpty)
        XCTAssertEqual(h.healthOpened, 0)
    }

    func testPresetAppliesThroughBridgeActionAndEditsRefreshToCustom() async {
        let h = Harness(); defer { h.clean() }
        let model = h.model(); await model.refresh()
        XCTAssertEqual(model.selectedPreset, 6)
        XCTAssertEqual(UsagePreset.values, [5, 1, 4, 6, 3, 2])
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
        h.status.requestedAccuracy = "Navigation"; h.status.minimumDistance = "25 m"; h.status.minimumTime = "30 s"
        await model.refresh()
        XCTAssertEqual(model.summary(for: .fineTune), "Navigation · 25 m · 30 s")
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
        let credentialStore = GLServerCredentials.store
        GLServerCredentials.store = MemorySettingsCredentialStore()
        defer {
            GLServerCredentials.store = credentialStore
            defaults.setPersistentDomain(saved, forName: domain)
            GLManagerBridge.shared.refresh()
        }
        action(GLManagerBridge.shared, GLManager.shared())
    }

    func testEveryFineTuneBindingSwitchesThePresetToCustom() {
        preservingSettings { bridge, manager in
            let bindings = OnboardingTrackingBindings(bridge: bridge)
            let edits: [(OnboardingTrackingBindings) -> Void] = [
                { $0.accuracy.wrappedValue = 2; XCTAssertEqual(manager.desiredAccuracy, kCLLocationAccuracyBestForNavigation) },
                { $0.accuracy.wrappedValue = 0; XCTAssertEqual(manager.desiredAccuracy, 100) },
                { $0.distance.wrappedValue = 25; XCTAssertEqual(manager.discardPointsWithinDistance, 25) },
                { $0.time.wrappedValue = 30; XCTAssertEqual(manager.discardPointsWithinSeconds, 30) },
                { $0.pause.wrappedValue = true; XCTAssertTrue(manager.pausesAutomatically) },
                { $0.visits.wrappedValue = true; XCTAssertTrue(manager.visitTrackingEnabled) }
            ]
            for edit in edits {
                bridge.usageProfile = 6
                XCTAssertEqual(bridge.usageProfile, 6)
                edit(bindings)
                XCTAssertEqual(bridge.usageProfile, 0)
            }
        }
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
