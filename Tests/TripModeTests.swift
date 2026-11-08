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
