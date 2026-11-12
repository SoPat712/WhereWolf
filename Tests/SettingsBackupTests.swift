import XCTest
@testable import WhereWolf

private final class TestSettingsCloud: SettingsCloudStore {
    var values: [String: Any] = [:]
    var writes: [String] = []
    func set(_ value: Any, forKey key: String) { values[key] = value; writes.append(key) }
    func synchronize() -> Bool { true }
}

final class SettingsBackupTests: XCTestCase {
    func testTripLockScreenMapDefaultsOnAndBackupRoundTripsBothChoices() throws {
        let suite = "WhereWolf.TripMap.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        XCTAssertTrue(TripActivityMapSettings.showsOnLockScreen(defaults: defaults))
        XCTAssertEqual(SettingsSchema.preferences["tripMapOnLockScreen"], TripActivityMapSettings.lockScreenKey)
        XCTAssertTrue(SettingsSchema.syncKeys.contains("tripMapOnLockScreen"))
        for enabled in [false, true] {
            defaults.set(enabled, forKey: TripActivityMapSettings.lockScreenKey)
            XCTAssertEqual(TripActivityMapSettings.showsOnLockScreen(defaults: defaults), enabled)
            let data = try SettingsBackup.encode(["tripMapOnLockScreen": enabled], credentials: false, appVersion: "1")
            let preview = try SettingsBackup.preview(data, current: [:])
            XCTAssertEqual(preview.values["tripMapOnLockScreen"] as? Bool, enabled)
            XCTAssertEqual(preview.changes.first?.title, "Map on Lock Screen")
        }
    }

