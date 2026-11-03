import CoreLocation
import XCTest
@testable import WhereWolf

final class TripEndPromptTests: XCTestCase {
    private let origin = Date(timeIntervalSince1970: 1_000_000)

    private func fix(_ meters: Double, at seconds: TimeInterval, accuracy: Double = 10) -> CLLocation {
        CLLocation(coordinate: CLLocationCoordinate2D(latitude: 45 + meters / 111_195, longitude: -122), altitude: 0,
                   horizontalAccuracy: accuracy, verticalAccuracy: -1, timestamp: origin.addingTimeInterval(seconds))
    }

    private func stopTime(_ result: StopDetector.Result) -> TimeInterval? {
        guard case .stopped(let location) = result else { return nil }
        return location.timestamp.timeIntervalSince(origin)
    }

    func testStopNeedsFiveMinutesInPlaceWithStationaryMotion() {
        var detector = StopDetector()
        func update(_ meters: Double, at seconds: TimeInterval, stationary: Bool = true) -> StopDetector.Result {
            detector.update(location: fix(meters, at: seconds), now: origin.addingTimeInterval(seconds),
                            hasMotion: true, stationary: stationary, inVehicle: false)
        }
        XCTAssertEqual(update(0, at: 0, stationary: false), .none)
        XCTAssertEqual(update(40, at: 120, stationary: false), .none)
        XCTAssertEqual(update(60, at: 299), .none)
        XCTAssertEqual(stopTime(update(70, at: 300)), 0)
        XCTAssertEqual(update(70, at: 400), .none, "One prompt per stop")
        XCTAssertEqual(update(500, at: 500), .movedOn)
        XCTAssertNil(stopTime(update(510, at: 700)))
        XCTAssertEqual(stopTime(update(520, at: 800)), 500)
    }

    func testTrafficAndMissingStationaryReadingsAreNotStops() {
        var detector = StopDetector()
        _ = detector.update(location: fix(0, at: 0), now: origin, hasMotion: true, stationary: true, inVehicle: true)
        XCTAssertEqual(detector.update(location: fix(10, at: 600), now: origin.addingTimeInterval(600),
                                       hasMotion: true, stationary: true, inVehicle: true), .none)
        detector.reset()
        _ = detector.update(location: fix(0, at: 0), now: origin, hasMotion: true, stationary: false, inVehicle: false)
        XCTAssertEqual(detector.update(location: fix(10, at: 600), now: origin.addingTimeInterval(600),
                                       hasMotion: true, stationary: false, inVehicle: false), .none)
    }

    func testWithoutMotionTheStopWaitsTenMinutesAndIgnoresCoarseFixes() {
        var detector = StopDetector()
        _ = detector.update(location: fix(0, at: 0), now: origin, hasMotion: false, stationary: false, inVehicle: false)
        XCTAssertEqual(detector.update(location: fix(900, at: 300, accuracy: 500), now: origin.addingTimeInterval(300),
                                       hasMotion: false, stationary: false, inVehicle: false), .none)
        XCTAssertEqual(detector.update(location: fix(20, at: 599), now: origin.addingTimeInterval(599),
                                       hasMotion: false, stationary: false, inVehicle: false), .none)
        XCTAssertEqual(stopTime(detector.update(location: nil, now: origin.addingTimeInterval(600), hasMotion: false,
                                                stationary: false, inVehicle: false)), nil)
        XCTAssertEqual(stopTime(detector.update(location: fix(20, at: 600), now: origin.addingTimeInterval(600),
                                                hasMotion: false, stationary: false, inVehicle: false)), 0)
    }

    func testPromptCarriesTheTripAndStop() {
        let info = TripEndPrompt.userInfo(tripStart: origin, stoppedAt: fix(100, at: 900, accuracy: 12))
        XCTAssertEqual(info[GLEndTripPromptTripStartKey], origin.timeIntervalSince1970)
        XCTAssertEqual(info[GLEndTripPromptStoppedAtKey], origin.timeIntervalSince1970 + 900)
        XCTAssertEqual(info[GLEndTripPromptLatitudeKey] ?? 0, 45 + 100 / 111_195, accuracy: 0.0000001)
        XCTAssertEqual(info[GLEndTripPromptAccuracyKey], 12)
    }
}
