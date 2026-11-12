import XCTest
import ObjectiveC
import Observation
@testable import WhereWolf

final class DawarichServerTests: XCTestCase {
    override class func setUp() {
        super.setUp()
        exchangeConfiguration()
    }

    override class func tearDown() {
        exchangeConfiguration()
        super.tearDown()
    }

    private class func exchangeConfiguration() {
        method_exchangeImplementations(
            class_getClassMethod(URLSessionConfiguration.self, #selector(getter: URLSessionConfiguration.default))!,
            class_getClassMethod(URLSessionConfiguration.self, #selector(URLSessionConfiguration.dawarich_testConfiguration))!)
    }

    override func tearDown() {
        DawarichTestProtocol.handler = nil
        super.tearDown()
    }

    // Synthetic credentials and account identities stay inside boolean assertions so failures cannot print them.
    private var key: String { "fixture+&=?/ value" }
    private var email: String { "fixture" + "@" + "wherewolf.test" }
    private func endpoint(_ path: String = "/api/v1/overland/batches", queryKey: Bool = true) -> String {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "wherewolf.test"
        parts.path = path
        if queryKey { parts.queryItems = [URLQueryItem(name: "api_key", value: key)] }
        return parts.url!.absoluteString
    }

    private func account(_ root: String, key: String? = nil) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["server_url": root, "api_key": key ?? self.key])
        return String(decoding: data, as: UTF8.self)
    }

    func testOverlandAndOwnTracksCandidates() throws {
        for path in ["/api/v1/overland/batches", "/api/v1/owntracks/points"] {
            let server = try XCTUnwrap(DawarichServer(endpoint: endpoint(path), token: ""))
            XCTAssertEqual(server.root.host, "wherewolf.test")
            XCTAssertEqual(server.root.path, "")
            XCTAssertTrue(server.healthRequest(headers: [:]).value(forHTTPHeaderField: "Authorization") == "Bearer " + key)
        }
    }

    func testPathPrefixPortAndTrailingSlash() throws {
        for path in ["/dawarich/api/v1/overland/batches/", "/dawarich/api/v1/owntracks/points/"] {
            var parts = URLComponents(string: endpoint(path))!
            parts.port = 8443
            let server = try XCTUnwrap(DawarichServer(endpoint: parts.url!.absoluteString, token: ""))
            XCTAssertEqual(server.root.path, "/dawarich")
            XCTAssertEqual(server.root.port, 8443)
            let request = server.healthRequest(headers: [:])
            XCTAssertEqual(request.url?.path, "/dawarich/api/v1/health")
            XCTAssertNil(request.url?.query)
        }
    }

    func testEncodedPrefixSurvivesHealthAndAccountParsing() throws {
        var parts = URLComponents(string: endpoint())!
        parts.percentEncodedPath = "/my%20server/api/v1/overland/batches"
        let server = try XCTUnwrap(DawarichServer(endpoint: parts.url!.absoluteString, token: ""))
        let requestParts = URLComponents(url: server.healthRequest(headers: [:]).url!, resolvingAgainstBaseURL: false)
        XCTAssertEqual(requestParts?.percentEncodedPath, "/my%20server/api/v1/health")
        guard case .dawarich(let url) = DawarichServer.parseQRCode(try account("https://wherewolf.test/my%20server/"), ownTracks: false) else {
            return XCTFail("Expected account setup")
        }
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath,
                       "/my%20server/api/v1/overland/batches")
    }

    func testTokenFallbackAndQueryPrecedence() throws {
        let fallback = try XCTUnwrap(DawarichServer(endpoint: endpoint(queryKey: false), token: key))
        XCTAssertTrue(fallback.healthRequest(headers: [:]).value(forHTTPHeaderField: "Authorization") == "Bearer " + key)
        let query = try XCTUnwrap(DawarichServer(endpoint: endpoint(), token: "unused-fixture"))
        XCTAssertTrue(query.healthRequest(headers: [:]).value(forHTTPHeaderField: "Authorization") == "Bearer " + key)
    }

