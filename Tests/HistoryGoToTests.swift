import XCTest
@testable import WhereWolf

final class HistoryGoToTests: XCTestCase {
    func testPhoneSummariesUseCalendarDaysAcrossDSTAndOffsetTimeZones() throws {
        let cases: [(String, String, TimeInterval)] = [
            ("America/New_York", "2026-03-08T12:00:00Z", 23 * 3_600),
            ("America/New_York", "2026-11-01T12:00:00Z", 25 * 3_600),
            ("Australia/Lord_Howe", "2026-04-05T02:00:00Z", 24.5 * 3_600),
            ("Asia/Kolkata", "2026-06-02T12:00:00Z", 24 * 3_600),
            ("Asia/Kathmandu", "2026-06-02T12:00:00Z", 24 * 3_600)
        ]
        for (zone, noon, duration) in cases {
            let calendar = makeCalendar(zone)
            let interval = try XCTUnwrap(calendar.dateInterval(of: .day, for: date(noon)))
            XCTAssertEqual(interval.duration, duration)
            let times = [interval.start.addingTimeInterval(-1), interval.start,
                         interval.start.addingTimeInterval(1_800), interval.end.addingTimeInterval(-1), interval.end]
            let points = times.enumerated().map { fix($0.offset, at: $0.element) }
            let provider = makeLandmarks(points, calendar: calendar).daySummaries
            let day = try XCTUnwrap(provider.summaries(in: interval).first)
            XCTAssertEqual(provider.summaries(in: interval).count, 1, zone)
            XCTAssertEqual(day.day, interval.start)
            XCTAssertEqual(day.pointCount, 3, "Midnight belongs to the next day: \(zone)")
            XCTAssertEqual(day.distance, 0)
            XCTAssertEqual(day.state, .phone)
            XCTAssertEqual(provider.firstDay, calendar.startOfDay(for: times[0]))
            let next = try XCTUnwrap(calendar.dateInterval(of: .day, for: interval.end))
            XCTAssertEqual(provider.summaries(in: next).first?.pointCount, 1)
        }
    }

    func testTimeZoneRebuildRegroupsTheSamePoints() {
        let points = [date("2026-06-02T03:50:00Z"), date("2026-06-02T04:10:00Z")].enumerated().map {
            fix($0.offset, at: $0.element, north: Double($0.offset) * 100)
        }
        let interval = DateInterval(start: date("2026-06-01T00:00:00Z"), end: date("2026-06-03T00:00:00Z"))
        let east = makeLandmarks(points, calendar: makeCalendar()).daySummaries
        let west = makeLandmarks(points, calendar: makeCalendar("America/Los_Angeles")).daySummaries
        XCTAssertEqual(east.summaries(in: interval).map(\.pointCount), [1, 1])
        XCTAssertEqual(west.summaries(in: interval).map(\.pointCount), [2])
        XCTAssertEqual(east.firstDay, date("2026-06-01T04:00:00Z"))
        XCTAssertEqual(west.firstDay, date("2026-06-01T07:00:00Z"))
    }

    func testPhoneDistanceSharesJumpCorrectionAndCrossMidnightAttribution() throws {
        let start = date("2026-06-02T03:59:30Z")
        let points = [0.0, 10, 20, 1_000, 40, 50, 60].enumerated().map {
            fix($0.offset, at: start.addingTimeInterval(Double($0.offset) * 10), north: $0.element)
        }
        let timeline = ReplayTimeline(points: points)
        let landmarks = makeLandmarks(points)
        let summaries = landmarks.daySummaries.summaries(in:
            DateInterval(start: date("2026-06-01T04:00:00Z"), end: date("2026-06-03T04:00:00Z")))
        let raw = zip(points, points.dropFirst()).reduce(0.0) { $0 + ReplayTimeline.distance($1.0, $1.1) }
        XCTAssertGreaterThan(raw, 1_900)
        XCTAssertEqual(summaries.map(\.pointCount), [3, 4])
        XCTAssertEqual(try XCTUnwrap(summaries.first?.distance), 20, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(summaries.last?.distance), 40, accuracy: 0.01)
        XCTAssertEqual(summaries.compactMap(\.distance).reduce(0, +),
                       timeline.distance(from: 0, through: points.count - 1), accuracy: 1e-8)
        for day in summaries {
            let journey = try XCTUnwrap(landmarks.journey.first { $0.id == day.day })
            XCTAssertEqual(day.distance, journey.rows.compactMap(\.distance).reduce(0, +))
        }
    }

