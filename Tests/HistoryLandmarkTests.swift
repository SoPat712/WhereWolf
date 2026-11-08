import XCTest
import MapKit
@testable import WhereWolf

final class HistoryLandmarkTests: XCTestCase {
    func testTimeLevelsKeepNeighboringMarksAtLeastSixtyScreenPointsApart() {
        let points = route(count: 8_641, every: 10, metersPerPoint: 10)
        let landmarks = makeLandmarks(points)
        let range = 0.0...Double(points.count - 1)
        let scales: [(Double, Int)] = [(1, 0), (2, 1), (10, 2), (30, 3), (100, 4)]

        for (pointsPerBar, expectedLevel) in scales {
            let level = landmarks.timeLevel(in: range, pointsPerBar: pointsPerBar, spacing: 12)
            XCTAssertEqual(level, expectedLevel, "points per bar: \(pointsPerBar)")
            let marks = HistoryLandmarks.visibleMarks(landmarks.timeMarks[level], in: range)
            XCTAssertGreaterThan(marks.count, 1)
            for (previous, next) in zip(marks, marks.dropFirst()) {
                XCTAssertGreaterThanOrEqual(Double(next.index - previous.index) * 12 / pointsPerBar, 60)
            }
        }
        XCTAssertEqual(HistoryLandmarks.timeMinutes, [1, 5, 15, 60, 360])
    }

    func testTimeLevelFollowsTimeRatherThanFixDensity() {
        var points = route(count: 361, every: 10, metersPerPoint: 10)
        let start = points[0].timestamp
        points += (1...60).map {
            fix(360 + $0, at: start.addingTimeInterval(3_600 + Double($0) * 60), north: 3_600 + Double($0) * 100)
        }
        let landmarks = makeLandmarks(points)

        // Fixes a minute apart take six ten-second slots each, so both stretches label every 5 minutes.
        XCTAssertEqual(landmarks.rulerSpacing.slotDuration, 10)
        XCTAssertEqual(landmarks.timeLevel(in: 0...350, pointsPerBar: 2, spacing: 12), 1)
        XCTAssertEqual(landmarks.timeLevel(in: 361...420, pointsPerBar: 2, spacing: 12), 1)
    }

    func testLocalMidnightsFollowSpringAndFallDayLengths() {
        let cases: [(String, [String], [TimeInterval])] = [
            ("2026-03-07T05:00:00Z", ["2026-03-07T05:00:00Z", "2026-03-08T05:00:00Z",
                                      "2026-03-09T04:00:00Z", "2026-03-10T04:00:00Z"],
             [86_400, 82_800, 86_400]),
            ("2026-10-31T04:00:00Z", ["2026-10-31T04:00:00Z", "2026-11-01T04:00:00Z",
                                      "2026-11-02T05:00:00Z", "2026-11-03T05:00:00Z"],
             [86_400, 90_000, 86_400])
        ]
        for (first, midnights, lengths) in cases {
            let start = date(first)
            let end = date(midnights.last!)
            let count = Int(end.timeIntervalSince(start) / 1_800) + 1
            let points = route(count: count, start: start, every: 1_800, metersPerPoint: 100)
            let landmarks = makeLandmarks(points)

            XCTAssertEqual(landmarks.days.map(\.time), midnights.map(date))
            XCTAssertEqual(zip(landmarks.days, landmarks.days.dropFirst()).map {
                $0.1.time.timeIntervalSince($0.0.time)
            }, lengths)
            for mark in landmarks.days {
                XCTAssertEqual(points[mark.index].timestamp, mark.time)
                XCTAssertEqual(calendar.component(.hour, from: mark.time), 0)
            }
        }
    }

    func testHourlyMarksSkipTheSpringHourAndRetainBothFallHours() {
        let spring = makeLandmarks(route(count: 24, start: date("2026-03-08T05:00:00Z"),
                                     every: 3_600, metersPerPoint: 100))
        let fall = makeLandmarks(route(count: 26, start: date("2026-11-01T04:00:00Z"),
                                   every: 3_600, metersPerPoint: 100))
        let springHours = spring.timeMarks[3]
        let fallHours = fall.timeMarks[3]

        XCTAssertEqual(springHours.count, 24)
        XCTAssertFalse(springHours.contains { calendar.component(.hour, from: $0.time) == 2 })
        let repeated = fallHours.filter { calendar.component(.hour, from: $0.time) == 1 }
        XCTAssertEqual(fallHours.count, 26)
        XCTAssertEqual(repeated.count, 2)
        XCTAssertEqual(repeated[1].time.timeIntervalSince(repeated[0].time), 3_600)
        XCTAssertNotEqual(repeated[0].index, repeated[1].index)
        for landmarks in [spring, fall] {
            XCTAssertEqual(landmarks.timeMarks[4].map { calendar.component(.hour, from: $0.time) }, [0, 6, 12, 18, 0])
        }
        XCTAssertEqual(spring.timeMarks[4][1].time.timeIntervalSince(spring.timeMarks[4][0].time), 5 * 3_600)
        XCTAssertEqual(fall.timeMarks[4][1].time.timeIntervalSince(fall.timeMarks[4][0].time), 7 * 3_600)
    }

    @MainActor func testMidnightMarkUsesTheFirstRecordedPointAfterTheBoundary() {
        let points = [fix(0, at: date("2026-06-02T03:55:00Z"), north: 0),
                      fix(1, at: date("2026-06-02T04:10:00Z"), north: 100),
                      fix(2, at: date("2026-06-02T04:40:00Z"), north: 200)]
        let landmarks = makeLandmarks(points)
        let marks = landmarks.days

        XCTAssertEqual(marks.count, 1)
        XCTAssertEqual(marks[0].index, 1)
        XCTAssertEqual(marks[0].time, date("2026-06-02T04:00:00Z"))
        XCTAssertEqual(landmarks.text(for: marks[0]), "Tue")
    }

