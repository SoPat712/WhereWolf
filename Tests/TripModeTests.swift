import Foundation
import UIKit
import XCTest
@testable import WhereWolf

final class TripModeTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let suite = "WhereWolf.TripModeTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
        TripModeStore.setUserDefaults(defaults)
    }

    override func tearDown() {
        TripModeStore.resetUserDefaults()
        defaults = nil
        super.tearDown()
    }

    func testCatalogKeepsAllTwentyOneBuiltInIDsIncludingFunicular() throws {
        XCTAssertEqual(TripMode.defaults.count, 21)
        XCTAssertEqual(Set(TripMode.defaults.map(\.id)).count, 21)
        XCTAssertTrue(TripMode.defaults.contains { $0.id == "funicular" })
        for symbol in TripModeStore.customSymbols {
            let image = try XCTUnwrap(TripModeStore.image(symbol: symbol), "Missing bundled icon: \(symbol)")
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1
            let rendered = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32), format: format).image { _ in
                image.withTintColor(.black, renderingMode: .alwaysOriginal)
                    .draw(in: CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            let cgImage = try XCTUnwrap(rendered.cgImage)
            var pixels = [UInt8](repeating: 0, count: 32 * 32 * 4)
            let context = try XCTUnwrap(CGContext(data: &pixels, width: 32, height: 32,
                                                 bitsPerComponent: 8, bytesPerRow: 32 * 4,
                                                 space: CGColorSpaceCreateDeviceRGB(),
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 32, height: 32))
            XCTAssertTrue(stride(from: 3, to: pixels.count, by: 4).contains { pixels[$0] > 0 },
                          "Blank bundled icon: \(symbol)")
        }
    }

    func testMigrationTranslatesOldSymbolsAndAppendsOnlyNewDefaults() throws {
        let saved = [
            TripMode(id: "walk", name: "On Foot", symbol: "figure.walk", closeZoom: false),
            TripMode(id: "kayak", name: "Kayak", symbol: "wherewolf.kayak", closeZoom: true),
        ]
        defaults.set(try JSONEncoder().encode(saved), forKey: TripModeStore.modesKey)
        defaults.set(Array(TripMode.originalIDs), forKey: TripModeStore.builtInIDsKey)

        let modes = TripModeStore.modes
        XCTAssertEqual(modes.first(where: { $0.id == "walk" })?.symbol, "wherewolf.walk")
        XCTAssertTrue(modes.contains { $0.id == "kayak" })
        XCTAssertTrue(modes.contains { $0.id == "hike" })
        XCTAssertTrue(modes.contains { $0.id == "funicular" })
        XCTAssertEqual(modes.filter { $0.id == "walk" }.count, 1)
    }

    func testKnownDeletedBuiltInStaysDeletedUntilRestore() throws {
        let custom = TripMode(id: "kayak", name: "Kayak", symbol: "figure.rower", closeZoom: true)
        XCTAssertTrue(TripModeStore.save([TripMode.defaults[0], custom]))
        XCTAssertFalse(TripModeStore.modes.contains { $0.id == "funicular" })

        XCTAssertTrue(TripModeStore.restoreDefaults())
        let modes = TripModeStore.modes
        XCTAssertEqual(modes.prefix(21).map(\.id), TripMode.defaults.map(\.id))
        XCTAssertEqual(modes.last?.id, "kayak")
    }

    func testNewDefaultIsAppendedWhenSavedMarkerIsOlder() throws {
        let saved = [TripMode.defaults[0]]
        defaults.set(try JSONEncoder().encode(saved), forKey: TripModeStore.modesKey)
        defaults.set(Array(TripMode.originalIDs), forKey: TripModeStore.builtInIDsKey)

        let ids = TripModeStore.allModeIDs
        XCTAssertEqual(ids.first, "walk")
        XCTAssertTrue(ids.contains("hike"))
        XCTAssertTrue(ids.contains("ski"))
        XCTAssertTrue(ids.contains("snowboard"))
        XCTAssertTrue(ids.contains("skate"))
        XCTAssertTrue(ids.contains("funicular"))
    }

    func testServerValueUsesExplicitValueAndReverseLookup() {
        let mode = TripMode(id: "kayak", name: "Kayak", symbol: "figure.rower", closeZoom: true,
                            serverValue: "watercraft")
        XCTAssertTrue(TripModeStore.save([mode]))
        XCTAssertEqual(TripModeStore.serverValue("kayak"), "watercraft")
        XCTAssertEqual(TripModeStore.modeID(serverValue: "watercraft"), "kayak")
        XCTAssertEqual(TripModeStore.modeID(serverValue: "kayak"), "kayak")
    }

    func testDuplicateIDsAndEmptyListsAreRejectedWithoutChangingSavedModes() {
        let mode = TripMode(id: "kayak", name: "Kayak", symbol: "figure.rower", closeZoom: true)
        XCTAssertTrue(TripModeStore.save([mode]))
        let before = TripModeStore.modes

        XCTAssertFalse(TripModeStore.save([mode, mode]))
        XCTAssertFalse(TripModeStore.save([]))
        XCTAssertEqual(TripModeStore.modes, before)
    }

    func testIconPayloadDistinguishesAppOwnedSVGFromSFSymbol() {
        let custom = TripMode(id: "kayak", name: "Kayak", symbol: "wherewolf.kayak", closeZoom: true)
        let apple = TripMode(id: "row", name: "Row", symbol: "figure.rower", closeZoom: true)
        XCTAssertTrue(TripModeStore.save([custom, apple]))

        let customPayload = TripModeStore.iconProperties("kayak")
        XCTAssertNotNil(customPayload["icon"])
        XCTAssertNil(customPayload["sf_symbol"])
        XCTAssertTrue(customPayload["icon"]?.hasPrefix("data:image/svg+xml;base64,") == true)

        let sfPayload = TripModeStore.iconProperties("row")
        XCTAssertEqual(sfPayload["sf_symbol"], "figure.rower")
        XCTAssertNil(sfPayload["icon"])
    }

    func testPreviousAssetPrefixResolvesForSavedAndRemoteModes() {
        for symbol in TripModeStore.customSymbols {
            let previous = "where." + String(symbol.dropFirst("wherewolf.".count))
            XCTAssertEqual(TripModeStore.resolvedSymbol(previous), symbol)
            XCTAssertTrue(TripModeStore.isCustomSymbol(previous))
            XCTAssertNotNil(TripModeStore.image(symbol: previous))
            XCTAssertEqual(TripModeStore.iconDataURI(symbol: previous), TripModeStore.iconDataURI(symbol: symbol))
        }
        let saved = TripMode(id: "kayak", name: "Kayak", symbol: "where.kayak", closeZoom: true)
        XCTAssertTrue(TripModeStore.save([saved]))
        XCTAssertEqual(TripModeStore.symbol("kayak"), "wherewolf.kayak")
        XCTAssertEqual(TripModeStore.iconProperties("kayak")["icon"], TripModeStore.iconDataURI(symbol: "wherewolf.kayak"))
        XCTAssertEqual(TripModeStore.modes.first?.symbol, "where.kayak")

        let unknown = TripMode(id: "custom", name: "Custom", symbol: "where.unknown", closeZoom: true)
        XCTAssertTrue(TripModeStore.save([unknown]))
        XCTAssertFalse(TripModeStore.isCustomSymbol(unknown.symbol))
        XCTAssertEqual(TripModeStore.symbol("custom"), unknown.symbol)
        XCTAssertEqual(TripModeStore.iconProperties("custom"), ["sf_symbol": unknown.symbol])
        XCTAssertNil(TripModeStore.iconDataURI(symbol: unknown.symbol))
    }
}

