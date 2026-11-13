import XCTest
import CoreLocation
@testable import WhereWolf

final class DawarichStopNameTests: XCTestCase {
    private let day = ISO8601DateFormatter().date(from: "2026-06-01T00:00:00Z")!
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    private var configuration: URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StopNamesProtocol.self]
        return configuration
    }
    private func client(version: String = "1.20.0") throws -> DawarichHistoryClient {
        let server = try XCTUnwrap(DawarichServer(endpoint: "https://wherewolf.test/prefix/api/v1/overland/batches", token: "fixture-key"))
        return DawarichHistoryClient(server: server, headers: ["X-Proxy": "fixture"], version: version, configuration: configuration)
    }
    private func place(_ name: String = "Home", id: Int64 = 4, north: Double = 0) -> DawarichStopPlace {
        .init(id: id, name: name, latitude: 40 + north / 111_195, longitude: -73)
    }
    private func visit(id: Int64 = 1, start: Double = 0, end: Double = 600, status: String = "confirmed",
                       place: DawarichStopPlace? = nil) -> DawarichStopVisit {
        let place = place ?? self.place()
        return .init(id: id, startedAt: day.addingTimeInterval(start), endedAt: day.addingTimeInterval(end),
                     status: status, placeID: place.id, place: place)
    }
    private func points(on day: Date? = nil, server: Bool = false) -> [RecordedLocation] {
        let day = day ?? self.day
        return (0...10).map { .init(id: Int64($0 + 1) * (server ? -1 : 1),
            timestamp: day.addingTimeInterval(Double($0) * 60), latitude: 40, longitude: -73) }
    }
    private func landmarks(_ visits: [DawarichStopVisit], wifi: [WifiPlace] = [], places: [DawarichStopPlace] = []) -> HistoryLandmarks {
        let points = points()
        return HistoryLandmarks(points: points, timeline: ReplayTimeline(points: points), places: wifi,
            calendar: calendar, stopNames: .init(places: places, visits: visits))
    }
    private func row(id: Int = 1, start: Date? = nil, end: Date? = nil, status: String = "confirmed") -> [String: Any] {
        let formatter = ISO8601DateFormatter()
        return ["id": id, "place_id": 4, "started_at": formatter.string(from: start ?? day),
                "ended_at": formatter.string(from: end ?? day.addingTimeInterval(600)), "status": status,
                "name": "Visit display name", "place": ["id": 4, "name": "Home", "latitude": "40.0", "longitude": "-73.0"]]
    }

    override func tearDown() {
        StopNamesProtocol.handler = nil
        super.tearDown()
    }

    func testPositiveTimeOverlapAndDistanceAreBothRequired() {
        XCTAssertEqual(landmarks([visit()]).stops.first?.name, "Home")
        XCTAssertEqual(landmarks([visit(start: -600, end: 60)]).stops.first?.name, "Home")
        XCTAssertNil(landmarks([visit(start: -600, end: 0)]).stops.first?.name)
        XCTAssertNil(landmarks([visit(start: 600, end: 1_200)]).stops.first?.name)
        XCTAssertNil(landmarks([visit(place: place(north: 301))]).stops.first?.name)
        XCTAssertEqual(landmarks([visit(place: place(north: 299))]).stops.first?.name, "Home")
        XCTAssertNil(landmarks([], places: [place()]).stops.first?.name, "Nearby places alone do not prove a visit")
    }

    func testWiFiWinsAndPlacesRefreshNamesWithoutChangingTheStop() {
        let wifi = WifiPlace(id: "owner", name: "My Name", latitude: 40, longitude: -73,
                             symbol: "heart.fill", color: "pink")
        let named = landmarks([visit()], places: [place("Office")])
        XCTAssertEqual(named.stops.first?.name, "Office")
        XCTAssertEqual(named.stops.first?.symbol, "building.2.fill")
        XCTAssertEqual(named.journey.first?.rows.first?.title, "Office")
        let own = landmarks([visit()], wifi: [wifi], places: [place("Office")])
        XCTAssertEqual(own.stops.first?.name, "My Name")
        XCTAssertEqual(own.stops.first?.symbol, "heart.fill")
        XCTAssertEqual(own.stops.first?.color, "pink")
        XCTAssertEqual(own.stops.first?.id, named.stops.first?.id)
        XCTAssertEqual(own.stops.first?.end, named.stops.first?.end)
    }

    func testCustomVisitNameSurvivesPersistenceAndClippingAndBeatsRefreshedPlace() throws {
        var value = row()
        value["custom_name"] = " Dentist \n"
        value["display_name"] = "Dentist"
        value["place"] = ["id": 4, "name": "Medical Centre", "latitude": 40, "longitude": -73]
        let decoded = try XCTUnwrap(DawarichStopDecoder.visit(value))
        XCTAssertEqual(decoded.customName, "Dentist")
        let restored = try JSONDecoder().decode(DawarichStopVisit.self, from: JSONEncoder().encode(decoded))
        let clipped = try XCTUnwrap(restored.clipped(from: day.addingTimeInterval(60), to: day.addingTimeInterval(540)))
        let refreshed = place("Renamed Medical Centre")
        let named = landmarks([clipped], places: [refreshed])
        XCTAssertEqual(named.stops.first?.name, "Dentist")
        XCTAssertEqual(named.journey.first?.rows.first?.title, "Dentist")
        let wifi = WifiPlace(name: "My Name", latitude: 40, longitude: -73)
        XCTAssertEqual(landmarks([clipped], wifi: [wifi], places: [refreshed]).stops.first?.name, "My Name")
        for absent in [NSNull(), " \n"] as [Any] {
            value["custom_name"] = absent
            let ordinary = try XCTUnwrap(DawarichStopDecoder.visit(value))
            XCTAssertEqual(landmarks([ordinary], places: [refreshed]).stops.first?.name, "Renamed Medical Centre")
        }
    }

    func testVisibleVisitCenterNamesStopsWithoutAPlaceAndMaskedCentersStayUnnamed() throws {
        var value = row()
        value["place"] = NSNull()
        value["place_id"] = NSNull()
        value["name"] = "Riverside"
        value["display_name"] = "Riverside Park"
        value["center"] = ["latitude": 40, "longitude": -73]
        let decoded = try XCTUnwrap(DawarichStopDecoder.visit(value))
        XCTAssertNil(decoded.place)
        XCTAssertEqual(decoded.center?.latitude, 40)
        XCTAssertEqual(decoded.center?.longitude, -73)
        let restored = try JSONDecoder().decode(DawarichStopVisit.self, from: JSONEncoder().encode(decoded))
        let clipped = try XCTUnwrap(restored.clipped(from: day.addingTimeInterval(60), to: day.addingTimeInterval(540)))
        XCTAssertEqual(landmarks([clipped], places: [place()]).stops.first?.name, "Riverside Park")
        let wifi = WifiPlace(name: "My Name", latitude: 40, longitude: -73)
        XCTAssertEqual(landmarks([clipped], wifi: [wifi]).stops.first?.name, "My Name")
        value["display_name"] = NSNull()
        XCTAssertEqual(landmarks([try XCTUnwrap(DawarichStopDecoder.visit(value))]).stops.first?.name, "Riverside")
        value["custom_name"] = "Picnic"
        XCTAssertEqual(landmarks([try XCTUnwrap(DawarichStopDecoder.visit(value))]).stops.first?.name, "Picnic")
        for status in ["suggested", "declined"] {
            var unconfirmed = value
            unconfirmed["status"] = status
            XCTAssertNil(landmarks([try XCTUnwrap(DawarichStopDecoder.visit(unconfirmed))]).stops.first?.name)
        }
        value["center"] = ["latitude": place(north: 301).latitude, "longitude": -73]
        XCTAssertNil(landmarks([try XCTUnwrap(DawarichStopDecoder.visit(value))]).stops.first?.name)
        value["place_id"] = 4
        for hidden in [NSNull(), ["latitude": NSNull(), "longitude": -73],
                       ["latitude": true, "longitude": -73], ["latitude": 91, "longitude": -73]] as [Any] {
            value["center"] = hidden
            let masked = try XCTUnwrap(DawarichStopDecoder.visit(value))
            XCTAssertNil(masked.center)
            XCTAssertNil(landmarks([masked], places: [place()]).stops.first?.name)
        }
    }

    func testSuggestionsDeclinedAndUnknownStatusesCannotSupplyNames() {
        for status in ["suggested", "declined", "unconfirmed", "", "new_status"] {
            let value = landmarks([visit(status: status)], places: [place("Home")])
            XCTAssertNil(value.stops.first?.name)
            XCTAssertEqual(value.stops.first?.symbol, "mappin")
            XCTAssertEqual(value.stops.first?.color, "gray")
            XCTAssertEqual(value.stops.first?.label, "Stop · 10 min")
        }
    }

    func testMissingOrMaskedVisitCoordinatesCannotBeFilledFromCachedPlaces() {
        let masked = DawarichStopVisit(id: 1, startedAt: day, endedAt: day.addingTimeInterval(600),
                                      status: "confirmed", placeID: 4, place: nil)
        XCTAssertNil(landmarks([masked], places: [place()]).stops.first?.name)
        var invalid = row()
        invalid["place"] = ["id": 4, "name": "Hidden", "latitude": NSNull(), "longitude": NSNull()]
        XCTAssertNil(DawarichStopDecoder.visit(invalid)?.place)
        invalid["place"] = ["id": 4, "name": "Invalid", "latitude": true, "longitude": "-73"]
        XCTAssertNil(DawarichStopDecoder.visit(invalid)?.place)
    }

    func testLongestOverlapThenNearestThenIDResolveCompetingVisits() {
        let short = visit(id: 1, start: 0, end: 60, place: place("Short", id: 1))
        let long = visit(id: 2, place: place("Long", id: 2, north: 100))
        let near = visit(id: 3, place: place("Near", id: 3))
        XCTAssertEqual(landmarks([short, long]).stops.first?.name, "Long")
        XCTAssertEqual(landmarks([long, near]).stops.first?.name, "Near")
        XCTAssertEqual(landmarks([visit(id: 4, place: place("Later", id: 4)), near]).stops.first?.name, "Near")
    }

    func testServerPointDaysAndUnloadedTimelineUseTheSameNamingOrder() {
        let points = points(server: true)
        let stop = visit()
        var snapshot = ServerHistorySnapshot(firstDay: day, days: [.init(day: day, pointCount: points.count,
            stops: [.init(startedAt: stop.startedAt, endedAt: stop.endedAt, name: "Old timeline name", visit: stop)])], calendar: calendar)
        let wifi = WifiPlace(name: "Owner Home", latitude: 40, longitude: -73)
        for loaded in [false, true] {
            snapshot.points = loaded ? [day: points.map { .init(location: $0) }] : [:]
            let actual = loaded ? points : []
            let ruler = ServerHistoryRuler(points: actual, phoneStart: day.addingTimeInterval(86_400), snapshot: snapshot,
                                           now: day.addingTimeInterval(86_400))
            let value = HistoryLandmarks(points: actual, timeline: ReplayTimeline(points: actual), places: [wifi],
                calendar: calendar, ruler: ruler, stopNames: .init(visits: [stop]))
            XCTAssertEqual(value.stops.first?.name, "Owner Home")
            let serverName = HistoryLandmarks(points: actual, timeline: ReplayTimeline(points: actual), places: [],
                calendar: calendar, ruler: ruler, stopNames: .init(visits: [stop]))
            XCTAssertEqual(serverName.stops.first?.name, "Home")
        }
        snapshot.points = [:]
        let ruler = ServerHistoryRuler(points: [], phoneStart: day.addingTimeInterval(86_400), snapshot: snapshot,
                                       now: day.addingTimeInterval(86_400))
        let removed = HistoryLandmarks(points: [], timeline: ReplayTimeline(points: []), places: [], calendar: calendar,
            ruler: ruler, stopNames: .init(days: [day]))
        XCTAssertTrue(removed.stops.allSatisfy { $0.name == nil }, "A refreshed empty visits range supersedes stale timeline names")
    }

    func testReadsUseGETMaskingBearerPrefixAndPaginationIncludingOvernightOverlap() async throws {
        let start = day.addingTimeInterval(-3_600), end = day.addingTimeInterval(600)
        let expected = row(start: start, end: end)
        StopNamesProtocol.handler = { mock in
            XCTAssertEqual(mock.request.httpMethod, "GET")
            XCTAssertNil(mock.request.httpBody)
            XCTAssertEqual(mock.request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-key")
            XCTAssertEqual(mock.request.value(forHTTPHeaderField: "X-Proxy"), "fixture")
            XCTAssertNil(mock.query["api_key"])
            XCTAssertEqual(mock.query["mask_privacy_zones"], "true")
            switch mock.request.url?.path {
            case "/prefix/api/v1/timeline":
                var entry = expected
                entry["type"] = "visit"; entry["visit_id"] = 1
                entry["place"] = ["name": "Home", "lat": 40, "lng": -73]
                mock.respond(object: ["days": [["entries": [entry]]]])
            case "/prefix/api/v1/visits":
                XCTAssertEqual(mock.query["start_at"], "2026-05-31T23:00:00Z")
                XCTAssertEqual(mock.query["end_at"], "2026-06-01T23:59:59Z")
                XCTAssertEqual(mock.query["per_page"], "500")
                let page = mock.query["page"]!
                mock.respond(pages: 2, object: [page == "1" ? expected : self.row(id: 2, status: "suggested")])
            case "/prefix/api/v1/places":
                XCTAssertEqual(mock.query["per_page"], "500")
                mock.respond(object: [["id": 4, "name": "Office", "latitude": 40, "longitude": -73]])
            default: XCTFail("Unexpected endpoint"); mock.respond(status: 404, object: [])
            }
        }
        let client = try client()
        let visits = try await client.stopVisits(from: day, to: day.addingTimeInterval(86_400))
        let places = try await client.stopPlaces()
        XCTAssertEqual(visits.count, 2)
        XCTAssertEqual(visits.first?.startedAt, start)
        XCTAssertEqual(landmarks(visits, places: places).stops.first?.name, "Office")
    }

    func testUnavailableMissingPaginationAndLaterPageFailureReturnNoPartialNames() async throws {
        for status in [404, 422, 401] {
            StopNamesProtocol.handler = { $0.respond(status: status, object: []) }
            do { _ = try await client().stopPlaces(); XCTFail("Expected unavailable names") }
            catch { XCTAssertTrue(error is DawarichHistoryError) }
        }
        StopNamesProtocol.handler = { mock in
            if mock.query["page"] == "1" {
                mock.respond(pages: 2, object: [["id": 4, "name": "Home", "latitude": 40, "longitude": -73]])
            } else { mock.respond(status: 401, object: []) }
        }
        do { _ = try await client().stopPlaces(); XCTFail("A partial catalog must not replace cached places") }
        catch { XCTAssertEqual(error as? DawarichHistoryError, .authentication) }
        StopNamesProtocol.handler = { $0.respond(pages: nil, object: []) }
        do { _ = try await client().stopPlaces(); XCTFail("Require pagination") }
        catch { XCTAssertEqual(error as? DawarichHistoryError, .invalidResponse) }
    }

    func testLongVisitsUseVisibleTimelineMetadataWithoutAnUnboundedLookback() async throws {
        let day = self.day
        let start = day.addingTimeInterval(-90 * 86_400), end = day.addingTimeInterval(600)
        StopNamesProtocol.handler = { mock in
            if mock.request.url?.lastPathComponent == "timeline" {
                mock.respond(object: ["days": [["entries": [["type": "visit", "visit_id": 1, "place_id": 4,
                    "started_at": ISO8601DateFormatter().string(from: start),
                    "ended_at": ISO8601DateFormatter().string(from: end), "status": "confirmed",
                    "place": ["name": "Home", "lat": 40, "lng": -73]]]]]])
            } else {
                XCTAssertEqual(mock.request.url?.lastPathComponent, "visits")
                XCTAssertEqual(mock.query["start_at"], ISO8601DateFormatter().string(from: day.addingTimeInterval(-31 * 86_400)))
                mock.respond(pages: 0, object: [])
            }
        }
        let visits = try await client().stopVisits(from: day, to: day.addingTimeInterval(86_400))
        XCTAssertEqual(visits.first?.startedAt, start)
        XCTAssertEqual(landmarks(visits).stops.first?.name, "Home")
    }

    func testOlderUnknownAndUnstableVersionsNeverSendNameRequests() async throws {
        StopNamesProtocol.handler = { _ in XCTFail("Unsupported versions cannot request names") }
        for version in ["unknown", "1.19.0", "2.0.0", "1.20.0-beta"] {
            do { _ = try await client(version: version).stopPlaces(); XCTFail("Expected version gate") }
            catch { XCTAssertEqual(error as? DawarichHistoryError, .unsupportedVersion) }
            do { _ = try await client(version: version).stopVisits(from: day, to: day.addingTimeInterval(86_400)); XCTFail("Expected version gate") }
            catch { XCTAssertEqual(error as? DawarichHistoryError, .unsupportedVersion) }
        }
    }

    @MainActor func testOtherOrUnauthenticatedServersNeverRequestNames() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let noRequests = expectation(description: "No unrecognized reads")
        noRequests.isInverted = true
        StopNamesProtocol.handler = { _ in noRequests.fulfill() }
        let store = ServerHistoryStore(cache: .init(directoryURL: directory), configuration: configuration)
        let statuses: [DawarichStatus] = [.notDawarich, .unknown, .dawarich(version: "1.20.0", authenticated: false, account: nil)]
        for status in statuses {
            store.configure(endpoint: "https://wherewolf.test/api/v1/overland/batches", token: "fixture", headers: [:], status: status)
            store.requestStopNames(in: day...day, source: .phoneNames)
            store.requestDays(in: day...day)
        }
        store.configure(endpoint: "https://wherewolf.test/other", token: "fixture", headers: [:],
                        status: .dawarich(version: "1.20.0", authenticated: true, account: nil))
        store.requestStopNames(in: day...day, source: .phoneNames)
        await fulfillment(of: [noRequests], timeout: 0.1)
        await store.clear()
    }

    func testCachePersistsNamesEvictsVisitDaysAndClearsWithSourceAndHistory() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let identity = String(repeating: "a", count: 64)
        var cache: ServerHistoryCache? = .init(directoryURL: directory, maximumPointDays: 2)
        try await cache!.selectSource(identity)
        try await cache!.storeStopPlaces([place()])
        try await cache!.storeStopVisits([visit()], on: day)
        try await cache!.storeStopVisits([], on: day.addingTimeInterval(86_400))
        cache = nil
        let reopened = ServerHistoryCache(directoryURL: directory, maximumPointDays: 2)
        try await reopened.selectSource(identity)
        let saved = try await reopened.stopVisits(on: day)
        let places = try await reopened.stopPlaces()
        XCTAssertEqual(saved, [visit()])
        XCTAssertEqual(places, [place()])
        try await reopened.storeStopVisits([], on: day.addingTimeInterval(172_800))
        let evicted = try await reopened.stopVisits(on: day.addingTimeInterval(86_400))
        XCTAssertNil(evicted)
        let empty = try await reopened.stopVisits(on: day.addingTimeInterval(172_800))
        XCTAssertEqual(empty, [])
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
#if !targetEnvironment(simulator)
            // The simulator reports no data protection class.
            XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: file.path)[.protectionKey] as? FileProtectionType,
                           .completeUntilFirstUserAuthentication)
