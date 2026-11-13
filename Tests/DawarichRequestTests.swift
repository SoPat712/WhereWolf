import XCTest
@testable import WhereWolf

final class DawarichRequestTests: XCTestCase {
    private var directories: [URL] = []

    override func tearDown() {
        SharedDawarichProtocol.handler = nil
        for directory in directories { try? FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        super.tearDown()
    }

    private struct Fixture: Decodable, Equatable { let value: Int }

    private func endpoint(suffix: String = "/api/v1/overland/batches", queryKey: Bool = true) -> String {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "wherewolf.test"
        parts.port = 8443
        parts.percentEncodedPath = "/my%20server" + suffix
        parts.queryItems = [URLQueryItem(name: "unrelated", value: "discarded")]
        if queryKey { parts.queryItems?.append(URLQueryItem(name: "api_key", value: "fixture-query-key")) }
        parts.fragment = "discarded"
        return parts.url!.absoluteString
    }

    private func clients(version: String = "1.22.0", endpoint: String? = nil,
                         headers: [String: String] = [:]) throws -> (DawarichHistoryClient, DawarichInsightsClient) {
        let endpoint = endpoint ?? self.endpoint()
        let server = try XCTUnwrap(DawarichServer(endpoint: endpoint, token: "fixture-token-key"))
        let connection = try XCTUnwrap(DawarichInsightsConnection(
            status: .dawarich(version: version, authenticated: true, account: nil),
            endpoint: endpoint, token: "fixture-token-key", headers: headers))
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharedDawarichProtocol.self]
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("dawarich-request-tests-" + UUID().uuidString)
        directories.append(directory)
        return (DawarichHistoryClient(server: server, headers: headers, version: version, configuration: configuration),
                DawarichInsightsClient(connection: connection, cache: DawarichInsightsCache(directory: directory),
                                       configuration: configuration))
    }

