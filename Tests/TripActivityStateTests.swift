import Foundation
import XCTest
@testable import WhereWolf

final class TripActivityStateTests: XCTestCase {
    private let suite = "WhereWolf.TripActivityStateTests.\(UUID().uuidString)"

    override func setUp() {
        super.setUp()
        TripModeStore.setUserDefaults(UserDefaults(suiteName: suite)!)
    }

    override func tearDown() {
        TripModeStore.resetUserDefaults()
        UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testOldContentDecodesWithoutTrailFields() throws {
        let json = Data(#"{"mode":"car","distance":1234.5,"speed":12}"#.utf8)
        let state = try JSONDecoder().decode(TripActivityState.self, from: json)
        XCTAssertEqual(state.mode, "car")
        XCTAssertEqual(state.distance, 1234.5)
        XCTAssertEqual(state.speed, 12)
        XCTAssertNil(state.topSpeed)
        XCTAssertNil(state.climb)
        XCTAssertNil(state.averageSpeed)
        XCTAssertNil(state.route)
        XCTAssertNil(state.map)
    }

    func testFullContentRoundTripsWellBelowActivityLimit() throws {
        let points = (0..<48).map { TripRouteSketch.Point(x: UInt8($0 * 5), y: UInt8(255 - $0 * 5)) }
        let state = TripActivityState(mode: "car", distance: 123_456.789, speed: 20,
            topSpeed: 30, climb: 150, averageSpeed: 15, route: .init(points: points),
            map: .init(token: UUID().uuidString, routeInMapFrame: .init(points: points),
                       lockScreenRouteInMapFrame: .init(points: points)))
        let data = try JSONEncoder().encode(state)
        XCTAssertLessThan(data.count, 2_200)
        XCTAssertEqual(try JSONDecoder().decode(TripActivityState.self, from: data), state)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let route = try XCTUnwrap(json["route"] as? [String: Any])
        let encodedPoints = try XCTUnwrap(route["points"] as? [[Int]])
        XCTAssertEqual(encodedPoints.last, [235, 20])
    }

    func testOldTrailContentDecodesWithoutMap() throws {
        let json = Data(#"{"mode":"walk","distance":12,"speed":1,"route":{"points":[[0,255],[255,0]]}}"#.utf8)
        let state = try JSONDecoder().decode(TripActivityState.self, from: json)
        XCTAssertEqual(state.route?.points.count, 2)
        XCTAssertNil(state.map)
    }

    func testTrailAverageUsesPaceForFootModesAndSpeedForCar() {
        var state = TripActivityState(mode: "walk", distance: 5_000, speed: 0,
                                      averageSpeed: 5_000.0 / 1_500)
        XCTAssertEqual(TripActivityFormat.details(state, metric: true), ["avg 5:00 /km"])
        state.mode = "run"
        XCTAssertEqual(TripActivityFormat.details(state, metric: false), ["avg 8:03 /mi"])
        state.mode = "car"
        XCTAssertEqual(TripActivityFormat.details(state, metric: true), ["avg 12 km/h"])
    }

    func testUnknownTopSpeedIsOmittedAndPaceTopIncludesSpeedUnit() {
        var state = TripActivityState(mode: "car", distance: 1_000, speed: 0,
                                      topSpeed: -1, averageSpeed: 10)
        XCTAssertEqual(TripActivityFormat.details(state, metric: false), ["avg 22 mph"])
        state.topSpeed = 20
        XCTAssertEqual(TripActivityFormat.details(state, metric: false), ["avg 22 mph", "top 45 mph"])
        state.mode = "walk"
        state.averageSpeed = 1
        XCTAssertEqual(TripActivityFormat.details(state, metric: true), ["avg 16:40 /km", "top 72 km/h"])
        state.climb = 36.6
        XCTAssertEqual(TripActivityFormat.details(state, metric: false), ["avg 26:49 /mi", "top 45 mph", "climb 120 ft"])
    }

    func testShortTripHasUnknownAveragePace() {
        let state = TripActivityState(mode: "walk", distance: 0, speed: 0)
        XCTAssertEqual(TripActivityFormat.details(state, metric: true), ["avg – /km"])
        let tinySpeed = TripActivityState(mode: "walk", distance: 1_000, speed: 0,
                                         averageSpeed: .leastNonzeroMagnitude)
        XCTAssertEqual(TripActivityFormat.details(tinySpeed, metric: true), ["avg – /km"])
    }

    func testTripStatsRouteResetsAndOrderedReplayMatchesLiveAppend() {
        let stats = TripStatsAccumulator()
        func add(_ latitude: Double, _ longitude: Double) {
            stats.add(speed: 2, speedAccuracy: 1, altitude: 10, verticalAccuracy: 1,
                      latitude: latitude, longitude: longitude)
        }
        add(45, -122)
        add(45.001, -121.999)
        add(45.002, -122)
        let live = stats.routeSketch()
        stats.reset()
        XCTAssertTrue(stats.routeSketch().points.isEmpty)
        XCTAssertEqual(stats.topSpeed, -1)
        XCTAssertEqual(stats.climb, 0)
        add(45, -122)
        add(45.001, -121.999)
        add(45.002, -122)
        XCTAssertEqual(stats.routeSketch(), live)
    }
}