    func testNonCandidatesAndMissingKeys() {
        for path in ["/upload", "/api/v1/health", "/api/v1/overland/batches/extra", "/api/v1/owntracks", "/other/api/v2/overland/batches"] {
            XCTAssertTrue(DawarichServer(endpoint: endpoint(path), token: key) == nil)
        }
        XCTAssertTrue(DawarichServer(endpoint: endpoint(queryKey: false), token: "") == nil)
        XCTAssertTrue(DawarichServer(endpoint: "file:///api/v1/overland/batches", token: key) == nil)
        XCTAssertTrue(DawarichServer(endpoint: "https:///api/v1/overland/batches", token: key) == nil)
    }

    func testHealthRequestHeadersAndTimeout() throws {
        let server = try XCTUnwrap(DawarichServer(endpoint: endpoint(), token: ""))
        let request = server.healthRequest(headers: ["CF-Access-Client-Id": "fixture-proxy", "aUtHoRiZaTiOn": "ignored",
            "Host": "ignored", "Content-Length": "99", "Connection": "close", "Transfer-Encoding": "chunked",
            "X-Bad": "line\nbreak", "Bad Name": "ignored", "Accept": "text/plain"])
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.timeoutInterval, 15)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + key)
        XCTAssertTrue(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "fixture-proxy")
        for name in ["Host", "Content-Length", "Connection", "Transfer-Encoding", "X-Bad", "Bad Name"] {
            XCTAssertNil(request.value(forHTTPHeaderField: name))
        }
    }

    func testAccountJSONWithAndWithoutTrailingSlash() throws {
        for root in ["https://wherewolf.test/dawarich", "https://wherewolf.test/dawarich/"] {
            guard case .dawarich(let url) = DawarichServer.parseQRCode(try account(root), ownTracks: false) else {
                return XCTFail("Expected account setup")
            }
            XCTAssertEqual(url.path, "/dawarich/api/v1/overland/batches")
            XCTAssertTrue(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first?.value == key)
        }
    }

    func testAccountJSONOwnTracksAndHTTP() throws {
        guard case .dawarich(let url) = DawarichServer.parseQRCode(try account("http://wherewolf.test:8080/"), ownTracks: true) else {
            return XCTFail("Expected account setup")
        }
        XCTAssertEqual(url.path, "/api/v1/owntracks/points")
        XCTAssertEqual(url.port, 8080)
        XCTAssertEqual(url.scheme, "http")
    }

    func testBadAccountJSONAndJunk() throws {
        for root in ["file:///tmp", "ftp://wherewolf.test", "https:///", "wherewolf.test"] {
            XCTAssertTrue(DawarichServer.parseQRCode(try account(root), ownTracks: false) == nil)
        }
        for text in ["{}", "{\"server_url\":\"https://wherewolf.test\"}", "{\"api_key\":\"fixture\"}",
                     "{\"server_url\":17,\"api_key\":true}", "junk", "", "[]"] {
            XCTAssertTrue(DawarichServer.parseQRCode(text, ownTracks: false) == nil)
        }
        XCTAssertTrue(DawarichServer.parseQRCode(try account("https://wherewolf.test", key: ""), ownTracks: false) == nil)
    }

    private func setupURL(scheme: String = "wherewolf", headers: [URLQueryItem] = [], path: String = "/api/v1/overland/batches") -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "setup"
        parts.queryItems = [URLQueryItem(name: "url", value: endpoint(path)), URLQueryItem(name: "token", value: key),
                            URLQueryItem(name: "device_id", value: "fixture-phone"), URLQueryItem(name: "unique_id", value: "yes")] + headers
        return parts.url!
    }

    func testSetupQRUsesSharedParserAndPreservesFields() throws {
        for scheme in ["wherewolf", "overland"] {
            let url = setupURL(scheme: scheme, headers: [URLQueryItem(name: "header_X-Proxy", value: "fixture-proxy")])
            guard case .setupLink(_, let scanned) = DawarichServer.parseQRCode(url.absoluteString, ownTracks: false) else {
                return XCTFail("Expected setup link")
            }
            let parsed = try XCTUnwrap(ServerSetup.parse(url))
            XCTAssertTrue(scanned.endpoint == endpoint() && parsed.endpoint == endpoint())
            XCTAssertTrue(scanned.token == key && parsed.token == key)
            XCTAssertTrue(scanned.deviceId == "fixture-phone")
            XCTAssertTrue(scanned.uniqueId)
            XCTAssertTrue(scanned.headers["X-Proxy"] == "fixture-proxy")
        }
    }

    func testSetupDefaultsAndValidation() throws {
        var parts = URLComponents(url: setupURL(), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "url", value: endpoint(queryKey: false))]
        let parsed = try XCTUnwrap(ServerSetup.parse(parts.url!))
        XCTAssertTrue(parsed.token.isEmpty && parsed.deviceId.isEmpty && parsed.headers.isEmpty)
        XCTAssertFalse(parsed.uniqueId)
        let invalidHeader = setupURL(headers: [URLQueryItem(name: "header_Authorization", value: "fixture")])
        XCTAssertTrue(ServerSetup.parse(invalidHeader) == nil)
        XCTAssertTrue(DawarichServer.parseQRCode(invalidHeader.absoluteString, ownTracks: false) == nil)
        parts.queryItems = [URLQueryItem(name: "url", value: "file:///tmp")]
        XCTAssertTrue(ServerSetup.parse(parts.url!) == nil)
        XCTAssertTrue(ServerSetup.parse(setupURL(scheme: "https")) == nil)
    }

    func testPlainEndpointQR() {
        for scheme in ["http", "https"] {
            let text = scheme + "://wherewolf.test/upload"
            guard case .endpoint(let url) = DawarichServer.parseQRCode(text, ownTracks: false) else {
                return XCTFail("Expected plain endpoint")
            }
            XCTAssertEqual(url.path, "/upload")
        }
    }

    private func userData(email: Any?) throws -> Data {
        var user: [String: Any] = ["id": 17, "theme": "fixture", "settings": ["email": self.email]]
        if let email { user["email"] = email }
        return try JSONSerialization.data(withJSONObject: ["user": user, "features": ["email": self.email]])
    }

    private func probe(status: Int = 200, headers: [String: String] = [:], error: URLError? = nil,
                       accountStatus: Int = 200, accountData: Data = Data(), accountError: URLError? = nil,
                       requestHeaders: [String: String] = [:], expectedAccountRequests: Int = 0,
                       inspectAccountRequest: ((URLRequest) -> Void)? = nil) async throws -> DawarichStatus {
        var accountRequests = 0
        DawarichTestProtocol.handler = { mock in
            XCTAssertEqual(mock.request.httpMethod, "GET")
            XCTAssertNil(mock.request.httpBody)
            switch mock.request.url?.path {
            case "/api/v1/health":
                if let error { mock.client?.urlProtocol(mock, didFailWithError: error) }
                else { mock.respond(status: status, headers: headers) }
            case "/api/v1/users/me":
                accountRequests += 1
                inspectAccountRequest?(mock.request)
                if let accountError { mock.client?.urlProtocol(mock, didFailWithError: accountError) }
                else { mock.respond(status: accountStatus, headers: [:], data: accountData) }
            default:
                XCTFail("Unexpected recognition request")
                mock.respond(status: 404, headers: [:])
            }
        }
        let server = try XCTUnwrap(DawarichServer(endpoint: endpoint(), token: ""))
        let result = await withCheckedContinuation { continuation in
            server.probe(headers: requestHeaders) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(accountRequests, expectedAccountRequests)
        return result
    }

    private var authenticatedHealth: [String: String] {
        ["X-Dawarich-Response": "Hey, I'm alive and authenticated!", "X-Dawarich-Version": "1.2.3"]
    }

    func testAuthenticatedHealthWithVersionAndCaseInsensitiveHeaders() async throws {
        let result = try await probe(headers: ["x-dawarich-response": "Hey, I'm alive and authenticated!", "x-dawarich-version": "1.2.3"],
                                     expectedAccountRequests: 1)
        XCTAssertTrue(result == .dawarich(version: "1.2.3", authenticated: true, account: nil))
    }

    func testUnauthenticatedHealthWithoutVersion() async throws {
        let result = try await probe(headers: ["X-Dawarich-Response": "Hey, I'm alive!"])
        XCTAssertTrue(result == .dawarich(version: nil, authenticated: false, account: nil))
    }

    func testAuthenticatedHealthLoadsTrimmedAccountEmail() async throws {
        let result = try await probe(headers: authenticatedHealth, accountData: userData(email: "  " + email + "  "),
                                     expectedAccountRequests: 1)
        XCTAssertTrue(result == .dawarich(version: "1.2.3", authenticated: true, account: email))
    }

    func testAccountRequestHeadersAndTimeout() async throws {
        let result = try await probe(headers: authenticatedHealth, accountData: userData(email: email),
                                     requestHeaders: ["CF-Access-Client-Id": "fixture-proxy", "aUtHoRiZaTiOn": "ignored",
                                         "Host": "ignored", "Content-Length": "99", "Connection": "close", "Transfer-Encoding": "chunked",
                                         "X-Bad": "line\nbreak", "Bad Name": "ignored", "Accept": "text/plain"],
                                     expectedAccountRequests: 1) { request in
            XCTAssertTrue(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + self.key)
            XCTAssertTrue(request.value(forHTTPHeaderField: "CF-Access-Client-Id") == "fixture-proxy")
            XCTAssertTrue(request.value(forHTTPHeaderField: "Accept") == "application/json")
            XCTAssertTrue(request.url?.query == nil)
            XCTAssertEqual(request.timeoutInterval, 15)
            XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
            XCTAssertFalse(request.httpShouldHandleCookies)
            for name in ["Host", "Content-Length", "Connection", "Transfer-Encoding", "X-Bad", "Bad Name"] {
                XCTAssertTrue(request.value(forHTTPHeaderField: name) == nil)
            }
        }
        XCTAssertTrue(result == .dawarich(version: "1.2.3", authenticated: true, account: email))
    }

    func testAccountRequestPreservesEncodedPrefixAndTokenFallback() async throws {
        var parts = URLComponents(string: endpoint(queryKey: false))!
        parts.percentEncodedPath = "/my%20server/api/v1/owntracks/points/"
        parts.port = 8443
        let server = try XCTUnwrap(DawarichServer(endpoint: parts.url!.absoluteString, token: key))
        let data = try userData(email: email)
        var requestedPaths: [String] = []
        DawarichTestProtocol.handler = { mock in
            let path = URLComponents(url: mock.request.url!, resolvingAgainstBaseURL: false)!.percentEncodedPath
            requestedPaths.append(path)
            XCTAssertTrue(mock.request.value(forHTTPHeaderField: "Authorization") == "Bearer " + self.key)
            XCTAssertTrue(mock.request.url?.query == nil)
            XCTAssertEqual(mock.request.url?.port, 8443)
            switch path {
            case "/my%20server/api/v1/health":
                mock.respond(status: 200, headers: self.authenticatedHealth)
            case "/my%20server/api/v1/users/me":
                mock.respond(status: 200, headers: [:], data: data)
            default:
                XCTFail("Unexpected recognition request")
                mock.respond(status: 404, headers: [:])
            }
        }
        let result = await withCheckedContinuation { continuation in
            server.probe(headers: [:]) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(requestedPaths, ["/my%20server/api/v1/health", "/my%20server/api/v1/users/me"])
        XCTAssertTrue(result == .dawarich(version: "1.2.3", authenticated: true, account: email))
    }

    func testAccountHTTPFailuresKeepDawarichStatus() async throws {
        for status in [401, 500] {
            let result = try await probe(headers: authenticatedHealth, accountStatus: status, accountData: userData(email: email),
                                         expectedAccountRequests: 1)
            XCTAssertTrue(result == .dawarich(version: "1.2.3", authenticated: true, account: nil))
        }
    }

    func testAccountTimeoutKeepsDawarichStatus() async throws {
        let result = try await probe(headers: authenticatedHealth, accountError: URLError(.timedOut), expectedAccountRequests: 1)
        XCTAssertTrue(result == .dawarich(version: "1.2.3", authenticated: true, account: nil))
    }

    func testMalformedAccountJSONKeepsDawarichStatus() async throws {
        let result = try await probe(headers: authenticatedHealth, accountData: Data("{".utf8), expectedAccountRequests: 1)
        XCTAssertTrue(result == .dawarich(version: "1.2.3", authenticated: true, account: nil))
    }

    func testMissingOrNonStringAccountEmailKeepsDawarichStatus() async throws {
        for data in [Data("{}".utf8), try userData(email: nil), try userData(email: true)] {
            let result = try await probe(headers: authenticatedHealth, accountData: data, expectedAccountRequests: 1)
            XCTAssertTrue(result == .dawarich(version: "1.2.3", authenticated: true, account: nil))
        }
    }

    func testEmptyAccountEmailKeepsDawarichStatus() async throws {
        for value in ["", "   "] {
            let result = try await probe(headers: authenticatedHealth, accountData: userData(email: value), expectedAccountRequests: 1)
            XCTAssertTrue(result == .dawarich(version: "1.2.3", authenticated: true, account: nil))
        }
    }

    func testOversizedAccountEmailKeepsDawarichStatus() async throws {
        let result = try await probe(headers: authenticatedHealth, accountData: userData(email: String(repeating: "a", count: 321)),
                                     expectedAccountRequests: 1)
        XCTAssertTrue(result == .dawarich(version: "1.2.3", authenticated: true, account: nil))
    }

    func testAccountEmailAtLengthLimit() async throws {
        let value = String(repeating: "a", count: 320 - email.count) + email
        let result = try await probe(headers: authenticatedHealth, accountData: userData(email: " " + value + " "),
                                     expectedAccountRequests: 1)
        XCTAssertTrue(result == .dawarich(version: "1.2.3", authenticated: true, account: value))
    }

    func testControlCharactersInAccountEmailKeepDawarichStatus() async throws {
        for value in ["\n" + email, email + "\r", email + "\t", email + "\u{0000}", email + "\u{007F}"] {
            let result = try await probe(headers: authenticatedHealth, accountData: userData(email: value), expectedAccountRequests: 1)
            XCTAssertTrue(result == .dawarich(version: "1.2.3", authenticated: true, account: nil))
        }
    }

    func testHealthWithoutSignature() async throws {
        let result = try await probe(headers: ["X-Dawarich-Version": "1.2.3"])
        XCTAssertTrue(result == .notDawarich)
    }

    func testHealthHTTPFailures() async throws {
        for status in [401, 500] {
            let result = try await probe(status: status, headers: ["X-Dawarich-Response": "Hey, I'm alive!"])
            XCTAssertTrue(result == .notDawarich)
        }
    }

    func testHealthTimeout() async throws {
        let result = try await probe(error: URLError(.timedOut))
        XCTAssertTrue(result == .notDawarich)
    }

    private func reviewProbe(status: Int = 200, headers: [String: String] = [:], error: URLError? = nil,
                             accountStatus: Int = 200, accountData: Data = Data(), accountError: URLError? = nil,
                             expectedAccountRequests: Int = 0) async throws -> DawarichReviewStatus {
        var accountRequests = 0
        DawarichTestProtocol.handler = { mock in
            XCTAssertEqual(mock.request.httpMethod, "GET")
            XCTAssertNil(mock.request.httpBody)
            XCTAssertTrue(mock.request.value(forHTTPHeaderField: "Authorization") == "Bearer " + self.key)
            XCTAssertTrue(mock.request.url?.query == nil)
            switch mock.request.url?.path {
            case "/api/v1/health":
                if let error { mock.client?.urlProtocol(mock, didFailWithError: error) }
                else { mock.respond(status: status, headers: headers) }
            case "/api/v1/users/me":
                accountRequests += 1
                if let accountError { mock.client?.urlProtocol(mock, didFailWithError: accountError) }
                else { mock.respond(status: accountStatus, headers: [:], data: accountData) }
            default:
                XCTFail("Unexpected review request")
                mock.respond(status: 404, headers: [:])
            }
        }
        let server = try XCTUnwrap(DawarichServer(endpoint: endpoint(), token: ""))
        let result = await withCheckedContinuation { continuation in
            server.probeForReview(headers: [:]) { continuation.resume(returning: $0) }
        }
        XCTAssertEqual(accountRequests, expectedAccountRequests)
        return result
    }

    func testReviewProbeAuthenticatedHealthLoadsAccount() async throws {
        let result = try await reviewProbe(headers: authenticatedHealth, accountData: userData(email: email),
                                           expectedAccountRequests: 1)
        XCTAssertTrue(result == .dawarich(version: "1.2.3", account: email))
    }

    func testReviewProbeRejectsUnauthenticatedHealthAndAuthorizationErrors() async throws {
        let unsigned = try await reviewProbe(headers: ["X-Dawarich-Response": "Hey, I'm alive!"])
        XCTAssertTrue(unsigned == .keyRejected)
        for status in [401, 403] {
            let result = try await reviewProbe(status: status, headers: authenticatedHealth)
            XCTAssertTrue(result == .keyRejected)
        }
    }

    func testReviewProbeTreatsMissingSignatureTransportAndOtherHTTPFailuresAsUnreachable() async throws {
        let missingSignature = try await reviewProbe(headers: ["X-Dawarich-Version": "1.2.3"])
        XCTAssertTrue(missingSignature == .unreachable)
        let failure = try await reviewProbe(status: 500, headers: authenticatedHealth)
        XCTAssertTrue(failure == .unreachable)
        let timeout = try await reviewProbe(error: URLError(.timedOut))
        XCTAssertTrue(timeout == .unreachable)
    }

    func testReviewProbeKeepsAuthenticatedServerWhenAccountCannotLoad() async throws {
        for status in [401, 500] {
            let result = try await reviewProbe(headers: authenticatedHealth, accountStatus: status,
                                               accountData: userData(email: email), expectedAccountRequests: 1)
            XCTAssertTrue(result == .dawarich(version: "1.2.3", account: nil))
        }
        let timeout = try await reviewProbe(headers: authenticatedHealth, accountError: URLError(.timedOut), expectedAccountRequests: 1)
        XCTAssertTrue(timeout == .dawarich(version: "1.2.3", account: nil))
        let malformed = try await reviewProbe(headers: authenticatedHealth, accountData: Data("{".utf8), expectedAccountRequests: 1)
        XCTAssertTrue(malformed == .dawarich(version: "1.2.3", account: nil))
    }

    @MainActor func testReviewCheckTreatsUnrecognizedEndpointAsUnreachableWithoutRequest() {
        DawarichTestProtocol.handler = { _ in XCTFail("Unexpected review request") }
        let values = ServerQRValues(endpoint: "", token: "", deviceId: "", uniqueId: false, acceptHTTP: false, headers: [:])
        let review = ServerQRReview(code: .endpoint(URL(string: endpoint("/upload", queryKey: false))!),
                                    current: values, ownTracks: false)
        let check = ServerQRReviewCheck()
        XCTAssertTrue(check.status == .checking)
        check.start(review)
        XCTAssertTrue(check.status == .unreachable)
        check.cancel()
    }

    @MainActor func testReviewCheckReplacesHealthProbeAndIgnoresCancelledResult() async throws {
        try await checkReviewReplacesProbe(waitForAccount: false)
    }

    @MainActor func testReviewCheckReplacesAccountProbeAndIgnoresCancelledResult() async throws {
        try await checkReviewReplacesProbe(waitForAccount: true)
    }

    @MainActor private func checkReviewReplacesProbe(waitForAccount: Bool) async throws {
        let started = expectation(description: "Review probe started")
        let cancelled = expectation(description: "Review probe cancelled")
        let pausedPath = waitForAccount ? "/api/v1/users/me" : "/api/v1/health"
        DawarichTestProtocol.handler = { mock in
            switch mock.request.url?.path {
            case pausedPath:
                mock.onStop = { cancelled.fulfill() }
                started.fulfill()
            case "/api/v1/health":
                mock.respond(status: 200, headers: self.authenticatedHealth)
            default:
                XCTFail("Unexpected review request")
                mock.respond(status: 404, headers: [:])
            }
        }
        let values = ServerQRValues(endpoint: "", token: "", deviceId: "", uniqueId: false, acceptHTTP: false, headers: [:])
        let review = ServerQRReview(code: .dawarich(URL(string: endpoint())!), current: values, ownTracks: false)
        let check = ServerQRReviewCheck()
        check.start(review)
        XCTAssertTrue(check.status == .checking)
        await fulfillment(of: [started], timeout: 2)
        var replacement = review
        replacement.previewStatus = .dawarich(version: "replacement", account: nil)
        check.start(replacement)
        let stale = expectation(description: "Cancelled result stays ignored")
        stale.isInverted = true
        withObservationTracking { _ = check.status } onChange: { stale.fulfill() }
        await fulfillment(of: [cancelled], timeout: 2)
        await fulfillment(of: [stale], timeout: 0.1)
        XCTAssertTrue(check.status == .dawarich(version: "replacement", account: nil))
        check.cancel()
    }

    @MainActor func testBridgeReplacesProbeAndClearResetsStatusWithoutSendStatistics() async throws {
        try await checkBridgeReplacesProbe(waitForAccount: false)
    }

    @MainActor func testBridgeReplacesAccountProbeAndClearResetsStatusWithoutSendStatistics() async throws {
        try await checkBridgeReplacesProbe(waitForAccount: true)
    }

    @MainActor private func checkBridgeReplacesProbe(waitForAccount: Bool) async throws {
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier!
        let saved = defaults.persistentDomain(forName: domain) ?? [:]
        let store = GLServerCredentials.store
        GLServerCredentials.store = MemorySettingsCredentialStore()
        let bridge = GLManagerBridge.shared
        defer {
            _ = bridge.clearServer()
            GLServerCredentials.store = store
            defaults.setPersistentDomain(saved, forName: domain)
            bridge.refresh()
        }
        let started = expectation(description: "First probe started")
        let replaced = expectation(description: "Replacement account probe finished")
        let cancelled = expectation(description: "Replaced probe cancelled")
        let data = try userData(email: email)
        let pausedPath = waitForAccount ? "/first/api/v1/users/me" : "/first/api/v1/health"
        DawarichTestProtocol.handler = { mock in
            switch mock.request.url?.path {
            case pausedPath:
                mock.onStop = { cancelled.fulfill() }
                started.fulfill()
            case "/first/api/v1/health", "/second/api/v1/health":
                mock.respond(status: 200, headers: self.authenticatedHealth)
            case "/second/api/v1/users/me":
                mock.respond(status: 200, headers: [:], data: data)
                replaced.fulfill()
            default:
                XCTFail("Unexpected recognition request")
                mock.respond(status: 404, headers: [:])
            }
        }
        let history = bridge.sendHistory
        func save(_ path: String) -> Bool {
            bridge.saveServer(url: endpoint(path), token: "", deviceId: "", uniqueId: false, acceptHTTP: false, headers: [:])
        }
        XCTAssertTrue(save("/first/api/v1/overland/batches"))
        XCTAssertTrue(bridge.dawarich == .checking)
        await fulfillment(of: [started], timeout: 2)
        XCTAssertTrue(WhereWolfSetupURLHandler.apply(setupURL(
            headers: [URLQueryItem(name: "header_X-Proxy", value: "fixture-proxy")], path: "/second/api/v1/overland/batches")))
        let manager = GLManager.shared()!
        XCTAssertTrue(manager.apiAccessToken() == key)
        XCTAssertTrue(manager.deviceId() == "fixture-phone")
        XCTAssertTrue(defaults.bool(forKey: GLIncludeUniqueIdDefaultsName))
        XCTAssertTrue(manager.customHTTPHeaders["X-Proxy"] == "fixture-proxy")
        await fulfillment(of: [cancelled, replaced], timeout: 2)
        // The URLSession callback publishes to the main queue after the response finishes.
        let published = expectation(description: "Recognition published")
        func observe() {
            if bridge.dawarich == .checking {
                withObservationTracking { _ = bridge.dawarich } onChange: {
                    DispatchQueue.main.async { observe() }
                }
            } else { published.fulfill() }
        }
        observe()
        await fulfillment(of: [published], timeout: 2)
        XCTAssertTrue(bridge.dawarich == .dawarich(version: "1.2.3", authenticated: true, account: email))
        XCTAssertEqual(bridge.sendHistory, history)
        XCTAssertTrue(bridge.clearServer())
        XCTAssertTrue(bridge.dawarich == .unknown)
    }
}

private extension URLSessionConfiguration {
    @objc class func dawarich_testConfiguration() -> URLSessionConfiguration {
        let configuration = dawarich_testConfiguration()
        configuration.protocolClasses = [DawarichTestProtocol.self]
        return configuration
    }
}

private final class DawarichTestProtocol: URLProtocol {
    static var handler: ((DawarichTestProtocol) -> Void)?
    var onStop: (() -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "wherewolf.test" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.handler?(self) }
    override func stopLoading() { onStop?() }
    func respond(status: Int, headers: [String: String], data: Data = Data()) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !data.isEmpty { client?.urlProtocol(self, didLoad: data) }
        client?.urlProtocolDidFinishLoading(self)
    }
}
