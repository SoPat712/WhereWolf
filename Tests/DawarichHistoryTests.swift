import XCTest
@testable import WhereWolf

final class DawarichHistoryTests: XCTestCase {
    override func tearDown() {
        HistoryTestProtocol.handler = nil
        super.tearDown()
    }

    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(identifier: "America/New_York")!
        return value
    }

    private func date(_ value: String) -> Date { ISO8601DateFormatter().date(from: value)! }

    private func client(version: String = "1.20.0") throws -> DawarichHistoryClient {
        let server = try XCTUnwrap(DawarichServer(endpoint: "https://wherewolf.test/prefix/api/v1/overland/batches", token: "fixture-history-key"))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [HistoryTestProtocol.self]
        return DawarichHistoryClient(server: server, headers: ["X-Proxy": "fixture-proxy"], version: version, configuration: configuration)
    }

    private func point(id: Int = 17, at timestamp: Date) -> [String: Any] {
        ["id": id, "latitude": "40.1", "longitude": "-73.2", "timestamp": timestamp.timeIntervalSince1970,
         "velocity": 36, "accuracy": 5, "altitude": 20, "battery": 80, "tracker_id": "fixture-device"]
    }

    func testUnauthenticatedSignatureCannotEnableHistory() throws {
        let url = URL(string: "https://wherewolf.test/api/v1/health")!
        for signature in ["unauthenticated", "not authenticated", "Hey, I'm alive!"] {
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                headerFields: ["X-Dawarich-Response": signature, "X-Dawarich-Version": "1.20.0"])!
            XCTAssertTrue(DawarichServer.classify(response) == .dawarich(version: "1.20.0", authenticated: false, account: nil))
        }
    }

    func testUnknownAndOlderVersionsNeverRequest() async throws {
        HistoryTestProtocol.handler = { mock in
            XCTFail("Unsupported version must not send history requests")
            mock.respond(status: 500, object: [:])
        }
        for version in ["", "unknown", "1.19.9", "0.99.0", "2.0.0", "1.20", "1.20.0-beta", "1.20.0+dev"] {
            do {
                _ = try await client(version: version).firstPointDate()
                XCTFail("Expected unsupported history")
            } catch { XCTAssertTrue(error as? DawarichHistoryError == .unsupportedVersion) }
        }
        XCTAssertTrue(DawarichHistoryClient.supports(version: "1.20.0"))
        XCTAssertTrue(DawarichHistoryClient.supports(version: "v1.22.0"))
    }

    func testFirstPointUsesBearerPrefixHeadersAndOneAscendingPoint() async throws {
        let timestamp = date("2014-05-20T13:00:00Z")
        HistoryTestProtocol.handler = { mock in
            let request = mock.request
            XCTAssertEqual(request.url?.path, "/prefix/api/v1/points")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-history-key")
            XCTAssertTrue(request.value(forHTTPHeaderField: "X-Proxy") == "fixture-proxy")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
            XCTAssertFalse(request.httpShouldHandleCookies)
            XCTAssertNil(request.httpBody)
            let query = mock.query
            XCTAssertEqual(query["per_page"], "1")
            XCTAssertEqual(query["page"], "1")
            XCTAssertEqual(query["order"], "asc")
            XCTAssertEqual(query["mask_privacy_zones"], "true")
            XCTAssertNil(query["api_key"])
            XCTAssertNil(query["start_at"])
            mock.respond(headers: ["X-Current-Page": "1", "X-Total-Pages": "10"], object: [self.point(at: timestamp)])
        }
        let first = try await client().firstPointDate()
        XCTAssertEqual(first, timestamp)
    }

    func testPointsPaginationUsesLocalDayAndConvertsVelocity() async throws {
        let day = date("2026-03-08T05:00:00Z")
        let requests = HistoryTestCounter()
        HistoryTestProtocol.handler = { mock in
            requests.increment()
            XCTAssertEqual(mock.query["start_at"], "2026-03-08T05:00:00Z")
            XCTAssertEqual(mock.query["end_at"], "2026-03-09T03:59:59Z")
            XCTAssertEqual(mock.query["per_page"], "1000")
            XCTAssertEqual(mock.query["order"], "asc")
            XCTAssertEqual(mock.query["mask_privacy_zones"], "true")
            let page = Int(mock.query["page"]!)!
            mock.respond(headers: ["X-Current-Page": String(page), "X-Total-Pages": "2"],
                         object: [self.point(id: page, at: day.addingTimeInterval(Double(page) * 60))])
        }
        let points = try await client().points(on: day, calendar: calendar)
        XCTAssertEqual(requests.value, 2)
        XCTAssertEqual(points.map(\.location.id), [-1, -2])
        XCTAssertEqual(points.first?.payload?.speed, 10)
        XCTAssertEqual(points.first?.payload?.battery, "80%")
        XCTAssertTrue(points.first?.location.latitude == 40.1 && points.first?.location.longitude == -73.2)
    }

    func testLaterPageFailureReturnsNoPartialDay() async throws {
        let day = date("2026-11-01T04:00:00Z")
        HistoryTestProtocol.handler = { mock in
            XCTAssertEqual(mock.query["end_at"], "2026-11-02T04:59:59Z")
            if mock.query["page"] == "1" {
                mock.respond(headers: ["X-Current-Page": "1", "X-Total-Pages": "2"], object: [self.point(at: day)])
            } else { mock.respond(status: 401, object: ["error": "fixture"]) }
        }
        do {
            _ = try await client().points(on: day, calendar: calendar)
            XCTFail("Expected all-or-nothing day failure")
        } catch { XCTAssertTrue(error as? DawarichHistoryError == .authentication) }
    }

    func testChangingPageCountAndConflictingDuplicateIDsFailWholeDay() async throws {
        let day = date("2026-05-01T04:00:00Z")
        for changingPages in [true, false] {
            HistoryTestProtocol.handler = { mock in
                let page = mock.query["page"]!
                let total = changingPages && page == "2" ? "3" : "2"
                mock.respond(headers: ["X-Current-Page": page, "X-Total-Pages": total],
                             object: [self.point(at: day.addingTimeInterval(page == "2" ? 60 : 0))])
            }
            do {
                _ = try await client().points(on: day, calendar: calendar)
                XCTFail("Expected inconsistent page failure")
            } catch { XCTAssertTrue(error as? DawarichHistoryError == .invalidResponse) }
        }
    }

    func testIdenticalPageOverlapIsDeduplicatedByServerID() async throws {
        let day = date("2026-05-01T04:00:00Z")
        HistoryTestProtocol.handler = { mock in
            mock.respond(headers: ["X-Current-Page": mock.query["page"]!, "X-Total-Pages": "2"],
                         object: [self.point(at: day)])
        }
        let points = try await client().points(on: day, calendar: calendar)
        XCTAssertEqual(points.count, 1)
    }

    func testMissingPaginationCannotMarkDayComplete() async throws {
        HistoryTestProtocol.handler = { $0.respond(object: []) }
        do {
            _ = try await client().points(on: date("2026-05-01T04:00:00Z"), calendar: calendar)
            XCTFail("Missing pagination must fail")
        } catch { XCTAssertTrue(error as? DawarichHistoryError == .invalidResponse) }
    }

    func testEmptyDayHasZeroPages() async throws {
        HistoryTestProtocol.handler = { $0.respond(headers: ["X-Current-Page": "1", "X-Total-Pages": "0"], object: []) }
        let points = try await client().points(on: date("2026-05-01T04:00:00Z"), calendar: calendar)
        XCTAssertTrue(points.isEmpty)
    }

    func testLocalDayCountsUseExactStatisticsAndRebucketTimelineIntervals() async throws {
        let start = date("2026-03-08T05:00:00Z")
        let end = date("2026-03-09T04:00:00Z")
        let calls = HistoryTestCounter()
        HistoryTestProtocol.handler = { mock in
            calls.increment()
            if mock.request.url?.path == "/prefix/api/v1/timeline" {
                XCTAssertEqual(mock.query["distance_unit"], "km")
                XCTAssertEqual(mock.query["mask_privacy_zones"], "true")
                // An account-local date cannot be used as the device-local date.
                mock.respond(object: ["days": [["date": "2026-03-07", "summary": ["total_distance": 9999], "entries": [
                    ["type": "visit", "name": "Fixture Place", "started_at": "2026-03-08T04:00:00Z", "ended_at": "2026-03-09T06:00:00Z"]
                ]]]])
            } else if mock.request.url?.path == "/prefix/api/v1/points" {
                XCTAssertEqual(mock.query["per_page"], "1")
                XCTAssertEqual(mock.query["page"], "1")
                XCTAssertEqual(mock.query["mask_privacy_zones"], "true")
                XCTAssertEqual(mock.query["start_at"], "2026-03-08T05:00:00Z")
                XCTAssertEqual(mock.query["end_at"], "2026-03-09T03:59:59Z")
                let timestamp = mock.query["order"] == "asc" ? start.addingTimeInterval(60) : end.addingTimeInterval(-60)
                mock.respond(headers: ["X-Current-Page": "1", "X-Total-Pages": "7"], object: [self.point(at: timestamp)])
            } else {
                XCTAssertEqual(mock.request.url?.path, "/prefix/api/v1/maps/statistics")
                if mock.query["start_at"] == "2026-03-08T05:00:00Z" {
                    XCTAssertEqual(mock.query["end_at"], "2026-03-09T03:59:59Z")
                    mock.respond(object: ["points": 7, "distance_meters": 1200.5])
                } else {
                    XCTAssertEqual(mock.query["start_at"], "2026-03-09T04:00:00Z")
                    XCTAssertEqual(mock.query["end_at"], "2026-03-10T03:59:59Z")
                    mock.respond(object: ["points": 0, "distance_meters": 0])
                }
            }
        }
        let days = try await client().days(from: start, through: end, calendar: calendar)
        XCTAssertEqual(calls.value, 5)
        XCTAssertEqual(days.map(\.pointCount), [7, 0])
        XCTAssertEqual(days.map(\.distance), [1200.5, 0])
        XCTAssertEqual(days.map(\.day), [start, end])
        XCTAssertEqual(days.first?.stops.first?.startedAt, start)
        XCTAssertEqual(days.first?.stops.first?.endedAt, end)
        XCTAssertTrue(days.first?.stops.first?.name == "Fixture Place")
        XCTAssertTrue(days.allSatisfy { $0.state == .notDownloaded })
        XCTAssertEqual(days.first?.firstTimestamp, start.addingTimeInterval(60))
        XCTAssertEqual(days.first?.lastTimestamp, end.addingTimeInterval(-60))
        XCTAssertNil(days.last?.firstTimestamp)
        XCTAssertNil(days.last?.lastTimestamp)
    }

    func testDayIndexRejectsFirstPointOutsideItsLocalDay() async throws {
        let day = date("2026-03-08T05:00:00Z")
        HistoryTestProtocol.handler = { mock in
            switch mock.request.url?.path {
            case "/prefix/api/v1/timeline": mock.respond(object: ["days": []])
            case "/prefix/api/v1/maps/statistics": mock.respond(object: ["points": 1, "distance_meters": 0])
            default:
                mock.respond(headers: ["X-Current-Page": "1", "X-Total-Pages": "1"],
                             object: [self.point(at: day.addingTimeInterval(-1))])
            }
        }
        do {
            _ = try await client().days(from: day, through: day, calendar: calendar)
            XCTFail("A boundary outside the requested day must not enter the index")
        } catch { XCTAssertTrue(error as? DawarichHistoryError == .invalidResponse) }
    }

    func testTimelineChunksNeverExceed31ElapsedDays() async throws {
        let start = date("2026-10-15T04:00:00Z")
        let end = date("2026-11-15T05:00:00Z")
        let timelineCalls = HistoryTestCounter()
        HistoryTestProtocol.handler = { mock in
            if mock.request.url?.path == "/prefix/api/v1/timeline" {
                timelineCalls.increment()
                let formatter = ISO8601DateFormatter()
                let from = formatter.date(from: mock.query["start_at"]!)!
                let through = formatter.date(from: mock.query["end_at"]!)!
                XCTAssertLessThan(through.timeIntervalSince(from), 31 * 24 * 60 * 60)
                mock.respond(object: ["days": []])
            } else { mock.respond(object: ["points": 0, "distance_meters": 0]) }
        }
        let days = try await client().days(from: start, through: end, calendar: calendar)
        XCTAssertEqual(days.count, 32)
        XCTAssertEqual(timelineCalls.value, 2)
    }

    func testRetryAfterSecondsDateAndExponentialFloor() {
        let url = URL(string: "https://wherewolf.test")!
        let now = date("2026-11-12T12:00:00Z")
        func response(_ value: String?) -> HTTPURLResponse {
            HTTPURLResponse(url: url, statusCode: 429, httpVersion: nil, headerFields: value.map { ["Retry-After": $0] })!
        }
        XCTAssertEqual(DawarichHistoryRetry.delay(response: response("7"), attempt: 0, now: now), 7)
        XCTAssertEqual(DawarichHistoryRetry.delay(response: response("Thu, 12 Nov 2026 12:00:12 GMT"), attempt: 0, now: now), 12)
        XCTAssertEqual(DawarichHistoryRetry.delay(response: response(nil), attempt: 2, now: now), 4)
        XCTAssertEqual(DawarichHistoryRetry.delay(response: response("invalid"), attempt: 1, now: now), 2)
    }

    func testRateLimitRetriesBeforeReturningFirstPoint() async throws {
        let calls = HistoryTestCounter()
        HistoryTestProtocol.handler = { mock in
            let number = calls.increment()
            if number == 1 { mock.respond(status: 429, headers: ["Retry-After": "0"], object: [:]) }
            else { mock.respond(headers: ["X-Current-Page": "1", "X-Total-Pages": "0"], object: []) }
        }
        let result = try await client().firstPointDate()
        XCTAssertNil(result)
        XCTAssertEqual(calls.value, 2)
    }

    func testOffServerRedirectAndPrefixEscapeAreRejected() throws {
        let delegate = DawarichHistoryRedirectDelegate(root: URL(string: "https://wherewolf.test/prefix")!)
        XCTAssertTrue(delegate.permits(URL(string: "https://wherewolf.test/prefix/api/v1/points")!))
        XCTAssertTrue(delegate.permits(URL(string: "https://wherewolf.test:443/prefix/api/v1/points")!))
        for value in ["http://wherewolf.test/prefix/api/v1/points", "https://other.wherewolf.test/prefix/api/v1/points",
                      "https://wherewolf.test:8443/prefix/api/v1/points", "https://wherewolf.test/prefix-other/api/v1/points",
                      "https://wherewolf.test/api/v1/points", "https://fixture@wherewolf.test/prefix/api/v1/points",
                      "https://wherewolf.test/prefix/../api/v1/points", "https://wherewolf.test/prefix/%2e%2e/api/v1/points"] {
            XCTAssertFalse(delegate.permits(URL(string: value)!))
        }
    }

    func testCancellationStopsPendingDayAndReturnsNoPoints() async throws {
        let started = expectation(description: "History request started")
        let stopped = expectation(description: "History request cancelled")
        HistoryTestProtocol.handler = { mock in
            mock.onStop = { stopped.fulfill() }
            started.fulfill()
        }
        let client = try client()
        let task = Task { try await client.points(on: self.date("2026-05-01T04:00:00Z"), calendar: self.calendar) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        await fulfillment(of: [stopped], timeout: 2)
    }

    func testCancellationDuringBackoffDoesNotRetry() async throws {
        let requested = expectation(description: "Server rate limited request")
        let calls = HistoryTestCounter()
        HistoryTestProtocol.handler = { mock in
            calls.increment()
            mock.respond(status: 429, headers: ["Retry-After": "3600"], object: [:])
            requested.fulfill()
        }
        let client = try client()
        let task = Task { try await client.firstPointDate() }
        await fulfillment(of: [requested], timeout: 2)
        task.cancel()
        do { _ = try await task.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(calls.value, 1)
    }

    func testIdenticalPendingRequestsCoalesce() async throws {
        let entered = expectation(description: "All consumers started")
        entered.expectedFulfillmentCount = 8
        let requested = expectation(description: "Shared network request started")
        let calls = HistoryTestCounter()
        HistoryTestProtocol.handler = { _ in
            if calls.increment() == 1 { requested.fulfill() }
        }
        let client = try client()
        let tasks = (0..<8).map { _ in
            Task {
                entered.fulfill()
                return try await client.firstPointDate()
            }
        }
        await fulfillment(of: [entered, requested], timeout: 2)
        tasks.forEach { $0.cancel() }
        for task in tasks {
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        XCTAssertEqual(calls.value, 1)
    }

    func testDistinctDayRequestsHaveAtMostTwoInFlight() async throws {
        let entered = expectation(description: "All day consumers started")
        entered.expectedFulfillmentCount = 8
        let requested = expectation(description: "Two network requests started")
        requested.expectedFulfillmentCount = 2
        let calls = HistoryTestCounter()
        let activity = HistoryTestActivity()
        HistoryTestProtocol.handler = { mock in
            activity.start()
            mock.onStop = { activity.stop() }
            if calls.increment() <= 2 { requested.fulfill() }
        }
        let client = try client()
        let day = date("2026-05-01T04:00:00Z")
        let calendar = self.calendar
        let tasks = (0..<8).map { offset in
            Task {
                entered.fulfill()
                return try await client.points(on: day.addingTimeInterval(Double(offset) * 86400), calendar: calendar)
            }
        }
        await fulfillment(of: [entered, requested], timeout: 2)
        tasks.forEach { $0.cancel() }
        for task in tasks {
            do { _ = try await task.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
        XCTAssertLessThanOrEqual(activity.maximum, 2)
    }

    func testNetworkErrorsAreSanitized() async throws {
        HistoryTestProtocol.handler = { mock in
            let error = NSError(domain: NSURLErrorDomain, code: URLError.badServerResponse.rawValue,
                                userInfo: [NSURLErrorFailingURLStringErrorKey: "https://wherewolf.test/fixture-sensitive"])
            mock.client?.urlProtocol(mock, didFailWithError: error)
        }
        do { _ = try await client().firstPointDate(); XCTFail("Expected network error") }
        catch {
            XCTAssertTrue(error as? DawarichHistoryError == .network)
            XCTAssertFalse(error.localizedDescription.contains("wherewolf.test"))
            XCTAssertFalse(error.localizedDescription.contains("fixture-sensitive"))
        }
    }
}

final class ServerHistoryCacheTests: XCTestCase {
    private var directory: URL!
    private let identity = String(repeating: "a", count: 64)

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ServerHistoryTests-" + UUID().uuidString, isDirectory: true)
    }

    override func tearDownWithError() throws {
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }

    private func day(_ offset: Int) -> Date { Date(timeIntervalSince1970: 1_700_006_400 + Double(offset) * 86400) }
    private func point(_ id: Int64, on day: Date) -> ServerHistoryPoint {
        ServerHistoryPoint(location: RecordedLocation(id: -id, timestamp: day.addingTimeInterval(60), latitude: 40.1, longitude: -73.2),
                           payload: RecordedPayload(format: "Dawarich", speed: 10, accuracy: 5, altitude: 20,
                                                    device: "fixture", battery: "80%", rawJSON: Data("{}".utf8)))
    }

    func testViewedDayLRUEvictsPointsButPermanentlyKeepsMetadata() async throws {
        let cache = ServerHistoryCache(directoryURL: directory, maximumPointDays: 2)
        try await cache.selectSource(identity)
        for offset in 0..<3 {
            try await cache.storeDays([ServerHistoryDay(day: day(offset), pointCount: 1, distance: Double(offset + 1) * 100)])
        }
        try await cache.storePoints([point(1, on: day(0))], on: day(0))
        try await cache.storePoints([point(2, on: day(1))], on: day(1))
        try await cache.touch(day(0))
        try await cache.storePoints([point(3, on: day(2))], on: day(2))
        let days = try await cache.days()
        XCTAssertEqual(days.count, 3)
        XCTAssertEqual(days.map(\.state), [.loaded, .notDownloaded, .loaded])
        XCTAssertEqual(days.map(\.distance), [100, 200, 300])
        XCTAssertEqual(days[1].pointCount, 1)
        XCTAssertEqual(days[1].firstTimestamp, day(1).addingTimeInterval(60))
        let evicted = try await cache.points(on: day(1))
        XCTAssertTrue(evicted.isEmpty)
        let loaded = try await cache.points(on: day(0))
        XCTAssertEqual(loaded.first?.payload?.speed, 10)
        try await cache.clear()
    }

    func testNoTouchDoesNotChangeEvictionOrder() async throws {
        let cache = ServerHistoryCache(directoryURL: directory, maximumPointDays: 2)
        try await cache.selectSource(identity)
        for offset in 0..<2 { try await cache.storePoints([point(Int64(offset + 1), on: day(offset))], on: day(offset)) }
        _ = try await cache.points(on: day(0), touch: false)
        try await cache.storePoints([point(3, on: day(2))], on: day(2))
        let days = try await cache.days()
        XCTAssertEqual(days.first?.state, .notDownloaded)
        try await cache.clear()
    }

    func testSourceChangeClearsAccountAndTimezoneData() async throws {
        let cache = ServerHistoryCache(directoryURL: directory)
        try await cache.selectSource(identity)
        try await cache.setFirstPointDate(day(-100))
        try await cache.storePoints([point(1, on: day(0))], on: day(0))
        try await cache.selectSource(String(repeating: "b", count: 64))
        let days = try await cache.days()
        let points = try await cache.points(on: day(0))
        let first = try await cache.firstPointDate()
        XCTAssertTrue(days.isEmpty)
        XCTAssertTrue(points.isEmpty)
        XCTAssertNil(first)
        do { try await cache.selectSource("https://wherewolf.test/fixture"); XCTFail("Raw source identity must be rejected") }
        catch { XCTAssertTrue(error is ServerHistoryCacheError) }
        try await cache.clear()
    }

    func testPointReplacementRollsBackInvalidOrDuplicateDay() async throws {
        let cache = ServerHistoryCache(directoryURL: directory)
        try await cache.selectSource(identity)
        try await cache.storePoints([point(1, on: day(0))], on: day(0))
        do {
            try await cache.storePoints([point(2, on: day(0)), point(2, on: day(0))], on: day(0))
            XCTFail("Duplicate points must not partially replace a day")
        } catch { XCTAssertTrue(error is ServerHistoryCacheError) }
        let retained = try await cache.points(on: day(0))
        XCTAssertEqual(retained.map(\.location.id), [-1])
        let days = try await cache.days()
        XCTAssertEqual(days.first?.state, .loaded)
        XCTAssertEqual(days.first?.pointCount, 1)
        try await cache.clear()
    }

    func testMetadataRefreshPreservesLoadedStateAndInvalidatesChangedCount() async throws {
        let cache = ServerHistoryCache(directoryURL: directory)
        try await cache.selectSource(identity)
        try await cache.storePoints([point(1, on: day(0))], on: day(0))
        try await cache.storeDays([ServerHistoryDay(day: day(0), pointCount: 1, distance: 150)])
        var days = try await cache.days()
        XCTAssertEqual(days.first?.state, .loaded)
        XCTAssertEqual(days.first?.firstTimestamp, day(0).addingTimeInterval(60))
        try await cache.storeDays([ServerHistoryDay(day: day(0), pointCount: 2, distance: 300)])
        days = try await cache.days()
        let points = try await cache.points(on: day(0))
        XCTAssertEqual(days.first?.state, .notDownloaded)
        XCTAssertEqual(days.first?.pointCount, 2)
        XCTAssertTrue(points.isEmpty)
        try await cache.clear()
    }

    func testProtectionBackupExclusionAndClearSize() async throws {
        let cache = ServerHistoryCache(directoryURL: directory)
        try await cache.selectSource(identity)
        try await cache.storePoints([point(1, on: day(0))], on: day(0))
        let bytes = try await cache.storageBytes()
        XCTAssertGreaterThan(bytes, 0)
        XCTAssertEqual(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertFalse(files.isEmpty)
        for file in files {
            XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
#if !targetEnvironment(simulator)
            // The simulator reports no data protection class.
            let protection = try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey] as? FileProtectionType
            XCTAssertEqual(protection, .completeUntilFirstUserAuthentication)
#endif
        }
        try await cache.clear()
        let clearedBytes = try await cache.storageBytes()
        XCTAssertEqual(clearedBytes, 0)
        try await cache.touch(day(0))
        let bytesAfterLateTouch = try await cache.storageBytes()
        XCTAssertEqual(bytesAfterLateTouch, 0, "A late view update cannot recreate a cleared cache")
        let clearedDays = try await cache.days()
        XCTAssertTrue(clearedDays.isEmpty)
        try await cache.clear()
    }

    func testSourceAndDayMetadataSurviveReopening() async throws {
        var cache: ServerHistoryCache? = ServerHistoryCache(directoryURL: directory)
        try await cache!.selectSource(identity)
        try await cache!.setFirstPointDate(day(-100))
        let stop = ServerHistoryInterval(startedAt: day(0), endedAt: day(0).addingTimeInterval(120), name: "Fixture Place")
        try await cache!.storeDays([ServerHistoryDay(day: day(0), pointCount: 4, distance: 123, stops: [stop])])
        cache = nil
        let reopened = ServerHistoryCache(directoryURL: directory)
        try await reopened.selectSource(identity)
        let days = try await reopened.days()
        let first = try await reopened.firstPointDate()
        XCTAssertEqual(first, day(-100))
        XCTAssertEqual(days.first?.pointCount, 4)
        XCTAssertEqual(days.first?.distance, 123)
        XCTAssertTrue(days.first?.stops.first?.name == "Fixture Place")
        XCTAssertEqual(days.first?.state, .notDownloaded)
        try await reopened.clear()
    }
}

private final class HistoryTestCounter {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    @discardableResult func increment() -> Int { lock.withLock { count += 1; return count } }
}

private final class HistoryTestActivity {
    private let lock = NSLock()
    private var active = 0
    private var peak = 0
    var maximum: Int { lock.withLock { peak } }
    func start() { lock.withLock { active += 1; peak = max(peak, active) } }
    func stop() { lock.withLock { active -= 1 } }
}

private final class HistoryTestProtocol: URLProtocol {
    static var handler: ((HistoryTestProtocol) -> Void)?
    var onStop: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "wherewolf.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() { onStop?() }
    var query: [String: String] {
        Dictionary(uniqueKeysWithValues: URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
    }
    func respond(status: Int = 200, headers: [String: String] = [:], object: Any) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        let data = try! JSONSerialization.data(withJSONObject: object)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