    func testMinuteMarksMapToTheFirstFixAfterEachBoundary() {
        let timestamps = ["2026-06-01T12:00:45Z", "2026-06-01T12:01:05Z",
                          "2026-06-01T12:01:55Z", "2026-06-01T12:02:15Z"].map(date)
        let points = timestamps.enumerated().map {
            fix($0.offset, at: $0.element, north: Double($0.offset) * 100)
        }
        let marks = makeLandmarks(points).timeMarks[0]

        XCTAssertEqual(marks.map(\.time), [date("2026-06-01T12:01:00Z"), date("2026-06-01T12:02:00Z")])
        XCTAssertEqual(marks.map(\.index), [1, 3])
    }

    func testStopsKeepReplayStayBoundsAndMatchTheNearestPlaceToTheirCenter() {
        let start = date("2026-06-01T12:00:00Z")
        let points = (0...10).map {
            fix($0, at: start.addingTimeInterval(Double($0) * 60), north: $0.isMultiple(of: 2) ? 12 : -12)
        }
        let timeline = ReplayTimeline(points: points)
        let near = place("Near", north: 2, symbol: "house.fill", color: "green")
        let farther = place("Farther", north: 20, symbol: "building.2.fill", color: "blue")
        let landmarks = HistoryLandmarks(points: points, timeline: timeline, places: [farther, near],
                                        calendar: calendar, locale: locale)

        XCTAssertEqual(timeline.stays, [ReplayStay(start: 0, end: 10, span: 600)])
        XCTAssertEqual(landmarks.stops.map(\.id), timeline.stays.map(\.start))
        XCTAssertEqual(landmarks.stops.map(\.end), timeline.stays.map(\.end))
        XCTAssertEqual(landmarks.stops[0].name, "Near")
        XCTAssertEqual(landmarks.stops[0].symbol, "house.fill")
        XCTAssertEqual(landmarks.stops[0].color, "green")
        XCTAssertEqual(landmarks.stops[0].arrival, points[0].timestamp)
        XCTAssertEqual(landmarks.stops[0].departure, points[10].timestamp)
    }

    func testSilencesOfTenMinutesOrMoreAreMarkedAsMissingData() {
        var points = route(count: 6, every: 60, metersPerPoint: 0)
        let start = points[0].timestamp
        points.append(fix(6, at: start.addingTimeInterval(300 + 540), north: 0))
        points.append(fix(7, at: start.addingTimeInterval(840 + 3_870), north: 5_000))
        let landmarks = makeLandmarks(points)

        XCTAssertEqual(landmarks.gaps, [HistoryGap(index: 7, duration: 3_870)])
        XCTAssertEqual(landmarks.gaps.first?.label, "No data · 1h 5m")
        XCTAssertEqual(Array(landmarks.visibleGaps(in: 0...6)), landmarks.gaps)
        XCTAssertEqual(Array(landmarks.visibleGaps(in: 7...7)), landmarks.gaps)
        XCTAssertTrue(landmarks.visibleGaps(in: 0...5).isEmpty)
        XCTAssertLessThan(HistoryRulerLabelLayout.Priority.stop.rawValue, HistoryRulerLabelLayout.Priority.gap.rawValue)
        XCTAssertLessThan(HistoryRulerLabelLayout.Priority.gap.rawValue, HistoryRulerLabelLayout.Priority.time.rawValue)
    }

    func testTheRulerShowsTimeWithStopsCappedCloseUpAndCompressedZoomedOut() throws {
        let points = parkedDrive()
        let landmarks = makeLandmarks(points)
        let spacing = landmarks.rulerSpacing
        let stop = try XCTUnwrap(landmarks.stops.first)
        XCTAssertEqual(landmarks.stops.count, 1)
        XCTAssertEqual(stop.end, 33)
        XCTAssertEqual(spacing.slotDuration, 1, "A slot is the typical interval between moving fixes.")
        // The stop is a stretch; the 40-second step into it is moving time.
        XCTAssertEqual(spacing.stretches.map { [$0.start, $0.end] }, [[stop.id, stop.end]])
        let stretch = spacing.stretches[0]
        let length = stop.departure.timeIntervalSince(stop.arrival)
        XCTAssertEqual(stretch.nearBars, 4 + 1.5 * log2(length / 300), accuracy: 1e-9)
        XCTAssertEqual(stretch.nearBars, 9.5, accuracy: 0.5, "About an hour keeps about 10 bars close up.")
        XCTAssertEqual(stretch.farSlots, 300 * (length / 300).squareRoot(), accuracy: 1e-9)

        for pointsPerBar in [1.0, 2, 20, 200, 2_000] {
            let map = spacing.scaled(pointsPerBar)
            XCTAssertEqual(map.bars(to: Double(stop.end)) - map.bars(to: Double(stop.id)),
                           min(stretch.nearBars, stretch.farSlots / pointsPerBar), accuracy: 1e-9)
            // Moving fixes a second apart keep one slot each.
            XCTAssertEqual(map.bars(to: 10), 10 / pointsPerBar, accuracy: 1e-12)
            XCTAssertEqual(map.bars(to: 50) - map.bars(to: 40), 10 / pointsPerBar, accuracy: 1e-9)
            var previous = -Double.infinity
            for index in stride(from: 0.0, through: Double(points.count), by: 0.125) {
                let bars = map.bars(to: index)
                XCTAssertGreaterThan(bars, previous)
                previous = bars
                XCTAssertEqual(map.index(atBars: bars), index, accuracy: 1e-9)
            }
        }
        XCTAssertLessThan(stretch.farSlots / 2_000, stretch.nearBars, "Zoomed out the stop shrinks with the scale.")
        // Within the silence, width follows time.
        let map = spacing.scaled(1)
        XCTAssertEqual(map.bars(to: 32.5) - map.bars(to: 32), 2 * (map.bars(to: 32.25) - map.bars(to: 32)), accuracy: 1e-9)
        let stretches = spacing.stretches.reduce(0) { $0 + $1.bars(pointsPerBar: 1) }
        XCTAssertEqual(spacing.totalBars(pointCount: points.count, pointsPerBar: 1), 29 + 40 + 30 + 1 + stretches,
                       accuracy: 1e-9, "Two drives of a fix a second, the walk in, Live's slot and the stop.")
    }

