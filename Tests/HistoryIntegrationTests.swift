import XCTest
import MapKit
@testable import WhereWolf

@MainActor
final class HistoryIntegrationTests: XCTestCase {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }
    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }
    private var now: Date { date("2026-11-12T18:00:00Z") }
    private var old: Date { calendar.startOfDay(for: date("2024-02-10T12:00:00Z")) }
    private func point(_ id: Int64, at time: Date, north: Double = 0) -> RecordedLocation {
        RecordedLocation(id: id, timestamp: time, latitude: 40 + north / 111_111, longitude: -73)
    }
    private var phone: [RecordedLocation] {
        [point(1, at: now.addingTimeInterval(-600)), point(2, at: now.addingTimeInterval(-30), north: 100)]
    }
    private func phoneProvider(_ points: [RecordedLocation]) -> PhoneHistoryDaySummaryProvider {
        HistoryLandmarks(points: points, timeline: ReplayTimeline(points: points), places: [], calendar: calendar).daySummaries
    }
    private func model(request: ((ClosedRange<Date>?, ServerHistoryRequestSource) -> Void)? = nil) -> HistoryPlaybackModel {
        let phone = phone, now = now
        return HistoryPlaybackModel(pointLoader: { _, done in done(phone) }, payloadLoader: { _, done in done([:]) },
            places: { [] }, clock: { now }, queueLoader: { $0([]) }, serverDayRequester: request)
    }
    private func apply(_ snapshot: ServerHistorySnapshot, to model: HistoryPlaybackModel) async {
        await withCheckedContinuation { continuation in
            model.applyServerHistory(snapshot) { continuation.resume() }
        }
    }
    private func snapshot(loaded: Bool = false) -> ServerHistorySnapshot {
        var value = ServerHistorySnapshot(firstDay: old, days: [
            .init(day: old, pointCount: 2, distance: 100, state: loaded ? .loaded : .notDownloaded)
        ], calendar: calendar)
        if loaded {
            value.points[old] = [ServerHistoryPoint(location: point(-1, at: old.addingTimeInterval(3_600))),
                                ServerHistoryPoint(location: point(-2, at: old.addingTimeInterval(3_660), north: 100))]
        }
        return value
    }

    func testCombinedProviderUsesPhoneBoundaryDayAndKeepsEmptyPhoneDaysEmpty() throws {
        let boundary = calendar.startOfDay(for: phone[0].timestamp)
        let next = calendar.date(byAdding: .day, value: 1, to: boundary)!
        let previous = calendar.date(byAdding: .day, value: -1, to: boundary)!
        let local = [point(1, at: boundary.addingTimeInterval(3_600))]
        let snapshot = ServerHistorySnapshot(firstDay: previous, days: [
            .init(day: previous, pointCount: 20, distance: 500),
            .init(day: boundary, pointCount: 99, distance: 9_000),
            .init(day: next, pointCount: 99, distance: 9_000)
        ], calendar: calendar)
        let provider = CombinedHistoryDaySummaryProvider(phone: phoneProvider(local),
            phoneWindow: DateInterval(start: local[0].timestamp, end: next.addingTimeInterval(7_200)), snapshot: snapshot)
        let values = provider.summaries(in: DateInterval(start: previous, end: next.addingTimeInterval(86_400)))
        XCTAssertEqual(values.map(\.state), [.notDownloaded, .phone])
        XCTAssertEqual(values.map(\.pointCount), [20, 1])
        XCTAssertEqual(values.last?.distance, 0)
        XCTAssertEqual(provider.firstDay, previous)
    }

    func testCombinedProviderDistinguishesIndexedCachedUnindexedAndEmptyServerDaysAcrossDST() throws {
        let start = calendar.startOfDay(for: date("2026-11-01T12:00:00Z"))
        let days = (0...4).map { calendar.date(byAdding: .day, value: $0, to: start)! }
        XCTAssertEqual(days[1].timeIntervalSince(days[0]), 25 * 3_600)
        var snapshot = ServerHistorySnapshot(firstDay: start, days: [
            .init(day: days[0], pointCount: 2, distance: 100, state: .loaded),
            .init(day: days[1], pointCount: 1, distance: 20, state: .loaded),
            .init(day: days[3], pointCount: 0)
        ], calendar: calendar)
        snapshot.points[days[0]] = [.init(location: point(-1, at: start))]
        let provider = CombinedHistoryDaySummaryProvider(phone: phoneProvider(phone),
            phoneWindow: DateInterval(start: phone[0].timestamp, end: now), snapshot: snapshot)
        let values = provider.summaries(in: DateInterval(start: start, end: days[4]))
        XCTAssertEqual(values.map(\.day), Array(days.prefix(3)))
        XCTAssertEqual(values.map(\.state), [.server, .notDownloaded, .notDownloaded])
        XCTAssertNil(values.last?.distance)
        XCTAssertEqual(values[1].distance, 20, "Disk totals alone cannot enable a jump before point detail loads")
    }

    func testCombinedProviderWithoutServerIsExactlyPhoneProvider() {
        let phone = phoneProvider(phone)
        let interval = DateInterval(start: now.addingTimeInterval(-86_400), end: now)
        let provider = CombinedHistoryDaySummaryProvider(phone: phone,
            phoneWindow: interval, snapshot: .init(calendar: calendar))
        XCTAssertEqual(provider.firstDay, phone.firstDay)
        XCTAssertEqual(provider.summaries(in: interval), phone.summaries(in: interval))
    }

    func testCalendarCallbacksRequestServerMonthAndSelectedDayWithoutReplacingEachOther() async throws {
        var calls: [(ClosedRange<Date>?, ServerHistoryRequestSource)] = []
        let model = model { calls.append(($0, $1)) }
        model.setConsumerActive(true)
        defer { model.setConsumerActive(false) }
        await apply(snapshot(), to: model)
        let month = calendar.dateInterval(of: .month, for: old)!
        model.requestCalendarMonth(month)
        model.requestCalendarDay(old)
        XCTAssertTrue(calls.contains { $0.1 == .calendarMonth && $0.0?.contains(old) == true })
        XCTAssertTrue(calls.contains { $0.1 == .calendar && $0.0 == (old...old) })
        model.closeCalendar()
        XCTAssertTrue(calls.contains { $0.1 == .calendarMonth && $0.0 == nil })
        XCTAssertTrue(calls.contains { $0.1 == .calendar && $0.0 == nil })
        XCTAssertEqual(model.daySummaries.summaries(in: calendar.dateInterval(of: .day, for: old)!).first?.state, .notDownloaded)
        await apply(snapshot(loaded: true), to: model)
        XCTAssertEqual(model.daySummaries.summaries(in: calendar.dateInterval(of: .day, for: old)!).first?.state, .server)
    }

    func testPhotoNavigationLoadsServerDayBeforeSelectingNearestPoint() async {
        var requests: [ClosedRange<Date>] = []
        let model = model { range, source in if source == .navigation, let range { requests.append(range) } }
        model.setConsumerActive(true)
        defer { model.setConsumerActive(false) }
        await apply(snapshot(), to: model)
        let request = HistoryNavigationRequest.moment(old.addingTimeInterval(3_650))
        model.navigate(to: request)
        XCTAssertNil(model.selectedPoint)
        XCTAssertEqual(model.rulerTime, request.date)
        XCTAssertTrue(requests.contains { $0.contains(request.date) })
        await apply(snapshot(loaded: true), to: model)
        XCTAssertEqual(model.selectedPoint?.id, -2)
        XCTAssertEqual(model.navigationRequest?.id, request.id)
        XCTAssertEqual(model.renderPose?.position, 1)
    }

    func testInsightsWaitsForInitialServerIndexBeforeSelectingAnOldMoment() async {
        let model = model()
        model.setConsumerActive(true)
        defer { model.setConsumerActive(false) }
        let request = HistoryNavigationRequest.moment(old.addingTimeInterval(3_600))
        model.navigate(to: request, waitForServer: true)
        XCTAssertNil(model.selectedPoint)
        XCTAssertEqual(model.rulerTime, request.date)
        await apply(snapshot(), to: model)
        XCTAssertNil(model.selectedPoint)
        await apply(snapshot(loaded: true), to: model)
        XCTAssertEqual(model.selectedPoint?.id, -1)
        XCTAssertEqual(model.navigationRequest?.id, request.id)
    }

    func testMonthNavigationWaitsForDaysThenFitsVirtualMonthAndRealRoute() async throws {
        let request = try XCTUnwrap(HistoryNavigationRequest.month(year: 2024, month: 2, calendar: calendar))
        let model = model()
        model.setConsumerActive(true)
        defer { model.setConsumerActive(false) }
        await apply(snapshot(), to: model)
        model.navigate(to: request)
        XCTAssertNil(model.rulerFrameRange)
        var loaded = snapshot(loaded: true)
        var day = old
        while day < request.interval!.end {
            if day != old { loaded.days.append(.init(day: day, pointCount: 0)) }
            day = calendar.date(byAdding: .day, value: 1, to: day)!
        }
        await apply(loaded, to: model)
        XCTAssertNotNil(model.rulerFrameRange)
        XCTAssertEqual(model.navigationRequest?.id, request.id)
        let zoom = try XCTUnwrap(model.rulerZoom)
        XCTAssertEqual(zoom.window(at: model.playbackIndex, count: model.points.count), 0..<2)
        XCTAssertEqual(model.routeGeometry?.coordinates.count, 4)
        XCTAssertGreaterThan(model.rulerPointCount, 4)
    }

    func testReplacedNavigationAndReturnToLiveCannotBeMovedByLateServerDays() async {
        let model = model()
        model.setConsumerActive(true)
        defer { model.setConsumerActive(false) }
        await apply(snapshot(), to: model)
        model.navigate(to: .moment(old.addingTimeInterval(3_600)))
        let phoneRequest = HistoryNavigationRequest.moment(phone[1].timestamp)
        model.navigate(to: phoneRequest)
        await apply(snapshot(loaded: true), to: model)
        XCTAssertEqual(model.selectedPoint?.id, 2)
        XCTAssertEqual(model.navigationRequest?.id, phoneRequest.id)
        model.returnToLive()
        await apply(snapshot(loaded: true), to: model)
        XCTAssertFalse(model.isBrowsing)
        XCTAssertNil(model.selectedPoint)
        XCTAssertNil(model.navigationRequest)
    }

    func testRulerFramesDoNotIssueRequestsAndFineSpacingUsesRealSourceOffsets() async throws {
        var calls = 0
        let current = now
        let near = (0...30).map { point(Int64($0 + 1), at: current.addingTimeInterval(Double($0 - 30) * 30)) }
        let model = HistoryPlaybackModel(pointLoader: { _, done in done(near) }, payloadLoader: { _, done in done([:]) },
            places: { [] }, clock: { current }, queueLoader: { $0([]) }, serverDayRequester: { _, _ in calls += 1 })
        model.setConsumerActive(true)
        defer { model.setConsumerActive(false) }
        await apply(snapshot(loaded: true), to: model)
        model.beginRulerInteraction()
        let before = calls
        for value in 1...120 { model.scrub(rulerPosition: Double(value), liveEdge: now) }
        XCTAssertEqual(calls, before)
        let ruler = try XCTUnwrap(model.serverRuler)
        let axis = try XCTUnwrap(model.serverRulerLandmarks).rulerAxis
        for step in [1.0, 2, 5] {
            let mapping = axis.mapping(pointsPerBar: step, pointCount: ruler.count)
            XCTAssertEqual(mapping.weight, 0)
            let last = ruler.sourcePositions.count - 1
            XCTAssertEqual(mapping.coordinate(at: Double(ruler.sourcePositions[last]))
                - mapping.coordinate(at: Double(ruler.sourcePositions[last - 1])), 1)
        }
        model.sendRulerScaleFrame(.init(pointsPerBar: 5, detents: model.rulerDetents, width: 350, axis: axis, interval: axis.interval))
        XCTAssertTrue(model.rulerScaleChannel.frame?.serverRuler === ruler)
        XCTAssertEqual(model.rulerScaleChannel.frame?.pointsPerBar, 5)
        let last = model.points.count - 1
        let zoom = ReplayRulerHold(pointsPerBar: 5, visibleBars: 20, coarseness: 0, axis: axis, serverRuler: ruler)
        XCTAssertEqual(zoom.window(at: Double(last), count: model.points.count), (last - 10)..<(last + 1))
        model.setRulerHold(.init(pointsPerBar: 5, visibleBars: 20, coarseness: 0))
        let held = try XCTUnwrap(model.rulerHold)
        XCTAssertTrue(held.serverRuler === ruler)
        XCTAssertEqual(held.window(at: Double(last), count: model.points.count), zoom.window(at: Double(last), count: model.points.count))
        model.sendRulerScaleFrame(nil)
        model.endRulerInteraction(cancelled: false)
    }

    func testRemoteTracksAndLoadedServerPointsFeedDayBuilderWithoutVirtualPoints() async throws {
        let model = model()
        model.setConsumerActive(true)
        defer { model.setConsumerActive(false) }
        let remoteDay = calendar.date(byAdding: .day, value: 1, to: old)!
        let line = [MKMapPoint(x: 100, y: 100), MKMapPoint(x: 120, y: 100), MKMapPoint(x: 140, y: 100)]
        var snapshot = snapshot(loaded: true)
        snapshot.tracks[old] = [line]
        snapshot.tracks[remoteDay] = [line, line.map { MKMapPoint(x: $0.x + 1_000, y: $0.y) }]
        await apply(snapshot, to: model)
        model.goTo(old.addingTimeInterval(3_600))
        XCTAssertNil(model.replayDayTracks?.segments[old], "Loaded source points own their geometry")
        XCTAssertEqual(model.replayDayTracks?.segments[remoteDay]?.count, 2)
        let route = try XCTUnwrap(model.routeGeometry)
        var builder = ReplayDayRouteBuilder()
        let result = builder.build(points: route.coordinates.map(MKMapPoint.init), ids: route.pointIDs,
            dates: route.timestamps, tracks: model.replayDayTracks, calendar: calendar, bucket: 2, highlight: nil)
        XCTAssertEqual(result.sourceIDs, model.points.map(\.id))
        XCTAssertTrue(result.sourceIndices.allSatisfy { model.points.indices.contains($0) })
        XCTAssertEqual(result.spans.count, 4, "Separate server tracks never acquire a connecting segment")
        XCTAssertEqual(result.points.count, 8, "Loaded day and phone retain endpoints; each remote line simplifies separately")
        XCTAssertEqual(route.coordinates.count, 4, "Day anchors stay out of the fine route")
    }

    func testFrameBoundsUseOnlyRequestedServerDaysAndCanFitTracksWithoutPoints() throws {
        let a = MKMapPoint(point(-1, at: old).coordinate)
        let b = MKMapPoint(point(-2, at: old, north: 100).coordinate)
        let tracks = ReplayDayTracks(segments: [old: [[a, b]]])
        let range = old...calendar.date(byAdding: .day, value: 1, to: old)!.addingTimeInterval(-1)
        let frame = try XCTUnwrap(ReplayHistoryFrame(points: [], tracks: tracks, range: range, calendar: calendar))
        XCTAssertEqual(frame.coordinates.count, 4)
        let remote = try XCTUnwrap(ReplayHistoryFrame(points: phone, tracks: tracks, range: range, calendar: calendar))
        XCTAssertTrue(zip(frame.coordinates, remote.coordinates).allSatisfy { $0.latitude == $1.latitude && $0.longitude == $1.longitude })
        XCTAssertNil(ReplayHistoryFrame(points: phone, tracks: nil, range: range, calendar: calendar))
        var builder = ReplayDayRouteBuilder()
        let geometry = builder.build(points: [], ids: [], dates: [], tracks: tracks, calendar: calendar, bucket: 2, highlight: nil)
        let display = ReplayRouteDisplay(ReplayRoutePresentation(coordinates: []))
        _ = display.stage(geometry, position: 0)
        _ = display.finishHandoff()
        XCTAssertEqual(display.fine.fullRoute.pointCount, 0)
        XCTAssertEqual(display.presentation.sections.count, 1)
        XCTAssertEqual(display.presentation.sections.first?.polyline.pointCount, 2)
    }

    func testMaskedTrackPagingUsesLocalDSTDayAndFeedsSeparateMapSpans() async throws {
        defer { HistoryTracksProtocol.handler = nil }
        let start = calendar.startOfDay(for: date("2026-11-01T12:00:00Z"))
        let end = calendar.date(byAdding: .day, value: 1, to: start)!
        let formatter = ISO8601DateFormatter()
        HistoryTracksProtocol.handler = { mock in
            let parts = URLComponents(url: mock.request.url!, resolvingAgainstBaseURL: false)!
            let query = Dictionary(uniqueKeysWithValues: parts.queryItems!.map { ($0.name, $0.value!) })
            XCTAssertEqual(parts.path, "/prefix/api/v1/tracks")
            XCTAssertTrue(mock.request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
            XCTAssertTrue(mock.request.value(forHTTPHeaderField: "X-Test") == "fixture")
            XCTAssertEqual(query["mask_privacy_zones"], "true")
            XCTAssertEqual(query["start_at"], formatter.string(from: start))
            XCTAssertEqual(query["end_at"], formatter.string(from: end.addingTimeInterval(-1)))
            let page = Int(query["page"]!)!
            mock.respond(page: page, total: 2, features: [Self.feature(id: page, start: start.addingTimeInterval(60), end: start.addingTimeInterval(120))])
        }
        let lines = try await client().tracks(on: start, calendar: calendar)
        XCTAssertEqual(lines.count, 2)
        var builder = ReplayDayRouteBuilder()
        let geometry = builder.build(points: [], ids: [], dates: [], tracks: ReplayDayTracks(segments: [start: lines]),
            calendar: calendar, bucket: 0, highlight: nil)
        XCTAssertEqual(geometry.spans.count, 2)
        XCTAssertTrue(geometry.sourceIndices.isEmpty)
    }

    func testTracksDegradeOnUnsupportedVersionsAndExcludeUnclippableMidnightTrack() async throws {
        defer { HistoryTracksProtocol.handler = nil }
        let start = old, end = calendar.date(byAdding: .day, value: 1, to: old)!
        HistoryTracksProtocol.handler = { mock in
            mock.respond(page: 1, total: 1, features: [Self.feature(id: 1, start: start.addingTimeInterval(-60), end: start.addingTimeInterval(60)),
                Self.feature(id: 2, start: end.addingTimeInterval(-60), end: end.addingTimeInterval(60))])
        }
        let lines = try await client().tracks(on: start, calendar: calendar)
        XCTAssertTrue(lines.isEmpty)
        HistoryTracksProtocol.handler = { _ in XCTFail("Unsupported versions must not issue requests") }
        do { _ = try await client(version: "2.0.0").tracks(on: start, calendar: calendar); XCTFail("Expected version gate") }
        catch { XCTAssertTrue(error as? DawarichHistoryError == .unsupportedVersion) }
    }

    private func client(version: String = "1.20.0") throws -> DawarichHistoryClient {
        let server = try XCTUnwrap(DawarichServer(endpoint: "https://wherewolf.test/prefix/api/v1/overland/batches", token: "fixture"))
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [HistoryTracksProtocol.self]
        return DawarichHistoryClient(server: server, headers: ["X-Test": "fixture"], version: version, configuration: config)
    }

    nonisolated private static func feature(id: Int, start: Date, end: Date) -> [String: Any] {
        ["type": "Feature", "properties": ["id": id, "start_at": ISO8601DateFormatter().string(from: start),
          "end_at": ISO8601DateFormatter().string(from: end)],
         "geometry": ["type": "LineString", "coordinates": [[-73.0, 40.0], [-73.0, 40.001]]]]
    }
}

private final class HistoryTracksProtocol: URLProtocol {
    static var handler: ((HistoryTracksProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "wherewolf.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() { }
    func respond(page: Int, total: Int, features: [[String: Any]]) {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1",
            headerFields: ["X-Current-Page": String(page), "X-Total-Pages": String(total)])!
        let data = try! JSONSerialization.data(withJSONObject: ["type": "FeatureCollection", "features": features])
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
