import XCTest
import CoreLocation
@testable import WhereWolf

@MainActor
final class ServerHistoryModelTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        return value
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private var now: Date { date("2026-11-12T18:00:00Z") }
    private var first: Date { calendar.startOfDay(for: date("2020-01-01T12:00:00Z")) }
    private func point(_ id: Int64, _ timestamp: Date) -> RecordedLocation {
        .init(id: id, timestamp: timestamp, latitude: 40 + Double(id % 10) / 100, longitude: -73)
    }
    private var phone: [RecordedLocation] {
        [point(1, now.addingTimeInterval(-600)), point(2, now.addingTimeInterval(-30))]
    }
    private func snapshot(state: ServerHistoryDayState = .notDownloaded) -> ServerHistorySnapshot {
        .init(firstDay: first, days: [.init(day: first, pointCount: 3, distance: 1_200, state: state)], calendar: calendar)
    }
    private func model(queue: [ServerHistoryPoint] = []) -> HistoryPlaybackModel {
        let phone = phone, now = now
        return HistoryPlaybackModel(pointLoader: { _, done in done(phone) }, payloadLoader: { _, done in done([:]) },
            places: { [] }, clock: { now }, serverHistory: nil, queueLoader: { $0(queue) })
    }
    private func apply(_ snapshot: ServerHistorySnapshot, to model: HistoryPlaybackModel) async {
        await withCheckedContinuation { continuation in
            model.applyServerHistory(snapshot) { continuation.resume() }
        }
    }

    func testMergeKeepsPhoneOverlapAndUnsentQueueAndEveryDistinctStoredFix() {
        let old = now.addingTimeInterval(-172_800)
        let server = [point(-1, old), point(-2, old), point(-1, old), point(-3, phone[0].timestamp),
                      point(-4, now.addingTimeInterval(-100))]
        let queued = [point(Int64.min + 1, old.addingTimeInterval(-60)), point(Int64.min + 2, phone[0].timestamp)]
        let merged = ServerHistoryMerge.points(phone: phone, server: server, queued: queued,
                                               retentionStart: now.addingTimeInterval(-86_400))
        XCTAssertEqual(Set(merged.map(\.id)), [1, 2, -1, -2, Int64.min + 1])
        XCTAssertEqual(merged.filter { $0.timestamp == old }.count, 2)
        XCTAssertTrue(zip(merged, merged.dropFirst()).allSatisfy { $0.timestamp <= $1.timestamp })
    }

    func testQueueWinsAgainstServerOutsidePhoneWindow() {
        let old = now.addingTimeInterval(-172_800)
        let queue = point(Int64.min + 42, old)
        let merged = ServerHistoryMerge.points(phone: phone, server: [point(-1, old)], queued: [queue], retentionStart: now)
        XCTAssertTrue(merged.contains { $0.id == queue.id })
        XCTAssertFalse(merged.contains { $0.id == -1 })
        let emptyPhone = ServerHistoryMerge.points(phone: [], server: [point(-1, old), point(-2, now)],
                                                   retentionStart: now.addingTimeInterval(-86_400))
        XCTAssertEqual(emptyPhone.map(\.id), [-1])
    }

    func testMergeKeepsDistinctQueueIDsWithTheSameSerializedTimestamp() throws {
        let old = now.addingTimeInterval(-172_800)
        func queued(_ key: String, at time: Date, latitude: Double) throws -> RecordedLocation {
            let record: [String: Any] = ["type": "Feature",
                "geometry": ["type": "Point", "coordinates": [-73.0, latitude]],
                "properties": ["timestamp": ISO8601DateFormatter().string(from: time)]]
            return try XCTUnwrap(ServerHistoryMerge.queuedPoint(["key": key, "record": record])).location
        }
        let first = try queued("same-second-first", at: old, latitude: 40)
        let second = try queued("same-second-second", at: old, latitude: 40.001)
        let overlap = try queued("phone-overlap", at: phone[0].timestamp, latitude: 40.002)
        let merged = ServerHistoryMerge.points(phone: phone,
            server: [point(-1, old), point(-2, old), point(-3, old.addingTimeInterval(-60))],
            queued: [first, second, first, overlap], retentionStart: now.addingTimeInterval(-86_400))
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(Set(merged.map(\.id)), [first.id, second.id, -3, 1, 2])
        XCTAssertEqual(merged.filter { $0.timestamp == old }.count, 2)
        XCTAssertEqual(merged.filter { $0.timestamp == old }.map(\.coordinate.latitude).sorted(), [40, 40.001])
    }

    func testQueueParserExcludesImportedHealthRoutesAndNonLocations() throws {
        let record: [String: Any] = ["_type": "location", "tst": now.timeIntervalSince1970, "lat": 40, "lon": -73]
        let parsed = try XCTUnwrap(ServerHistoryMerge.queuedPoint(["key": "fixture", "record": record]))
        XCTAssertLessThan(parsed.location.id, -(1 << 62))
        XCTAssertTrue(parsed.location.timestamp == now)
        XCTAssertEqual(parsed.location.id, ServerHistoryMerge.queuedPoint(["key": "fixture", "record": record])?.location.id)
        XCTAssertNil(ServerHistoryMerge.queuedPoint(["key": "healthkit:fixture", "record": record]))
        XCTAssertNil(ServerHistoryMerge.queuedPoint(["key": "fixture", "record": ["_type": "transition"]]))
    }

    func testSparseIndexReachesFirstDayWithoutInventingMapPoints() {
        let ruler = ServerHistoryRuler(points: phone, phoneStart: phone[0].timestamp, snapshot: snapshot(), now: now)
        XCTAssertEqual(ruler.timestamps.first, first)
        XCTAssertEqual(ruler.timestamps.last, phone.last?.timestamp)
        XCTAssertLessThan(ruler.timestamps.count, 6_000, "Years use day anchors until points are requested")
        XCTAssertEqual(ruler.loadingDay(at: 0)?.pointCount, 3)
        XCTAssertEqual(ruler.loadingDay(at: 0)?.label, "Not downloaded")
    }

    func testSparseCountsPreserveFinePointSpacingAndPureTimeAtDayScale() {
        let phone = [point(10, now.addingTimeInterval(-60)), point(11, now.addingTimeInterval(-30)), point(12, now)]
        let ruler = ServerHistoryRuler(points: phone, phoneStart: phone[0].timestamp, snapshot: snapshot(), now: now)
        let axis = HistoryRulerAxis(timestamps: ruler.timestamps, positions: ruler.positions)
        XCTAssertGreaterThan(ruler.count, ruler.timestamps.count * 100)
        let fine = axis.mapping(pointsPerBar: 5, pointCount: ruler.count)
        XCTAssertEqual(fine.weight, 0)
        XCTAssertEqual(fine.coordinate(at: Double(ruler.sourcePositions[2]))
            - fine.coordinate(at: Double(ruler.sourcePositions[1])), 1)
        let detents = HistoryRulerCoarseDrag.Detents(tickCount: ruler.count, rulerWidth: 350)
        XCTAssertTrue(detents.menuEntries(interval: axis.interval!, current: 1).contains { $0.title == "5 minutes" })
        let time = first.addingTimeInterval(43_200)
        let index = ruler.index(at: time)
        let pure = axis.mapping(pointsPerBar: 86_400 / axis.interval!, pointCount: ruler.count)
        XCTAssertEqual(pure.weight, 1, accuracy: 1e-10)
        let expected = Double(ruler.count - 1) * time.timeIntervalSince(ruler.timestamps.first!)
            / ruler.timestamps.last!.timeIntervalSince(ruler.timestamps.first!)
        XCTAssertEqual(pure.coordinate(at: index), expected, accuracy: 0.0001)
        XCTAssertEqual(pure.index(at: pure.coordinate(at: index)), index, accuracy: 0.0001)
        XCTAssertEqual(ruler.time(at: index), time)
    }

    func testRulerKeepsDistinctFixesSharingATimestamp() {
        let points = [point(-1, first), point(-2, first), point(1, now)]
        var loaded = snapshot(state: .loaded)
        loaded.points[first] = points.prefix(2).map { ServerHistoryPoint(location: $0) }
        let ruler = ServerHistoryRuler(points: points, phoneStart: now, snapshot: loaded, now: now)
        XCTAssertNotEqual(ruler.sourcePositions[0], ruler.sourcePositions[1])
        XCTAssertEqual(ruler.sourcePosition(at: Double(ruler.sourcePositions[1])), 1)
        XCTAssertEqual(ruler.index(forSourcePosition: 0.5), 0.5)
    }

    func testLoadingAndUndownloadedDaysAreNotPhoneGaps() throws {
        let ruler = ServerHistoryRuler(points: phone, phoneStart: phone[0].timestamp,
                                      snapshot: snapshot(state: .loading), now: now)
        let landmarks = HistoryLandmarks(points: phone, timeline: ReplayTimeline(points: phone), places: [],
                                         calendar: calendar, ruler: ruler)
        XCTAssertEqual(landmarks.loadingDay(at: 0)?.label, "Loading…")
        XCTAssertTrue(landmarks.gaps.allSatisfy { landmarks.rulerTimestamp(at: $0.index - 1) >= phone[0].timestamp })
        XCTAssertFalse(landmarks.loadingDays.isEmpty)
        XCTAssertTrue(landmarks.timeMarks[0].count < 3_000, "No minute arrays for unloaded years")
        XCTAssertEqual(try XCTUnwrap(landmarks.loadingDays.first).day, first)
    }

    func testYearAndMonthLabelsFramesAndWholeHistoryMenu() {
        let ruler = ServerHistoryRuler(points: phone, phoneStart: phone[0].timestamp, snapshot: snapshot(), now: now)
        let landmarks = HistoryLandmarks(points: phone, timeline: ReplayTimeline(points: phone), places: [],
                                         calendar: calendar, ruler: ruler)
        XCTAssertTrue(landmarks.rulerFrames.contains(.month))
        XCTAssertTrue(landmarks.rulerFrames.contains(.year))
        XCTAssertEqual(landmarks.years.count, 7)
        XCTAssertGreaterThan(landmarks.months.count, 80)
        let detents = HistoryRulerCoarseDrag.Detents(tickCount: ruler.count, rulerWidth: 350)
        let interval = landmarks.rulerAxis.interval!
        let entries = detents.menuEntries(interval: interval, current: detents.steps[0])
        XCTAssertEqual(entries.last?.title, "Whole history")
        XCTAssertTrue(entries.contains { $0.title == "1 month" })
        XCTAssertEqual(Set(entries.map(\.step)).count, entries.count)
        let dayStep = max(2, 86_400 / interval)
        XCTAssertEqual(landmarks.rulerAxis.mapping(pointsPerBar: dayStep, pointCount: ruler.count).weight, 1,
                       accuracy: 1e-10)
        let year = landmarks.stretch(frame: .year, at: first)!
        let fit = HistoryRulerFraming.fit(year, axis: landmarks.rulerAxis, detents: detents, width: 350)
        XCTAssertGreaterThan(fit.step, 1)
        XCTAssertTrue(fit.position.isFinite)
    }

    func testCalendarLabelPrioritiesWinCollisions() {
        let frame = CGRect(x: 0, y: 0, width: 60, height: 16)
        let priorities: [HistoryRulerLabelLayout.Priority] = [.time, .gap, .stop, .day, .month, .year]
        let candidates = priorities.enumerated().map { HistoryRulerLabelLayout.Candidate(id: $0.offset,
            priority: $0.element, frame: frame) }
        XCTAssertEqual(HistoryRulerLabelLayout.resolve(candidates).map(\.id), [5])
        XCTAssertEqual(HistoryRulerLabelLayout.resolve(Array(candidates.dropLast())).map(\.id), [4])
    }

    func testArrivingDayWaitsForInteractionAndPreservesNeedleTimeAndScale() async throws {
        let model = model()
        model.setConsumerActive(true)
        await apply(snapshot(), to: model)
        let needle = first.addingTimeInterval(3_600)
        model.scrub(to: needle)
        model.setRulerStep(5)
        model.beginRulerInteraction()
        let position = model.rulerPosition, revision = model.rulerInteractionRevision
        let cameraIntent = model.cameraIntentRevision, cameraCenter = model.cameraCenter
        let seconds = model.rulerSecondsPerBar, originalCount = model.rulerPointCount
        var loaded = snapshot(state: .loaded)
        loaded.points[first] = [0.0, 3_600, 7_200].enumerated().map {
            ServerHistoryPoint(location: point(-Int64($0.offset + 1), first.addingTimeInterval($0.element)))
        }
        await apply(loaded, to: model)
        XCTAssertEqual(model.rulerPointCount, originalCount)
        XCTAssertEqual(model.points.count, phone.count)
        XCTAssertEqual(model.rulerPosition, position)
        model.endRulerInteraction(cancelled: false)
        XCTAssertEqual(model.rulerTime, needle)
        XCTAssertEqual(model.rulerInteractionRevision, revision)
        XCTAssertEqual(model.rulerSecondsPerBar, seconds, accuracy: 0.001)
        XCTAssertEqual(model.selectedPoint?.id, -2)
        XCTAssertEqual(model.cameraIntentRevision, cameraIntent)
        XCTAssertEqual(model.cameraCenter, cameraCenter, "A newly available marker is not a camera request")
        XCTAssertNotNil(model.renderPose)
        XCTAssertEqual(model.points.count, phone.count + 3)
        let ruler = try XCTUnwrap(model.serverRuler)
        XCTAssertEqual(ruler.time(at: Double(model.rulerPointCount) - model.rulerPlaybackPosition), needle)
        model.setConsumerActive(false)
    }

    func testServerPublicationRefreshesFrameBoundsWithoutCameraIntentDuringOrAfterAFrameFit() async throws {
        for waitForFrame in [false, true] {
            let queue = OperationQueue()
            queue.maxConcurrentOperationCount = 1
            let phone = phone, now = now
            let model = HistoryPlaybackModel(pointLoader: { _, done in done(phone) },
                payloadLoader: { _, done in done([:]) }, places: { [] }, clock: { now },
                queueLoader: { $0([]) }, serverProjectionQueue: queue)
            model.setConsumerActive(true)
            defer { model.setConsumerActive(false) }
            var loaded = snapshot(state: .loaded)
            loaded.points[first] = [point(-1, first), point(-2, first.addingTimeInterval(7_200))]
                .map { ServerHistoryPoint(location: $0) }
            await apply(loaded, to: model)
            queue.isSuspended = true
            model.fitRuler(HistoryRulerStretch(range: 0...0, title: "All", frame: .all))
            let needle = model.rulerTime, seconds = model.rulerSecondsPerBar
            let intent = model.cameraIntentRevision, frameRevision = model.rulerFrameRevision
            let focus = model.cameraCenter
            let drain = {
                await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                    queue.addOperation { DispatchQueue.main.async { continuation.resume() } }
                }
            }
            if waitForFrame { queue.isSuspended = false; await drain() }
            let previousFrame = model.replayFrame
            let nextDay = calendar.date(byAdding: .day, value: 1, to: first)!
            loaded.points[nextDay] = [ServerHistoryPoint(location: RecordedLocation(id: -3,
                timestamp: nextDay, latitude: -20, longitude: 140))]
            let published = expectation(description: "Server publication completes")
            model.applyServerHistory(loaded) { published.fulfill() }
            queue.isSuspended = false
            await fulfillment(of: [published], timeout: 2)
            await drain()
            XCTAssertEqual(model.rulerTime, needle)
            XCTAssertEqual(model.rulerSecondsPerBar, seconds, accuracy: 0.001)
            XCTAssertEqual(model.cameraCenter, focus)
            XCTAssertEqual(model.cameraIntentRevision, intent)
            XCTAssertEqual(model.rulerFrameRevision, frameRevision)
            let frame = try XCTUnwrap(model.replayFrame)
            if let previousFrame { XCTAssertFalse(frame === previousFrame) }
            XCTAssertTrue(frame.coordinates.contains { $0.latitude < 0 },
                          "Latest bounds are available for the next explicit fit without issuing one on publication")
            let ruler = try XCTUnwrap(model.serverRuler)
            XCTAssertEqual(ruler.time(at: Double(model.rulerPointCount) - model.rulerPlaybackPosition), needle)
            XCTAssertEqual(model.serverRouteDays, [first, nextDay])
        }
    }

    func testScrubbingNewestServerRulerPointDuringPhoneExpiryKeepsTheMatchingFix() async throws {
        var current = now
        let samples = [point(1, current.addingTimeInterval(-86_370)), point(2, current.addingTimeInterval(-30))]
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let model = HistoryPlaybackModel(pointLoader: { after, done in done(samples.filter { $0.id > after }) },
            payloadLoader: { _, done in done([:]) }, retentionDuration: { 86_400 }, places: { [] },
            clock: { current }, queueLoader: { $0([]) }, serverProjectionQueue: queue)
        model.setConsumerActive(true)
        defer { queue.isSuspended = false; model.setConsumerActive(false) }
        var loaded = snapshot(state: .loaded)
        loaded.points[first] = [ServerHistoryPoint(location: point(-1, first))]
        await apply(loaded, to: model)
        let ruler = try XCTUnwrap(model.serverRuler)
        let position = Double(ruler.count - ruler.sourcePositions.last!)
        queue.isSuspended = true
        current = current.addingTimeInterval(120)
        model.expireOldPoints()
        model.scrub(rulerPosition: position, liveEdge: current)
        XCTAssertEqual(model.selectedPoint?.id, 2)
        XCTAssertEqual(model.renderPose?.coordinate, ReplayCoordinate(samples[1].coordinate))
        XCTAssertEqual(model.rulerTime, samples[1].timestamp)
        queue.isSuspended = false
        await apply(loaded, to: model)
        XCTAssertEqual(model.points.map(\.id), [-1, 2])
        XCTAssertEqual(model.selectedIndex, 1)
        XCTAssertEqual(model.renderPose?.position, 1)
        XCTAssertEqual(model.renderPose?.coordinate, ReplayCoordinate(samples[1].coordinate))
    }

    func testPhoneAppendInvalidatesAProjectionEvenWhenItsRebuildIsDeferred() async {
        var samples = phone
        let current = now
        var cursors: [Int64] = []
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let model = HistoryPlaybackModel(pointLoader: { after, done in
            cursors.append(after)
            done(samples.filter { $0.id > after })
        }, payloadLoader: { _, done in done([:]) }, places: { [] }, landmarkClock: { 0 }, clock: { current },
           queueLoader: { $0([]) }, serverProjectionQueue: queue)
        model.setConsumerActive(true)
        defer { queue.isSuspended = false; model.setConsumerActive(false) }
        await apply(snapshot(), to: model)
        let previous = model.serverRuler
        queue.isSuspended = true
        var loaded = snapshot(state: .loaded)
        loaded.points[first] = [ServerHistoryPoint(location: point(-1, first))]
        let stale = expectation(description: "Obsolete projection finished")
        model.applyServerHistory(loaded) { stale.fulfill() }
        samples.append(point(3, current))
        model.reload()
        queue.isSuspended = false
        await fulfillment(of: [stale], timeout: 2)
        XCTAssertTrue(model.serverRuler === previous, "The pre-append projection must not publish during coalescing")
        // The queue cursor has advanced; another incremental read cannot recover an overwritten fix.
        model.reload()
        XCTAssertEqual(cursors.last, 3)
        await apply(loaded, to: model)
        XCTAssertEqual(model.points.map(\.id), [-1, 1, 2, 3])
        XCTAssertEqual(model.liveRulerGeometry.pointIDs, model.points.map(\.id))
    }

    func testPhoneExpiryInvalidatesACompletedProjectionWaitingForInteraction() async {
        var current = now
        let samples = [point(1, current.addingTimeInterval(-86_370)), point(2, current.addingTimeInterval(-30))]
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let model = HistoryPlaybackModel(pointLoader: { after, done in done(samples.filter { $0.id > after }) },
            payloadLoader: { _, done in done([:]) }, retentionDuration: { 86_400 }, places: { [] },
            clock: { current }, queueLoader: { $0([]) }, serverProjectionQueue: queue)
        model.setConsumerActive(true)
        defer { queue.isSuspended = false; model.setConsumerActive(false) }
        await apply(snapshot(), to: model)
        let previous = model.serverRuler
        model.beginRulerInteraction()
        var loaded = snapshot(state: .loaded)
        loaded.points[first] = [ServerHistoryPoint(location: point(-1, first))]
        await apply(loaded, to: model)
        XCTAssertTrue(model.serverRuler === previous)
        queue.isSuspended = true
        current = current.addingTimeInterval(120)
        model.expireOldPoints()
        model.endRulerInteraction(cancelled: false)
        XCTAssertTrue(model.serverRuler === previous, "Expiry must discard the completed pre-expiry projection too")
        queue.isSuspended = false
        await apply(loaded, to: model)
        XCTAssertEqual(model.points.map(\.id), [-1, 2])
    }

    func testPhoneAppendKeepsCompleteServerPresentationUntilReplacementPublishes() async throws {
        var samples = phone
        let current = now
        let queue = OperationQueue()
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        let model = HistoryPlaybackModel(pointLoader: { after, done in done(samples.filter { $0.id > after }) },
            payloadLoader: { _, done in done([:]) }, places: { [] }, landmarkClock: { 0 }, clock: { current },
            queueLoader: { $0([]) }, serverProjectionQueue: queue)
        model.setConsumerActive(true)
        defer { queue.isSuspended = false; model.setConsumerActive(false) }
        var loaded = snapshot(state: .loaded)
        loaded.points[first] = [ServerHistoryPoint(location: point(-1, first)),
                               ServerHistoryPoint(location: point(-2, first.addingTimeInterval(60)))]
        await apply(loaded, to: model)
        model.scrub(to: samples[0].timestamp)
        let ids = model.points.map(\.id)
        let route = try XCTUnwrap(model.routeGeometry)
        let live = model.liveRulerGeometry
        let landmarks = model.landmarks
        let pose = model.renderPose
        queue.isSuspended = true
        samples.append(point(3, current))
        model.reload()
        XCTAssertEqual(model.points.map(\.id), ids)
        XCTAssertTrue(model.routeGeometry === route, "A map read must not rebuild downloaded geometry on the main actor")
        XCTAssertTrue(model.liveRulerGeometry === live)
        XCTAssertTrue(model.landmarks === landmarks)
        XCTAssertEqual(model.renderPose, pose)
        model.refreshLandmarks()
        XCTAssertTrue(model.routeGeometry === route, "Keep the complete presentation while the utility build is pending")
        queue.isSuspended = false
        await apply(loaded, to: model)
        XCTAssertEqual(model.points.map(\.id), ids + [3])
        XCTAssertEqual(model.routeGeometry?.pointIDs, ids + [3])
        XCTAssertEqual(model.liveRulerGeometry.pointIDs, ids + [3])
        XCTAssertEqual(model.landmarks.timestamps, model.points.map(\.timestamp))
        XCTAssertFalse(model.routeGeometry === route)
        XCTAssertEqual(model.selectedPoint?.id, 1)
        XCTAssertEqual(model.renderPose, pose)
    }

    func testDayAccessSummaryAndPlaybackDropsToFineScale() async {
        let model = model()
        model.setConsumerActive(true)
        var loaded = snapshot(state: .loaded)
        loaded.points[first] = [ServerHistoryPoint(location: point(-1, first.addingTimeInterval(3_600))),
                               ServerHistoryPoint(location: point(-2, first.addingTimeInterval(7_200)))]
        await apply(loaded, to: model)
        XCTAssertEqual(model.firstServerDay, first)
        XCTAssertEqual(model.serverDaySummary(on: first)?.distance, 1_200)
        let perDay = await model.serverPoints(on: first)
        XCTAssertEqual(perDay.map(\.id), [-1, -2])
        model.goTo(first.addingTimeInterval(3_600))
        model.setRulerStep(model.rulerDetents.steps[0])
        XCTAssertGreaterThanOrEqual(model.rulerSecondsPerBar, 86_400)
        model.togglePlayback()
        XCTAssertEqual(model.rulerStep, 1)
        XCTAssertTrue(model.isPlaying)
        model.pause()
        model.setConsumerActive(false)
    }

    func testRemovingServerSnapshotKeepsPhoneHistory() async {
        let model = model()
        model.setConsumerActive(true)
        var loaded = snapshot(state: .loaded)
        loaded.points[first] = [ServerHistoryPoint(location: point(-1, first))]
        await apply(loaded, to: model)
        model.retentionDidChange()
        XCTAssertTrue(model.points.contains { $0.id == -1 }, "Phone expiry cannot prune server cache points")
        await apply(.init(), to: model)
        XCTAssertNil(model.serverRuler)
        XCTAssertEqual(model.points.map(\.id), phone.map(\.id))
        XCTAssertNil(model.firstServerDay)
        model.setConsumerActive(false)
    }

    func testWithoutDawarichKeepsOriginalPhonePath() async {
        var queueReads = 0
        let phone = phone, now = now
        let model = HistoryPlaybackModel(pointLoader: { _, done in done(phone) }, payloadLoader: { _, done in done([:]) }, places: { [] }, clock: { now },
            serverHistory: nil, queueLoader: { done in queueReads += 1; done([]) })
        model.setConsumerActive(true)
        await apply(.init(), to: model)
        XCTAssertNil(model.serverRuler)
        XCTAssertEqual(model.rulerPointCount, phone.count)
        XCTAssertEqual(model.points.map(\.id), phone.map(\.id))
        XCTAssertEqual(queueReads, 0)
        model.setConsumerActive(false)
    }

    func testClearServerHistoryDeletesCacheAndSize() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ServerHistoryCache(directoryURL: directory)
        try await cache.selectSource(String(repeating: "a", count: 64))
        try await cache.setFirstPointDate(first)
        try await cache.storeDays(snapshot().days)
        try await cache.storePoints([.init(location: point(-1, first))], on: first)
        let store = ServerHistoryStore(cache: cache)
        await store.refreshStorageSize()
        XCTAssertGreaterThan(store.storageBytes, 0)
        await store.clear()
        XCTAssertEqual(store.storageBytes, 0)
        XCTAssertFalse(store.available)
        XCTAssertNil(store.errorMessage)
        let days = try await cache.days()
        let first = try await cache.firstPointDate()
        XCTAssertTrue(days.isEmpty)
        XCTAssertNil(first)
    }
}
