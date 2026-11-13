import XCTest
@testable import WhereWolf

final class SettingsReliabilityTests: XCTestCase {
    func testRetryStatusIncludesDeadlineReasonAndEnabledRetryNow() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let status = UploadPresentation(retryDate: now.addingTimeInterval(3600),
                                       failureReason: "There is no internet connection.", queued: 6000,
                                       waitingForWifi: true, now: now)
        XCTAssertTrue(status.waitingToRetry)
        XCTAssertTrue(status.showsStatus)
        XCTAssertTrue(status.canSend)
        XCTAssertEqual(status.buttonTitle, "Retry Now")
        XCTAssertTrue(status.statusText.hasPrefix("Waiting to retry, next attempt at "))
        XCTAssertTrue(status.statusText.contains(status.retryDate!.formatted(date: .abbreviated, time: .shortened)))
        XCTAssertTrue(status.statusText.contains("There is no internet connection."))
    }

    func testSendPresentationShowsDrainProgressAndCloudSaveAction() {
        var status = UploadPresentation(queued: 6000)
        XCTAssertEqual(status.buttonTitle, "Send Now")
        XCTAssertTrue(status.canSend)
        status.savesToCloud = true
        XCTAssertEqual(status.buttonTitle, "Save Now")
        status.sending = true
        status.batchesCompleted = 3
        XCTAssertEqual(status.buttonTitle, "Saving")
        XCTAssertFalse(status.canSend)
        XCTAssertTrue(status.statusText.contains("3 batches saved"))
        XCTAssertTrue(status.statusText.contains("\(6000.formatted()) points left"))
        status.sending = false
        status.blocked = true
        XCTAssertEqual(status.buttonTitle, "Retry Now")
        XCTAssertTrue(status.canSend)
        status.destinationSet = false
        XCTAssertFalse(status.canSend)
        status.destinationSet = true
        status.queued = 0
        XCTAssertFalse(status.canSend)
    }

    func testExpiredRetryDoesNotKeepRetryActionOrHideAnActiveSend() {
        let now = Date()
        var status = UploadPresentation(retryDate: now.addingTimeInterval(-1), queued: 1, now: now)
        XCTAssertFalse(status.waitingToRetry)
        XCTAssertEqual(status.buttonTitle, "Send Now")
        status.retryDate = now.addingTimeInterval(3600)
        status.sending = true
        XCTAssertFalse(status.waitingToRetry)
        XCTAssertEqual(status.buttonTitle, "Sending")
    }

    func testWifiNetworksUseExactSSIDAndUTF8Limit() throws {
        XCTAssertNotNil(WifiObservedNetwork(name: "Home"))
        XCTAssertNotNil(WifiObservedNetwork(name: " Home "))
        XCTAssertNil(WifiObservedNetwork(name: ""))
        XCTAssertNotNil(WifiObservedNetwork(name: String(repeating: "é", count: 16)))
        XCTAssertNil(WifiObservedNetwork(name: String(repeating: "é", count: 17)))
        let network = try XCTUnwrap(WifiObservedNetwork(["name": "Home", "bssid": "ignored", "lastSeen": 100]))
        XCTAssertEqual(network.id, "Home")
    }

    func testWifiPlaceAutoIconUsesWholeWordsWithoutCaseOrDiacritics() {
        let rules = [
            ("HOME", "house.fill"), ("My House", "house.fill"), ("Office", "building.2.fill"), ("Work", "building.2.fill"),
            ("School", "graduationcap.fill"), ("Campus", "graduationcap.fill"), ("University", "graduationcap.fill"), ("College", "graduationcap.fill"),
            ("Gym", "dumbbell.fill"), ("Fitness", "dumbbell.fill"), ("Corner CAFÉ", "cup.and.saucer.fill"), ("Cafe", "cup.and.saucer.fill"), ("Coffee", "cup.and.saucer.fill"),
            ("Shop", "cart.fill"), ("Store", "cart.fill"), ("Market", "cart.fill"), ("Restaurant", "fork.knife"), ("Hotel", "bed.double.fill"),
            ("Mom’s", "heart.fill"), ("Dad", "heart.fill"), ("Family", "heart.fill"), ("Parents", "heart.fill"),
            ("Park", "tree.fill"), ("Airport", "airplane"), ("Library", "books.vertical.fill"), ("Hospital", "cross.case.fill"), ("Clinic", "cross.case.fill"),
            ("Homework", "mappin"), ("Workshop", "mappin"), ("Parking", "mappin"), ("homework cafeine", "mappin"), ("Unknown", "mappin")]
        for (name, symbol) in rules { XCTAssertEqual(WifiPlace.autoSymbol(for: name), symbol, name) }
    }

    func testWifiPlaceValidationRoundTripsManualIconChoice() throws {
        let place = WifiPlace(name: "Home", latitude: 45.5, longitude: -122.6, networks: ["Home"],
                              symbol: "star.fill", color: "orange", record: .nothing, symbolChosen: true)
        let restored = try XCTUnwrap(WifiPlace(place.dictionary))
        XCTAssertEqual(restored, place)
        XCTAssertTrue(restored.symbolChosen)
        XCTAssertEqual(WifiPlace(name: "Office").symbol, "building.2.fill")
        XCTAssertEqual(WifiPlace(name: "Home").color, "blue")
        XCTAssertEqual(WifiPlace(name: "Home").record, .point)
        XCTAssertFalse(WifiPlace(name: "Home").isValid)
    }

    func testWifiPlaceDropsLegacyRadius() throws {
        let place = WifiPlace(name: "Home", latitude: 45.5, longitude: -122.6, networks: ["SSID"])
        var legacy = place.dictionary
        legacy["radius"] = 25
        let restored = try XCTUnwrap(WifiPlace(legacy))
        XCTAssertEqual(restored, place)
        XCTAssertNil(restored.dictionary["radius"])
        XCTAssertTrue(WifiPlace.Recording.nothing.footer.contains(WifiPlace.distanceLabel(GLWifiPlaceMatchDistance)))
    }

    func testWifiPlaceRenamePicksIconUntilUserChoosesOne() throws {
        var place = WifiPlace(name: "Home", latitude: 45.5, longitude: -122.6, networks: ["SSID"])
        place.rename(to: "Work")
        XCTAssertEqual(place.symbol, "building.2.fill")
        place.symbol = "building.2.fill"
        place.symbolChosen = true
        place = try XCTUnwrap(WifiPlace(place.dictionary))
        place.rename(to: "Home")
        XCTAssertEqual(place.symbol, "building.2.fill")
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