    func testTicksAreEvenAlongMovingTimeAndLeaveStopsClear() throws {
        let points = parkedDrive()
        let landmarks = makeLandmarks(points)
        let stop = try XCTUnwrap(landmarks.stops.first)
        let map = landmarks.rulerSpacing.scaled(1)
        let live = map.slots(to: Double(points.count))
        var previous: Double?
        for slot in stride(from: 0.0, through: live, by: 1) {
            let index = map.index(atSlots: slot)
            XCTAssertEqual(map.slots(to: index), slot, accuracy: 1e-9)
            XCTAssertFalse(index > Double(stop.id) && index < Double(stop.end), "No tick inside the stop.")
            if let previous {
                let gap = map.bars(to: index) - map.bars(to: previous)
                if index <= Double(stop.id) || previous >= Double(stop.end) {
                    XCTAssertEqual(gap, 1, accuracy: 1e-9, "One bar between ticks while moving.")
                }
            }
            previous = index
        }
        XCTAssertEqual(map.index(atSlots: map.slots(to: Double(stop.id))), Double(stop.end),
                       "A tick at the stop sits at its departure.")
    }

    func testANightAtHomeLeavesRoomOnTheRulerCloseUp() {
        var points = route(count: 30, every: 1, metersPerPoint: 15)
        let home = points.last!.timestamp
        // Parked twelve hours with a fix every 5 minutes, then the first fix of the morning drive.
        points += (1...144).map { fix(29 + $0, at: home.addingTimeInterval(Double($0) * 300), north: 435) }
        points += (1...30).map {
            fix(173 + $0, at: home.addingTimeInterval(43_200 + Double($0)), north: 435 + Double($0) * 15)
        }
        let spacing = makeLandmarks(points).rulerSpacing
        let night = spacing.stretches.max { $0.duration < $1.duration }
        XCTAssertGreaterThan(night?.duration ?? 0, 11 * 3_600)
        XCTAssertLessThan(night?.nearBars ?? .infinity, 16, "Twelve hours stays well under a ruler's width.")
    }

    func testDenseAndSparseMovementShareOneTimeScale() {
        // Forty seconds at a fix a second, then walking with a fix every 5 seconds.
        var points = route(count: 41, every: 1, metersPerPoint: 15)
        let start = points.last!.timestamp
        points += (1...20).map { fix(40 + $0, at: start.addingTimeInterval(Double($0) * 5), north: 600 + Double($0) * 7) }
        let spacing = makeLandmarks(points).rulerSpacing
        XCTAssertEqual(spacing.slotDuration, 1)
        XCTAssertTrue(spacing.stretches.isEmpty)
        for pointsPerBar in [1.0, 20] {
            let map = spacing.scaled(pointsPerBar)
            XCTAssertEqual(map.bars(to: 50) - map.bars(to: 45), map.bars(to: 35) - map.bars(to: 10),
                           accuracy: 1e-9, "Five walking fixes and 25 driving fixes cover 25 seconds alike.")
        }
    }

    func testTheRulerLadderFitsStopsAndSilencesInOneWidth() {
        let points = parkedDrive()
        let spacing = makeLandmarks(points).rulerSpacing
        let detents = HistoryRulerCoarseDrag.Detents(tickCount: points.count, rulerWidth: 350, spacing: spacing)
        let coarsest = detents.steps[0]
        XCTAssertLessThanOrEqual(spacing.totalBars(pointCount: points.count, pointsPerBar: coarsest) * 18, 350)
        XCTAssertGreaterThan(spacing.totalBars(pointCount: points.count, pointsPerBar: detents.steps[1]) * 18, 350)
        XCTAssertGreaterThan(coarsest, HistoryRulerCoarseDrag.Detents(tickCount: points.count, rulerWidth: 350).steps[0])
    }

    func testTimeMarksInsideASilenceSitAtTheirExactTime() {
        let points = parkedDrive()
        let landmarks = makeLandmarks(points)
        let start = points[32].timestamp, end = points[33].timestamp
        let silent = landmarks.timeMarks[0].filter { $0.index == 33 && $0.time < end }
        XCTAssertGreaterThan(silent.count, 50)
        for mark in silent {
            XCTAssertEqual(landmarks.position(of: mark),
                           32 + mark.time.timeIntervalSince(start) / end.timeIntervalSince(start), accuracy: 1e-9)
        }
        for mark in landmarks.timeMarks[0] where points[mark.index].timestamp == mark.time {
            XCTAssertEqual(landmarks.position(of: mark), Double(mark.index))
        }
    }

    func testAStopExplainsItsOwnSilence() {
        var points = route(count: 6, every: 60, metersPerPoint: 0)
        let start = points[0].timestamp
        points.append(fix(6, at: start.addingTimeInterval(300 + 540), north: 0))
        // Parked, then the first fix across the lot: the silence belongs to the stop.
        points.append(fix(7, at: start.addingTimeInterval(840 + 3_870), north: 64))
        let landmarks = makeLandmarks(points)

        XCTAssertEqual(landmarks.stops.map(\.id), [0])
        XCTAssertEqual(landmarks.stops.map(\.end), [7])
        XCTAssertTrue(landmarks.gaps.isEmpty)
    }

