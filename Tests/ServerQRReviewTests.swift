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

    private func setupURL(scheme: String = "wherewolf", path: String = "/upload", headers: [String: String] = [:]) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = "setup"
        parts.queryItems = [URLQueryItem(name: "url", value: endpoint(path: path).absoluteString),
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

    func testDawarichBadgeRecognizesAccountJSON() throws {
        for ownTracks in [false, true] {
            let review = ServerQRReview(code: try accountCode(ownTracks: ownTracks), current: current, ownTracks: ownTracks)
            XCTAssertTrue(review.isDawarich)
        }
    }

    func testDawarichBadgeRecognizesSetupLinksAndUploadURLs() throws {
        for suffix in ["/api/v1/overland/batches", "/api/v1/owntracks/points"] {
            for trailing in ["", "/"] {
                let path = "/my%20server/a%2Fb" + suffix + trailing
                let codes = [try parsed(endpoint(path: path)),
                             try parsed(setupURL(path: path)),
                             try parsed(setupURL(scheme: "overland", path: path))]
                for code in codes {
                    XCTAssertTrue(ServerQRReview(code: code, current: current, ownTracks: false).isDawarich)
                }
            }
        }
    }

    func testDawarichBadgeDoesNotRecognizeOtherURLsOrSetupLinks() throws {
        for path in ["/upload", "/api/v1/overland/batches/extra", "/api/v1/owntracks/points/extra"] {
            for code in [try parsed(endpoint(path: path)), try parsed(setupURL(path: path))] {
                XCTAssertFalse(ServerQRReview(code: code, current: current, ownTracks: false).isDawarich)
            }
        }
    }

    func testDawarichBadgeUsesProbeCredentialRecognition() throws {
        let code = try parsed(endpoint(keyed: false))
        XCTAssertTrue(ServerQRReview(code: code, current: current, ownTracks: false).isDawarich)
        var empty = current
        empty.token = ""
        XCTAssertFalse(ServerQRReview(code: code, current: empty, ownTracks: false).isDawarich)
    }

    func testFoundAnnouncementNamesDawarichForEveryCodeKind() throws {
        let codes = [try accountCode(), try parsed(endpoint()),
                     try parsed(setupURL(path: "/tracking/api/v1/overland/batches"))]
        for code in codes {
            XCTAssertEqual(ServerQRReview(code: code, current: current, ownTracks: false).foundAnnouncement,
                           "Dawarich server found")
        }
        for code in [try parsed(endpoint(path: "/upload")), try parsed(setupURL())] {
            XCTAssertEqual(ServerQRReview(code: code, current: current, ownTracks: false).foundAnnouncement, "Code found")
        }
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

    private var waiting: ServerPendingQueue {
        let first = Date(timeIntervalSince1970: 1_700_000_000)
        return ServerPendingQueue(count: 6_133, importedCount: 10, oldest: first, newest: first.addingTimeInterval(86_400))
    }

    func testPendingConfirmationSkipsEmptyQueueAndUnchangedServer() async {
        for changed in [false, true] {
            let confirmation = ServerChangeConfirmation()
            var reads = 0
            var saves = 0
            var values = current
            if changed { values.endpoint = "https://wherewolf.test/new" }
            let result = await confirmation.request(values, current: current, load: {
                reads += 1
                return changed ? .empty : self.waiting
            }, save: { saves += 1; return true })
            XCTAssertEqual(result, true)
            XCTAssertEqual(reads, changed ? 1 : 0)
            XCTAssertEqual(saves, 1)
            XCTAssertNil(confirmation.pending)
        }
    }

    func testServerIdentityIncludesAccountAndHeadersButNotDeviceOptions() {
        var same = current
        same.endpoint = " HTTPS://WHEREWOLF.TEST:443/old#ignored "
        same.headers = ["x-existing": "existing value"]
        same.deviceId = "another-device"
        same.uniqueId.toggle()
        same.acceptHTTP.toggle()
        XCTAssertFalse(same.changesServer(from: current))
        for field in ["endpoint", "token", "headers"] {
            var changed = current
            switch field {
            case "endpoint": changed.endpoint += "/other"
            case "token": changed.token = "another-account"
            default: changed.headers = ["X-Existing": "another-account"]
            }
            XCTAssertTrue(changed.changesServer(from: current))
        }
        var firstConnection = current
        firstConnection.endpoint = ""
        XCTAssertTrue(current.changesServer(from: firstConnection))
    }

    func testPendingBackReturnsToEachReviewWithoutSaving() async throws {
        for code in [try accountCode(), try parsed(setupURL()), try parsed(endpoint(path: "/upload"))] {
            let review = ServerQRReview(code: code, current: current, ownTracks: false)
            let confirmation = ServerChangeConfirmation()
            let read = expectation(description: "Queue metadata read")
            var saves = 0
            let request = Task {
                await confirmation.request(review.values, current: current, load: {
                    read.fulfill()
                    return self.waiting
                }, save: { saves += 1; return true })
            }
            await fulfillment(of: [read], timeout: 1)
            XCTAssertEqual(confirmation.pending, waiting)
            XCTAssertEqual(confirmation.host, "wherewolf.test")
            XCTAssertEqual(saves, 0)
            confirmation.back()
            let result = await request.value
            XCTAssertNil(result)
            XCTAssertNil(confirmation.pending)
            XCTAssertNil(confirmation.error)
            await confirmation.confirm()
            XCTAssertEqual(saves, 0)
        }
    }

    func testPendingUseSavesExactlyOnceDespiteRepeatedTaps() async {
        let confirmation = ServerChangeConfirmation()
        var proposed = current
        proposed.endpoint = "https://fixture-user:fixture-password@new.wherewolf.test/upload?api_key=secret#private"
        let values = proposed
        let read = expectation(description: "Queue metadata read")
        let saving = expectation(description: "Save started")
        var finishSave: CheckedContinuation<Bool, Never>?
        var saves = 0
        let request = Task {
            await confirmation.request(values, current: current, load: {
                read.fulfill()
                return self.waiting
            }, save: {
                saves += 1
                return await withCheckedContinuation {
                    finishSave = $0
                    saving.fulfill()
                }
            })
        }
        await fulfillment(of: [read], timeout: 1)
        XCTAssertEqual(confirmation.host, "new.wherewolf.test")
        XCTAssertEqual(saves, 0)
        let use = Task { await confirmation.confirm() }
        await fulfillment(of: [saving], timeout: 1)
        await confirmation.confirm()
        confirmation.back()
        XCTAssertNotNil(confirmation.pending)
        XCTAssertEqual(saves, 1)
        finishSave?.resume(returning: true)
        await use.value
        let result = await request.value
        XCTAssertEqual(result, true)
        await confirmation.confirm()
        XCTAssertEqual(saves, 1)
        XCTAssertNil(confirmation.pending)
    }

    func testFailedMetadataReadNeverSavesAndCanBeRetried() async {
        let confirmation = ServerChangeConfirmation()
        var values = current
        values.endpoint += "/new"
        var saves = 0
        let failed = await confirmation.request(values, current: current, load: { nil }, save: { saves += 1; return true })
        XCTAssertEqual(failed, false)
        XCTAssertNotNil(confirmation.error)
        XCTAssertEqual(saves, 0)
        let retried = await confirmation.request(values, current: current, load: { .empty }, save: { saves += 1; return true })
        XCTAssertEqual(retried, true)
        XCTAssertNil(confirmation.error)
        XCTAssertEqual(saves, 1)
    }

    func testImportedOnlyQueueStillConfirmsAndFailedSaveKeepsTheStep() async {
        let confirmation = ServerChangeConfirmation()
        var proposed = current
        proposed.endpoint += "/new"
        let values = proposed
        let imported = ServerPendingQueue(count: 1, importedCount: 1, oldest: waiting.oldest, newest: waiting.oldest)
        let read = expectation(description: "Imported queue metadata read")
        var attempts = 0
        let request = Task {
            await confirmation.request(values, current: current, load: {
                read.fulfill()
                return imported
            }, save: { attempts += 1; return attempts > 1 })
        }
        await fulfillment(of: [read], timeout: 1)
        XCTAssertEqual(confirmation.pending, imported)
        await confirmation.confirm()
        XCTAssertEqual(confirmation.pending, imported)
        XCTAssertNotNil(confirmation.error)
        XCTAssertFalse(confirmation.busy)
        await confirmation.confirm()
        let result = await request.value
        XCTAssertEqual(result, true)
        XCTAssertEqual(attempts, 2)
        XCTAssertNil(confirmation.pending)
        XCTAssertNil(confirmation.error)
    }

    func testClosingDuringMetadataReadDoesNotSaveWhenReadCompletes() async {
        let confirmation = ServerChangeConfirmation()
        var proposed = current
        proposed.endpoint += "/new"
        let values = proposed
        let reading = expectation(description: "Read started")
        var finishRead: CheckedContinuation<ServerPendingQueue?, Never>?
        var saves = 0
        let request = Task {
            await confirmation.request(values, current: current, load: {
                await withCheckedContinuation {
                    finishRead = $0
                    reading.fulfill()
                }
            }, save: { saves += 1; return true })
        }
        await fulfillment(of: [reading], timeout: 1)
        confirmation.cancel()
        finishRead?.resume(returning: .empty)
        let result = await request.value
        XCTAssertNil(result)
        XCTAssertEqual(saves, 0)
        XCTAssertNil(confirmation.pending)
    }

    func testPendingCountTextSeparatesImportedWorkoutsAndHandlesOnePoint() {
        let locale = Locale(identifier: "en_US")
        XCTAssertEqual(waiting.countText(locale: locale), "6,123 points waiting")
        XCTAssertEqual(waiting.importedText(locale: locale), "and 10 imported workout points")
        let single = ServerPendingQueue(count: 1, importedCount: 0, oldest: waiting.oldest, newest: waiting.oldest)
        XCTAssertEqual(single.countText(locale: locale), "1 point waiting")
        XCTAssertNil(single.importedText(locale: locale))
        let imported = ServerPendingQueue(count: 1, importedCount: 1, oldest: waiting.oldest, newest: waiting.oldest)
        XCTAssertEqual(imported.countText(locale: locale), "1 imported workout point waiting")
        XCTAssertNil(imported.importedText(locale: locale))
        let mixed = ServerPendingQueue(count: 2, importedCount: 1, oldest: waiting.oldest, newest: waiting.newest)
        XCTAssertEqual(mixed.countText(locale: locale), "1 point waiting")
        XCTAssertEqual(mixed.importedText(locale: locale), "and 1 imported workout point")
        XCTAssertEqual(waiting.countText(locale: Locale(identifier: "de_DE")), "6.123 points waiting")
    }

    func testPendingRangeUsesLocalDatesAndDistinguishesRepeatedDSTHour() throws {
        let formatter = ISO8601DateFormatter()
        let first = try XCTUnwrap(formatter.date(from: "2026-11-01T05:30:00Z"))
        let last = try XCTUnwrap(formatter.date(from: "2026-11-01T06:30:00Z"))
        let summary = ServerPendingQueue(count: 2, importedCount: 0, oldest: first, newest: last)
        let locale = Locale(identifier: "en_US")
        let eastern = summary.rangeText(locale: locale, timeZone: try XCTUnwrap(TimeZone(identifier: "America/New_York")))
        XCTAssertTrue(eastern.contains("Nov 1, 2026"))
        XCTAssertTrue(eastern.contains("EDT"))
        XCTAssertTrue(eastern.contains("EST"))
        XCTAssertTrue(eastern.contains(" – "))
        let pacific = summary.rangeText(locale: locale, timeZone: try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles")))
        XCTAssertTrue(pacific.contains("Oct 31, 2026"))
        XCTAssertTrue(pacific.contains("PDT"))
        XCTAssertNotEqual(eastern, pacific)
        let single = ServerPendingQueue(count: 1, importedCount: 0, oldest: first, newest: first)
        XCTAssertFalse(single.rangeText(locale: locale).contains(" – "))
        XCTAssertEqual(ServerPendingQueue.empty.rangeText(), "Recorded dates unavailable")
    }

    func testGuidePendingReviewResolvesTheSameSavedDestination() throws {
        let setup = setupURL(headers: ["X-Scanned": "scanned value"])
        let values = try XCTUnwrap(ServerQRValues.onboarding(.setupLink(setup.absoluteString), current: current))
        let review = ServerQRReview(code: try parsed(setup), current: current, ownTracks: false)
        XCTAssertEqual(values, review.values)
        let manual = try XCTUnwrap(ServerQRValues.onboarding(.server(endpoint: " https://wherewolf.test/manual ", token: "manual", ownTracks: true), current: current))
        XCTAssertEqual(manual.endpoint, "https://wherewolf.test/manual")
        XCTAssertEqual(manual.token, "manual")
        XCTAssertEqual(manual.headers, current.headers)
        XCTAssertNil(ServerQRValues.onboarding(.setupLink("invalid"), current: current))
        XCTAssertNil(ServerQRValues.onboarding(.server(endpoint: "file:///fixture", token: "", ownTracks: false), current: current))
    }

    #if !WHEREWOLF_APP_STORE
    func testPendingPreviewParsesPositiveCountsInEitherArgumentOrder() throws {
        for kind in ["dawarich", "setup", "url"] {
            for arguments in [
                ["-WhereWolfQRReviewPreview", kind, "-WhereWolfQRPendingPreview", "6123"],
                ["-WhereWolfQRPendingPreview", "6123", "-WhereWolfQRReviewPreview", kind]
            ] {
                let review = try XCTUnwrap(ServerQRReview.preview(arguments: arguments))
                let pending = try XCTUnwrap(review.previewPendingQueue)
                XCTAssertEqual(pending.count, 6_123)
                XCTAssertEqual(pending.importedCount, 0)
                XCTAssertEqual(pending.newest?.timeIntervalSince(pending.oldest!), 3 * 86_400)
                XCTAssertNotNil(review.previewStatus)
            }
        }
        let one = try XCTUnwrap(ServerQRReview.preview(arguments: ["-WhereWolfQRReviewPreview", "url", "-WhereWolfQRPendingPreview", "1"])?.previewPendingQueue)
        XCTAssertEqual(one.oldest, one.newest)
        for count in ["0", "-1", "1.5", "garbage", "1000000001", "99999999999999999999999999"] {
            XCTAssertNil(ServerQRReview.preview(arguments: ["-WhereWolfQRReviewPreview", "url", "-WhereWolfQRPendingPreview", count])?.previewPendingQueue)
        }
        XCTAssertNil(ServerQRReview.preview(arguments: ["-WhereWolfQRReviewPreview", "url", "-WhereWolfQRPendingPreview"])?.previewPendingQueue)
        XCTAssertNil(ServerQRReview.preview(arguments: ["-WhereWolfQRPendingPreview", "6123"]))
    }

    func testScanPreviewFixturesCoverEveryCodeKindWithoutProbing() throws {
        let expected: [(String, ServerQRReview.Kind, Bool)] = [
            ("dawarich", .dawarich, true), ("setup", .setup, true), ("url", .url, true), ("other", .url, false)
        ]
        for (name, kind, isDawarich) in expected {
            let preview = try XCTUnwrap(ServerQRScanPreview.parse(arguments: ["WhereWolf", "-WhereWolfQRScanPreview", name]))
            XCTAssertEqual(preview.fixture.rawValue, name)
            XCTAssertNil(preview.hold)
            let code = try XCTUnwrap(DawarichServer.parseQRCode(preview.fixture.text, ownTracks: false))
            var review = ServerQRReview(code: code, current: ServerQRPreviewFixture.current, ownTracks: false)
            review.previewStatus = preview.fixture.status
            XCTAssertEqual(review.kind, kind)
            XCTAssertEqual(review.isDawarich, isDawarich)
            if name != "other" {
                let direct = try XCTUnwrap(ServerQRReview.preview(arguments: ["-WhereWolfQRReviewPreview", name]))
                XCTAssertTrue(review.values == direct.values)
                XCTAssertTrue(review.serverDisplay == "dawarich.example.com/tracking")
            }
            let check = ServerQRReviewCheck()
            check.start(review)
            XCTAssertTrue(check.status == preview.fixture.status)
            check.cancel()
        }
    }

    func testScanPreviewParsesHoldStagesInEitherArgumentOrder() throws {
        for stage in ["check", "badge"] {
            for arguments in [
                ["-WhereWolfQRScanPreview", "dawarich", "-WhereWolfQRScanPreviewHold", stage],
                ["-WhereWolfQRScanPreviewHold", stage, "-WhereWolfQRScanPreview", "setup"]
            ] {
                let preview = try XCTUnwrap(ServerQRScanPreview.parse(arguments: arguments))
                XCTAssertEqual(preview.hold?.rawValue, stage)
            }
        }
    }

    func testScanPreviewIgnoresMissingAndUnknownArguments() throws {
        for arguments in [
            [], ["-WhereWolfQRScanPreview"], ["-WhereWolfQRScanPreview", "unknown"],
            ["-WhereWolfQRScanPreview", "DAWARICH"], ["-WhereWolfQRScanPreviewHold", "badge"],
            ["-WhereWolfQRScanPreview", "-WhereWolfQRScanPreviewHold", "check"]
        ] {
            XCTAssertNil(ServerQRScanPreview.parse(arguments: arguments))
        }
        for arguments in [
            ["-WhereWolfQRScanPreview", "url", "-WhereWolfQRScanPreviewHold"],
            ["-WhereWolfQRScanPreview", "url", "-WhereWolfQRScanPreviewHold", "unknown"],
            ["-WhereWolfQRScanPreviewHold", "unknown", "-WhereWolfQRScanPreview", "url"]
        ] {
            let preview = try XCTUnwrap(ServerQRScanPreview.parse(arguments: arguments))
            XCTAssertEqual(preview.fixture, .url)
            XCTAssertNil(preview.hold)
        }
    }

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