    func testStopsDoNotAddWanderingDistanceOrDoubleCountSharedEndpoints() throws {
        let start = date("2026-06-01T12:00:00Z")
        let jitter = (0...10).map {
            fix($0, at: start.addingTimeInterval(Double($0) * 60), north: $0.isMultiple(of: 2) ? 0 : 2)
        }
        let interval = try XCTUnwrap(makeCalendar().dateInterval(of: .day, for: start))
        let stopped = try XCTUnwrap(makeLandmarks(jitter).daySummaries.summaries(in: interval).first)
        XCTAssertEqual(stopped.distance, 0)
        XCTAssertEqual(stopped.pointCount, jitter.count)

        let points = twoStops(start: start)
        let landmarks = makeLandmarks(points)
        let summary = try XCTUnwrap(landmarks.daySummaries.summaries(in: interval).first)
        XCTAssertEqual(summary.pointCount, points.count)
        XCTAssertGreaterThan(landmarks.journey[0].rows.reduce(0) { $0 + $1.end - $1.start + 1 }, points.count)
        XCTAssertEqual(try XCTUnwrap(summary.distance), 1_000, accuracy: 0.1)
    }

    func testEmptyDaysAndHalfOpenQueriesDoNotInventData() {
        let interval = DateInterval(start: date("2026-06-01T04:00:00Z"), end: date("2026-06-04T04:00:00Z"))
        let empty = makeLandmarks([]).daySummaries
        XCTAssertNil(empty.firstDay)
        XCTAssertTrue(empty.summaries(in: interval).isEmpty)
        let points = [fix(0, at: date("2026-06-01T12:00:00Z")), fix(1, at: date("2026-06-03T12:00:00Z"))]
        let provider = makeLandmarks(points).daySummaries
        XCTAssertEqual(provider.summaries(in: interval).map(\.pointCount), [1, 1])
        let gap = DateInterval(start: date("2026-06-02T04:00:00Z"), end: date("2026-06-03T04:00:00Z"))
        XCTAssertTrue(provider.summaries(in: gap).isEmpty)
        XCTAssertTrue(provider.summaries(in: DateInterval(start: interval.start, duration: 0)).isEmpty)
    }

    func testMonthPagingStopsAtFirstHistoryMonthAndCurrentMonth() {
        let bounds = HistoryGoToCalendar(calendar: makeCalendar(), firstDay: date("2024-12-15T05:00:00Z"),
                                        now: date("2026-03-08T12:00:00Z"))
        XCTAssertNil(bounds.page(from: date("2024-12-31T12:00:00Z"), by: -1))
        XCTAssertEqual(bounds.page(from: date("2024-12-31T12:00:00Z"), by: 1), date("2025-01-01T05:00:00Z"))
        XCTAssertEqual(bounds.page(from: date("2026-03-31T12:00:00Z"), by: -1), date("2026-02-01T05:00:00Z"))
        XCTAssertNil(bounds.page(from: date("2026-03-01T05:00:00Z"), by: 1))
        XCTAssertEqual(bounds.clampedMonth(date("2020-01-01T00:00:00Z")), date("2024-12-01T05:00:00Z"))
        XCTAssertEqual(bounds.clampedMonth(date("2030-01-01T00:00:00Z")), date("2026-03-01T05:00:00Z"))
        XCTAssertFalse(bounds.contains(date("2024-12-14T05:00:00Z")))
        XCTAssertTrue(bounds.contains(date("2024-12-15T05:00:00Z")))
        XCTAssertTrue(bounds.contains(date("2026-03-08T05:00:00Z")))
        XCTAssertFalse(bounds.contains(date("2026-03-09T04:00:00Z")))
    }

    func testEmptyCalendarStaysOnTodayWithNoPaging() {
        let now = date("2026-06-01T12:00:00Z")
        let bounds = HistoryGoToCalendar(calendar: makeCalendar(), firstDay: nil, now: now)
        XCTAssertNil(bounds.page(from: now, by: -1))
        XCTAssertNil(bounds.page(from: now, by: 1))
        XCTAssertEqual(bounds.window(firstPoint: nil), now...now)
        XCTAssertTrue(bounds.contains(date("2026-06-01T04:00:00Z")))
        XCTAssertFalse(bounds.contains(date("2026-05-31T04:00:00Z")))
    }