final class TripFormatTests: XCTestCase {
    func testTripStatsFormatBothUnitSystems() {
        XCTAssertEqual(TripFormat.duration(0), "0:00:00")
        XCTAssertEqual(TripFormat.duration(3_725.9), "1:02:05")
        XCTAssertEqual(TripFormat.duration(-5), "0:00:00")
        XCTAssertEqual(TripFormat.distance(1_234, metric: true), "1.23 km")
        XCTAssertEqual(TripFormat.distance(32_186.88, metric: false), "20.0 mi")
        XCTAssertEqual(TripFormat.averageSpeed(distance: 10_000, duration: 1_800, metric: true), "20.0 km/h")
        XCTAssertEqual(TripFormat.averageSpeed(distance: 1_609.344, duration: 120, metric: false), "30.0 mph")
        XCTAssertEqual(TripFormat.averageSpeed(distance: 50, duration: 0, metric: true), "– km/h")
        XCTAssertEqual(TripFormat.averageSpeed(distance: .nan, duration: 60, metric: false), "– mph")
    }
}

final class TripTabPolicyTests: XCTestCase {
    func testActivationShowsEachTripOnce() {
        var policy = TripTabPolicy()
        let first = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(policy.showsTrip(onActivationWithTripStart: nil, setupPresented: false))
        XCTAssertTrue(policy.showsTrip(onActivationWithTripStart: first, setupPresented: false))
        // Leaving Trip and coming back to the app during the same trip keeps the chosen tab.
        XCTAssertFalse(policy.showsTrip(onActivationWithTripStart: first, setupPresented: false))
        XCTAssertFalse(policy.showsTrip(onActivationWithTripStart: nil, setupPresented: false))
        let second = first.addingTimeInterval(3_600)
        XCTAssertFalse(policy.showsTrip(onActivationWithTripStart: second, setupPresented: true))
        XCTAssertTrue(policy.showsTrip(onActivationWithTripStart: second, setupPresented: false))
        XCTAssertFalse(policy.showsTrip(onActivationWithTripStart: second, setupPresented: false))
    }
}

