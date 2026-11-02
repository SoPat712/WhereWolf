import XCTest
@testable import Where

final class SettingsReliabilityTests: XCTestCase {
    func testWifiSelectionTreatsBSSIDSpellingsAsOneNetwork() throws {
        let first = try XCTUnwrap(WifiZoneNetwork(name: "Home", bssid: "A:B:C:D:E:F"))
        let second = try XCTUnwrap(WifiZoneNetwork(name: "Home", bssid: "0a:0b:0c:0d:0e:0f"))
        XCTAssertEqual(Set([first, second]).count, 1)
        XCTAssertEqual(first.dictionary["bssid"], "0a:0b:0c:0d:0e:0f")
    }

    func testWifiSelectionDistinguishesAccessPointsAndExactNetworkNames() throws {
        let names = try [
            XCTUnwrap(WifiZoneNetwork(name: "Home")),
            XCTUnwrap(WifiZoneNetwork(name: "Home", bssid: "aa:bb:cc:dd:ee:01")),
            XCTUnwrap(WifiZoneNetwork(name: "Home", bssid: "aa:bb:cc:dd:ee:02")),
            XCTUnwrap(WifiZoneNetwork(name: " Home "))
        ]
        XCTAssertEqual(Set(names).count, 4)
        XCTAssertEqual(names.last?.dictionary["name"], " Home ")
    }

    func testWifiSelectionRejectsInvalidIdentifiers() {
        XCTAssertNil(WifiZoneNetwork(name: ""))
        XCTAssertNil(WifiZoneNetwork(name: String(repeating: "é", count: 17)))
        XCTAssertNil(WifiZoneNetwork(name: "Home", bssid: "not-an-address"))
        XCTAssertNil(WifiZoneNetwork(name: "Wi-Fi", bssid: "00:00:00:00:00:00"))
        XCTAssertNil(WifiZoneNetwork(name: "WLAN", bssid: "00:00:00:00:00:00"))
        XCTAssertNotNil(WifiZoneNetwork(name: "Home", bssid: "  "))
    }

    func testTimeDetentsIncludeCommonSettingsAndOff() {
        let detents = SliderDetents(range: 0...600, unit: "seconds")
        for value in [0.0, 1, 5, 10, 30, 60, 300, 600] {
            XCTAssertTrue(detents.values.contains(value))
        }
        XCTAssertEqual(detents.values, detents.values.sorted())
    }

    func testCustomValuesSurviveDetentScaleRoundTrip() {
        for (range, unit) in [(0.0...600, "seconds"), (5.0...3000, "meters"), (1.0...1000, "locations")] {
            let detents = SliderDetents(range: range, unit: unit)
            for value in stride(from: range.lowerBound, through: range.upperBound, by: 7) {
                XCTAssertEqual(detents.value(at: detents.position(for: value)), value)
            }
        }
    }

    func testSnapHysteresisHoldsUntilLeavingDetent() {
        let detents = SliderDetents(range: 0...600, unit: "seconds")
        XCTAssertEqual(detents.snap(3.15, held: nil), 3)
        XCTAssertEqual(detents.snap(3.25, held: 3), 3)
        XCTAssertNil(detents.snap(3.3, held: 3))
        XCTAssertNil(detents.snap(3.25, held: nil))
    }

    func testDetentsKeepRangeEndpointsAndAccessibleSteps() {
        let detents = SliderDetents(range: 30...3600, unit: "seconds")
        XCTAssertEqual(detents.values.first, 30)
        XCTAssertEqual(detents.values.last, 3600)
        XCTAssertEqual(detents.value(at: -4), 30)
        XCTAssertEqual(detents.value(at: 100), 3600)
        XCTAssertEqual(detents.adjacent(to: 61, increasing: true), 120)
        XCTAssertEqual(detents.adjacent(to: 61, increasing: false), 60)
    }

    func testAudioRecoveryStopsAfterThreeAttempts() {
        var budget = AudioRecoveryBudget()
        XCTAssertEqual(budget.nextDelay(), 2)
        XCTAssertEqual(budget.nextDelay(), 4)
        XCTAssertEqual(budget.nextDelay(), 8)
        XCTAssertNil(budget.nextDelay())
        budget.reset()
        XCTAssertEqual(budget.nextDelay(), 2)
    }

    func testBriefPlaybackDoesNotResetAudioRecoveryLimit() {
        var budget = AudioRecoveryBudget()
        _ = budget.nextDelay()
        budget.started(at: 100)
        budget.checkStable(at: 159)
        XCTAssertEqual(budget.nextDelay(), 4)
        budget.started(at: 200)
        budget.checkStable(at: 260)
        XCTAssertEqual(budget.nextDelay(), 2)
    }
}