    func testMonthCellsIncludeLeapDayAndUseLocaleWeekStartAcrossDST() {
        var calendar = makeCalendar()
        calendar.firstWeekday = 2
        let bounds = HistoryGoToCalendar(calendar: calendar, firstDay: date("2024-01-01T05:00:00Z"),
                                        now: date("2026-11-12T12:00:00Z"))
        let leap = bounds.days(in: date("2024-02-15T12:00:00Z"))
        XCTAssertEqual(leap.count, 29)
        XCTAssertEqual(leap.last, date("2024-02-29T05:00:00Z"))
        XCTAssertEqual(bounds.leadingDays(in: leap[0]), 3)
        let march = bounds.days(in: date("2026-03-15T12:00:00Z"))
        XCTAssertEqual(march.count, 31)
        XCTAssertEqual(Set(march).count, 31)
        XCTAssertEqual(march[8].timeIntervalSince(march[7]), 23 * 3_600)
        let november = bounds.days(in: date("2026-11-15T12:00:00Z"))
        XCTAssertEqual(november.count, 30)
        XCTAssertEqual(november[1].timeIntervalSince(november[0]), 25 * 3_600)
    }

    func testExactTimeWindowPreservesPhoneBoundsAndExtendsForServerHistory() {
        let first = date("2026-06-01T12:00:00Z"), now = date("2026-06-02T12:00:00Z")
        let phone = HistoryGoToCalendar(calendar: makeCalendar(), firstDay: makeCalendar().startOfDay(for: first), now: now)
        XCTAssertEqual(phone.window(firstPoint: first), first...now)
        let older = date("2024-01-01T05:00:00Z")
        let server = HistoryGoToCalendar(calendar: makeCalendar(), firstDay: older, now: now)
        XCTAssertEqual(server.window(firstPoint: first), older...now)
        XCTAssertEqual(server.window(firstPoint: nil), older...now)
    }

    func testSelectingADayPreservesWallTimeThroughDSTAndClampsExactBounds() {
        let first = date("2026-03-07T17:00:00Z"), now = date("2026-03-09T16:00:00Z")
        let bounds = HistoryGoToCalendar(calendar: makeCalendar(), firstDay: makeCalendar().startOfDay(for: first), now: now)
        let window = bounds.window(firstPoint: first)
        let spring = bounds.time(on: date("2026-03-08T05:00:00Z"), preserving: date("2026-03-07T07:30:00Z"), in: window)
        XCTAssertEqual(spring, date("2026-03-08T07:30:00Z"), "The missing 02:30 becomes 03:30 on the selected day")
        XCTAssertEqual(bounds.time(on: first, preserving: date("2026-03-08T06:00:00Z"), in: window), first)
        XCTAssertEqual(bounds.time(on: now, preserving: date("2026-03-08T23:00:00Z"), in: window), now)
    }

    func testDaySelectionShowsOnlyThatDaysRowsNewestFirstAndKeepsViewingOwnership() throws {
        let points = twoStops(start: date("2026-06-02T03:57:00Z"))
        let landmarks = makeLandmarks(points)
        let bounds = HistoryGoToCalendar(calendar: makeCalendar(), firstDay: landmarks.daySummaries.firstDay,
                                        now: date("2026-06-02T12:00:00Z"))
        let selected = bounds.time(on: date("2026-06-02T04:00:00Z"), preserving: points.last!.timestamp,
                                   in: bounds.window(firstPoint: points.first?.timestamp))
        let day = try XCTUnwrap(bounds.journey(on: selected, in: landmarks.journey))
        XCTAssertEqual(day.rows.map(\.start), [6, 5, 3])
        XCTAssertEqual(day.rows.map(\.end), [11, 6, 5])
        XCTAssertEqual(landmarks.viewingRow(at: 6)?.id, day.rows[0].id)
        let previous = try XCTUnwrap(bounds.journey(on: date("2026-06-01T12:00:00Z"), in: landmarks.journey))
        XCTAssertEqual(previous.rows.map(\.start), [0])
        XCTAssertNil(bounds.journey(on: date("2026-05-31T12:00:00Z"), in: landmarks.journey))
    }

