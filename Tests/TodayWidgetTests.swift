import Foundation
import XCTest
@testable import WhereWolf

final class TodayHistoryTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    func testLocalMidnightBoundariesAndDST() {
        for (noon, start, end, hours) in [
            ("2026-11-06T17:00:00Z", "2026-11-06T05:00:00Z", "2026-11-07T05:00:00Z", 24.0),
            ("2026-03-08T16:00:00Z", "2026-03-08T05:00:00Z", "2026-03-09T04:00:00Z", 23.0),
            ("2026-11-01T17:00:00Z", "2026-11-01T04:00:00Z", "2026-11-02T05:00:00Z", 25.0)
        ] {
            let day = TodayWindow(containing: date(noon), calendar: calendar)
            XCTAssertEqual(day.start, date(start))
            XCTAssertEqual(day.end, date(end))
            XCTAssertEqual(day.end.timeIntervalSince(day.start), hours * 3600)
            XCTAssertFalse(day.contains(day.start.addingTimeInterval(-0.001)))
            XCTAssertTrue(day.contains(day.start))
            XCTAssertTrue(day.contains(day.end.addingTimeInterval(-0.001)))
            XCTAssertFalse(day.contains(day.end))
            XCTAssertEqual(TodayWindow(containing: day.end, calendar: calendar).start, day.end)
        }
    }

    func testIncrementalExtensionEqualsFullRecomputeAtEveryFix() {
        let start = date("2026-11-06T12:00:00Z")
        var points = (0..<100).map { point($0 + 1, start.addingTimeInterval(Double($0) * 5), meters: Double($0) * 7) }
        points[20] = point(21, points[20].timestamp, meters: 540)
        points += (100..<180).map {
            point($0 + 1, start.addingTimeInterval(Double($0) * 5), meters: 700 + ($0.isMultiple(of: 2) ? 0 : 15))
        }
        // Sparse fixes exercise the net-speed fallback across gaps beyond its normal window.
        points += (180..<200).map {
            point($0 + 1, start.addingTimeInterval(2000 + Double($0 - 180) * 700), meters: Double($0) * 20)
        }
        var cache = makeCache(now: points.last!.timestamp)
        for index in points.indices {
            let prefix = Array(points[...index])
            cache.extend([points[index]], through: points[index].timestamp)
            let summary = cache.summary(lastFixDate: points[index].timestamp)
            XCTAssertEqual(summary.points, prefix.count)
            XCTAssertEqual(summary.distance, ReplayTimeline.distanceIncrements(prefix).reduce(0, +), accuracy: 0.000001)
            XCTAssertEqual(cache.lastArchivedID, points[index].id)
        }
        var full = makeCache(now: points.last!.timestamp)
        full.extend(points, through: points.last!.timestamp)
        XCTAssertEqual(cache.summary(lastFixDate: nil).distance, full.summary(lastFixDate: nil).distance, accuracy: 0.000001)
    }

    func testIncrementalBatchesEqualFullRecomputeWithDenseAndEqualTimestamps() {
        let start = date("2026-11-06T12:00:00Z")
        let points = (0..<400).map { index in
            point(index + 1, start.addingTimeInterval(Double(index / 2)),
                  meters: index % 67 == 0 ? 500 : Double(index % 11))
        }
        for batchSize in [1, 3, 17, 100] {
            var cache = makeCache(now: start)
            for first in stride(from: 0, to: points.count, by: batchSize) {
                let end = min(points.count, first + batchSize)
                cache.extend(Array(points[first..<end]), through: points[end - 1].timestamp)
                XCTAssertEqual(cache.summary(lastFixDate: nil).distance,
                               ReplayTimeline.distanceIncrements(Array(points[..<end])).reduce(0, +), accuracy: 0.000001)
            }
        }
    }

    func testOutAndBackSpikeUsesDirectDistanceAndRealUTurnSurvives() {
        let start = date("2026-11-06T12:00:00Z")
        var walk = (0..<40).map { point($0 + 1, start.addingTimeInterval(Double($0) * 5), meters: Double($0) * 7) }
        walk[20] = point(21, walk[20].timestamp, meters: 540)
        var cache = makeCache(now: start)
        cache.extend(walk, through: walk.last!.timestamp)
        XCTAssertEqual(cache.summary(lastFixDate: nil).distance, 39 * 7, accuracy: 1)

        let turn = (0..<19).map { index in
            point(index + 1, start.addingTimeInterval(Double(index) * 5), meters: Double(index <= 9 ? index : 18 - index) * 125)
        }
        var driving = makeCache(now: start)
        driving.extend(turn, through: turn.last!.timestamp)
        XCTAssertEqual(driving.summary(lastFixDate: nil).distance, 18 * 125, accuracy: 2)
    }

    func testStationaryWanderingCountsEveryPointButNoDistance() {
        let start = date("2026-11-06T12:00:00Z")
        let points = (0..<80).map {
            point($0 + 1, start.addingTimeInterval(Double($0) * 5), meters: $0.isMultiple(of: 2) ? 0 : 15)
        }
        var cache = makeCache(now: start)
        cache.extend(points, through: points.last!.timestamp)
        XCTAssertEqual(cache.summary(lastFixDate: nil).points, points.count)
        XCTAssertEqual(cache.summary(lastFixDate: nil).distance, 0, accuracy: 0.001)
    }

    func testDailyDistanceContinuesAcrossStopsInsteadOfResetting() {
        let start = date("2026-11-06T12:00:00Z")
        let meters = (0...10).map { Double($0) * 100 } + Array(repeating: 1000.0, count: 80)
            + (1...10).map { 1000 + Double($0) * 100 }
        let points = meters.enumerated().map { point($0.offset + 1, start.addingTimeInterval(Double($0.offset) * 5), meters: $0.element) }
        var cache = makeCache(now: start)
        cache.extend(points, through: points.last!.timestamp)
        XCTAssertEqual(cache.summary(lastFixDate: nil).distance, 2000, accuracy: 1)
        XCTAssertEqual(ReplayTimeline(points: points).legDistance(at: points.count - 1) ?? 0, 1000, accuracy: 1)
    }

    func testPruningDayAndTimeZoneChangesInvalidateCache() {
        let now = date("2026-11-06T12:00:00Z")
        var cache = makeCache(now: now)
        cache.extend([point(1, now.addingTimeInterval(-60), meters: 0)], through: now)
        cache.prepare(now: now, calendar: calendar, pruningRevision: 1, cutoff: .distantPast)
        XCTAssertEqual(cache.lastArchivedID, 0)
        XCTAssertEqual(cache.summary(lastFixDate: nil).points, 0)
        cache.extend([point(2, now, meters: 100)], through: now)

        var otherZone = calendar
        otherZone.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        cache.prepare(now: now, calendar: otherZone, pruningRevision: 1, cutoff: .distantPast)
        XCTAssertEqual(cache.lastArchivedID, 0)
        XCTAssertEqual(cache.day?.start, date("2026-11-06T08:00:00Z"))
        cache.extend([point(2, now, meters: 100)], through: now)
        cache.prepare(now: date("2026-11-07T08:00:00Z"), calendar: otherZone,
                      pruningRevision: 1, cutoff: .distantPast)
        XCTAssertEqual(cache.summary(lastFixDate: nil).points, 0)
    }

    func testMovingRetentionCutoffInvalidatesBeforePhysicalPrune() {
        let now = date("2026-11-01T17:00:00Z")
        var cache = makeCache(now: now)
        cache.extend([point(1, date("2026-11-01T04:30:00Z"), meters: 0)], through: now)
        cache.prepare(now: date("2026-11-02T04:45:00Z"), calendar: calendar, pruningRevision: 0,
                      cutoff: date("2026-11-01T04:45:00Z"))
        XCTAssertEqual(cache.lastArchivedID, 0)
        XCTAssertEqual(cache.summary(lastFixDate: nil).points, 0)
    }

    func testArchiveLimitsGeometryToTodayAndNowAndKeepsPreviousLastFix() throws {
        var now = date("2026-11-06T05:00:00Z")
        try withStore(clock: { now }) { store in
            let previous = now.addingTimeInterval(-1)
            record(store, previous, meters: 0)
            var summary = try load(store)
            XCTAssertEqual(summary.points, 0)
            XCTAssertEqual(summary.lastFixDate, previous)
            record(store, now, meters: 100)
            // Insert a future fix before another current fix to exercise the ID watermark.
            record(store, now.addingTimeInterval(60), meters: 200)
            record(store, now, meters: 110)
            summary = try load(store)
            XCTAssertEqual(summary.points, 2)
            XCTAssertEqual(summary.start, now)
            XCTAssertEqual(summary.lastFixDate, now)
            now = now.addingTimeInterval(60)
            summary = try load(store)
            XCTAssertEqual(summary.points, 3)
            XCTAssertEqual(summary.lastFixDate, now)
            XCTAssertEqual(try load(store), summary)
        }
    }

    func testArchiveRecomputesAfterRetentionPrunesTodaysEarlyDSTHour() throws {
        var now = date("2026-11-02T04:30:00Z")
        try withStore(clock: { now }) { store in
            store.setRetentionHours(168)
            record(store, date("2026-11-01T04:05:00Z"), meters: 0)
            record(store, date("2026-11-01T12:00:00Z"), meters: 1000)
            XCTAssertEqual(try load(store).points, 2)
            store.setRetentionHours(24)
            let summary = try load(store)
            XCTAssertEqual(summary.points, 1)
            XCTAssertEqual(summary.distance, 0)
            now = date("2026-11-02T05:00:00Z")
            XCTAssertEqual(try load(store).points, 0)
        }
    }

    func testOutOfOrderArchiveAdditionRecomputesInTimestampOrder() {
        let now = date("2026-11-06T12:00:00Z")
        let first = point(1, now.addingTimeInterval(-60), meters: 0)
        let last = point(2, now, meters: 200)
        let middle = point(3, now.addingTimeInterval(-30), meters: 100)
        var cache = makeCache(now: now)
        cache.extend([first, last], through: now)
        cache.extend([middle], through: now)
        XCTAssertEqual(cache.summary(lastFixDate: nil).distance,
                       ReplayTimeline.distanceIncrements([first, middle, last]).reduce(0, +), accuracy: 0.000001)
        XCTAssertEqual(cache.lastArchivedID, 3)
    }

    private func makeCache(now: Date) -> TodayHistoryCache {
        var cache = TodayHistoryCache()
        cache.prepare(now: now, calendar: calendar, pruningRevision: 0, cutoff: .distantPast)
        return cache
    }

    private func point(_ id: Int, _ timestamp: Date, meters: Double) -> RecordedLocation {
        RecordedLocation(id: Int64(id), timestamp: timestamp, latitude: 45 + meters / 111_195, longitude: -122)
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func withStore(clock: @escaping () -> Date, body: (RecentLocationHistory) throws -> Void) throws {
        let suite = "WhereWolf.TodayHistoryTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        try body(RecentLocationHistory(directoryURL: directory, defaults: defaults, clock: clock))
    }

    private func record(_ store: RecentLocationHistory, _ timestamp: Date, meters: Double) {
        store.recordUpdate(["_type": "location", "lat": 45 + meters / 111_195, "lon": -122,
                            "tst": timestamp.timeIntervalSince1970] as NSDictionary)
    }

    private func load(_ store: RecentLocationHistory) throws -> TodayHistorySummary {
        let finished = expectation(description: "today summary")
        var result: TodayHistorySummary?
        store.loadTodaySummary(calendar: calendar) {
            result = $0
            finished.fulfill()
        }
        wait(for: [finished], timeout: 2)
        return try XCTUnwrap(result)
    }
}