    func testAnOutsidePlaceLeavesTheStopUnnamedAndDoesNotCreateStopsOnAMovingRoute() {
        let points = route(count: 11, every: 60, metersPerPoint: 0)
        let unnamed = makeLandmarks(points, places: [place("Outside", north: 400)])

        XCTAssertEqual(unnamed.stops.count, 1)
        XCTAssertNil(unnamed.stops[0].name)
        XCTAssertEqual(unnamed.stops[0].title, "Stop")
        XCTAssertEqual(unnamed.stops[0].label, "Stop · 10 min")
        XCTAssertEqual(unnamed.stops[0].symbol, "mappin")
        XCTAssertEqual(unnamed.stops[0].color, "gray")
        let moving = makeLandmarks(route(count: 11, every: 60, metersPerPoint: 100),
                               places: [place("Nearby", north: 500)])
        XCTAssertTrue(moving.stops.isEmpty)
        XCTAssertTrue(moving.boundaries.isEmpty)
    }

    func testStayCenterMatchingUnwrapsTheDateline() {
        let start = date("2026-06-01T12:00:00Z")
        let points = (0...10).map { index in
            RecordedLocation(id: Int64(index), timestamp: start.addingTimeInterval(Double(index) * 60),
                             latitude: 0, longitude: index.isMultiple(of: 2) ? 179.99995 : -179.99995)
        }
        let nearby = WifiPlace(id: "dateline", name: "Dateline", latitude: 0, longitude: 179.99999)
        let far = WifiPlace(id: "greenwich", name: "Greenwich", latitude: 0, longitude: 0)
        let landmarks = makeLandmarks(points, places: [far, nearby])

        XCTAssertEqual(landmarks.stops.count, 1)
        XCTAssertEqual(landmarks.stops[0].name, "Dateline")
    }

    func testLabelCollisionsPreferDaysThenStopsThenTimesAndKeepAStopSymbol() {
        let day = CGRect(x: 40, y: 0, width: 30, height: 12)
        let symbol = CGRect(x: 10, y: 0, width: 10, height: 12)
        let placements = HistoryRulerLabelLayout.resolve([
            .init(id: 3, priority: .time, frame: CGRect(x: 80, y: 0, width: 25, height: 12)),
            .init(id: 2, priority: .stop, frame: CGRect(x: 10, y: 0, width: 55, height: 12), symbolFrame: symbol),
            .init(id: 4, priority: .time, frame: CGRect(x: 31, y: 0, width: 7, height: 12)),
            .init(id: 5, priority: .stop, frame: CGRect(x: 45, y: 0, width: 40, height: 12)),
            .init(id: 1, priority: .day, frame: day)
        ])

        XCTAssertEqual(placements.map(\.id), [1, 2, 3])
        XCTAssertEqual(placements.map(\.symbolOnly), [false, true, false])
        XCTAssertEqual(placements[0].frame, day)
        XCTAssertEqual(placements[1].frame, symbol)
    }

    func testEqualPriorityLabelsResolveDeterministicallyAndUseFullLabelsWhenTheyFit() {
        let frame = CGRect(x: 10, y: 0, width: 50, height: 12)
        let placements = HistoryRulerLabelLayout.resolve([
            .init(id: 12, priority: .stop, frame: frame),
            .init(id: 11, priority: .stop, frame: frame,
                  symbolFrame: CGRect(x: 10, y: 0, width: 10, height: 12))
        ])

        XCTAssertEqual(placements.map(\.id), [11])
        XCTAssertEqual(placements[0].frame, frame)
        XCTAssertFalse(placements[0].symbolOnly)
    }

    // The stop in these tests is wider than its fixes, so positions are measured in screen points.
    func testSnapEntersAtSixPointsAndHoldsUntilFingerTravelExceedsTen() {
        let points = route(count: 11, every: 60, metersPerPoint: 0)
        let landmarks = makeLandmarks(points)
        let position = rulerPositions(landmarks, pointsPerBar: 2, spacing: 12)
        var snap = HistoryStopSnap()

        let outside = snap.move(position: position(6.1, 10), translation: 0, finger: 99, pointsPerBar: 2,
                                spacing: 12, pointCount: points.count, landmarks: landmarks)
        XCTAssertEqual(outside, position(6.1, 10), accuracy: 1e-9)
        XCTAssertNil(snap.boundary)
        let entry = snap.move(position: position(11.9, 10), translation: -6, finger: 100, pointsPerBar: 2,
                              spacing: 12, pointCount: points.count, landmarks: landmarks)
        XCTAssertEqual(entry, 1)
        XCTAssertEqual(snap.boundary?.index, 10)
        XCTAssertEqual(snap.boundary?.event, "Left a stop")
        let held = snap.move(position: entry, translation: 30, finger: 110, pointsPerBar: 2,
                             spacing: 12, pointCount: points.count, landmarks: landmarks)
        XCTAssertEqual(held, entry)
        XCTAssertNotNil(snap.boundary)

        let released = snap.move(position: held, translation: 30, finger: 110.1, pointsPerBar: 2,
                                 spacing: 12, pointCount: points.count, landmarks: landmarks)
        XCTAssertEqual(released, held, "Escaping a stop must rebase without moving the ruler")
        XCTAssertNil(snap.boundary)
        snap.reset()
        let arrival = snap.move(position: position(-5.9, 0), translation: 0, finger: 200, pointsPerBar: 2,
                                spacing: 12, pointCount: points.count, landmarks: landmarks)
        XCTAssertEqual(arrival, 11)
        XCTAssertEqual(snap.boundary?.index, 0)
        XCTAssertEqual(snap.boundary?.event, "Arrived at a stop")
    }