    private func success(_ mock: SharedDawarichProtocol) {
        if mock.request.url?.path.hasSuffix("/points") == true {
            mock.respond(headers: ["X-Current-Page": "1", "X-Total-Pages": "0"], data: Data("[]".utf8))
        } else { mock.respond(data: Data(#"{"value":17}"#.utf8)) }
    }

    func testBothClientsShareEncodedPrefixCredentialsAndHeaderFiltering() async throws {
        for suffix in ["/api/v1/overland/batches", "/api/v1/owntracks/points/"] {
            for queryKey in [true, false] {
                let calls = SharedDawarichCounter()
                SharedDawarichProtocol.handler = { mock in
                    calls.increment()
                    let request = mock.request
                    let parts = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
                    XCTAssertTrue(parts.host == "wherewolf.test" && parts.port == 8443)
                    XCTAssertTrue(parts.percentEncodedPath.hasPrefix("/my%20server/api/v1/"))
                    XCTAssertNil(parts.fragment)
                    XCTAssertFalse(parts.queryItems?.contains { ["api_key", "unrelated"].contains($0.name) } ?? false)
                    let key = queryKey ? "fixture-query-key" : "fixture-token-key"
                    // Boolean assertions never print a credential or full URL on failure.
                    XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + key)
                    XCTAssertTrue(request.value(forHTTPHeaderField: "X-Proxy") == "fixture-proxy")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
                    XCTAssertEqual(request.httpMethod, "GET")
                    XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
                    XCTAssertFalse(request.httpShouldHandleCookies)
                    XCTAssertNil(request.httpBody)
                    for name in ["Host", "Content-Length", "Connection", "X-Bad", "Bad Name"] {
                        XCTAssertNil(request.value(forHTTPHeaderField: name))
                    }
                    self.success(mock)
                }
                let (history, insights) = try clients(endpoint: endpoint(suffix: suffix, queryKey: queryKey), headers: [
                    "X-Proxy": "fixture-proxy", "aUtHoRiZaTiOn": "ignored", "Accept": "text/plain",
                    "Host": "ignored", "Content-Length": "99", "Connection": "close",
                    "X-Bad": "line\nbreak", "Bad Name": "ignored"
                ])
                let first = try await history.firstPointDate()
                let result = await insights.read(.overview(2025), as: Fixture.self, policy: .refresh(force: true))
                XCTAssertNil(first)
                XCTAssertEqual(result.value, Fixture(value: 17))
                XCTAssertFalse(result.offline)
                XCTAssertEqual(calls.value, 2)
            }
        }
    }

    func testSharedVersionParserPreservesDifferentClientContracts() async throws {
        let versions: [(String, Bool, Bool)] = [
            ("1.19.9", false, true), ("1.20.0", true, true), ("v1.22.0", true, true),
            ("1.22.0-rc.1", false, true), ("1.22.0+custom", false, true), ("2.0.0", false, true),
            ("1.2.0-rc.1", false, true), ("1.2.0+custom", false, true), ("1.2.0+custom-build", false, true),
            ("1.1.9", false, true), ("1.20", false, true), ("", false, true),
            ("1.22.0-", false, true), ("1.22.0+", false, true), ("1.22.0.1", false, true)
        ]
        for (version, historySupported, insightsSupported) in versions {
            let calls = SharedDawarichCounter()
            SharedDawarichProtocol.handler = { mock in calls.increment(); self.success(mock) }
            let (history, insights) = try clients(version: version)
            do {
                _ = try await history.firstPointDate()
                XCTAssertTrue(historySupported)
            } catch {
                XCTAssertFalse(historySupported)
                XCTAssertTrue(error as? DawarichHistoryError == .unsupportedVersion)
            }
            let result = await insights.read(.overview(2025), as: Fixture.self, policy: .refresh(force: true))
            XCTAssertEqual(result.value != nil, insightsSupported)
            XCTAssertFalse(result.offline)
            XCTAssertEqual(calls.value, (historySupported ? 1 : 0) + (insightsSupported ? 1 : 0))
        }
        XCTAssertFalse(DawarichVersion.supports(nil, minimum: "1.2.0"))
        XCTAssertFalse(DawarichVersion.supports("1.22.0", minimum: "unknown"))
    }

    func testSharedHTTPClassificationPreservesErrorsAndUnavailableInsights() async throws {
        let statuses: [(Int, DawarichHistoryError, Bool)] = [
            (302, .redirectRejected, false), (400, .httpStatus(400), false),
            (401, .authentication, false), (403, .authentication, false),
            (404, .unavailable, true), (405, .unavailable, true), (410, .unavailable, true),
            (418, .httpStatus(418), false), (422, .httpStatus(422), false), (501, .httpStatus(501), true)
        ]
        for (status, historyError, insightsUnavailable) in statuses {
            let (history, insights) = try clients()
            SharedDawarichProtocol.handler = { self.success($0) }
            let initial = await insights.read(.overview(2025), as: Fixture.self, policy: .refresh(force: true))
            XCTAssertEqual(initial.value, Fixture(value: 17))
            let calls = SharedDawarichCounter()
            SharedDawarichProtocol.handler = { mock in
                calls.increment()
                mock.respond(status: status, data: Data(#"{"error":"fixture-private-body"}"#.utf8))
            }
            do { _ = try await history.firstPointDate(); XCTFail("Expected History request failure") }
            catch {
                XCTAssertTrue(error as? DawarichHistoryError == historyError)
                XCTAssertFalse(error.localizedDescription.contains("fixture-private-body"))
            }
            let result = await insights.read(.overview(2025), as: Fixture.self, policy: .refresh(force: true))
            XCTAssertEqual(result.value, insightsUnavailable ? nil : initial.value)
            XCTAssertEqual(result.offline, !insightsUnavailable)
            XCTAssertEqual(result.updated, insightsUnavailable ? nil : initial.updated)
            let cached = await insights.read(.overview(2025), as: Fixture.self, policy: .cacheOnly)
            XCTAssertEqual(cached.value, result.value)
            XCTAssertEqual(calls.value, 2)
        }
    }

    func testBothClientsRejectResponseAddressEscapesAndKeepInsightsCache() async throws {
        for target in ["https://wherewolf.test:8443/outside/api/v1/result",
                       "https://wherewolf.test:9443/my%20server/api/v1/result",
                       "http://wherewolf.test:8443/my%20server/api/v1/result"] {
            let (history, insights) = try clients()
            SharedDawarichProtocol.handler = { self.success($0) }
            let initial = await insights.read(.overview(2025), as: Fixture.self, policy: .refresh(force: true))
            SharedDawarichProtocol.handler = { mock in
                mock.respond(url: URL(string: target)!, headers: ["X-Current-Page": "1", "X-Total-Pages": "0"],
                             data: mock.request.url?.path.hasSuffix("/points") == true ? Data("[]".utf8) : Data(#"{"value":99}"#.utf8))
            }
            do { _ = try await history.firstPointDate(); XCTFail("Expected rejected response address") }
            catch { XCTAssertTrue(error as? DawarichHistoryError == .redirectRejected) }
            let result = await insights.read(.overview(2025), as: Fixture.self, policy: .refresh(force: true))
            XCTAssertEqual(result.value, initial.value)
            XCTAssertEqual(result.updated, initial.updated)
            XCTAssertTrue(result.offline)
        }
    }

    func testHistoryPermitsInRootResponseChangesAndInsightsRequiresExactURL() async throws {
        let (history, insights) = try clients()
        SharedDawarichProtocol.handler = { mock in
            mock.respond(url: URL(string: "https://wherewolf.test:8443/my%20server/api/v1/redirected")!,
                         headers: ["X-Current-Page": "1", "X-Total-Pages": "0"],
                         data: mock.request.url?.path.hasSuffix("/points") == true ? Data("[]".utf8) : Data(#"{"value":17}"#.utf8))
        }
        let first = try await history.firstPointDate()
        XCTAssertNil(first)
        let result = await insights.read(.overview(2025), as: Fixture.self, policy: .refresh(force: true))
        XCTAssertNil(result.value)
        XCTAssertTrue(result.offline)
    }

    func testSharedRedirectDelegatePreservesHeadersOnlyInsideHistoryRoot() throws {
        let server = try XCTUnwrap(DawarichServer(endpoint: endpoint(), token: "fixture-token-key"))
        let historyPolicy = DawarichRequestPolicy(root: server.root)
        let insightsPolicy = DawarichRequestPolicy()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SharedDawarichProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let request = server.request(path: "/api/v1/points", headers: ["X-Proxy": "fixture-proxy"])
        let task = session.dataTask(with: request)
        for path in ["/my%20server/api/v1/next", "/outside/api/v1/next", "/my%20server/%2e%2e/api/v1/next"] {
            let target = URL(string: "https://wherewolf.test:8443" + path)!
            let response = HTTPURLResponse(url: request.url!, statusCode: 302, httpVersion: nil,
                                           headerFields: ["Location": target.absoluteString])!
            var calls = 0
            historyPolicy.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                     newRequest: URLRequest(url: target)) { redirected in
                calls += 1
                if path == "/my%20server/api/v1/next" {
                    XCTAssertNotNil(redirected)
                    XCTAssertTrue(redirected?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-query-key")
                    XCTAssertTrue(redirected?.value(forHTTPHeaderField: "X-Proxy") == "fixture-proxy")
                    XCTAssertEqual(redirected?.value(forHTTPHeaderField: "Accept"), "application/json")
                    XCTAssertFalse(redirected?.httpShouldHandleCookies ?? true)
                } else { XCTAssertNil(redirected) }
            }
            insightsPolicy.urlSession(session, task: task, willPerformHTTPRedirection: response,
                                      newRequest: URLRequest(url: target)) { redirected in
                calls += 1
                XCTAssertNil(redirected)
            }
            XCTAssertEqual(calls, 2)
        }
    }

    func testSharedNetworkFailureIsSanitizedAndInsightsFallsBack() async throws {
        let (history, insights) = try clients()
        SharedDawarichProtocol.handler = { self.success($0) }
        let initial = await insights.read(.overview(2025), as: Fixture.self, policy: .refresh(force: true))
        SharedDawarichProtocol.handler = { mock in
            let error = NSError(domain: NSURLErrorDomain, code: URLError.badServerResponse.rawValue,
                                userInfo: [NSURLErrorFailingURLStringErrorKey: "https://wherewolf.test/fixture-private-error",
                                           NSLocalizedDescriptionKey: "fixture-private-error"])
            mock.client?.urlProtocol(mock, didFailWithError: error)
        }
        do { _ = try await history.firstPointDate(); XCTFail("Expected network failure") }
        catch {
            XCTAssertTrue(error as? DawarichHistoryError == .network)
            XCTAssertFalse(error.localizedDescription.contains("fixture-private-error"))
            XCTAssertFalse(error.localizedDescription.contains("wherewolf.test"))
        }
        let result = await insights.read(.overview(2025), as: Fixture.self, policy: .refresh(force: true))
        XCTAssertEqual(result.value, initial.value)
        XCTAssertEqual(result.updated, initial.updated)
        XCTAssertTrue(result.offline)
    }
}

private final class SharedDawarichCounter {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func increment() { lock.withLock { count += 1 } }
}

private final class SharedDawarichProtocol: URLProtocol {
    static var handler: ((SharedDawarichProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "wherewolf.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() {}

    func respond(status: Int = 200, url: URL? = nil, headers: [String: String] = [:], data: Data) {
        let response = HTTPURLResponse(url: url ?? request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}
