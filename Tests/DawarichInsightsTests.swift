import XCTest
import Foundation
import SwiftUI
@testable import WhereWolf

final class DawarichInsightsTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        InsightsTestProtocol.handler = nil
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        super.tearDown()
    }

    private func cache(thumbnailBudget: Int = 64 * 1_024 * 1_024) -> DawarichInsightsCache {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("insights-tests-" + UUID().uuidString)
        directories.append(directory)
        return DawarichInsightsCache(directory: directory, thumbnailBudget: thumbnailBudget)
    }

    private func connection(version: String? = "1.22.0", token: String = "fixture-key",
                            headers: [String: String] = [:]) -> DawarichInsightsConnection {
        DawarichInsightsConnection(status: .dawarich(version: version, authenticated: true, account: nil),
            endpoint: "https://wherewolf.test/prefix/api/v1/overland/batches", token: token, headers: headers)!
    }

    private func client(version: String? = "1.22.0", cache: DawarichInsightsCache? = nil,
                        clock: @escaping () -> Date = Date.init, headers: [String: String] = [:]) -> DawarichInsightsClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InsightsTestProtocol.self]
        return DawarichInsightsClient(connection: connection(version: version, headers: headers),
                                      cache: cache ?? self.cache(), configuration: configuration, clock: clock)
    }

    func testVisibilityAndStableSelection() {
        for status in [DawarichStatus.unknown, .checking, .notDawarich,
                       .dawarich(version: "1.22.0", authenticated: false, account: nil)] {
            XCTAssertFalse(ShellTabPolicy.showsInsights(status: status))
        }
        XCTAssertTrue(ShellTabPolicy.showsInsights(status: .dawarich(version: nil, authenticated: true, account: nil)))
        XCTAssertTrue(ShellTabPolicy.showsInsights(status: .unknown, preview: true))
        XCTAssertEqual(ShellTabPolicy.validSelection(3, insights: false), 2)
        for tab in 0...2 { XCTAssertEqual(ShellTabPolicy.validSelection(tab, insights: true), tab) }
        XCTAssertEqual(ShellTabPolicy.validSelection(3, insights: true), 3)
        XCTAssertNil(DawarichInsightsConnection(status: .checking, endpoint: "https://wherewolf.test/api/v1/overland/batches", token: "fixture", headers: [:]))
    }

    @MainActor func testTabOrderAndFourMeasuredCells() {
        XCTAssertEqual(DrawerTabStrip.items(showsInsights: false).map(\.id), [0, 1, 2])
        XCTAssertEqual(DrawerTabStrip.items(showsInsights: true).map(\.id), [0, 1, 3, 2])
        let items = (0..<4).map { CGRect(x: 20 + CGFloat($0) * 86, y: 700, width: 94, height: 54) }
        let union = items.reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -4, dy: -4)
        let platter = DrawerBarGeometry(frame: union, radius: 31)
        let inset = SystemTabBarGeometry.stripInset(for: platter, items: items, itemCount: 4)
        let pitch = (union.width - 2 * inset - 2 * DrawerTabStrip.sideInset) / 4
        for (index, item) in items.enumerated() {
            XCTAssertEqual(union.minX + inset + DrawerTabStrip.sideInset + pitch * (CGFloat(index) + 0.5), item.midX, accuracy: 0.01)
        }
    }

    func testDrawerInsetsReachBothNarrowAndWideNativePlattersWithoutChangingCellSize() {
        let closed = CGSize(width: 346, height: 76)
        for system in [CGSize(width: 274, height: 62), CGSize(width: 364, height: 62), CGSize(width: 402, height: 83)] {
            let from = DrawerBarGeometry(frame: CGRect(origin: .zero, size: closed), radius: 38)
            let to = DrawerBarGeometry(frame: CGRect(origin: .zero, size: system), radius: 31)
            XCTAssertEqual(from.nativeInsetProgress(closed: closed, system: system), 0, accuracy: 0.001)
            XCTAssertEqual(to.nativeInsetProgress(closed: closed, system: system), 1, accuracy: 0.001)
            for fraction in [0.1, 0.25, 0.5, 0.75, 0.9] {
                let geometry = from.blended(to: to, progress: fraction)
                XCTAssertEqual(geometry.nativeInsetProgress(closed: closed, system: system), fraction, accuracy: 0.001)
            }
        }
    }

    func testVersionGatesAtReleaseBoundariesAndUnknownVersions() {
        let gates: [(DawarichInsightsEndpoint, String, String)] = [
            (.trackedMonths, "0.19.9", "0.20.0"), (.photos(2025), "0.18.9", "0.19.0"),
            (.overview(2025), "1.1.9", "1.2.0"), (.details(2025), "1.1.9", "1.2.0"),
            (.digests, "1.1.9", "1.2.0"), (.digest(2025), "1.1.9", "1.2.0"),
            (.places, "1.1.9", "1.2.0"), (.visits(2025), "1.1.9", "1.2.0"),
            (.cities(2025), "1.1.9", "1.2.0"), (.residency(2025), "1.4.9", "1.5.0"),
            (.countries(2025), "1.14.9", "1.15.0")]
        for (endpoint, before, release) in gates {
            XCTAssertFalse(endpoint.supports(nil))
            XCTAssertFalse(endpoint.supports(""))
            XCTAssertFalse(endpoint.supports("unknown"))
            XCTAssertFalse(endpoint.supports(before))
            XCTAssertFalse(endpoint.supports(release + "-rc1"))
            XCTAssertTrue(endpoint.supports(release))
            XCTAssertTrue(endpoint.supports("v" + release))
            XCTAssertTrue(endpoint.supports("1.22.0+custom"))
        }
    }

    func testYearAndThumbnailParametersUseSpecNames() {
        func params(_ endpoint: DawarichInsightsEndpoint) -> [String: String] {
            Dictionary(uniqueKeysWithValues: endpoint.query.map { ($0.name, $0.value ?? "") })
        }
        XCTAssertEqual(params(.photos(2025)), ["start_date": "2025-01-01", "end_date": "2025-12-31", "mask_privacy_zones": "true"])
        XCTAssertEqual(params(.cities(2025)), ["start_at": "2025-01-01", "end_at": "2025-12-31"])
        XCTAssertEqual(params(.visits(2025))["end_at"], "2025-12-31T23:59:59Z")
        XCTAssertEqual(params(.residency(2025)), ["year": "2025"])
        XCTAssertEqual(params(.details(2025)), ["year": "2025", "distance_unit": "km"])
        XCTAssertEqual(params(.thumbnail(id: "sample", source: "immich")), ["source": "immich"])
        XCTAssertFalse(DawarichInsightsEndpoint.thumbnail(id: "..", source: "immich").isValid)
        XCTAssertFalse(DawarichInsightsEndpoint.thumbnail(id: "sample", source: "other").isValid)
        XCTAssertFalse(DawarichInsightsEndpoint.photos(0).isValid)
    }

    func testAuthenticatedGetPreservesPrefixAndHeadersWithoutKeyInQuery() async throws {
        InsightsTestProtocol.handler = { mock in
            let request = mock.request
            XCTAssertTrue(request.url?.host == "wherewolf.test")
            XCTAssertTrue(request.url?.path == "/prefix/api/v1/insights")
            XCTAssertTrue(request.url?.query?.contains("year=2025") == true)
            XCTAssertTrue(request.url?.query?.contains("api_key") == false)
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            XCTAssertTrue(request.value(forHTTPHeaderField: "X-Proxy") == "fixture-proxy")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertNil(request.httpBody)
            XCTAssertFalse(request.httpShouldHandleCookies)
            mock.respond(data: Data(#"{"year":2025,"totals":{"totalDistance":12,"distanceUnit":"km"}}"#.utf8))
        }
        let result = await client(headers: ["X-Proxy": "fixture-proxy", "Authorization": "ignored"])
            .read(.overview(2025), as: DawarichInsights.Overview.self, policy: .refresh(force: true))
        XCTAssertEqual(result.value?.totals?.totalDistance, 12)
        XCTAssertFalse(result.offline)
    }

    func testUnsupportedVersionNeverRequestsOrShowsOlderCache() async {
        let cache = cache()
        let connection = connection(version: "1.1.0")
        let generation = await cache.generation
        await cache.write(.init(body: Data(#"{"year":2025}"#.utf8), updated: Date()), scope: connection.id,
                          key: DawarichInsightsEndpoint.overview(2025).cacheKey, generation: generation)
        InsightsTestProtocol.handler = { _ in XCTFail("Unsupported endpoint requested") }
        let result = await client(version: "1.1.0", cache: cache)
            .read(.overview(2025), as: DawarichInsights.Overview.self, policy: .refresh(force: true))
        XCTAssertNil(result.value)
    }

    func testRedirectsAreRefusedEvenOnTheSameHost() {
        let policy = DawarichRequestPolicy()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InsightsTestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://wherewolf.test/api/v1/insights")!
        let task = session.dataTask(with: url)
        for target in ["https://wherewolf.test/other", "https://redirect.wherewolf.test/other"] {
            let response = HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: ["Location": target])!
            var called = false
            policy.urlSession(session, task: task, willPerformHTTPRedirection: response,
                              newRequest: URLRequest(url: URL(string: target)!)) { request in
                called = true
                XCTAssertNil(request)
            }
            XCTAssertTrue(called)
        }
    }

    func testScopeSeparatesKeyProxyAndServerVersion() {
        let first = connection()
        XCTAssertTrue(first.id != connection(token: "another-fixture").id)
        XCTAssertTrue(first.id != connection(headers: ["X-Proxy": "other-account"]).id)
        XCTAssertTrue(first.id != connection(version: "1.15.0").id)
        XCTAssertTrue(first.id == connection().id)
        XCTAssertEqual(first.id.count, 64)
    }

    func testCacheFreshnessUsesSixHoursAndRejectsFutureDates() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let entry = DawarichInsightsCache.Entry(body: Data(), updated: now)
        XCTAssertTrue(entry.isFresh(at: now))
        XCTAssertTrue(entry.isFresh(at: now.addingTimeInterval(21_599)))
        XCTAssertFalse(entry.isFresh(at: now.addingTimeInterval(21_600)))
        XCTAssertFalse(entry.isFresh(at: now.addingTimeInterval(-1)))
    }

    func testFreshCacheSkipsNetworkForceRefreshesAndOfflineKeepsTimestamp() async {
        let cache = cache()
        let clock = InsightsTestClock()
        let client = client(cache: cache, clock: { clock.now })
        var requests = 0
        InsightsTestProtocol.handler = { mock in
            requests += 1
            mock.respond(data: Data(#"{"year":2025,"totals":{"totalDistance":12}}"#.utf8))
        }
        let first = await client.read(.overview(2025), as: DawarichInsights.Overview.self, policy: .refresh(force: false))
        _ = await client.read(.overview(2025), as: DawarichInsights.Overview.self, policy: .refresh(force: false))
        XCTAssertEqual(requests, 1)
        _ = await client.read(.overview(2025), as: DawarichInsights.Overview.self, policy: .refresh(force: true))
        XCTAssertEqual(requests, 2)
        clock.now.addTimeInterval(21_600)
        InsightsTestProtocol.handler = { mock in mock.fail(.notConnectedToInternet) }
        let offline = await client.read(.overview(2025), as: DawarichInsights.Overview.self, policy: .refresh(force: false))
        XCTAssertEqual(offline.value?.year, 2025)
        XCTAssertEqual(offline.updated, first.updated)
        XCTAssertTrue(offline.offline)
        let other = await client.read(.overview(2024), as: DawarichInsights.Overview.self, policy: .cacheOnly)
        XCTAssertNil(other.value)
    }

    func testMissingForbiddenAndUnconfiguredEndpointsHideCachedSection() async {
        let client = client()
        for status in [401, 403, 404, 405, 422, 501] {
            InsightsTestProtocol.handler = { mock in mock.respond(data: Data(#"{"countries":[{"iso_a3":"DEU","name":"Germany"}]}"#.utf8)) }
            let loaded = await client.read(.countries(2025), as: DawarichInsights.Countries.self, policy: .refresh(force: true))
            XCTAssertNotNil(loaded.value)
            InsightsTestProtocol.handler = { mock in mock.respond(status: status) }
            let missing = await client.read(.countries(2025), as: DawarichInsights.Countries.self, policy: .refresh(force: true))
            XCTAssertNil(missing.value)
            XCTAssertFalse(missing.offline)
            InsightsTestProtocol.handler = { _ in XCTFail("Missing endpoint should be cached briefly") }
            let cached = await client.read(.countries(2025), as: DawarichInsights.Countries.self, policy: .refresh(force: false))
            XCTAssertNil(cached.value)
        }
    }

    func testMalformedAndOversizedResponsesDoNotEnterCache() async {
        let client = client()
        for data in [Data("invalid".utf8), Data(repeating: 32, count: DawarichInsightsCache.responseLimit + 1)] {
            InsightsTestProtocol.handler = { mock in mock.respond(data: data) }
            let result = await client.read(.overview(2025), as: DawarichInsights.Overview.self, policy: .refresh(force: true))
            XCTAssertNil(result.value)
            XCTAssertTrue(result.offline)
            let cached = await client.read(.overview(2025), as: DawarichInsights.Overview.self, policy: .cacheOnly)
            XCTAssertNil(cached.value)
        }
    }

    func testCacheFilesAreProtectedExcludedAndOpaqueAndClearRejectsLateWrites() async throws {
        let cache = cache()
        let generation = await cache.generation
        let entry = DawarichInsightsCache.Entry(body: Data("fixture".utf8), updated: Date())
        await cache.write(entry, scope: "fixture-scope", key: "overview-2025", generation: generation)
        let directory = await cache.directory
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(files.count, 1)
        for url in [directory] + files {
            let excluded = try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup
            XCTAssertEqual(excluded, true)
#if !targetEnvironment(simulator)
            // The simulator reports no data protection class.
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual(attributes[.protectionKey] as? String, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
#endif
        }
        XCTAssertEqual(files.first?.deletingPathExtension().lastPathComponent.count, 64)
        try await cache.clear()
        await cache.write(entry, scope: "fixture-scope", key: "late", generation: generation)
        let bytes = await cache.storageBytes()
        XCTAssertEqual(bytes, 0)
        let cached = await cache.read(scope: "fixture-scope", key: "overview-2025")
        XCTAssertNil(cached)
    }

    func testThumbnailBudgetEvictsOldestAndClearSeparatesFromPhoneHistory() async throws {
        let cache = cache(thumbnailBudget: 1_500)
        let generation = await cache.generation
        for key in ["first", "second", "third"] {
            await cache.write(.init(body: Data(repeating: 7, count: 800), updated: Date()), scope: "fixture", key: key,
                              thumbnail: true, generation: generation)
        }
        let bytes = await cache.storageBytes()
        XCTAssertLessThanOrEqual(bytes, 1_500)
        let directory = await cache.directory
        let sibling = directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        try Data("phone history fixture".utf8).write(to: sibling)
        defer { try? FileManager.default.removeItem(at: sibling) }
        try await cache.clear()
        XCTAssertTrue(FileManager.default.fileExists(atPath: sibling.path))
    }

#if !WHEREWOLF_APP_STORE
    func testEveryEndpointDecodesSpecExamplesAndSerializerFields() throws {
        let decoder = JSONDecoder()
        let tracked = try decoder.decode([DawarichInsights.TrackedYear].self,
            from: Data(#"[{"year":2024,"months":["Jan","Feb","Mar","Apr","May","Jun","Jul","Aug","Sep","Oct","Nov","Dec"]}]"#.utf8))
        XCTAssertEqual(tracked.first?.months.count, 12)
        let fixture = DawarichInsightsFixtures.snapshot()
        XCTAssertEqual(fixture.overview?.totals?.countriesCount, 3)
        XCTAssertEqual(fixture.details?.comparison?.previousYear, 2024)
        XCTAssertEqual(fixture.details?.travelPatterns?.dayOfWeek?.count, 7)
        XCTAssertEqual(fixture.countries?.countries.first?.iso_a3, "DEU")
        XCTAssertEqual(fixture.cities?.data.first?.cities.first?.stayed_for, 24490)
        XCTAssertEqual(fixture.residency?.countries.first?.days, 178)
        XCTAssertEqual(fixture.places.first?.id, 101)
        XCTAssertEqual(fixture.visits.first?.duration, 480)
        XCTAssertEqual(fixture.photos.count, 3)
        XCTAssertEqual(fixture.digest?.distance?.meters, 12_482_600)
        let digests = try decoder.decode(DawarichInsights.DigestList.self, from: DawarichInsightsFixtures.data("digests"))
        XCTAssertEqual(digests.digests.first?.year, 2025)
        let changed = Data(#"{"digests":[{"year":2025,"distance":{"meters":12000,"converted":12,"unit":"km"}}],"availableYears":[]}"#.utf8)
        XCTAssertEqual(try decoder.decode(DawarichInsights.DigestList.self, from: changed).digests.count, 1)
        XCTAssertEqual(fixture.sections, ["year", "comparison", "patterns", "countries", "cities", "places", "visits", "photos", "digest"])
    }

    func testChartUsesMeterValuesAndStatsHaveVoiceOverLabels() throws {
        let snapshot = DawarichInsightsFixtures.snapshot()
        let overview = try XCTUnwrap(snapshot.overview)
        XCTAssertEqual(overview.months.count, 12)
        XCTAssertEqual(overview.months.reduce(0) { $0 + $1.meters }, 12_482_600, accuracy: 0.01)
        for month in overview.months {
            XCTAssertTrue(month.accessibilityLabel.contains(month.title))
            XCTAssertTrue(month.accessibilityLabel.contains("km"))
        }
        for stat in overview.stats {
            XCTAssertEqual(stat.accessibilityLabel, stat.title + ", " + stat.value)
        }
        XCTAssertEqual(snapshot.digest?.months.first?.meters, 824_000)
        XCTAssertEqual(snapshot.topPlaces.first?.name, "Example Garden Studio")
        XCTAssertEqual(snapshot.topPlaces.first?.minutes, 900)
    }

    func testEmptyAndNullSectionsStayHidden() throws {
        var snapshot = DawarichInsights.Snapshot()
        XCTAssertTrue(snapshot.sections.isEmpty)
        snapshot.overview = try JSONDecoder().decode(DawarichInsights.Overview.self,
            from: Data(#"{"year":2025,"totals":{"totalDistance":0,"countriesCount":0,"citiesCount":0},"activityHeatmap":null}"#.utf8))
        snapshot.details = try JSONDecoder().decode(DawarichInsights.Details.self,
            from: Data(#"{"year":2025,"comparison":null,"travelPatterns":{}}"#.utf8))
        snapshot.countries = try JSONDecoder().decode(DawarichInsights.Countries.self, from: Data(#"{"countries":[]}"#.utf8))
        snapshot.cities = try JSONDecoder().decode(DawarichInsights.Cities.self, from: Data(#"{"data":[{"country":"Germany","cities":[]}]}"#.utf8))
        XCTAssertTrue(snapshot.sections.isEmpty)
    }

    func testFlagsAcceptBothISOFormatsAndRejectInvalidCodes() {
        XCTAssertEqual(DawarichInsights.flag("DEU"), "🇩🇪")
        XCTAssertEqual(DawarichInsights.flag("FR"), "🇫🇷")
        XCTAssertEqual(DawarichInsights.flag("prt"), "🇵🇹")
        XCTAssertEqual(DawarichInsights.flag("unknown"), "")
    }

    func testPhotosUseCanonicalInstantAndAuthenticatedThumbnailPath() async throws {
        let photo = try XCTUnwrap(DawarichInsightsFixtures.snapshot().photos.first)
        XCTAssertEqual(photo.date, DawarichInsights.parseDate("2025-12-14T10:20:00Z"))
        XCTAssertTrue(photo.accessibilityLabel.contains("Photo"))
        let data = Data([0xff, 0xd8, 0xff, 0x00])
        InsightsTestProtocol.handler = { mock in
            XCTAssertTrue(mock.request.url?.path == "/prefix/api/v1/photos/sample%2Dgarden/thumbnail"
                || mock.request.url?.path == "/prefix/api/v1/photos/sample-garden/thumbnail")
            XCTAssertTrue(mock.request.url?.query == "source=immich")
            XCTAssertTrue(mock.request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-key")
            XCTAssertEqual(mock.request.value(forHTTPHeaderField: "Accept"), "image/jpeg")
            mock.respond(data: data)
        }
        let client = client()
        let first = await client.thumbnail(photo)
        XCTAssertTrue(first == data)
        InsightsTestProtocol.handler = { _ in XCTFail("Fresh thumbnail requested twice") }
        let cached = await client.thumbnail(photo)
        XCTAssertTrue(cached == data)
    }

    @MainActor func testPreviewHasAllSectionsAndDoesNotWriteDefaults() async {
        let domain = Bundle.main.bundleIdentifier!
        let defaults = UserDefaults.standard.persistentDomain(forName: domain) ?? [:]
        InsightsTestProtocol.handler = { _ in XCTFail("Preview made a request") }
        let model = DawarichInsightsModel(preview: true)
        await model.load(connection: nil, force: true)
        XCTAssertEqual(model.snapshot.sections.count, 9)
        XCTAssertEqual(model.years, [2025, 2024])
        await model.selectYear(2024)
        XCTAssertEqual(model.snapshot.overview?.year, 2024)
        XCTAssertTrue(NSDictionary(dictionary: defaults).isEqual(to: UserDefaults.standard.persistentDomain(forName: domain) ?? [:]))
    }
#endif

    @MainActor func testNavigationDefersUntilPhoneHistoryAndKeepsOriginalServerDate() throws {
        let now = Date()
        let start = now.addingTimeInterval(-600)
        let points = (0...5).map { RecordedLocation(id: Int64($0 + 1), timestamp: start.addingTimeInterval(Double($0) * 60),
                                                   latitude: 45, longitude: -122) }
        let model = HistoryPlaybackModel(pointLoader: { _, completion in completion(points) },
            payloadLoader: { _, completion in completion([:]) }, places: { [] },
            landmarkBuilder: { points, timeline, places, calendar, locale, completion in
                completion(HistoryLandmarks(points: points, timeline: timeline, places: places, calendar: calendar, locale: locale))
            }, clock: { now })
        let request = HistoryNavigationRequest.moment(start.addingTimeInterval(-365 * 86_400))
        model.navigate(to: request)
        XCTAssertNil(model.selectedIndex)
        model.setConsumerActive(true)
        XCTAssertEqual(model.selectedIndex, 0)
        XCTAssertEqual(model.navigationRequest, request)
        let moment = HistoryNavigationRequest.moment(start.addingTimeInterval(125))
        model.navigate(to: moment)
        XCTAssertEqual(model.selectedIndex, 2)
        XCTAssertEqual(model.navigationRequest?.id, moment.id)
        model.beginRulerInteraction()
        XCTAssertNil(model.navigationRequest)
        model.endRulerInteraction()
        XCTAssertFalse(model.applyNavigationRequest())
        model.navigate(to: moment)
        model.returnToLive()
        XCTAssertNil(model.navigationRequest)
    }

    func testMonthRequestKeepsCalendarIntervalAndRejectsInvalidMonths() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let request = try XCTUnwrap(HistoryNavigationRequest.month(year: 2024, month: 2, calendar: calendar))
        XCTAssertEqual(request.interval?.duration, 29 * 86_400)
        XCTAssertEqual(request.date, request.interval?.start)
        XCTAssertNil(HistoryNavigationRequest.month(year: 2025, month: 13))
        XCTAssertNil(HistoryNavigationRequest.month(year: 0, month: 1))
    }
}

private final class InsightsTestClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
}

private final class InsightsTestProtocol: URLProtocol {
    static var handler: ((InsightsTestProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "wherewolf.test" else {
            XCTFail("Unexpected Insights request host")
            fail(.unsupportedURL)
            return
        }
        guard let handler = Self.handler else { fail(.resourceUnavailable); return }
        handler(self)
    }
    override func stopLoading() { }
    func respond(status: Int = 200, data: Data = Data()) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
    func fail(_ error: URLError.Code) { client?.urlProtocol(self, didFailWithError: URLError(error)) }
}