    func testSnapDoesNotImmediatelyRecaptureAReleasedBoundary() {
        let points = route(count: 11, every: 60, metersPerPoint: 0)
        let landmarks = makeLandmarks(points)
        let position = rulerPositions(landmarks, pointsPerBar: 2, spacing: 12)
        var snap = HistoryStopSnap()
        let entry = snap.move(position: position(11.9, 10), translation: -6, finger: 100, pointsPerBar: 2,
                              spacing: 12, pointCount: points.count, landmarks: landmarks)
        _ = snap.move(position: entry, translation: 12, finger: 111, pointsPerBar: 2,
                      spacing: 12, pointCount: points.count, landmarks: landmarks)
        let nearby = snap.move(position: entry, translation: 3, finger: 114, pointsPerBar: 2,
                               spacing: 12, pointCount: points.count, landmarks: landmarks)
        XCTAssertEqual(nearby, position(3, 10), accuracy: 1e-9)
        XCTAssertNil(snap.boundary)
        let away = snap.move(position: nearby, translation: 4, finger: 118, pointsPerBar: 2,
                             spacing: 12, pointCount: points.count, landmarks: landmarks)
        XCTAssertEqual(away, position(7, 10), accuracy: 1e-9)
        XCTAssertNil(snap.boundary)
        let returned = snap.move(position: away, translation: -4, finger: 114, pointsPerBar: 2,
                                 spacing: 12, pointCount: points.count, landmarks: landmarks)
        XCTAssertEqual(returned, entry)
        XCTAssertEqual(snap.boundary?.index, 10)
    }

    func testSnapKeepsItsFingerAnchorAcrossCoarseDetentChanges() {
        let points = route(count: 11, every: 60, metersPerPoint: 0)
        let landmarks = makeLandmarks(points)
        let position = rulerPositions(landmarks, pointsPerBar: 2, spacing: 12)
        var snap = HistoryStopSnap()
        let entry = snap.move(position: position(11.9, 10), translation: -6, finger: 100, pointsPerBar: 2,
                              spacing: 12, pointCount: points.count, landmarks: landmarks)
        let held = snap.move(position: entry, translation: 9, finger: 109, pointsPerBar: 5,
                             spacing: 18, pointCount: points.count, landmarks: landmarks)
        XCTAssertEqual(held, entry)
        XCTAssertEqual(snap.boundary?.index, 10)
        let released = snap.move(position: held, translation: 2, finger: 111, pointsPerBar: 5,
                                 spacing: 18, pointCount: points.count, landmarks: landmarks)
        XCTAssertEqual(released, held)
        XCTAssertNil(snap.boundary)
    }

    func testPointPrecisionAndResetClearTheSnap() {
        let points = route(count: 11, every: 60, metersPerPoint: 0)
        let landmarks = makeLandmarks(points)
        let position = rulerPositions(landmarks, pointsPerBar: 2, spacing: 12)
        var snap = HistoryStopSnap()
        let entry = snap.move(position: position(11.9, 10), translation: -6, finger: 100, pointsPerBar: 2,
                              spacing: 12, pointCount: points.count, landmarks: landmarks)
        let precise = snap.move(position: entry, translation: 4, finger: 104, pointsPerBar: 1,
                                spacing: 12, pointCount: points.count, landmarks: landmarks)
        XCTAssertEqual(precise, rulerPositions(landmarks, pointsPerBar: 1, spacing: 12)(4, 10), accuracy: 1e-9)
        XCTAssertNil(snap.boundary)
        _ = snap.move(position: position(11.9, 10), translation: -6, finger: 110, pointsPerBar: 2,
                      spacing: 12, pointCount: points.count, landmarks: landmarks)
        XCTAssertNotNil(snap.boundary)
        snap.reset()
        XCTAssertNil(snap.boundary)
        let afterReset = snap.move(position: entry, translation: 0, finger: 110, pointsPerBar: 2,
                                   spacing: 12, pointCount: points.count, landmarks: landmarks)
        XCTAssertEqual(afterReset, entry)
        XCTAssertNotNil(snap.boundary)
    }

    func testStopBoundaryNavigationIsStrictInBothDirectionsAndStopsAtTheEnds() {
        let (points, places) = twoStops()
        let landmarks = makeLandmarks(points, places: places)

        XCTAssertEqual(landmarks.boundaries.map(\.index), [0, 5, 6, 11])
        XCTAssertEqual(landmarks.boundaries.map(\.isArrival), [true, false, true, false])
        XCTAssertEqual(landmarks.boundaries.map(\.event),
                       ["Arrived at Home", "Left Home", "Arrived at Work", "Left Work"])
        for (position, expected) in [(-1.0, 0), (0, 5), (5, 6), (6, 11)] {
            XCTAssertEqual(landmarks.boundary(from: position, direction: 1)?.index, expected)
        }
        for (position, expected) in [(12.0, 11), (11, 6), (6, 5), (5, 0)] {
            XCTAssertEqual(landmarks.boundary(from: position, direction: -1)?.index, expected)
        }
        XCTAssertNil(landmarks.boundary(from: 11, direction: 1))
        XCTAssertNil(landmarks.boundary(from: 0, direction: -1))
        XCTAssertNil(landmarks.boundary(from: 4, direction: 0))
        XCTAssertEqual(landmarks.boundaries.map(\.time), [0, 5, 6, 11].map { points[$0].timestamp })
        XCTAssertEqual(landmarks.stop(containing: 2.5)?.name, "Home")
        XCTAssertNil(landmarks.stop(containing: 5.5))
        XCTAssertEqual(landmarks.visibleStops(in: 5...6).map(\.name), ["Home", "Work"])
        XCTAssertEqual(landmarks.visibleStops(in: 5.5...6).map(\.name), ["Work"])
    }

