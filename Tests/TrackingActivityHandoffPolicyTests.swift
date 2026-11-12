import XCTest
@testable import WhereWolf

final class TrackingActivityHandoffPolicyTests: XCTestCase {
    private let tripStart = Date(timeIntervalSince1970: 1_700_000_000)

    func testActiveAndStaleTripsReplaceTrackingAndSupportBackgroundLocation() {
        for state in [TrackingActivityHandoffPolicy.TripActivity.active, .stale] {
            XCTAssertTrue(state.supportsBackgroundLocation)
            for hasTracking in [false, true] {
                XCTAssertEqual(decision(trip: state, hasTracking: hasTracking), .stepAside)
            }
        }
    }

    func testFailedOrRefusedTripRequestKeepsExistingTrackingActivity() {
        XCTAssertEqual(decision(trip: .absent, hasTracking: true), .keep)
        XCTAssertFalse(TrackingActivityHandoffPolicy.TripActivity.absent.supportsBackgroundLocation)
    }

    func testAudioHiddenTripReservesRestorationForTripOnly() {
        for action in [LiveActivityAudioPolicy.Action.hide, .restore, .waitForForeground, .keep] {
            XCTAssertEqual(decision(trip: .audioHidden, foreground: true, audio: action), .stepAside)
        }
        XCTAssertFalse(TrackingActivityHandoffPolicy.TripActivity.audioHidden.supportsBackgroundLocation)
    }

    func testEndedTripRestoresTrackingInForeground() {
        XCTAssertEqual(decision(trip: .absent, foreground: true), .request)
        XCTAssertEqual(decision(trip: .active, ending: true, foreground: true), .request)
    }

    func testPlainBackgroundEndWaitsForForeground() {
        XCTAssertEqual(decision(trip: .active, ending: true), .waitForForeground)
        XCTAssertEqual(decision(trip: .absent), .waitForForeground)
    }

    func testIntentEndRequestsTrackingBeforeTripActivityEnds() {
        for state in [TrackingActivityHandoffPolicy.TripActivity.active, .stale, .absent] {
            XCTAssertEqual(decision(trip: state, ending: true, intent: intentEnd()), .request)
        }
    }

    func testIntentEndCannotOverrideAudioRules() {
        XCTAssertEqual(decision(trip: .audioHidden, ending: true, audio: .hide, intent: intentEnd()), .hideForAudio)
        XCTAssertEqual(decision(ending: true, audio: .waitForForeground, intent: intentEnd()), .waitForAudioRestore)
    }

    func testTrackingOffOrIneligibleNeverRequestsEvenFromIntent() {
        for state in [TrackingActivityHandoffPolicy.TripActivity.absent, .active, .stale, .audioHidden] {
            XCTAssertEqual(decision(trip: state, ending: true, eligible: false,
                                    foreground: true, intent: intentEnd()), .ineligible)
        }
    }

    func testIntentEndAllowanceExpiresAndCannotRestoreForAnotherTrip() {
        XCTAssertEqual(decision(ending: true, intent: intentEnd(), now: 101.999), .request)
        XCTAssertEqual(decision(ending: true, intent: intentEnd(), now: 102), .waitForForeground)
        let otherTrip = TripLiveActivityRequestPolicy.IntentAllowance(tripStart: tripStart.addingTimeInterval(60), now: 100)
        XCTAssertEqual(decision(ending: true, intent: otherTrip), .waitForForeground)
        XCTAssertEqual(decision(ending: false, intent: intentEnd()), .waitForForeground)
    }

    func testIntentEndBudgetIncludesSummaryWaitAndActivityRequest() {
        XCTAssertEqual(TripLiveActivityRequestPolicy.intentEndTimeout, 7)
        let intent = TripLiveActivityRequestPolicy.IntentAllowance(tripStart: tripStart, now: 100,
            timeout: TripLiveActivityRequestPolicy.intentEndTimeout)
        XCTAssertEqual(decision(ending: true, intent: intent, now: 105), .request)
        XCTAssertEqual(decision(ending: true, intent: intent, now: 107), .waitForForeground)
    }

    func testAudioRestoreAllowanceStillWorksWithoutATrip() {
        XCTAssertEqual(decision(audio: .restore), .request)
    }

    private func intentEnd() -> TripLiveActivityRequestPolicy.IntentAllowance {
        .init(tripStart: tripStart, now: 100)
    }

    private func decision(trip: TrackingActivityHandoffPolicy.TripActivity = .absent,
                          ending: Bool = false, eligible: Bool = true, hasTracking: Bool = false,
                          foreground: Bool = false, audio: LiveActivityAudioPolicy.Action = .keep,
                          intent: TripLiveActivityRequestPolicy.IntentAllowance? = nil,
                          now: TimeInterval = 100) -> TrackingActivityHandoffPolicy.Decision {
        TrackingActivityHandoffPolicy.decision(tripActivity: trip, endingTripActivity: ending,
            trackingEligible: eligible, hasTrackingActivity: hasTracking, isForeground: foreground,
            audioAction: audio, endingTripStart: tripStart, intentEnd: intent, now: now)
    }
}