    func testNotDownloadedRemainsSelectableWithKnownOrUnknownDistance() {
        let day = date("2025-01-01T05:00:00Z")
        let provider = StubSummaries(firstDay: day, days: [
            HistoryDaySummary(day: day, distance: 1_609.344, pointCount: 500, state: .notDownloaded)
        ])
        let bounds = HistoryGoToCalendar(calendar: makeCalendar(), firstDay: provider.firstDay,
                                        now: date("2026-06-01T12:00:00Z"))
        let summary = provider.summaries(in: bounds.month(containing: day)).first
        let cell = HistoryGoToDay(day: day, summary: summary, selected: day, viewed: nil, bounds: bounds)
        XCTAssertTrue(cell.enabled)
        XCTAssertTrue(cell.selected)
        XCTAssertTrue(cell.notDownloaded)
        XCTAssertEqual(cell.accessibilityValue(metric: false), "1.0 mi, Not downloaded")
        let unknown = HistoryGoToDay(day: day,
            summary: HistoryDaySummary(day: day, distance: nil, pointCount: 0, state: .notDownloaded),
            selected: day, viewed: nil, bounds: bounds)
        XCTAssertEqual(unknown.accessibilityValue(metric: true), "Not downloaded")
        XCTAssertFalse(unknown.accessibilityValue(metric: true).contains("No data"))
        XCTAssertTrue(unknown.enabled)
    }

    func testDayAccessibilityNamesDistanceSourceTodayAndViewedDay() {
        let now = date("2026-06-01T12:00:00Z"), day = date("2026-06-01T04:00:00Z")
        let bounds = HistoryGoToCalendar(calendar: makeCalendar(), firstDay: day, now: now)
        let cell = HistoryGoToDay(day: day,
            summary: HistoryDaySummary(day: day, distance: 1_609.344, pointCount: 25, state: .phone),
            selected: now, viewed: now, bounds: bounds)
        XCTAssertEqual(cell.accessibilityValue(metric: true), "1.6 km, On this phone, Today, Viewing")
        XCTAssertEqual(cell.accessibilityValue(metric: false), "1.0 mi, On this phone, Today, Viewing")
        let label = bounds.title(for: day, template: "EEEEyMMMMd", locale: Locale(identifier: "en_US"))
        XCTAssertTrue(label.contains("Monday"))
        XCTAssertTrue(label.contains("June"))
        XCTAssertTrue(label.contains("2026"))
        let server = HistoryGoToDay(day: day,
            summary: HistoryDaySummary(day: day, distance: 0, pointCount: 1, state: .server),
            selected: now, viewed: nil, bounds: bounds)
        XCTAssertTrue(server.accessibilityValue(metric: true).contains("Downloaded from server"))
        XCTAssertFalse(server.accessibilityValue(metric: true).contains("Viewing"))
        let empty = HistoryGoToDay(day: day, summary: nil, selected: now, viewed: nil, bounds: bounds)
        XCTAssertEqual(empty.accessibilityValue(metric: true), "No data, Today")
    }

