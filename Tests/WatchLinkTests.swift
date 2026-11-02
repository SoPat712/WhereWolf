import XCTest
@testable import Where

final class WatchLinkTests: XCTestCase {
    private let status = WatchStatus(
        tracking: true, tripActive: true, tripMode: "Driving",
        tripStart: Date(timeIntervalSince1970: 1_700_000_000), tripDistance: 1_234.5,
        lastFix: Date(timeIntervalSince1970: 1_700_000_100), queued: 42, preset: 3, metric: true,
        modes: [WatchTripMode(id: "car", name: "Driving")])

    func testCommandsSurviveTheTrip() {
        let commands: [WatchCommand] = [
            .refresh, .setTracking(true), .setTracking(false), .retryUpdates, .startTrip(mode: "walk"),
            .startTrip(mode: nil), .endTrip, .sendNow, .setPreset(1), .setPreset(5)
        ]
        for command in commands {
            XCTAssertEqual(WatchCommand(message: command.message), command)
            XCTAssertTrue(PropertyListSerialization.propertyList(command.message, isValidFor: .binary))
        }
    }

    func testMalformedCommandsAreRejected() {
        XCTAssertNil(WatchCommand(message: [:]))
        XCTAssertNil(WatchCommand(message: ["command": "wipe"]))
        XCTAssertNil(WatchCommand(message: ["command": "setTracking"]))
        XCTAssertNil(WatchCommand(message: ["command": "setTracking", "value": "yes"]))
        XCTAssertNil(WatchCommand(message: ["command": "setPreset"]))
        XCTAssertNil(WatchCommand(message: ["command": "setPreset", "value": WatchStatus.customPreset]))
        XCTAssertNil(WatchCommand(message: ["command": "setPreset", "value": 6]))
    }

    func testStatusSurvivesTheTripWithAndWithoutOptionalValues() {
        XCTAssertEqual(WatchStatus(message: status.message), status)
        XCTAssertTrue(PropertyListSerialization.propertyList(status.message, isValidFor: .binary))
        let idle = WatchStatus(tracking: false, tripActive: false, tripMode: nil, tripStart: nil, tripDistance: 0,
                               lastFix: nil, queued: 0, preset: 0, metric: false, modes: [])
        XCTAssertEqual(WatchStatus(message: idle.message), idle)
        XCTAssertNil(WatchStatus(message: [:]))
        XCTAssertNil(WatchStatus(message: ["tracking": "yes", "tripActive": false, "queued": 0, "preset": 0]))
    }

    func testEmbeddedWatchAppBelongsToThisPhoneApp() throws {
        let phone = Bundle.main
        let identifier = try XCTUnwrap(phone.bundleIdentifier)
        let watch = try XCTUnwrap(Bundle(url: phone.bundleURL.appendingPathComponent("Watch/WhereWatch.app")))
        XCTAssertEqual(watch.bundleIdentifier, identifier + ".watchkitapp")
        XCTAssertEqual(watch.object(forInfoDictionaryKey: "WKCompanionAppBundleIdentifier") as? String, identifier)
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            XCTAssertEqual(watch.object(forInfoDictionaryKey: key) as? String,
                           phone.object(forInfoDictionaryKey: key) as? String, key)
        }
    }

    func testPresetTagsMatchSettings() {
        XCTAssertEqual(WatchStatus.presets.map(\.id), [1, 2, 3, 4, 5])
        XCTAssertEqual(WatchStatus.presets.map(\.name),
                       ["High Resolution", "Low Power", "Balanced", "Walking / Running", "Driving"])
    }

    func testRetryAppearsOnlyWhenTrackingHasGoneQuiet() {
        let now = Date(timeIntervalSince1970: 1_700_000_100)
        var checked = status
        XCTAssertFalse(checked.isStale(at: now))
        XCTAssertFalse(checked.isStale(at: now.addingTimeInterval(WatchStatus.staleAfter)))
        XCTAssertTrue(checked.isStale(at: now.addingTimeInterval(WatchStatus.staleAfter + 1)))
        checked.lastFix = nil
        XCTAssertTrue(checked.isStale(at: now))
        checked.tracking = false
        XCTAssertFalse(checked.isStale(at: now), "Stop must not offer a retry")
    }

    func testCommandsReachThePhonesOwnControls() {
        var calls: [String] = []
        var inTrip = false
        var actions = OverlandWatchLink.Actions()
        actions.setTracking = { calls.append("tracking \($0)") }
        actions.retryUpdates = { calls.append("retry") }
        actions.startTrip = { calls.append("start \($0 ?? "current")") }
        actions.endTrip = { calls.append("end") }
        actions.sendNow = { calls.append("send") }
        actions.setPreset = { calls.append("preset \($0)") }
        actions.tripInProgress = { inTrip }
        let link = OverlandWatchLink(actions: actions)

        link.perform(.refresh)
        XCTAssertEqual(calls, [], "Reading status must not change anything")
        for command: WatchCommand in [.setTracking(true), .setTracking(false), .retryUpdates, .startTrip(mode: "walk"),
                                      .startTrip(mode: nil), .endTrip, .sendNow, .setPreset(2)] {
            link.perform(command)
        }
        XCTAssertEqual(calls, ["tracking true", "tracking false", "retry", "start walk", "start current",
                               "end", "send", "preset 2"])

        calls = []
        inTrip = true
        link.perform(.setPreset(3))
        XCTAssertEqual(calls, [], "Settings disables Usage Preset during a trip")
    }
}
