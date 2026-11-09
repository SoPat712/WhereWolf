import XCTest
@testable import WhereWolf

final class WatchLinkTests: XCTestCase {
    private let status = WatchStatus(
        tracking: true, tripActive: true, tripMode: "Driving",
        tripStart: Date(timeIntervalSince1970: 1_700_000_000), tripDistance: 1_234.5,
        lastFix: Date(timeIntervalSince1970: 1_700_000_100), queued: 42, preset: 3, metric: true,
        modes: [WatchTripMode(id: "car", name: "Driving", symbol: "wherewolf.car")], tripSymbol: "wherewolf.car")

    func testCommandsSurviveTheTrip() {
        let commands: [WatchCommand] = [
            .refresh, .setTracking(true), .setTracking(false), .retryUpdates, .startTrip(mode: "walk"),
            .startTrip(mode: nil), .endTrip, .sendNow, .setPreset(1), .setPreset(5), .setPreset(6)
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
        XCTAssertNil(WatchCommand(message: ["command": "setPreset", "value": 7]))
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

    func testTripModeSymbolsRoundTripAsPropertyListValues() {
        for symbol in ["wherewolf.walk", "figure.run", "unknown.future.symbol"] {
            let mode = WatchTripMode(id: "custom", name: "My Trip", symbol: symbol)
            XCTAssertEqual(mode.message["symbol"], symbol)
            XCTAssertEqual(WatchTripMode(message: mode.message), mode)
            XCTAssertTrue(PropertyListSerialization.propertyList(mode.message, isValidFor: .binary))
        }
        XCTAssertEqual(WatchTripMode(id: "walk", name: "Walk", symbol: "").symbol, "location.fill")
        XCTAssertNil(WatchTripMode(message: ["name": "Walk", "symbol": "figure.walk"]))
        XCTAssertNil(WatchTripMode(message: ["id": "walk", "symbol": "figure.walk"]))
    }

    func testStatusFromAnOlderPhoneWithoutSymbolsStillDecodes() throws {
        var old = status.message
        old["modes"] = [["id": "car", "name": "Driving"]]
        old.removeValue(forKey: "tripSymbol")
        let decoded = try XCTUnwrap(WatchStatus(message: old))
        XCTAssertEqual(decoded.modes, [WatchTripMode(id: "car", name: "Driving", symbol: "location.fill")])
        XCTAssertNil(decoded.tripSymbol)
        XCTAssertEqual(decoded.tripMode, "Driving")
        XCTAssertEqual(decoded.tracking, status.tracking)
        XCTAssertEqual(decoded.queued, status.queued)
    }

    func testTrackingHomeShowsTheStopHeroAndOrderedControls() {
        var checked = status
        checked.tripActive = false
        checked.queued = 3
        checked.preset = 6
        let home = presentation(checked)
        XCTAssertEqual(home.hero, .tracking)
        XCTAssertEqual(home.title, "Tracking")
        XCTAssertEqual(home.subtitle, "Last fix 12 s ago")
        XCTAssertEqual(home.heroLabel, "Stop Tracking")
        XCTAssertEqual(home.heroValue, "Tracking. Last fix 12 s ago")
        XCTAssertTrue(home.heroIsEnabled)
        XCTAssertEqual(home.rows.map(\.id), [.startTrip, .sendNow, .preset])
        XCTAssertEqual(home.rows.map(\.title), ["Start Trip", "Send Now", "Preset"])
        XCTAssertEqual(home.rows.map(\.subtitle), [nil, "3 waiting", "Everyday Detailed"])
        XCTAssertTrue(home.rows.allSatisfy(\.isEnabled))
    }

    func testOffHomeOffersTripOnlyTrackingAndDisablesAnEmptySend() {
        var checked = status
        checked.tracking = false
        checked.tripActive = false
        checked.lastFix = .distantPast
        checked.queued = 0
        checked.preset = WatchStatus.customPreset
        let home = presentation(checked)
        XCTAssertEqual(home.hero, .off)
        XCTAssertEqual(home.title, "Tracking Off")
        XCTAssertEqual(home.subtitle, "Tap to start")
        XCTAssertEqual(home.heroLabel, "Start Tracking")
        XCTAssertTrue(home.heroIsEnabled)
        XCTAssertEqual(home.rows.map(\.id), [.startTrip, .sendNow, .preset])
        XCTAssertEqual(home.rows.map(\.subtitle), ["Tracks just the trip", "Nothing waiting", "Custom"])
        XCTAssertEqual(home.rows.map(\.isEnabled), [true, false, true])
    }

    func testStaleHomePutsRetryFirstAndKeepsTheStopHero() {
        var checked = status
        checked.tripActive = false
        checked.lastFix = now.addingTimeInterval(-14 * 60)
        checked.queued = 41
        let home = presentation(checked)
        XCTAssertEqual(home.hero, .stale)
        XCTAssertEqual(home.title, "No Updates")
        XCTAssertEqual(home.subtitle, "Last fix 14 min ago")
        XCTAssertEqual(home.heroLabel, "Stop Tracking")
        XCTAssertTrue(home.heroIsEnabled)
        XCTAssertEqual(home.rows.map(\.id), [.retryUpdates, .startTrip, .sendNow, .preset])
        XCTAssertEqual(home.rows.first?.title, "Retry Updates")
        XCTAssertEqual(home.rows.first?.subtitle, "Restarts location updates")
        XCTAssertEqual(home.rows.first?.isEnabled, true)
        XCTAssertEqual(home.rows.first { $0.id == .sendNow }?.subtitle, "41 waiting")
    }

    func testMissingAndFutureFixesHaveHonestHomeSubtitles() {
        var checked = status
        checked.lastFix = nil
        XCTAssertEqual(presentation(checked).hero, .stale)
        XCTAssertEqual(presentation(checked).subtitle, "No fix yet")
        checked.lastFix = now.addingTimeInterval(30)
        XCTAssertEqual(presentation(checked).hero, .tracking)
        XCTAssertEqual(presentation(checked).subtitle, "Last fix 0 s ago")
    }

    func testHomeChangesAtTheStaleBoundaryAndUsesMinuteAndSingularSubtitles() {
        var checked = status
        checked.tripActive = false
        checked.queued = 1
        checked.lastFix = now.addingTimeInterval(-60)
        XCTAssertEqual(presentation(checked).subtitle, "Last fix 1 min ago")
        XCTAssertEqual(presentation(checked).rows.first { $0.id == .sendNow }?.subtitle, "1 waiting")
        checked.lastFix = now.addingTimeInterval(-WatchStatus.staleAfter)
        XCTAssertEqual(presentation(checked).hero, .tracking)
        checked.lastFix = now.addingTimeInterval(-WatchStatus.staleAfter - 1)
        XCTAssertEqual(presentation(checked).hero, .stale)
        checked.tracking = false
        XCTAssertEqual(presentation(checked).hero, .off)
    }

    func testUnreachableHomeOverridesCachedStatusAndDisablesAllButRefresh() {
        for tracking in [false, true] {
            for trip in [false, true] {
                var checked = status
                checked.tracking = tracking
                checked.tripActive = trip
                checked.lastFix = .distantPast
                let home = presentation(checked, unreachable: true)
                XCTAssertEqual(home.hero, .unreachable)
                XCTAssertEqual(home.title, "Can’t Reach iPhone")
                XCTAssertEqual(home.subtitle, "Bring it closer, or open WhereWolf there.")
                XCTAssertEqual(home.heroLabel, "Tracking unavailable")
                XCTAssertFalse(home.heroIsEnabled)
                XCTAssertEqual(home.rows.first?.id, .refresh)
                XCTAssertEqual(home.rows.first?.title, "Try Again")
                XCTAssertEqual(home.rows.first?.isEnabled, true)
                XCTAssertTrue(home.rows.dropFirst().allSatisfy { !$0.isEnabled })
                XCTAssertEqual(home.rows.map(\.id), trip
                               ? [.refresh, .trip, .endTrip, .sendNow, .preset]
                               : [.refresh, .startTrip, .sendNow, .preset])
            }
        }
        let empty = WatchHomePresentation(status: nil, unreachable: true, now: now)
        XCTAssertEqual(empty.hero, .unreachable)
        XCTAssertEqual(empty.rows.map(\.id), [.refresh, .startTrip, .sendNow, .preset])
        XCTAssertEqual(empty.rows.map(\.subtitle), [nil, nil, nil, nil])
        XCTAssertEqual(empty.rows.map(\.isEnabled), [true, false, false, false])
    }

    func testTripHomeReplacesStartWithTheCardAndEndAndLocksPreset() {
        let home = presentation(status)
        XCTAssertEqual(home.rows.map(\.id), [.trip, .endTrip, .sendNow, .preset])
        XCTAssertEqual(home.rows.first?.title, "Driving")
        XCTAssertEqual(home.rows.first { $0.id == .endTrip }?.isEnabled, true)
        XCTAssertEqual(home.rows.last?.subtitle, "Locked during a trip")
        XCTAssertEqual(home.rows.last?.isEnabled, false)

        var stale = status
        stale.lastFix = nil
        XCTAssertEqual(presentation(stale).rows.map(\.id), [.retryUpdates, .trip, .endTrip, .sendNow, .preset])
    }

    func testBusyHomePreventsDuplicateCommandsAndMissingModesPreventStart() {
        var checked = status
        checked.tripActive = false
        let busy = presentation(checked, busy: true)
        XCTAssertEqual(busy.hero, .tracking)
        XCTAssertFalse(busy.heroIsEnabled)
        XCTAssertTrue(busy.rows.allSatisfy { !$0.isEnabled })
        XCTAssertEqual(presentation(checked, unreachable: true, busy: true).rows.first?.isEnabled, false)
        checked.modes = []
        XCTAssertEqual(presentation(checked).rows.first?.isEnabled, false)
        checked.preset = 99
        XCTAssertEqual(presentation(checked).rows.last?.subtitle, "Custom")
    }

    private var now: Date { Date(timeIntervalSince1970: 1_700_000_112) }

    private func presentation(_ checked: WatchStatus, unreachable: Bool = false, busy: Bool = false) -> WatchHomePresentation {
        WatchHomePresentation(status: checked, unreachable: unreachable, busy: busy, now: now)
    }

    func testEmbeddedWatchAppBelongsToThisPhoneApp() throws {
        let phone = Bundle.main
        let identifier = try XCTUnwrap(phone.bundleIdentifier)
        let watch = try XCTUnwrap(Bundle(url: phone.bundleURL.appendingPathComponent("Watch/WhereWolfWatch.app")))
        XCTAssertEqual(watch.bundleIdentifier, identifier + ".watchkitapp")
        XCTAssertEqual(watch.object(forInfoDictionaryKey: "WKCompanionAppBundleIdentifier") as? String, identifier)
        for key in ["CFBundleShortVersionString", "CFBundleVersion"] {
            XCTAssertEqual(watch.object(forInfoDictionaryKey: key) as? String,
                           phone.object(forInfoDictionaryKey: key) as? String, key)
        }
    }

    func testPresetTagsMatchSettings() {
        XCTAssertEqual(WatchStatus.presets.map(\.id), [5, 1, 4, 6, 3, 2])
        XCTAssertEqual(WatchStatus.presets.map(\.name),
                       ["Driving", "High Resolution", "Walking / Running", "Everyday Detailed", "Balanced", "Low Power"])
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
        var actions = WhereWolfWatchLink.Actions()
        actions.setTracking = { calls.append("tracking \($0)") }
        actions.retryUpdates = { calls.append("retry") }
        actions.startTrip = { calls.append("start \($0 ?? "current")") }
        actions.endTrip = { calls.append("end") }
        actions.sendNow = { calls.append("send") }
        actions.setPreset = { calls.append("preset \($0)") }
        actions.tripInProgress = { inTrip }
        let link = WhereWolfWatchLink(actions: actions)

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