    private func fixture() throws -> [String: Any] {
        ["desiredAccuracy": -1, "sendingInterval": 60, "pointsPerBatch": 200, "notificationsEnabled": true,
         "historyRetentionHours": 168, "serverURL": "https://wherewolf.test/api", "serverToken": "secret",
         "customHTTPHeaders": ["X-API-Key": "other-secret"], "deviceId": "Phone",
         "wifiPlaces": [WifiPlace(id: "B34764B9-0F12-44EE-AC47-F2F956E72714", name: "Home", latitude: 45.5, longitude: -122.6, networks: ["Home"]).dictionary],
         "tripModes": try JSONSerialization.jsonObject(with: JSONEncoder().encode(TripMode.defaults))]
    }
    func testBackupRoundTripWithCredentials() throws {
        let input = try fixture()
        let data = try SettingsBackup.encode(input, credentials: true, appVersion: "1.2")
        let decoded = try SettingsBackup.preview(data, current: [:])
        XCTAssertTrue(decoded.includesCredentials)
        XCTAssertTrue(SettingsSchema.equal(decoded.values, try SettingsSchema.validate(input)))
        let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(envelope["schemaVersion"] as? Int, SettingsSchema.version)
        XCTAssertEqual(envelope["appVersion"] as? String, "1.2")
    }
    func testLegacyWifiZonesBackupImportConvertsToPlaces() throws {
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "settings": [
            "wifiZones": [
                ["name": "Home", "latitude": "45.5", "longitude": "-122.6", "bssid": "one"],
                ["name": "Home 5G", "latitude": "45.5", "longitude": "-122.6", "bssid": "two"],
                ["name": "Home", "latitude": "45.5", "longitude": "-122.6", "bssid": "three"]]]])
        let preview = try SettingsBackup.preview(data, current: [:])
        let places = try XCTUnwrap(preview.values["wifiPlaces"] as? [[String: Any]])
        XCTAssertEqual(places.count, 1)
        XCTAssertEqual(places[0]["networks"] as? [String], ["Home", "Home 5G"])
        XCTAssertNil(places[0]["bssid"])
        XCTAssertNil(places[0]["radius"])
        XCTAssertNil(preview.values["wifiZones"])
        XCTAssertTrue(preview.ignoredKeys.isEmpty)
        XCTAssertEqual(preview.changes.first?.title, "Wi-Fi Places")
        XCTAssertTrue(SettingsSchema.syncKeys.contains("wifiPlaces"))
        XCTAssertFalse(SettingsSchema.syncKeys.contains("wifiZones"))
        let newData = try SettingsBackup.encode(preview.values, credentials: false, appVersion: "1")
        XCTAssertTrue(SettingsSchema.equal(try SettingsBackup.preview(newData, current: [:]).values, preview.values))
    }
    func testWifiPlaceBackupIgnoresLegacyRadiusAndExportsPointsOnly() throws {
        let place = WifiPlace(name: "Home", latitude: 45.5, longitude: -122.6, networks: ["Home"]).dictionary
        var legacy = place
        legacy["radius"] = 25
        let input: [String: Any] = ["wifiPlaces": [legacy]]
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 1, "settings": input])
        let preview = try SettingsBackup.preview(data, current: [:])
        let imported = try XCTUnwrap(preview.values["wifiPlaces"] as? [[String: Any]])
        XCTAssertTrue(SettingsSchema.equal(imported, [place]))
        XCTAssertNil(imported[0]["radius"])
        for values in [input, preview.values] {
            let exported = try SettingsBackup.encode(values, credentials: false, appVersion: "1")
            let envelope = try XCTUnwrap(JSONSerialization.jsonObject(with: exported) as? [String: Any])
            let settings = try XCTUnwrap(envelope["settings"] as? [String: Any])
            let places = try XCTUnwrap(settings["wifiPlaces"] as? [[String: Any]])
            XCTAssertTrue(SettingsSchema.equal(places, [place]))
            XCTAssertNil(places[0]["radius"])
        }
    }
    func testBackupWithoutCredentialsOmitsHeadersToo() throws {
        let data = try SettingsBackup.encode(fixture(), credentials: false, appVersion: "1")
        let preview = try SettingsBackup.preview(data, current: [:])
        XCTAssertFalse(preview.includesCredentials)
        for key in SettingsSchema.secrets { XCTAssertNil(preview.values[key]) }
        XCTAssertNotNil(preview.values["deviceId"])
        XCTAssertNotNil(preview.values["wifiPlaces"])
    }
    func testRejectsInvalidValuesBeforeAnyApply() {
        let invalid: [[String: Any]] = [
            ["serverURL": "ftp://bad.test"], ["serverToken": "line\nbreak"], ["desiredAccuracy": 0],
            ["pointsPerBatch": 0], ["notificationsEnabled": 2], ["historyRetentionHours": 169],
            ["historyRetentionHours": true], ["sendingInterval": 0.5], ["activityType": 70],
            ["customHTTPHeaders": ["Authorization": "x"]], ["customHTTPHeaders": ["X-Test": "a\rb"]],
            ["wifiZones": [["name": "Home", "latitude": "91", "longitude": "0"]]],
            ["tripModes": []], ["tripModes": "invalid"], ["advancedTracking": ["location_retry_after": 5]], ["workoutImportDays": 2]
        ]
        for input in invalid { XCTAssertThrowsError(try SettingsSchema.validate(input), "\(input.keys)") }
    }
    func testSummaryContainsOnlyChangedKnownSettingsAndRedactsCredentials() throws {
        let data = try JSONSerialization.data(withJSONObject: ["schemaVersion": 5, "settings": [
            "serverToken": "secret", "pointsPerBatch": 100, "historyRetentionHours": 24, "futureSetting": 1]])
        let preview = try SettingsBackup.preview(data, current: ["pointsPerBatch": 100, "historyRetentionHours": 48])
        XCTAssertEqual(Set(preview.changes.map(\.id)), ["historyRetentionHours", "serverToken"])
        XCTAssertTrue(preview.newerSchema)
        XCTAssertEqual(preview.ignoredKeys, ["futureSetting"])
        XCTAssertEqual(preview.changes.first { $0.id == "serverToken" }?.after, "Hidden")
        XCTAssertEqual(preview.changes.first { $0.id == "historyRetentionHours" }?.before, "48")
    }
    func testDeviceStateNeverEntersBackups() throws {
        let state: [String: Any] = [GLTrackingStateDefaultsName: true, GLTripStartTimeDefaultsName: 123,
            "LiveActivityID": "id", "HistoryArchivePath": "/private/route", "WorkoutImportReadRequested": true,
            "authorization": "always", "queue": [1, 2], "WifiKnownNetworks": [["name": "Private"]],
            "observedWifiNetworks": [["name": "Private"]], "pointsPerBatch": 100]
        let preview = try SettingsBackup.preview(SettingsBackup.encode(state, credentials: true, appVersion: "1"), current: [:])
        XCTAssertEqual(Set(preview.values.keys), ["pointsPerBatch"])
    }
    @MainActor func testSyncIsOffByDefaultAndDoesNotReadOrWriteCloud() throws {
        let suite = "WhereWolf.Backup.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = TestSettingsCloud(), secrets = MemorySettingsCredentialStore()
        var applied = false
        let sync = SettingsSync(defaults: defaults, cloud: cloud, secrets: secrets,
            snapshot: { ["pointsPerBatch": 100] }, apply: { _ in applied = true })
        sync.synchronize()
        XCTAssertFalse(sync.enabled); XCTAssertFalse(applied); XCTAssertTrue(cloud.writes.isEmpty); XCTAssertNil(secrets.cloud)
        let unavailable = SettingsSync(defaults: defaults, cloud: cloud, secrets: secrets,
            snapshot: { [:] }, apply: { _ in XCTFail("Unsupported build must stay local") }, supported: false)
        unavailable.setEnabled(true)
        XCTAssertFalse(unavailable.enabled); XCTAssertFalse(unavailable.available); XCTAssertTrue(cloud.writes.isEmpty)
    }
    @MainActor func testWifiPlacesSyncIgnoresLegacyRadiusAndWritesPointsOnly() throws {
        let suite = "WhereWolf.Backup.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = TestSettingsCloud(), secrets = MemorySettingsCredentialStore()
        let place = WifiPlace(name: "Home", latitude: 45.5, longitude: -122.6, networks: ["Home"]).dictionary
        var legacy = place
        legacy["radius"] = 2000
        var settings: [String: Any] = ["wifiPlaces": []]
        let sync = SettingsSync(defaults: defaults, cloud: cloud, secrets: secrets,
            snapshot: { settings }, apply: { settings.merge($0) { _, new in new } },
            clock: { Date(timeIntervalSince1970: 100) })
        sync.observeLocalChanges(initial: true)
        cloud.values[SettingsSync.prefix + "wifiPlaces"] = SettingsSyncRecord(value: [legacy], modified: 50, writer: "remote").dictionary
        sync.setEnabled(true)
        XCTAssertTrue(SettingsSchema.equal(settings["wifiPlaces"], [place]))
        let records = try XCTUnwrap(defaults.dictionary(forKey: SettingsSync.recordsKey))
        let accepted = try XCTUnwrap(SettingsSyncRecord(try XCTUnwrap(records["wifiPlaces"])))
        XCTAssertTrue(SettingsSchema.equal(accepted.value, [place]))
        XCTAssertEqual(accepted.modified, 50)
        legacy["name"] = "House"
        settings["wifiPlaces"] = [legacy]
        sync.synchronize()
        let exported = try XCTUnwrap(SettingsSyncRecord(try XCTUnwrap(cloud.values[SettingsSync.prefix + "wifiPlaces"])))
        let places = try XCTUnwrap(exported.value as? [[String: Any]])
        XCTAssertEqual(places[0]["name"] as? String, "House")
        XCTAssertNil(places[0]["radius"])
        XCTAssertEqual(exported.modified, 100)
    }
    @MainActor func testSyncMergesPerKeyAndExcludesSecretsAndDeviceState() throws {
        let suite = "WhereWolf.Backup.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = TestSettingsCloud(), secrets = MemorySettingsCredentialStore()
        var settings = try fixture()
        settings["queue"] = [1]; settings["LiveActivityID"] = "private"; settings["permissions"] = "always"
        var applied: [String: Any] = [:]
        let sync = SettingsSync(defaults: defaults, cloud: cloud, secrets: secrets,
            snapshot: { settings }, apply: { values in applied = values; settings.merge(values) { _, new in new } },
            clock: { Date(timeIntervalSince1970: 100) })
        sync.observeLocalChanges(initial: true)
        cloud.values[SettingsSync.prefix + "pointsPerBatch"] = SettingsSyncRecord(value: 500, modified: 50, writer: "remote").dictionary
        cloud.values[SettingsSync.prefix + "serverToken"] = SettingsSyncRecord(value: "malicious", modified: 900, writer: "remote").dictionary
        sync.setEnabled(true)
        XCTAssertEqual(applied["pointsPerBatch"] as? Int, 500)
        XCTAssertNil(applied["serverToken"])
        XCTAssertEqual(settings["sendingInterval"] as? Int, 60)
        for key in SettingsSchema.secrets.union(SettingsSchema.deviceOnly).union(["queue", "LiveActivityID", "permissions"]) {
            XCTAssertFalse(cloud.writes.contains(SettingsSync.prefix + key))
        }
        let secure = try XCTUnwrap(secrets.cloud)
        let secured = try XCTUnwrap(JSONSerialization.jsonObject(with: secure) as? [String: Any])
        XCTAssertNotNil(secured["serverURL"]); XCTAssertNotNil(secured["serverToken"])
        let metadata = try JSONSerialization.data(withJSONObject: defaults.dictionary(forKey: SettingsSync.recordsKey) ?? [:])
        XCTAssertFalse(String(decoding: metadata, as: UTF8.self).contains("other-secret"))
        settings["pointsPerBatch"] = 200
        sync.synchronize()
        let updated = SettingsSyncRecord(try XCTUnwrap(cloud.values[SettingsSync.prefix + "pointsPerBatch"]))
        XCTAssertEqual(updated?.modified, 100)
        XCTAssertEqual(updated?.value as? Int, 200)
    }
    @MainActor func testSyncDefersDuringTripAndAppliesEncryptedCredentialThroughBatch() throws {
        let suite = "WhereWolf.Backup.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = TestSettingsCloud(), secrets = MemorySettingsCredentialStore()
        secrets.cloud = try JSONSerialization.data(withJSONObject: ["serverToken": SettingsSyncRecord(value: "remote-token", modified: 100, writer: "peer").dictionary])
        var trip = true
        var applied: [String: Any] = [:]
        var settings: [String: Any] = ["serverToken": "local"]
        let sync = SettingsSync(defaults: defaults, cloud: cloud, secrets: secrets,
            snapshot: { settings }, apply: { values in applied = values; settings.merge(values) { _, new in new } }, canApply: { !trip })
        sync.observeLocalChanges(initial: true); sync.setEnabled(true)
        XCTAssertTrue(applied.isEmpty)
        trip = false; sync.synchronize()
        XCTAssertEqual(applied["serverToken"] as? String, "remote-token")
        XCTAssertTrue(cloud.writes.isEmpty)
    }
    @MainActor func testAdvancedOptionsMergeIndependentlyAndTurningOffStopsCloudWrites() {
        let suite = "WhereWolf.Backup.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = TestSettingsCloud(), secrets = MemorySettingsCredentialStore()
        var options: [String: Any] = ["adaptive": false, "background_recovery": false]
        let sync = SettingsSync(defaults: defaults, cloud: cloud, secrets: secrets,
            snapshot: { ["advancedTracking": options] }, apply: { values in options = values["advancedTracking"] as? [String: Any] ?? [:] },
            clock: { Date(timeIntervalSince1970: 100) })
        sync.observeLocalChanges(initial: true)
        options["background_recovery"] = true
        sync.observeLocalChanges()
        cloud.values[SettingsSync.prefix + "advancedTracking.adaptive"] = SettingsSyncRecord(value: true, modified: 50, writer: "peer").dictionary
        cloud.values[SettingsSync.prefix + "advancedTracking.background_recovery"] = SettingsSyncRecord(value: false, modified: 50, writer: "peer").dictionary
        sync.setEnabled(true)
        XCTAssertEqual(options["adaptive"] as? Bool, true)
        XCTAssertEqual(options["background_recovery"] as? Bool, true)
        let writes = cloud.writes.count
        sync.setEnabled(false)
        options["adaptive"] = false
        sync.synchronize()
        XCTAssertEqual(cloud.writes.count, writes)
    }
    @MainActor func testCurrentSnapshotContainsEveryPortableSettingAndRoundTrips() throws {
        let snapshot = GLManagerBridge.shared.settingsSnapshot()
        XCTAssertEqual(Set(snapshot.keys), SettingsSchema.keys)
        let result = try SettingsBackup.preview(SettingsBackup.encode(snapshot, credentials: true, appVersion: "test"), current: snapshot)
        XCTAssertTrue(result.changes.isEmpty)
        XCTAssertEqual(Set(result.values.keys), SettingsSchema.keys)
    }
    @MainActor func testApplyKeepsTrackingSwitchAndRefusesToChangeActiveTrip() throws {
        let defaults = UserDefaults.standard
        let domain = Bundle.main.bundleIdentifier!
        let saved = defaults.persistentDomain(forName: domain) ?? [:]
        let store = GLServerCredentials.store
        GLServerCredentials.store = MemorySettingsCredentialStore()
        defer { GLServerCredentials.store = store; defaults.setPersistentDomain(saved, forName: domain) }
        let manager = GLManager.shared()!
        let tracking = manager.trackingEnabled
        defaults.removeObject(forKey: GLTripStartTimeDefaultsName)
        let data = try SettingsBackup.encode(["pointsPerBatch": 123, "notificationsEnabled": false,
            "serverURL": "https://wherewolf.test/restored", "serverToken": "imported"], credentials: true, appVersion: "test")
        let preview = try SettingsBackup.preview(data, current: GLManagerBridge.shared.settingsSnapshot())
        try GLManagerBridge.shared.applySettings(preview.values)
        XCTAssertEqual(manager.apiEndpointURL(), "https://wherewolf.test/restored")
        XCTAssertEqual(GLServerCredentials.token(), "imported")
        let without = try SettingsBackup.encode(["serverURL": "https://wherewolf.test/omit", "serverToken": "omit", "pointsPerBatch": 123], credentials: false, appVersion: "test")
        try GLManagerBridge.shared.applySettings(SettingsBackup.preview(without, current: GLManagerBridge.shared.settingsSnapshot()).values)
        XCTAssertEqual(GLServerCredentials.token(), "imported")
        XCTAssertEqual(manager.apiEndpointURL(), "https://wherewolf.test/restored")
        XCTAssertEqual(manager.pointsPerBatch, 123)
        XCTAssertEqual(manager.trackingEnabled, tracking)
        let start = Date(timeIntervalSince1970: 1000)
        defaults.set(start, forKey: GLTripStartTimeDefaultsName)
        XCTAssertThrowsError(try GLManagerBridge.shared.applySettings(["pointsPerBatch": 456, "serverToken": "replacement"]))
        XCTAssertEqual(manager.currentTripStart(), start)
        XCTAssertEqual(manager.pointsPerBatch, 123)
        XCTAssertEqual(GLServerCredentials.token(), "imported")
    }
    @MainActor func testInvalidCloudBatchCannotPartiallyApply() {
        let suite = "WhereWolf.Backup.\(UUID())"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let cloud = TestSettingsCloud(), secrets = MemorySettingsCredentialStore()
        cloud.values[SettingsSync.prefix + "pointsPerBatch"] = SettingsSyncRecord(value: 500, modified: 50, writer: "peer").dictionary
        cloud.values[SettingsSync.prefix + "historyRetentionHours"] = SettingsSyncRecord(value: 999, modified: 50, writer: "peer").dictionary
        var applied = false
        let sync = SettingsSync(defaults: defaults, cloud: cloud, secrets: secrets,
            snapshot: { ["pointsPerBatch": 100, "historyRetentionHours": 24] }, apply: { _ in applied = true })
        sync.observeLocalChanges(initial: true); sync.setEnabled(true)
        XCTAssertFalse(applied); XCTAssertTrue(cloud.writes.isEmpty)
        XCTAssertTrue(sync.status.contains("Couldn’t sync"))
    }
    func testMergeTieUsesWriterAndRejectsMalformedRecord() {
        let a = SettingsSyncRecord(value: 1, modified: 5, writer: "a")
        let b = SettingsSyncRecord(value: 2, modified: 5, writer: "b")
        XCTAssertTrue(b.isNewer(than: a)); XCTAssertFalse(a.isNewer(than: b)); XCTAssertFalse(b.isNewer(than: b))
        XCTAssertNil(SettingsSyncRecord(["value": 1, "modified": Double.nan, "writer": "b", "schema": 1]))
    }
}
