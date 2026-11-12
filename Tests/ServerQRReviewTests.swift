import XCTest
@testable import WhereWolf

@MainActor
final class ServerQRReviewTests: XCTestCase {
    private var key: String { "review+&=?/ fixture" }
    private var current: ServerQRValues {
        ServerQRValues(endpoint: "https://wherewolf.test/old", token: "existing fixture",
                       deviceId: "existing-phone", uniqueId: false, acceptHTTP: true,
                       headers: ["X-Existing": "existing value"])
    }

    private func endpoint(path: String = "/tracking/api/v1/overland/batches", keyed: Bool = true) -> URL {
        var parts = URLComponents()
        parts.scheme = "https"
        parts.host = "wherewolf.test"
        parts.percentEncodedPath = path
        if keyed { parts.queryItems = [URLQueryItem(name: "api_key", value: key)] }
        return parts.url!
    }

    private func accountCode(ownTracks: Bool = false) throws -> ServerSetupCode {
        let data = try JSONSerialization.data(withJSONObject: [
            "server_url": "https://wherewolf.test/tracking/", "api_key": key
        ])
        return try XCTUnwrap(DawarichServer.parseQRCode(String(decoding: data, as: UTF8.self), ownTracks: ownTracks))
    }

    private func setupURL(scheme: String = "wherewolf", headers: [String: String] = [:]) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "setup"
        parts.queryItems = [URLQueryItem(name: "url", value: endpoint(path: "/upload").absoluteString),
                            URLQueryItem(name: "token", value: key),
                            URLQueryItem(name: "device_id", value: "scanned-phone"),
                            URLQueryItem(name: "unique_id", value: "yes")]
            + headers.map { URLQueryItem(name: "header_" + $0.key, value: $0.value) }
        return parts.url!
    }

    private func parsed(_ url: URL, ownTracks: Bool = false) throws -> ServerSetupCode {
        try XCTUnwrap(DawarichServer.parseQRCode(url.absoluteString, ownTracks: ownTracks))
    }

    func testDawarichReviewUsesScannedKeyAndPreservesOtherFormValues() throws {
        for ownTracks in [false, true] {
            let review = ServerQRReview(code: try accountCode(ownTracks: ownTracks), current: current, ownTracks: ownTracks)
            var expected = current
            expected.endpoint = endpoint(path: ownTracks ? "/tracking/api/v1/owntracks/points" : "/tracking/api/v1/overland/batches").absoluteString
            expected.token = ""
            XCTAssertEqual(review.kind, .dawarich)
            XCTAssertTrue(review.values == expected)
            XCTAssertTrue(review.includesKey)
            XCTAssertEqual(review.format, ownTracks ? "OwnTracks" : "GeoJSON")
            XCTAssertTrue(review.destination == .server(endpoint: expected.endpoint, token: "", ownTracks: ownTracks))
        }
    }

    func testPlainURLReviewPreservesTokenAndUnsavedFormFields() throws {
        let url = endpoint(path: "/upload", keyed: false)
        let review = ServerQRReview(code: try parsed(url), current: current, ownTracks: true)
        var expected = current
        expected.endpoint = url.absoluteString
        XCTAssertEqual(review.kind, .url)
        XCTAssertTrue(review.values == expected)
        XCTAssertTrue(review.includesKey)
        XCTAssertEqual(review.format, "OwnTracks")
        XCTAssertTrue(review.destination == .server(endpoint: expected.endpoint, token: expected.token, ownTracks: true))
    }

    func testSetupReviewAppliesParsedFieldsAndReplacesNonemptyHeaders() throws {
        for scheme in ["wherewolf", "overland"] {
            let url = setupURL(scheme: scheme, headers: ["X-Scanned": "scanned value"])
            let review = ServerQRReview(code: try parsed(url), current: current, ownTracks: false)
            var expected = current
            expected.endpoint = endpoint(path: "/upload").absoluteString
            expected.token = key
            expected.deviceId = "scanned-phone"
            expected.uniqueId = true
            expected.headers = ["X-Scanned": "scanned value"]
            XCTAssertEqual(review.kind, .setup)
            XCTAssertTrue(review.values == expected)
            XCTAssertTrue(review.includesKey)
            XCTAssertTrue(review.destination == .setupLink(url.absoluteString))
        }
    }

    func testSetupReviewPreservesHeadersWhenLinkOmitsThemAndAppliesDefaults() throws {
        var parts = URLComponents(url: setupURL(), resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "url", value: endpoint(path: "/upload", keyed: false).absoluteString)]
        let review = ServerQRReview(code: try parsed(parts.url!), current: current, ownTracks: true)
        var expected = current
        expected.endpoint = endpoint(path: "/upload", keyed: false).absoluteString
        expected.token = ""
        expected.deviceId = ""
        expected.uniqueId = false
        XCTAssertTrue(review.values == expected)
        XCTAssertFalse(review.includesKey)
        XCTAssertEqual(review.format, "OwnTracks")
    }

    func testServerDisplayStripsDawarichSuffixButKeepsPrefixPortAndEncoding() {
        for suffix in ["/api/v1/overland/batches", "/api/v1/owntracks/points"] {
            for trailing in ["", "/"] {
                var parts = URLComponents(url: endpoint(path: "/my%20server/a%2Fb%3Fpart" + suffix + trailing), resolvingAgainstBaseURL: false)!
                parts.port = 8443
                let review = ServerQRReview(code: .dawarich(parts.url!), current: current, ownTracks: false)
                XCTAssertTrue(review.serverDisplay == "wherewolf.test:8443/my%20server/a%2Fb%3Fpart")
            }
        }
    }

    func testServerDisplayOmitsUserInfoQueryFragmentAndFormToken() {
        var parts = URLComponents(url: endpoint(path: "/private%40place/upload/"), resolvingAgainstBaseURL: false)!
        parts.user = "fixture-user"
        parts.password = key
        parts.fragment = key
        let review = ServerQRReview(code: .endpoint(parts.url!), current: current, ownTracks: false)
        XCTAssertTrue(review.serverDisplay == "wherewolf.test/private%40place/upload")
        XCTAssertFalse(review.serverDisplay.contains(key))
        XCTAssertFalse(review.serverDisplay.contains(current.token))
        XCTAssertFalse(review.serverDisplay.contains("fixture-user"))
        XCTAssertFalse(review.serverDisplay.contains("api_key"))
    }

    func testServerDisplayKeepsOtherEndpointPathsAndHandlesMissingHost() {
        let review = ServerQRReview(code: .endpoint(endpoint(path: "/api/v1/overland/batches/extra", keyed: false)),
                                    current: current, ownTracks: false)
        XCTAssertTrue(review.serverDisplay == "wherewolf.test/api/v1/overland/batches/extra")
        let hostless = ServerQRReview(code: .endpoint(URL(string: "file:///fixture")!), current: current, ownTracks: false)
        XCTAssertEqual(hostless.serverDisplay, "Server")
    }

    func testIncludesKeyRequiresNonemptyAPIKeyOrToken() {
        var empty = current
        empty.token = ""
        let url = endpoint(path: "/upload", keyed: false)
        XCTAssertFalse(ServerQRReview(code: .endpoint(url), current: empty, ownTracks: false).includesKey)
        var parts = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        parts.queryItems = [URLQueryItem(name: "api_key", value: ""), URLQueryItem(name: "other", value: key)]
        XCTAssertFalse(ServerQRReview(code: .endpoint(parts.url!), current: empty, ownTracks: false).includesKey)
        parts.queryItems = [URLQueryItem(name: "api_key", value: key)]
        XCTAssertTrue(ServerQRReview(code: .endpoint(parts.url!), current: empty, ownTracks: false).includesKey)
        XCTAssertTrue(ServerQRReview(code: .endpoint(url), current: current, ownTracks: false).includesKey)
    }

    func testMalformedScansCannotCreateReview() throws {
        let malformed: [[String: Any]] = [
            ["server_url": "https://wherewolf.test", "api_key": ""],
            ["server_url": "https://wherewolf.test", "api_key": 17],
            ["server_url": "https://wherewolf.test", "api_key": key + "\n"],
            ["server_url": "file:///fixture", "api_key": key]
        ]
        for object in malformed {
            let data = try JSONSerialization.data(withJSONObject: object)
            XCTAssertTrue(DawarichServer.parseQRCode(String(decoding: data, as: UTF8.self), ownTracks: false) == nil)
        }
        for text in ["", "junk", "{", "[]", "wherewolf://setup", "wherewolf://setup?url=file%3A%2F%2Ffixture"] {
            XCTAssertTrue(DawarichServer.parseQRCode(text, ownTracks: false) == nil)
        }
        XCTAssertTrue(DawarichServer.parseQRCode(setupURL(headers: ["Authorization": key]).absoluteString, ownTracks: false) == nil)
    }

    func testReviewConfirmationPassesExactDestinationThroughOnboardingAction() async throws {
        let suite = "ServerQRReviewTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var applied: [OnboardingDestination] = []
        let model = OnboardingModel(defaults: defaults, actions: OnboardingActions(
            loadStatus: { OnboardingStatus() }, request: { _ in nil }, openSettings: {}, openHealth: {},
            applyDestination: { applied.append($0); return true }, applyPreset: { _ in }, startTracking: { XCTFail("Unexpected tracking start") }
        ))
        await model.refresh()
        let setup = setupURL(headers: ["X-Scanned": "scanned value"])
        let plain = endpoint(path: "/upload", keyed: false)
        let reviews = [
            ServerQRReview(code: try accountCode(), current: current, ownTracks: false),
            ServerQRReview(code: try parsed(setup), current: current, ownTracks: false),
            ServerQRReview(code: try parsed(plain), current: current, ownTracks: true)
        ]
        XCTAssertTrue(applied.isEmpty)
        for review in reviews { await model.chooseDestination(review.destination) }
        XCTAssertTrue(applied == [
            .server(endpoint: endpoint().absoluteString, token: "", ownTracks: false),
            .setupLink(setup.absoluteString),
            .server(endpoint: plain.absoluteString, token: current.token, ownTracks: true)
        ])
        XCTAssertFalse(model.completed)
        XCTAssertNil(model.error)
    }

    private func preservingSettings(_ action: (GLManagerBridge, GLManager) -> Void) {
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
        action(bridge, GLManager.shared())
    }

    private func savedValues(_ manager: GLManager) -> ServerQRValues {
        ServerQRValues(endpoint: manager.apiEndpointURL() ?? "", token: manager.apiAccessToken() ?? "",
                       deviceId: manager.deviceId() ?? "", uniqueId: UserDefaults.standard.bool(forKey: GLIncludeUniqueIdDefaultsName),
                       acceptHTTP: UserDefaults.standard.bool(forKey: GLConsiderHTTP200SuccessDefaultsName), headers: manager.customHTTPHeaders)
    }

    func testReviewSaveMatchesManualSaveForEveryFormField() throws {
        let review = ServerQRReview(code: try parsed(setupURL(headers: ["X-Scanned": "scanned value"])),
                                    current: current, ownTracks: false)
        preservingSettings { bridge, manager in
            let tracking = manager.trackingEnabled
            let history = bridge.sendHistory
            let value = review.values
            XCTAssertTrue(bridge.saveServer(url: value.endpoint, token: value.token, deviceId: value.deviceId,
                                           uniqueId: value.uniqueId, acceptHTTP: value.acceptHTTP, headers: value.headers))
            let manual = savedValues(manager)
            XCTAssertTrue(manual == value)
            XCTAssertTrue(bridge.saveServer(url: "https://wherewolf.test/reset", token: "", deviceId: "reset",
                                           uniqueId: false, acceptHTTP: false, headers: [:]))
            XCTAssertTrue(review.values.save(using: bridge))
            XCTAssertTrue(savedValues(manager) == manual)
            XCTAssertEqual(manager.trackingEnabled, tracking)
            XCTAssertTrue(bridge.sendHistory == history)
        }
    }

    func testReviewSaveUsesManualValidationWithoutPartialWrites() {
        preservingSettings { bridge, manager in
            var value = current
            value.endpoint = "https://wherewolf.test/upload"
            XCTAssertTrue(value.save(using: bridge))
            let saved = savedValues(manager)
            for invalid in [
                ServerQRValues(endpoint: "file:///fixture", token: key, deviceId: "changed", uniqueId: true, acceptHTTP: false, headers: [:]),
                ServerQRValues(endpoint: value.endpoint, token: key, deviceId: "changed", uniqueId: true, acceptHTTP: false, headers: ["Authorization": key])
            ] {
                XCTAssertFalse(invalid.save(using: bridge))
                XCTAssertTrue(savedValues(manager) == saved)
            }
        }
    }

    #if !WHEREWOLF_APP_STORE
    func testPreviewFixturesCoverEachReviewKindWithoutProbing() {
        let expected: [(String, ServerQRReview.Kind)] = [("dawarich", .dawarich), ("setup", .setup), ("url", .url)]
        for (name, kind) in expected {
            let review = ServerQRReview.preview(arguments: ["WhereWolf", "-WhereWolfQRReviewPreview", name])
            XCTAssertEqual(review?.kind, kind)
            XCTAssertTrue(review?.previewStatus != nil)
            XCTAssertTrue(review?.serverDisplay == "dawarich.example.com/tracking")
            if let review {
                let check = ServerQRReviewCheck()
                check.start(review)
                XCTAssertTrue(check.status == review.previewStatus)
                check.cancel()
            }
        }
        XCTAssertTrue(ServerQRReview.preview(arguments: []) == nil)
        XCTAssertTrue(ServerQRReview.preview(arguments: ["-WhereWolfQRReviewPreview"]) == nil)
        XCTAssertTrue(ServerQRReview.preview(arguments: ["-WhereWolfQRReviewPreview", "unknown"]) == nil)
    }
    #endif
}
