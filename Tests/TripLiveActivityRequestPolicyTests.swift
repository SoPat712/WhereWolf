import Foundation
import XCTest
@testable import WhereWolf

final class TripLiveActivityRequestPolicyTests: XCTestCase {
    private let tripStart = Date(timeIntervalSince1970: 1_700_000_000)

    func testIntentStartRequestsInBackgroundWithStartAlert() {
        XCTAssertEqual(decision(intent: intentStart()), .requestAndAlert)
    }

    func testPlainBackgroundStartDefers() {
        XCTAssertEqual(decision(), .deferRequest)
    }

    func testDisabledOrUnauthorizedIntentStartDefers() {
        XCTAssertEqual(decision(enabled: false, intent: intentStart()), .deferRequest)
        XCTAssertEqual(decision(authorized: false, intent: intentStart()), .deferRequest)
    }

    func testAudioHideAndWaitOverrideIntentStart() {
        for action in [LiveActivityAudioPolicy.Action.hide, .waitForForeground] {
            for isActive in [false, true] {
                XCTAssertEqual(decision(isActive: isActive, audioAction: action, intent: intentStart()), .deferRequest)
            }
        }
    }

    func testForegroundStartAndAudioRestoreDoNotAlert() {
        XCTAssertEqual(decision(isActive: true), .request)
        XCTAssertEqual(decision(isActive: true, intent: intentStart()), .request)
        XCTAssertEqual(decision(requestPending: false, audioAction: .restore), .request)
    }

    func testIntentAllowanceExpiresAfterTwoSeconds() {
        let intent = intentStart()
        XCTAssertEqual(intent.deadline, 102)
        XCTAssertEqual(decision(intent: intent, now: 101.999), .requestAndAlert)
        XCTAssertEqual(decision(intent: intent, now: 102), .deferRequest)
        XCTAssertEqual(decision(intent: intent, now: 103), .deferRequest)
        XCTAssertEqual(decision(isActive: true, intent: intent, now: 103), .request)
    }

    func testIntentAllowanceCannotStartAnotherTrip() {
        let intent = TripLiveActivityRequestPolicy.IntentStart(tripStart: tripStart.addingTimeInterval(-60), now: 100)
        XCTAssertEqual(decision(intent: intent), .deferRequest)
    }

    func testLaterUpdatesAndBackgroundRefreshesDoNotAlertOrRequest() {
        XCTAssertEqual(decision(requestPending: false, intent: intentStart()), .deferRequest)
        XCTAssertEqual(decision(requestPending: false, isActive: true), .deferRequest)
        XCTAssertEqual(decision(requestPending: true), .deferRequest)
    }

    func testTripRelevanceOutranksZeroTrackingRelevance() {
        XCTAssertGreaterThan(TripLiveActivityRequestPolicy.relevanceScore, 0)
    }

    func testBundledStartAlertSoundContainsOnlySilentPCM() throws {
        let url = try XCTUnwrap(Bundle.main.url(forResource: TripLiveActivityRequestPolicy.silentSoundName, withExtension: nil))
        let data = try Data(contentsOf: url)
        XCTAssertEqual(data.count, 16_044)
        guard data.count == 16_044 else { return }
        XCTAssertEqual(String(decoding: data[0..<4], as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: data[8..<16], as: UTF8.self), "WAVEfmt ")
        // One second of mono signed 16-bit PCM at 8 kHz, matching SilentAudioSession's format.
        XCTAssertEqual(Array(data[20..<36]), [1, 0, 1, 0, 64, 31, 0, 0, 128, 62, 0, 0, 2, 0, 16, 0])
        XCTAssertEqual(String(decoding: data[36..<40], as: UTF8.self), "data")
        XCTAssertTrue(data[44...].allSatisfy { $0 == 0 })
    }

    private func intentStart() -> TripLiveActivityRequestPolicy.IntentStart {
        .init(tripStart: tripStart, now: 100)
    }

    private func decision(enabled: Bool = true, authorized: Bool = true, requestPending: Bool = true,
                          isActive: Bool = false, audioAction: LiveActivityAudioPolicy.Action = .keep,
                          intent: TripLiveActivityRequestPolicy.IntentStart? = nil,
                          now: TimeInterval = 100) -> TripLiveActivityRequestPolicy.Decision {
        TripLiveActivityRequestPolicy.decision(tripStart: tripStart, enabled: enabled, authorized: authorized,
            requestPending: requestPending, isActive: isActive, audioAction: audioAction, intentStart: intent, now: now)
    }
}