final class TripStatsAccumulatorTests: XCTestCase {
    func testTopSpeedUsesOnlyTrustedSpeeds() {
        let stats = TripStatsAccumulator()
        XCTAssertEqual(stats.topSpeed, -1)
        stats.add(speed: 12, speedAccuracy: 1, altitude: 0, verticalAccuracy: -1)
        stats.add(speed: 40, speedAccuracy: 9, altitude: 0, verticalAccuracy: -1)
        stats.add(speed: 50, speedAccuracy: -1, altitude: 0, verticalAccuracy: -1)
        stats.add(speed: -1, speedAccuracy: 1, altitude: 0, verticalAccuracy: -1)
        XCTAssertEqual(stats.topSpeed, 12)
        stats.reset()
        XCTAssertEqual(stats.topSpeed, -1)
        XCTAssertEqual(stats.climb, 0)
    }

    func testClimbCountsRisesBeyondAltitudeNoise() {
        let stats = TripStatsAccumulator()
        // Wandering by a few meters is not climbing; a 30 m hill is, and so is a second one after a dip.
        for altitude in [100.0, 102, 99, 103, 98, 101] {
            stats.add(speed: -1, speedAccuracy: -1, altitude: altitude, verticalAccuracy: 4)
        }
        XCTAssertEqual(stats.climb, 0)
        for altitude in [104.0, 110, 118, 128, 125, 115, 120, 126] {
            stats.add(speed: -1, speedAccuracy: -1, altitude: altitude, verticalAccuracy: 4)
        }
        XCTAssertEqual(stats.climb, 30 + 11, accuracy: 0.001)
        stats.add(speed: -1, speedAccuracy: -1, altitude: 400, verticalAccuracy: 30)
        stats.add(speed: -1, speedAccuracy: -1, altitude: 400, verticalAccuracy: -1)
        XCTAssertEqual(stats.climb, 41, accuracy: 0.001)
    }
}

final class TripStatsFormatTests: XCTestCase {
    func testSpeedPaceClimbAndDay() {
        XCTAssertEqual(TripFormat.speed(10, metric: true), "36.0 km/h")
        XCTAssertEqual(TripFormat.speed(10, metric: false), "22.4 mph")
        XCTAssertEqual(TripFormat.speed(-1, metric: false), "– mph")
        XCTAssertEqual(TripFormat.pace(distance: 5_000, duration: 1_500, metric: true), "5:00 /km")
        XCTAssertEqual(TripFormat.pace(distance: 1_609.344, duration: 600, metric: false), "10:00 /mi")
        XCTAssertEqual(TripFormat.pace(distance: 5, duration: 600, metric: true), "– /km")
        XCTAssertEqual(TripFormat.climb(100, metric: true), "100 m")
        XCTAssertEqual(TripFormat.climb(100, metric: false), "328 ft")
        XCTAssertEqual(TripFormat.climb(-1, metric: false), "– ft")
        XCTAssertTrue(TripFormat.usesPace("walk"))
        XCTAssertTrue(TripFormat.usesPace("run"))
        XCTAssertFalse(TripFormat.usesPace("car"))
    }
}

final class TripLogTests: XCTestCase {
    private var saved: UserDefaults!

    override func setUp() {
        super.setUp()
        saved = TripLog.defaults
        TripLog.defaults = UserDefaults(suiteName: "WhereWolf.TripLogTests.\(UUID().uuidString)")!
    }

    override func tearDown() {
        TripLog.defaults = saved
        super.tearDown()
    }

    func testRecordsNewestFirstWithinTheLimit() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        for index in 0..<(TripLog.limit + 3) {
            let begin = start.addingTimeInterval(Double(index) * 3_600)
            TripLog.record(mode: "car", start: begin, end: begin.addingTimeInterval(600), distance: 5_000,
                           topSpeed: index == 0 ? -1 : 20, climb: -1)
        }
        let trips = TripLog.trips
        XCTAssertEqual(trips.count, TripLog.limit)
        XCTAssertEqual(trips.first?.start, start.addingTimeInterval(Double(TripLog.limit + 2) * 3_600))
        XCTAssertTrue(zip(trips, trips.dropFirst()).allSatisfy { $0.0.start > $0.1.start })
        XCTAssertEqual(trips.first?.topSpeed, 20)
        XCTAssertNil(trips.first?.climb)
    }

    func testReplacesARecordedTripAndIgnoresEmptyOnes() {
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        TripLog.record(mode: "walk", start: start, end: start.addingTimeInterval(60), distance: 80, topSpeed: 1.5, climb: 2)
        TripLog.record(mode: "run", start: start, end: start.addingTimeInterval(90), distance: 200, topSpeed: 3, climb: 4)
        TripLog.record(mode: "car", start: start.addingTimeInterval(500), end: start.addingTimeInterval(500), distance: 0,
                       topSpeed: -1, climb: -1)
        XCTAssertEqual(TripLog.trips, [TripSummary(mode: "run", start: start, end: start.addingTimeInterval(90),
                                                   distance: 200, topSpeed: 3, climb: 4)])
    }

    func testDaysReadTodayAndYesterday() {
        XCTAssertTrue(TripFormat.day(Date()).hasPrefix("Today, "))
        XCTAssertTrue(TripFormat.day(Date().addingTimeInterval(-86_400)).hasPrefix("Yesterday, "))
    }
}