    func testNearestPointUsesTimestampDistanceAndEarlierPointForTies() {
        let start = date("2026-06-01T12:00:00Z")
        let points = [0.0, 60, 300].enumerated().map {
            fix($0.offset, at: start.addingTimeInterval($0.element), north: Double($0.offset) * 100)
        }
        let landmarks = makeLandmarks(points)
        for (offset, expected) in [(-60.0, 0), (0, 0), (30, 0), (50, 1), (180, 1), (181, 2), (600, 2)] {
            XCTAssertEqual(landmarks.nearestPoint(to: start.addingTimeInterval(offset)), expected)
        }
        let now = start.addingTimeInterval(600)
        XCTAssertEqual(landmarks.window(now: now), start...now)
        let beforeArchive = start.addingTimeInterval(-60)
        XCTAssertEqual(landmarks.window(now: beforeArchive), beforeArchive...beforeArchive)
    }

    func testEmptyAndMovingHistoriesHaveNoStopNavigation() {
        let empty = makeLandmarks([])
        XCTAssertTrue(empty.stops.isEmpty)
        XCTAssertTrue(empty.boundaries.isEmpty)
        XCTAssertTrue(empty.days.isEmpty)
        XCTAssertTrue(empty.timeMarks.allSatisfy(\.isEmpty))
        XCTAssertTrue(empty.journey.isEmpty)
        XCTAssertNil(empty.nearestPoint(to: date("2026-06-01T12:00:00Z")))
        XCTAssertNil(empty.window(now: date("2026-06-01T12:00:00Z")))
        XCTAssertNil(empty.viewingRow(at: 0))
        for history in [empty, makeLandmarks(route(count: 20, every: 10, metersPerPoint: 100))] {
            XCTAssertNil(history.boundary(from: 5, direction: 1))
            XCTAssertNil(history.boundary(from: 5, direction: -1))
        }
    }

    func testJourneyListsNewestDaysAndRowsFirst() {
        let (points, places) = twoStops(start: date("2026-06-02T03:57:00Z"))
        let landmarks = makeLandmarks(points, places: places)

        XCTAssertEqual(landmarks.journey.map(\.id), [date("2026-06-02T04:00:00Z"), date("2026-06-01T04:00:00Z")])
        XCTAssertEqual(landmarks.journey[0].rows.map(\.start), [6, 5, 3])
        XCTAssertEqual(landmarks.journey[0].rows.map(\.end), [11, 6, 5])
        XCTAssertEqual(landmarks.journey[1].rows.map(\.start), [0])
        XCTAssertEqual(landmarks.journey[1].rows.map(\.end), [2])
        XCTAssertEqual(landmarks.journey[0].rows.last?.title, "Home")
        XCTAssertEqual(landmarks.journey[1].rows.first?.title, "Home")
        XCTAssertEqual(landmarks.viewingRow(at: 2.5)?.start, 0)
        let rows = landmarks.journey.flatMap(\.rows)
        XCTAssertEqual(Set(rows.map(\.id)).count, rows.count)
        for day in landmarks.journey {
            for row in day.rows {
                XCTAssertEqual(calendar.startOfDay(for: row.startTime), day.id)
                XCTAssertEqual(calendar.startOfDay(for: row.endTime), day.id)
            }
            XCTAssertTrue(zip(day.rows, day.rows.dropFirst()).allSatisfy { $0.0.startTime >= $0.1.startTime })
        }
    }

    func testJourneyMovementNamesUseInferredActivityAndFlyingSpeed() {
        let cases: [(Double, String, String)] = [
            (1, "Walk", "figure.walk"), (12, "Drive", "car.fill"),
            (6, "Moving", "location.north.line"), (100, "Flight", "airplane")
        ]
        for (speed, title, symbol) in cases {
            let points = route(count: 9, every: 10, metersPerPoint: speed * 10)
            let rows = makeLandmarks(points).journey.flatMap(\.rows)
            XCTAssertEqual(rows.count, 1)
            XCTAssertEqual(rows[0].title, title, "speed: \(speed)")
            XCTAssertEqual(rows[0].symbol, symbol)
            XCTAssertFalse(rows[0].isStop)
        }
    }

    func testFlightTakesPrecedenceOverThePredominantInferredMovement() {
        let start = date("2026-06-01T12:00:00Z")
        let points = (0...12).map { index in
            fix(index, at: start.addingTimeInterval(Double(index) * 60),
                north: index < 10 ? Double(index) * 60 : 600 + Double(index - 9) * 12_000)
        }
        let timeline = ReplayTimeline(points: points)
        XCTAssertEqual(timeline.inferredActivity(at: 0), .walking)
        XCTAssertEqual(timeline.inferredActivity(at: 12), .flying)
        XCTAssertEqual(makeLandmarks(points).journey.first?.rows.first?.title, "Flight")
    }

    func testAStrayFixFarOffADriveDoesNotNameItAFlight() {
        let start = date("2026-06-01T12:00:00Z")
        var points = (0..<40).map { fix($0, at: start.addingTimeInterval(Double($0) * 60), north: Double($0) * 900) }
        // One sparse fix lands 10 km off the road, so its neighbors' net speeds look like flying.
        let stray = points[20]
        points[20] = RecordedLocation(id: stray.id, timestamp: stray.timestamp, latitude: stray.latitude,
                                      longitude: stray.longitude + 10_000 / (111_195 * cos(45 * Double.pi / 180)))
        let timeline = ReplayTimeline(points: points)
        XCTAssertEqual(timeline.inferredActivity(at: 19), .flying)
        let row = makeLandmarks(points).journey.first?.rows.first
        XCTAssertEqual(row?.title, "Drive")
        XCTAssertEqual(row?.symbol, "car.fill")
    }