final class TodaySharedStateTests: XCTestCase {
    func testOldSnapshotDecodesWithoutTodayFields() throws {
        let data = Data("""
        {"trackingEnabled":true,"tripMode":"walk","tripDistance":1234,"queueCount":12,
         "tripStart":1000,"lastSentDate":900,"lastSendError":"Offline","updatedAt":1100}
        """.utf8)
        let state = try JSONDecoder().decode(SharedTripState.self, from: data)
        XCTAssertTrue(state.trackingEnabled)
        XCTAssertEqual(state.tripMode, "walk")
        XCTAssertEqual(state.tripDistance, 1234)
        XCTAssertEqual(state.queueCount, 12)
        XCTAssertEqual(state.tripStart, Date(timeIntervalSinceReferenceDate: 1000))
        XCTAssertEqual(state.lastSentDate, Date(timeIntervalSinceReferenceDate: 900))
        XCTAssertEqual(state.lastSendError, "Offline")
        XCTAssertEqual(state.updatedAt, Date(timeIntervalSinceReferenceDate: 1100))
        XCTAssertEqual(state.todayDistance, 0)
        XCTAssertEqual(state.todayPoints, 0)
        XCTAssertNil(state.todayStart)
        XCTAssertNil(state.lastFixDate)
    }

    func testNewSnapshotRoundTripsWithoutCoordinates() throws {
        var state = SharedTripState()
        state.todayStart = Date(timeIntervalSince1970: 1_800_000_000)
        state.todayDistance = 1234.5
        state.todayPoints = 1204
        state.lastFixDate = state.todayStart?.addingTimeInterval(60)
        let data = try JSONEncoder().encode(state)
        XCTAssertEqual(try JSONDecoder().decode(SharedTripState.self, from: data), state)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(Set(fields.keys), ["trackingEnabled", "tripMode", "tripDistance", "queueCount",
                                         "updatedAt", "todayStart", "todayDistance", "todayPoints", "lastFixDate"])
    }

    func testMidnightEntryResetsTotalsButKeepsTrackingAndLastFix() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let now = ISO8601DateFormatter().date(from: "2026-11-01T17:00:00Z")!
        let day = TodayWindow(containing: now, calendar: calendar)
        var state = SharedTripState()
        state.trackingEnabled = true
        state.todayStart = day.start
        state.todayDistance = 1234
        state.todayPoints = 12
        state.lastFixDate = now
        XCTAssertEqual(state.forToday(at: day.end.addingTimeInterval(-0.001), calendar: calendar), state)
        let midnight = state.forToday(at: day.end, calendar: calendar)
        XCTAssertEqual(midnight.todayStart, day.end)
        XCTAssertEqual(midnight.todayDistance, 0)
        XCTAssertEqual(midnight.todayPoints, 0)
        XCTAssertEqual(midnight.lastFixDate, now)
        XCTAssertTrue(midnight.trackingEnabled)
    }
}