#endif
        }
        try await reopened.selectSource(String(repeating: "b", count: 64))
        let switched = try await reopened.stopPlaces(), oldVisits = try await reopened.stopVisits(on: day)
        XCTAssertTrue(switched.isEmpty); XCTAssertNil(oldVisits)
        try await reopened.storeStopPlaces([place()])
        try await reopened.clear()
        let bytes = try await reopened.storageBytes()
        XCTAssertEqual(bytes, 0)
    }

    @MainActor func testRefreshFetchesPlacesOnceAndVisitDaysOnceAndKeepsCachedNamesWhenOffline() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ServerHistoryCache(directoryURL: directory)
        let identity = String(repeating: "a", count: 64)
        let names = ServerHistoryNames(cache: cache)
        let visits = [row()], day = day, calendar = calendar
        let placeReads = StopNameCounter(), visitReads = StopNameCounter()
        StopNamesProtocol.handler = { mock in
            switch mock.request.url?.lastPathComponent {
            case "timeline": mock.respond(object: ["days": []])
            case "places":
                placeReads.increment()
                mock.respond(object: [["id": 4, "name": "Office", "latitude": 40, "longitude": -73]])
            case "visits": visitReads.increment(); mock.respond(object: visits)
            default: XCTFail("Unexpected endpoint"); mock.respond(status: 404, object: [])
            }
        }
        let loaded = expectation(description: "Both naming reads publish")
        names.changed = {
            if names.snapshot.days.contains(day), names.snapshot.places.first?.name == "Office" {
                names.changed = nil
                loaded.fulfill()
            }
        }
        names.configure(client: try client(), identity: identity, calendar: calendar, after: nil)
        names.request(day...day, source: .phoneNames)
        names.request(day...day, source: .calendar)
        await fulfillment(of: [loaded], timeout: 2)
        XCTAssertEqual(placeReads.value, 1)
        XCTAssertEqual(visitReads.value, 1)
        names.request(day...day, source: .ruler)
        for task in names.reset() { await task.value }
        let offline = expectation(description: "Protected cached names restored")
        names.changed = {
            if names.snapshot.days.contains(day) {
                names.changed = nil
                offline.fulfill()
            }
        }
        StopNamesProtocol.handler = { _ in XCTFail("Cache-only reads cannot start network requests") }
        names.configure(client: nil, identity: identity, calendar: calendar, after: nil)
        names.request(day...day, source: .phoneNames)
        await fulfillment(of: [offline], timeout: 2)
        XCTAssertEqual(names.snapshot.visits.count, 1)
        XCTAssertEqual(names.snapshot.places.first?.name, "Office")
        for task in names.reset() { await task.value }
        try await cache.clear()
        let bytes = try await cache.storageBytes()
        XCTAssertEqual(bytes, 0)
    }

    @MainActor func testClearingWaitsForInFlightNamingReadsAndCannotRecreateCache() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ServerHistoryCache(directoryURL: directory)
        let names = ServerHistoryNames(cache: cache)
        let requested = expectation(description: "Visit read in flight")
        StopNamesProtocol.handler = { mock in
            switch mock.request.url?.lastPathComponent {
            case "places": mock.respond(pages: 0, object: [])
            case "timeline": mock.respond(object: ["days": []])
            case "visits": requested.fulfill()
            default: XCTFail("Unexpected endpoint")
            }
        }
        names.configure(client: try client(), identity: String(repeating: "a", count: 64), calendar: calendar, after: nil)
        names.request(day...day, source: .phoneNames)
        await fulfillment(of: [requested], timeout: 2)
        for task in names.reset() { await task.value }
        try await cache.clear()
        let bytes = try await cache.storageBytes()
        XCTAssertEqual(bytes, 0)
        XCTAssertEqual(names.snapshot, DawarichStopNames())
    }

    @MainActor func testAnEmptyRefreshedDayCannotInheritAnOldOvernightVisit() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ServerHistoryCache(directoryURL: directory)
        let identity = String(repeating: "a", count: 64), next = day.addingTimeInterval(86_400)
        try await cache.selectSource(identity)
        try await cache.storeStopVisits([visit(end: 2 * 86_400)], on: day)
        try await cache.storeStopVisits([], on: next)
        let names = ServerHistoryNames(cache: cache)
        let loaded = expectation(description: "Both cached days loaded")
        names.changed = {
            if names.snapshot.days.count == 2 { names.changed = nil; loaded.fulfill() }
        }
        StopNamesProtocol.handler = { _ in XCTFail("Offline metadata stays offline") }
        names.configure(client: nil, identity: identity, calendar: calendar, after: nil)
        names.request(day...next, source: .calendar)
        await fulfillment(of: [loaded], timeout: 2)
        let namer = HistoryStopNamer(wifi: [], names: names.snapshot, distance: 300)
        XCTAssertNil(namer.name(at: place().location, from: next, to: next.addingTimeInterval(600)))
        XCTAssertEqual(namer.name(at: place().location, from: day, to: day.addingTimeInterval(600))?.title, "Home")
        for task in names.reset() { await task.value }
        try await cache.clear()
    }

    @MainActor func testVisitOverlapAggregatesAcrossDaysWithoutRestoringRefreshedEmptyDays() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ServerHistoryCache(directoryURL: directory)
        let identity = String(repeating: "a", count: 64), next = day.addingTimeInterval(86_400)
        let overnight = visit(id: 1, start: 86_400 - 1_200, end: 86_400 + 1_200, place: place("Across Midnight", id: 1))
        let evening = visit(id: 2, start: 86_400 - 1_800, end: 86_400 - 300, place: place("Before Midnight", id: 2))
        try await cache.selectSource(identity)
        try await cache.storeStopVisits([overnight, evening], on: day)
        let names = ServerHistoryNames(cache: cache)
        StopNamesProtocol.handler = { _ in XCTFail("Offline metadata stays offline") }
        for empty in [false, true] {
            try await cache.storeStopVisits(empty ? [] : [overnight], on: next)
            let loaded = expectation(description: "Both visit days loaded, second day empty: \(empty)")
            names.changed = {
                if names.snapshot.days.count == 2 { names.changed = nil; loaded.fulfill() }
            }
            names.configure(client: nil, identity: identity, calendar: calendar, after: nil)
            names.request(day...next, source: .calendar)
            await fulfillment(of: [loaded], timeout: 2)
            XCTAssertEqual(names.snapshot.visits.filter { $0.id == overnight.id }.count, empty ? 1 : 2)
            let namer = HistoryStopNamer(wifi: [], names: names.snapshot, distance: 300)
            XCTAssertEqual(namer.name(at: place().location, from: next.addingTimeInterval(-1_800),
                                      to: next.addingTimeInterval(1_800))?.title,
                           empty ? "Before Midnight" : "Across Midnight")
            XCTAssertEqual(namer.name(at: place().location, from: next, to: next.addingTimeInterval(1_800))?.title,
                           empty ? nil : "Across Midnight")
            for task in names.reset() { await task.value }
        }
        try await cache.clear()
    }

    func testPointsPlacesAndVisitsShareTwoInFlightRequests() async throws {
        let started = expectation(description: "Two shared transport requests")
        started.expectedFulfillmentCount = 2
        let entered = expectation(description: "All consumers queued")
        entered.expectedFulfillmentCount = 3
        let count = StopNameCounter()
        StopNamesProtocol.handler = { _ in if count.increment() <= 2 { started.fulfill() } }
        let client = try client(), day = day
        let tasks: [Task<Void, Error>] = [
            Task { entered.fulfill(); _ = try await client.stopPlaces() },
            Task { entered.fulfill(); _ = try await client.stopVisits(from: day, to: day.addingTimeInterval(86_400)) },
            Task { entered.fulfill(); _ = try await client.firstPointDate() }
        ]
        await fulfillment(of: [entered, started], timeout: 2)
        XCTAssertEqual(count.value, 2)
        for task in tasks { task.cancel() }
        for task in tasks {
            do { try await task.value; XCTFail("Expected cancellation") }
            catch { XCTAssertTrue(error is CancellationError) }
        }
    }

    @MainActor func testNamesPublishAfterGestureWithoutMovingNeedleOrReplacingGeometryAndAxis() async throws {
        let points = points(), end = day.addingTimeInterval(700)
        let model = HistoryPlaybackModel(pointLoader: { after, done in done(after == 0 ? points : []) },
            payloadLoader: { _, done in done([:]) }, places: { [] },
            landmarkBuilder: { points, timeline, places, calendar, locale, done in
                done(HistoryLandmarks(points: points, timeline: timeline, places: places, calendar: calendar, locale: locale))
            }, clock: { end }, queueLoader: { $0([]) })
        model.setConsumerActive(true)
        model.beginRulerInteraction()
        model.scrub(rulerPosition: 5.5, liveEdge: end)
        let position = model.rulerPosition, time = model.rulerTime, pose = model.renderPose, index = model.selectedIndex
        let geometry = model.routeGeometry, axis = model.landmarks.rulerAxis, step = model.rulerStep
        let revision = model.rulerInteractionRevision
        await withCheckedContinuation { continuation in
            model.applyStopNames(.init(places: [place("Office")], visits: [visit()])) { continuation.resume() }
        }
        XCTAssertNil(model.landmarks.stops.first?.name)
        XCTAssertEqual(model.rulerPosition, position)
        model.endRulerInteraction(cancelled: false)
        XCTAssertEqual(model.landmarks.stops.first?.name, "Office")
        XCTAssertEqual(model.landmarks.journey.first?.rows.first?.title, "Office")
        XCTAssertEqual(model.replayStatus?.title, "Office")
        XCTAssertEqual(model.replayStatus?.symbol, "building.2.fill")
        XCTAssertEqual(model.rulerPosition, position)
        XCTAssertEqual(model.rulerTime, time)
        XCTAssertEqual(model.renderPose, pose)
        XCTAssertEqual(model.selectedIndex, index)
        XCTAssertEqual(model.rulerStep, step)
        XCTAssertEqual(model.rulerInteractionRevision, revision)
        XCTAssertTrue(model.routeGeometry === geometry)
        XCTAssertTrue(model.landmarks.rulerAxis === axis)
        model.setConsumerActive(false)
    }
}

private final class StopNamesProtocol: URLProtocol {
    static var handler: ((StopNamesProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard request.url?.host == "wherewolf.test" else { XCTFail("Only mocked requests are allowed"); return }
        Self.handler?(self)
    }
    override func stopLoading() { }
    var query: [String: String] {
        Dictionary(uniqueKeysWithValues: (URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
    }
    func respond(status: Int = 200, pages: Int? = 1, object: Any) {
        let headers = pages.map { ["X-Current-Page": query["page"] ?? "1", "X-Total-Pages": String($0)] }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: object))
        client?.urlProtocolDidFinishLoading(self)
    }
}

private final class StopNameCounter {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    @discardableResult func increment() -> Int { lock.withLock { count += 1; return count } }
}