    @MainActor func testRowJumpUsesExistingSelectionPathBeforeDismissing() throws {
        let points = twoStops(start: date("2026-06-01T12:00:00Z"))
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) },
            payloadLoader: { _, completion in completion([:]) }, places: { [] },
            landmarkBuilder: immediateLandmarks, clock: { points.last!.timestamp })
        model.setConsumerActive(true)
        defer { model.setConsumerActive(false) }
        let row = try XCTUnwrap(model.landmarks.journey.first?.rows.first)
        let landmarks = model.landmarks
        model.beginRulerInteraction()
        model.scrub(rulerPosition: 5.5, liveEdge: points.last!.timestamp)
        var dismissals = 0
        HistoryGoToView(history: model).choose(row) {
            XCTAssertEqual(model.selectedIndex, row.start)
            dismissals += 1
        }
        XCTAssertEqual(dismissals, 1)
        XCTAssertTrue(model.isBrowsing)
        XCTAssertEqual(model.renderPose?.position, Double(row.start))
        XCTAssertNil(model.rulerPosition)
        XCTAssertFalse(model.isRulerInteracting)
        XCTAssertTrue(model.landmarks === landmarks)
    }

    @MainActor func testPhoneSummariesRefreshAndExpireWithLandmarks() {
        var now = date("2026-06-01T12:00:00Z")
        var points = [fix(0, at: now.addingTimeInterval(-600))]
        let model = HistoryPlaybackModel(pointLoader: { after, completion in completion(points.filter { $0.id > after }) },
            payloadLoader: { _, completion in completion([:]) }, retentionDuration: { 86_400 }, places: { [] },
            landmarkBuilder: immediateLandmarks, landmarkClock: { 0 }, clock: { now })
        model.setConsumerActive(true)
        defer { model.setConsumerActive(false) }
        let interval = DateInterval(start: now.addingTimeInterval(-86_400), end: now.addingTimeInterval(172_800))
        let cached = model.landmarks.daySummaries
        points.append(fix(1, at: now.addingTimeInterval(-300), north: 100))
        model.reload()
        XCTAssertEqual(model.landmarks.daySummaries.summaries(in: interval).first?.pointCount, 1)
        model.refreshLandmarks()
        XCTAssertEqual(model.landmarks.daySummaries.summaries(in: interval).first?.pointCount, 2)
        XCTAssertEqual(cached.summaries(in: interval).first?.pointCount, 1, "Published snapshots remain immutable")
        model.setConsumerActive(false)
        now = now.addingTimeInterval(90_000)
        points.append(fix(2, at: now.addingTimeInterval(-60), north: 200))
        model.setConsumerActive(true)
        XCTAssertEqual(model.landmarks.daySummaries.summaries(in: interval).map(\.pointCount), [1])
        XCTAssertEqual(model.landmarks.daySummaries.firstDay, Calendar.current.startOfDay(for: points.last!.timestamp))
    }

    @MainActor func testGoDoesNotJumpToPhoneHistoryWhenSelectedDayIsNotDownloaded() {
        let points = twoStops(start: Date().addingTimeInterval(-3_600))
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) },
            payloadLoader: { _, completion in completion([:]) }, places: { [] },
            landmarkBuilder: immediateLandmarks, clock: { points.last!.timestamp })
        model.setConsumerActive(true)
        defer { model.setConsumerActive(false) }
        model.scrub(pointAt: 6)
        let day = Calendar.current.startOfDay(for: points[6].timestamp)
        let provider = StubSummaries(firstDay: day, days: [
            HistoryDaySummary(day: day, distance: nil, pointCount: 0, state: .notDownloaded)
        ])
        let view = HistoryGoToView(history: model, daySummaries: provider)
        var dismissals = 0
        view.go { dismissals += 1 }
        XCTAssertEqual(dismissals, 0)
        XCTAssertEqual(model.selectedIndex, 6)
        HistoryGoToView(history: model).go { dismissals += 1 }
        XCTAssertEqual(dismissals, 1, "A downloaded selection still uses the native Go action")
    }

    private struct StubSummaries: HistoryDaySummaryProvider {
        let firstDay: Date?
        let days: [HistoryDaySummary]
        func summaries(in interval: DateInterval) -> [HistoryDaySummary] {
            days.filter { $0.day >= interval.start && $0.day < interval.end }
        }
    }

    @MainActor private func immediateLandmarks(points: [RecordedLocation], timeline: ReplayTimeline, places: [WifiPlace],
                                              calendar: Calendar, locale: Locale, completion: @escaping (HistoryLandmarks) -> Void) {
        completion(HistoryLandmarks(points: points, timeline: timeline, places: places, calendar: calendar, locale: locale))
    }

    private func makeCalendar(_ zone: String = "America/New_York") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: zone)!
        return calendar
    }

    private func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }

    private func fix(_ index: Int, at time: Date, north: Double = 0) -> RecordedLocation {
        RecordedLocation(id: Int64(index + 1), timestamp: time, latitude: 45 + north / 111_195, longitude: -122)
    }

    private func makeLandmarks(_ points: [RecordedLocation], calendar: Calendar? = nil) -> HistoryLandmarks {
        HistoryLandmarks(points: points, timeline: ReplayTimeline(points: points), places: [],
                         calendar: calendar ?? self.makeCalendar(), locale: Locale(identifier: "en_US_POSIX"))
    }

    private func twoStops(start: Date) -> [RecordedLocation] {
        (0...5).map { fix($0, at: start.addingTimeInterval(Double($0) * 60)) }
            + (6...11).map { fix($0, at: start.addingTimeInterval(1_200 + Double($0 - 6) * 60), north: 1_000) }
    }
}