    func testJourneyDistanceUsesTheSameJumpCorrectionAsTheReplayOverlay() {
        let start = date("2026-06-01T12:00:00Z")
        let north = [0.0, 10, 20, 1_000, 40, 50, 60]
        let points = north.enumerated().map {
            fix($0.offset, at: start.addingTimeInterval(Double($0.offset) * 10), north: $0.element)
        }
        let timeline = ReplayTimeline(points: points)
        let landmarks = HistoryLandmarks(points: points, timeline: timeline, places: [],
                                        calendar: calendar, locale: locale)
        let row = landmarks.journey[0].rows[0]
        let raw = zip(points, points.dropFirst()).reduce(0.0) { $0 + ReplayTimeline.distance($1.0, $1.1) }

        XCTAssertGreaterThan(raw, 1_900)
        XCTAssertEqual(row.distance!, 60, accuracy: 0.01)
        XCTAssertEqual(row.distance!, timeline.legDistance(at: points.count - 1)!, accuracy: 0.000001)
        XCTAssertEqual(row.distance!, timeline.distance(from: 0, through: points.count - 1), accuracy: 0.000001)
    }

    func testJourneyDetailsFormatBothUnitsAndViewingIncludesTheEndpoints() {
        let start = date("2026-06-01T12:00:00Z")
        let row = HistoryJourneyRow(start: 2, end: 8, startTime: start, endTime: start.addingTimeInterval(600),
                                    title: "Walk", symbol: "figure.walk", color: "gray", distance: 1_609.344, isStop: false)
        XCTAssertTrue(row.detail(metric: true).hasSuffix(" · 1.6 km"))
        XCTAssertTrue(row.detail(metric: false).hasSuffix(" · 1.0 mi"))
        XCTAssertTrue(row.detail(metric: true).hasPrefix(row.timeRange))
        XCTAssertEqual(row.viewingText(at: 2), "Viewing")
        XCTAssertEqual(row.viewingText(at: 5.5), "Viewing")
        XCTAssertEqual(row.viewingText(at: 8), "Viewing")
        XCTAssertNil(row.viewingText(at: 1.99))
        XCTAssertNil(row.viewingText(at: 8.01))

        let (points, places) = twoStops()
        let landmarks = makeLandmarks(points, places: places)
        let stop = landmarks.viewingRow(at: 5)!
        XCTAssertEqual(stop.title, "Home")
        XCTAssertTrue(stop.isStop)
        XCTAssertEqual(stop.detail(metric: true), stop.timeRange)
        XCTAssertFalse(landmarks.viewingRow(at: 5.5)!.isStop)
        XCTAssertEqual(landmarks.viewingRow(at: 6)?.title, "Work")
        XCTAssertNil(landmarks.viewingRow(at: -1))
        XCTAssertNil(landmarks.viewingRow(at: Double(points.count)))
    }

    func testArithmeticMinuteMarksMatchTheCalendarWalkAcrossDSTAndInAHalfHourZone() {
        let cases: [(String, String, TimeInterval)] = [
            ("America/New_York", "2026-03-08T05:00:00Z", 23 * 3_600),
            ("America/New_York", "2026-11-01T04:00:00Z", 25 * 3_600),
            ("Asia/Kolkata", "2026-06-01T18:30:00Z", 24 * 3_600)
        ]
        for (zone, first, duration) in cases {
            var calendar = self.calendar
            calendar.timeZone = TimeZone(identifier: zone)!
            // Non-minute fixes exercise the first-fix mapping and duplicate mark indices.
            let points = route(count: Int(duration / 137) + 1,
                               start: date(first).addingTimeInterval(-37), every: 137, metersPerPoint: 100)
            let landmarks = HistoryLandmarks(points: points, timeline: ReplayTimeline(points: points), places: [],
                                            calendar: calendar, locale: locale)
            let levels: [(Int?, [HistoryTimeMark])] = [(nil, landmarks.days)]
                + Array(zip(HistoryLandmarks.timeMinutes.map { Optional($0) }, landmarks.timeMarks))
            for (minutes, actual) in levels {
                let expected = calendarWalk(points, minutes: minutes, calendar: calendar, locale: locale)
                XCTAssertEqual(actual.map(\.time), expected.map(\.time), "\(zone), \(String(describing: minutes))")
                XCTAssertEqual(actual.map(\.index), expected.map(\.index), "\(zone), \(String(describing: minutes))")
            }
        }
    }

    @MainActor func testLazyMarkTextMatchesEagerFormattingAndKeepsABoundedCache() {
        for zone in ["America/New_York", "Asia/Kolkata"] {
            var calendar = self.calendar
            calendar.timeZone = TimeZone(identifier: zone)!
            for locale in [self.locale, Locale(identifier: "en_GB"), Locale(identifier: "fr_FR")] {
                let points = route(count: 541, start: date("2026-11-01T03:00:00Z"), every: 60, metersPerPoint: 100)
                let landmarks = HistoryLandmarks(points: points, timeline: ReplayTimeline(points: points), places: [],
                                                calendar: calendar, locale: locale)
                XCTAssertEqual(landmarks.cachedMarkTextCount, 0, "Building metadata must not format labels")
                let levels: [(Int?, [HistoryTimeMark])] = [(nil, landmarks.days)]
                    + Array(zip(HistoryLandmarks.timeMinutes.map { Optional($0) }, landmarks.timeMarks))
                for (minutes, marks) in levels {
                    let expected = calendarWalk(points, minutes: minutes, calendar: calendar, locale: locale)
                    XCTAssertEqual(marks.count, expected.count)
                    for (mark, eager) in zip(marks, expected) {
                        XCTAssertEqual(landmarks.text(for: mark), eager.text)
                        let cached = landmarks.cachedMarkTextCount
                        XCTAssertEqual(landmarks.text(for: mark), eager.text)
                        XCTAssertEqual(landmarks.cachedMarkTextCount, cached)
                        XCTAssertLessThanOrEqual(cached, 128)
                    }
                }
            }
        }
    }

