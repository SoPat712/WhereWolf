import XCTest
import Foundation
import SwiftUI
import Observation
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
                        clock: @escaping () -> Date = Date.init, headers: [String: String] = [:],
                        timeout: TimeInterval = 15) -> DawarichInsightsClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [InsightsTestProtocol.self]
        return DawarichInsightsClient(connection: connection(version: version, headers: headers),
                                      cache: cache ?? self.cache(), configuration: configuration, clock: clock, timeout: timeout)
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

    func testUnknownOlderAndCustomVersionsProbeReadOnlyCapabilities() async {
        let versions: [String?] = [nil, "", "unknown", "0.27.0", "1.1.9", "1.2.0-rc1", "1.22.0+custom"]
        for version in versions {
            InsightsTestProtocol.handler = { mock in
                XCTAssertEqual(mock.request.httpMethod, "GET")
                mock.respond(data: Data(#"{"year":2025,"totals":{"totalDistance":12}}"#.utf8))
            }
            let result = await client(version: version)
                .read(.overview(2025), as: DawarichInsights.Overview.self, policy: .refresh(force: true))
            XCTAssertEqual(result.value?.year, 2025)
            XCTAssertEqual(result.outcome, .available)
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

    func testLegacyUnavailableCacheIsReprobedOnOlderServers() async {
        let cache = cache()
        let connection = connection(version: "1.1.0")
        let generation = await cache.generation
        await cache.write(.init(body: Data(), updated: Date(), unavailable: true), scope: connection.id,
                          key: DawarichInsightsEndpoint.overview(2025).cacheKey, generation: generation)
        InsightsTestProtocol.handler = { mock in
            mock.respond(data: Data(#"{"year":2025,"totals":{"totalDistance":12}}"#.utf8))
        }
        let result = await client(version: "1.1.0", cache: cache)
            .read(.overview(2025), as: DawarichInsights.Overview.self, policy: .refresh(force: false))
        XCTAssertEqual(result.value?.year, 2025)
        XCTAssertEqual(result.outcome, .available)
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

    func testMissingEndpointsHideCachedSectionAndRememberHTTPStatus() async {
        let client = client()
        for status in [404, 405, 410, 501] {
            InsightsTestProtocol.handler = { mock in mock.respond(data: Data(#"{"countries":[{"iso_a3":"DEU","name":"Germany"}]}"#.utf8)) }
            let loaded = await client.read(.countries(2025), as: DawarichInsights.Countries.self, policy: .refresh(force: true))
            XCTAssertNotNil(loaded.value)
            InsightsTestProtocol.handler = { mock in mock.respond(status: status) }
            let missing = await client.read(.countries(2025), as: DawarichInsights.Countries.self, policy: .refresh(force: true))
            XCTAssertNil(missing.value)
            XCTAssertFalse(missing.offline)
            XCTAssertEqual(missing.outcome, .unsupported(status))
            InsightsTestProtocol.handler = { _ in XCTFail("Missing endpoint should be cached briefly") }
            let cached = await client.read(.countries(2025), as: DawarichInsights.Countries.self, policy: .refresh(force: false))
            XCTAssertNil(cached.value)
            XCTAssertEqual(cached.outcome, .unsupported(status))
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

    func testValidationAuthenticationAndServerFailuresOfferRetryWithSavedData() async {
        let client = client()
        InsightsTestProtocol.handler = { $0.respond(data: Data(#"{"year":2025,"totals":{"totalDistance":12}}"#.utf8)) }
        let first = await client.read(.overview(2025), as: DawarichInsights.Overview.self, policy: .refresh(force: true))
        for status in [400, 401, 403, 422, 429, 500, 502, 503] {
            InsightsTestProtocol.handler = { $0.respond(status: status, data: Data("private-server-error".utf8)) }
            let result = await client.read(.overview(2025), as: DawarichInsights.Overview.self, policy: .refresh(force: true))
            XCTAssertEqual(result.outcome, .failed(.http(status)))
            XCTAssertEqual(result.value?.totals?.totalDistance, 12)
            XCTAssertEqual(result.updated, first.updated)
            XCTAssertTrue(result.offline)
            XCTAssertFalse(DawarichInsightsFailure.http(status).message.contains("private-server-error"))
        }
    }

    func testUnconfiguredPhotoIntegrationIsHiddenWithoutHidingAuthenticationErrors() async {
        let client = client()
        InsightsTestProtocol.handler = { $0.respond(status: 401) }
        let photos = await client.read(.photos(2025), as: [DawarichInsights.Photo].self, policy: .refresh(force: true))
        let overview = await client.read(.overview(2025), as: DawarichInsights.Overview.self, policy: .refresh(force: true))
        XCTAssertEqual(photos.outcome, .unsupported(401))
        XCTAssertEqual(overview.outcome, .failed(.http(401)))
    }

    func testDecodeFailureHasTerminalStateAndIsNotNegativelyCached() async {
        let client = client()
        InsightsTestProtocol.handler = { $0.respond(data: Data(#"{"year":"unexpected"}"#.utf8)) }
        let broken = await client.read(.overview(2025), as: DawarichInsights.Overview.self, policy: .refresh(force: true))
        XCTAssertEqual(broken.outcome, .failed(.decoding))
        InsightsTestProtocol.handler = { $0.respond(data: Data(#"{"year":2025}"#.utf8)) }
        let retried = await client.read(.overview(2025), as: DawarichInsights.Overview.self, policy: .refresh(force: false))
        XCTAssertEqual(retried.outcome, .available)
    }

    func testAbsoluteDeadlineResolvesARequestThatNeverReplies() async {
        let client = client(timeout: 0.05)
        InsightsTestProtocol.handler = { _ in }
        let result = await client.read(.overview(2025), as: DawarichInsights.Overview.self, policy: .refresh(force: true))
        XCTAssertEqual(result.outcome, .failed(.timedOut))
    }

    func testClientCancellationResolvesAndDoesNotCacheFailure() async {
        let client = client()
        let started = expectation(description: "GET started")
        InsightsTestProtocol.handler = { _ in started.fulfill() }
        let task = Task { await client.read(.overview(2025), as: DawarichInsights.Overview.self, policy: .refresh(force: true)) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        let result = await task.value
        XCTAssertEqual(result.outcome, .failed(.cancelled))
        let cached = await client.read(.overview(2025), as: DawarichInsights.Overview.self, policy: .cacheOnly)
        XCTAssertEqual(cached.outcome, .notCached)
    }

    @MainActor func testSectionsPublishBeforeDiscoveryOrSlowSectionsFinish() async {
        let client = client()
        let model = DawarichInsightsModel(initialYear: 2025, clientFactory: { _ in client })
        let published = expectation(description: "Year published while other GETs are held")
        observeOverview(model, published: published)
        InsightsTestProtocol.handler = { mock in
            if mock.request.url?.path.hasSuffix("/insights") == true, mock.request.url?.query?.contains("year=2025") == true {
                mock.respond(data: Data(#"{"year":2025,"totals":{"totalDistance":12}}"#.utf8))
            }
        }
        let task = Task { await model.load(connection: connection()) }
        await fulfillment(of: [published], timeout: 2)
        XCTAssertEqual(model.snapshot.overview?.totals?.totalDistance, 12)
        XCTAssertTrue(model.loading)
        XCTAssertFalse(model.showEmptyState)
        task.cancel()
        await task.value
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.state(for: .photos), .failed(.cancelled))
        XCTAssertEqual(model.state(for: .overview), .loaded)
    }

    @MainActor func testEveryFailurePathLeavesNoLoadingSections() async {
        for failure in [DawarichInsightsFailure.http(422), .http(500), .decoding, .timedOut] {
            let client = client(timeout: failure == .timedOut ? 0.05 : 15)
            InsightsTestProtocol.handler = { mock in
                switch failure {
                case .http(let status): mock.respond(status: status)
                case .decoding: mock.respond(data: Data("not-json".utf8))
                default: break
                }
            }
            let model = DawarichInsightsModel(initialYear: 2025, clientFactory: { _ in client })
            await model.load(connection: connection())
            XCTAssertFalse(model.loading, "\(failure)")
            XCTAssertTrue(model.showEmptyState)
            for section in DawarichInsightsSection.allCases {
                XCTAssertEqual(model.state(for: section), .failed(failure))
            }
        }
    }

    @MainActor private func observeOverview(_ model: DawarichInsightsModel, published: XCTestExpectation) {
        if model.snapshot.overview != nil { published.fulfill(); return }
        withObservationTracking { _ = model.snapshot.overview } onChange: {
            Task { @MainActor in self.observeOverview(model, published: published) }
        }
    }

    @MainActor func testCancellationFinishesEverySectionAndNextAppearanceCanLoad() async {
        let client = client()
        let model = DawarichInsightsModel(initialYear: 2025, clientFactory: { _ in client })
        let started = expectation(description: "First GET")
        let count = InsightsRequestCounter()
        InsightsTestProtocol.handler = { _ in if count.increment() == 1 { started.fulfill() } }
        let task = Task { await model.load(connection: connection()) }
        await fulfillment(of: [started], timeout: 2)
        task.cancel()
        await task.value
        XCTAssertFalse(model.loading)
        for section in DawarichInsightsSection.allCases {
            XCTAssertEqual(model.state(for: section), .failed(.cancelled))
        }
        InsightsTestProtocol.handler = { $0.respond(status: 404) }
        await model.load(connection: connection())
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.state(for: .overview), .unsupported(404))
    }

    @MainActor func testUnsupportedServerShowsOneInformativeEmptyState() async {
        let client = client(version: "0.27.0")
        InsightsTestProtocol.handler = { $0.respond(status: 404) }
        let model = DawarichInsightsModel(initialYear: 2025, clientFactory: { _ in client })
        await model.load(connection: connection(version: "0.27.0"))
        XCTAssertTrue(model.showEmptyState)
        XCTAssertTrue(model.snapshot.sections.isEmpty)
        XCTAssertTrue(model.emptyMessage.contains("Dawarich 0.27.0"))
        XCTAssertTrue(model.emptyMessage.contains("Countries (HTTP 404)"))
        XCTAssertTrue(model.emptyMessage.contains("not saved for this year"))
        for section in DawarichInsightsSection.allCases {
            XCTAssertEqual(model.state(for: section), .unsupported(404))
            XCTAssertNil(model.state(for: section).failure)
            XCTAssertFalse(model.state(for: section).isLoading)
        }
    }

    @MainActor func testMissingYearAndOlderResidencyWithoutYearBothResolve() async {
        let client = client()
        InsightsTestProtocol.handler = { mock in
            if mock.request.url?.path.hasSuffix("/insights") == true, mock.request.url?.query?.contains("year=") == true {
                mock.respond(data: Data(#"{"year":2024,"totals":{"totalDistance":12}}"#.utf8))
            } else if mock.request.url?.path.hasSuffix("/residency") == true {
                mock.respond(data: Data(#"{"countries":[{"country_name":"Germany","days":10}]}"#.utf8))
            } else { mock.respond(status: 404) }
        }
        let model = DawarichInsightsModel(initialYear: 2025, clientFactory: { _ in client })
        await model.load(connection: connection())
        XCTAssertEqual(model.state(for: .overview), .failed(.missingYear))
        XCTAssertNil(model.snapshot.overview)
        XCTAssertEqual(model.state(for: .residency), .loaded)
        XCTAssertTrue(model.snapshot.sections.contains("countries"))
        XCTAssertFalse(model.loading)
    }

    @MainActor func testRetryOnlyRequestsItsSectionAndRecovers() async {
        let client = client()
        InsightsTestProtocol.handler = { $0.respond(status: 500) }
        let model = DawarichInsightsModel(initialYear: 2025, clientFactory: { _ in client })
        await model.load(connection: connection())
        let count = InsightsRequestCounter()
        InsightsTestProtocol.handler = { mock in
            count.increment()
            XCTAssertTrue(mock.request.url?.path.hasSuffix("/countries/visited") == true)
            mock.respond(data: Data(#"{"countries":[{"iso_a3":"DEU","name":"Germany"}]}"#.utf8))
        }
        await model.retry(.countries)
        XCTAssertEqual(count.value, 1)
        XCTAssertEqual(model.state(for: .countries), .loaded)
        XCTAssertEqual(model.state(for: .overview), .failed(.http(500)))
        XCTAssertFalse(model.showEmptyState)
        XCTAssertFalse(model.loading)
    }

    @MainActor func testClearingPresentationCancelsReadsAndRejectsLatePublication() async {
        let client = client()
        let model = DawarichInsightsModel(initialYear: 2025, clientFactory: { _ in client })
        let started = expectation(description: "First GET")
        let count = InsightsRequestCounter()
        InsightsTestProtocol.handler = { _ in if count.increment() == 1 { started.fulfill() } }
        let task = Task { await model.load(connection: connection()) }
        await fulfillment(of: [started], timeout: 2)
        model.clearPresentation()
        await task.value
        XCTAssertFalse(model.loading)
        XCTAssertTrue(model.snapshot.sections.isEmpty)
        XCTAssertTrue(model.showEmptyState)
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
    @MainActor func testModelCacheRefreshAndIndependentRetryKeepPublishedSections() async {
        let client = client()
        let count = InsightsRequestCounter()
        InsightsTestProtocol.handler = { mock in count.increment(); self.respondFixture(mock) }
        let model = DawarichInsightsModel(initialYear: 2025, clientFactory: { _ in client })
        await model.load(connection: connection())
        let firstCount = count.value
        XCTAssertEqual(model.snapshot.sections.count, 9)
        XCTAssertFalse(model.loading)
        await model.load(connection: connection())
        XCTAssertEqual(count.value, firstCount)
        await model.load(connection: connection(), force: true)
        XCTAssertGreaterThan(count.value, firstCount)
        let cached = model.snapshot.updated
        InsightsTestProtocol.handler = { $0.fail(.notConnectedToInternet) }
        await model.load(connection: connection(), force: true)
        XCTAssertEqual(model.snapshot.sections.count, 9)
        XCTAssertEqual(model.snapshot.updated, cached)
        XCTAssertTrue(model.snapshot.offline)
        XCTAssertFalse(model.loading)
        XCTAssertEqual(model.state(for: .overview), .failed(.network))
    }

    @MainActor func testMissingCurrentYearFindsOlderYearWithoutRequiringDigestCatalog() async {
        let client = client()
        InsightsTestProtocol.handler = { mock in
            let url = mock.request.url!
            if url.path.hasSuffix("/tracked_months") {
                mock.respond(data: Data(#"[{"year":2025,"months":["Jan"]}]"#.utf8))
            } else if url.path.hasSuffix("/insights"), url.query?.contains("year=2025") == true {
                mock.respond(data: DawarichInsightsFixtures.data("overview"))
            } else { mock.respond(status: 404) }
        }
        let model = DawarichInsightsModel(initialYear: 2026, clientFactory: { _ in client })
        await model.load(connection: connection())
        XCTAssertEqual(model.year, 2025)
        XCTAssertEqual(model.snapshot.overview?.year, 2025)
        XCTAssertEqual(model.years, [2026, 2025])
        XCTAssertFalse(model.loading)
        await model.selectYear(2026)
        XCTAssertEqual(model.year, 2026)
        XCTAssertNil(model.snapshot.overview)
        XCTAssertTrue(model.showEmptyState)
    }

    @MainActor func testReplacingYearCancelsPriorRequestsAndKeepsNewYear() async {
        let client = client(timeout: 2)
        let model = DawarichInsightsModel(initialYear: 2025, clientFactory: { _ in client })
        InsightsTestProtocol.handler = { self.respondFixture($0) }
        await model.load(connection: connection())
        let started = expectation(description: "Held refresh")
        let counter = InsightsRequestCounter()
        InsightsTestProtocol.handler = { _ in if counter.increment() == 1 { started.fulfill() } }
        let previous = Task { await model.load(connection: connection(), force: true) }
        await fulfillment(of: [started], timeout: 2)
        InsightsTestProtocol.handler = { self.respondFixture($0, year: 2024) }
        await model.selectYear(2024)
        await previous.value
        XCTAssertEqual(model.year, 2024)
        XCTAssertEqual(model.snapshot.overview?.year, 2024)
        XCTAssertFalse(model.loading)
    }

    @MainActor func testSuccessfulEmptyResponsesDescribeWhatServerReturned() async {
        let client = client()
        InsightsTestProtocol.handler = { mock in
            let path = mock.request.url!.path
            let json: String
            if path.hasSuffix("/insights") || path.hasSuffix("/details") || path.hasSuffix("/digests/2025") { json = #"{"year":2025}"# }
            else if path.hasSuffix("/visited") || path.hasSuffix("/residency") { json = #"{"countries":[]}"# }
            else if path.hasSuffix("/visited_cities") { json = #"{"data":[]}"# }
            else if path.hasSuffix("/digests") { json = #"{"digests":[],"availableYears":[]}"# }
            else { json = "[]" }
            mock.respond(data: Data(json.utf8))
        }
        let model = DawarichInsightsModel(initialYear: 2025, clientFactory: { _ in client })
        await model.load(connection: connection())
        XCTAssertTrue(model.showEmptyState)
        XCTAssertFalse(model.loading)
        XCTAssertTrue(model.emptyMessage.contains("Returned no data"))
        for section in DawarichInsightsSection.allCases { XCTAssertEqual(model.state(for: section), .empty) }
    }

    @MainActor func testLoadingAndPartialPreviewStatesAreDeterministicAndReadOnly() async {
        InsightsTestProtocol.handler = { _ in XCTFail("Preview made a request") }
        let loading = DawarichInsightsModel(preview: true, previewState: .loading)
        await loading.load(connection: connection(), force: true)
        XCTAssertTrue(loading.loading)
        XCTAssertFalse(loading.showEmptyState)
        XCTAssertTrue(loading.snapshot.sections.isEmpty)
        XCTAssertTrue(DawarichInsightsSection.allCases.allSatisfy { loading.state(for: $0).isLoading })
        let partial = DawarichInsightsModel(preview: true, previewState: .partial)
        await partial.load(connection: connection())
        XCTAssertFalse(partial.loading)
        XCTAssertFalse(partial.showEmptyState)
        XCTAssertTrue(partial.snapshot.sections.contains("year"))
        XCTAssertEqual(partial.state(for: .details), .failed(.http(500)))
        XCTAssertEqual(partial.state(for: .photos), .failed(.timedOut))
        XCTAssertEqual(partial.state(for: .residency), .unsupported(404))
    }

    @MainActor func testChartTapMapsOnlyValidMonthsToTrackerAndHasVoiceOverText() throws {
        let months = DawarichInsightsFixtures.snapshot().months
        let month = try XCTUnwrap(InsightsMonthChart.month(at: 2.2, in: months))
        XCTAssertEqual(month.month, 2)
        let request = try XCTUnwrap(month.navigationRequest)
        XCTAssertEqual(request.date, month.date)
        XCTAssertEqual(request.interval?.start, month.date)
        XCTAssertTrue(month.accessibilityLabel.contains(month.title))
        XCTAssertTrue(month.accessibilityLabel.contains("km"))
        XCTAssertNil(InsightsMonthChart.month(at: .nan, in: months))
        XCTAssertNil(InsightsMonthChart.month(at: .infinity, in: months))
        XCTAssertNil(InsightsMonthChart.month(at: 13, in: months))
        XCTAssertNil(InsightsMonthChart.month(at: 3, in: Array(months.prefix(2))))
        for stat in DawarichInsightsFixtures.snapshot().heroStats {
            XCTAssertEqual(stat.accessibilityLabel, stat.title + ", " + stat.value)
        }
    }

    func testIncrementalPlaceNamesInvalidatePreparedRanking() throws {
        var snapshot = DawarichInsightsFixtures.snapshot()
        snapshot.prepare()
        snapshot.places = try JSONDecoder().decode([DawarichInsights.Place].self,
            from: Data(#"[{"id":101,"name":"Updated studio name"}]"#.utf8))
        snapshot.prepare()
        XCTAssertEqual(snapshot.topPlaces.first?.name, "Updated studio name")
        XCTAssertEqual(snapshot.topPlaces.first?.minutes, 900)
    }

    private func respondFixture(_ mock: InsightsTestProtocol, year: Int = 2025) {
        let path = mock.request.url!.path
        let name: String
        if path.hasSuffix("/tracked_months") { name = "trackedMonths" }
        else if path.hasSuffix("/insights") { name = "overview" }
        else if path.hasSuffix("/details") { name = "details" }
        else if path.hasSuffix("/visited") { name = "countries" }
        else if path.hasSuffix("/visited_cities") { name = "cities" }
        else if path.hasSuffix("/residency") { name = "residency" }
        else if path.hasSuffix("/places") { name = "places" }
        else if path.hasSuffix("/visits") { name = "visits" }
        else if path.hasSuffix("/photos") { name = "photos" }
        else if path.hasSuffix("/digests") { name = "digests" }
        else { name = "digest" }
        mock.respond(data: DawarichInsightsFixtures.data(name, year: year))
    }

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

private final class InsightsRequestCounter {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    @discardableResult func increment() -> Int { lock.withLock { count += 1; return count } }
}

private final class InsightsTestClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
}

private final class InsightsTestProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var storedHandler: ((InsightsTestProtocol) -> Void)?
    static var handler: ((InsightsTestProtocol) -> Void)? {
        get { lock.withLock { storedHandler } }
        set { lock.withLock { storedHandler = newValue } }
    }
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
