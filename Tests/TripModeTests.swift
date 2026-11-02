import Foundation
import UIKit
import XCTest
@testable import Where

final class TripModeTests: XCTestCase {
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        let suite = "Where.TripModeTests.\(UUID().uuidString)"
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
            TripMode(id: "kayak", name: "Kayak", symbol: "where.kayak", closeZoom: true),
        ]
        defaults.set(try JSONEncoder().encode(saved), forKey: TripModeStore.modesKey)
        defaults.set(Array(TripMode.originalIDs), forKey: TripModeStore.builtInIDsKey)

        let modes = TripModeStore.modes
        XCTAssertEqual(modes.first(where: { $0.id == "walk" })?.symbol, "where.walk")
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
        let custom = TripMode(id: "kayak", name: "Kayak", symbol: "where.kayak", closeZoom: true)
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
}