    func testStaleStopSnapAndNavigationClampToTheCurrentPointCount() {
        let points = route(count: 11, every: 60, metersPerPoint: 0)
        let landmarks = makeLandmarks(points)
        var snap = HistoryStopSnap()
        _ = snap.move(position: 1, translation: 0, finger: 0, pointsPerBar: 2,
                      spacing: 12, pointCount: 11, landmarks: landmarks)
        XCTAssertEqual(snap.boundary?.index, 10)
        let held = snap.move(position: 1, translation: 0, finger: 0, pointsPerBar: 2,
                             spacing: 12, pointCount: 3, landmarks: landmarks)
        XCTAssertEqual(held, 1)
        XCTAssertEqual(snap.boundary?.index, 2)
        XCTAssertEqual(landmarks.boundary(from: 0, direction: 1, pointCount: 3)?.index, 2)
        XCTAssertNil(landmarks.boundary(from: 2, direction: 1, pointCount: 3))
        XCTAssertEqual(landmarks.nearestPoint(to: points.last!.timestamp, pointCount: 3), 2)
        XCTAssertNil(landmarks.boundary(from: 0, direction: 1, pointCount: 0))
        XCTAssertNil(landmarks.nearestPoint(to: points.last!.timestamp, pointCount: 0))
        _ = snap.move(position: 0, translation: 0, finger: 0, pointsPerBar: 2,
                      spacing: 12, pointCount: 0, landmarks: landmarks)
        XCTAssertNil(snap.boundary)
    }

    // The round-1 calendar walk is the reference for arithmetic boundaries and eager text.
    private func calendarWalk(_ points: [RecordedLocation], minutes: Int?, calendar: Calendar, locale: Locale)
        -> [(index: Int, time: Date, text: String)] {
        guard let first = points.first?.timestamp, let last = points.last?.timestamp else { return [] }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "EEE"
        if let minutes {
            if minutes >= 60 { formatter.setLocalizedDateFormatFromTemplate("j") }
            else { formatter.dateStyle = .none; formatter.timeStyle = .short }
        }
        var result: [(index: Int, time: Date, text: String)] = []
        var day = calendar.startOfDay(for: first)
        var index = 0
        while day <= last {
            let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
            var boundary = day
            while boundary < nextDay && boundary <= last {
                let components = calendar.dateComponents([.hour, .minute], from: boundary)
                let wallMinute = (components.hour ?? 0) * 60 + (components.minute ?? 0)
                if boundary >= first && (minutes == nil || wallMinute.isMultiple(of: minutes!)) {
                    while index < points.count && points[index].timestamp < boundary { index += 1 }
                    if index < points.count { result.append((index, boundary, formatter.string(from: boundary))) }
                }
                guard minutes != nil else { break }
                boundary = boundary.addingTimeInterval(60)
            }
            day = nextDay
        }
        return result
    }

    private var locale: Locale { Locale(identifier: "en_US_POSIX") }

    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func fix(_ index: Int, at time: Date, north: Double) -> RecordedLocation {
        RecordedLocation(id: Int64(index + 1), timestamp: time, latitude: 45 + north / 111_195,
                         longitude: -122)
    }

    private func route(count: Int, start: Date? = nil, every interval: TimeInterval,
                       metersPerPoint: Double) -> [RecordedLocation] {
        let start = start ?? date("2026-06-01T04:00:00Z")
        return (0..<count).map {
            fix($0, at: start.addingTimeInterval(Double($0) * interval), north: Double($0) * metersPerPoint)
        }
    }

    private func place(_ name: String, north: Double, symbol: String = "mappin", color: String = "blue") -> WifiPlace {
        WifiPlace(id: name, name: name, latitude: 45 + north / 111_195, longitude: -122,
                  symbol: symbol, color: color)
    }

    // A drive at one fix a second, about an hour parked with a few fixes and a long silence, then a drive.
    private func parkedDrive() -> [RecordedLocation] {
        var points = route(count: 30, every: 1, metersPerPoint: 15)
        let parked = points.last!.timestamp
        points += (1...3).map { fix(29 + $0, at: parked.addingTimeInterval(Double($0) * 40), north: 435) }
        points.append(fix(33, at: parked.addingTimeInterval(66 * 60), north: 505))
        points += (1...30).map {
            fix(33 + $0, at: parked.addingTimeInterval(66 * 60 + Double($0)), north: 505 + Double($0) * 15)
        }
        return points
    }

    // The ruler position, in fixes back from Live, a number of screen points older than a point index.
    private func rulerPositions(_ landmarks: HistoryLandmarks, pointsPerBar: Double,
                                spacing: Double) -> (Double, Int) -> Double {
        let map = landmarks.rulerSpacing.scaled(pointsPerBar)
        let count = Double(landmarks.timestamps.count)
        return { points, index in count - map.index(atBars: map.bars(to: Double(index)) - points / spacing) }
    }

    private func makeLandmarks(_ points: [RecordedLocation], places: [WifiPlace] = []) -> HistoryLandmarks {
        HistoryLandmarks(points: points, timeline: ReplayTimeline(points: points), places: places,
                         calendar: calendar, locale: locale)
    }

    private func twoStops(start: Date? = nil) -> ([RecordedLocation], [WifiPlace]) {
        let start = start ?? date("2026-06-01T12:00:00Z")
        let first = (0...5).map { fix($0, at: start.addingTimeInterval(Double($0) * 60), north: 0) }
        let second = (6...11).map { fix($0, at: start.addingTimeInterval(1_200 + Double($0 - 6) * 60), north: 1_000) }
        return (first + second, [place("Home", north: 0), place("Work", north: 1_000)])
    }
}
