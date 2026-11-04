import Foundation
import CoreLocation
import UIKit

struct SettingsImport {
    struct Change: Identifiable {
        let id: String
        let title: String
        let before: String
        let after: String
    }
    let values: [String: Any]
    let changes: [Change]
    let newerSchema: Bool
    let ignoredKeys: [String]
    var includesCredentials: Bool { !SettingsSchema.secrets.isDisjoint(with: values.keys) }
}

enum SettingsBackupError: LocalizedError {
    case invalid(String), activeTrip, credentialStorage
    var errorDescription: String? {
        switch self {
        case .invalid(let key): return "Invalid settings value: \(SettingsSchema.title(key)). No settings were changed."
        case .activeTrip: return "Finish the current trip before importing settings."
        case .credentialStorage: return "The Keychain could not save the server credential. Unlock this iPhone and try again."
        }
    }
}

// This allowlist is also the boundary for iCloud. Runtime state never enters a backup.
enum SettingsSchema {
    static let version = 2
    static let secrets: Set<String> = ["serverURL", "serverToken", "customHTTPHeaders"]
    static let deviceOnly: Set<String> = ["deviceId"]
    static let managerBools = ["pausesAutomatically", "useNewLocationEngine", "visitTrackingEnabled",
        "includeTrackingStats", "notificationsEnabled", "problemNotificationsOnly", "showBackgroundLocationIndicator",
        "showBackgroundLocationIndicatorDuringTrip", "pausesAutomaticallyDuringTrip", "discardPointsWithoutGPS",
        "discardPointsWithoutGPSDuringTrip", "discardPointsWhileStationary", "discardPointsWhileStationaryDuringTrip",
        "tripLiveActivityEnabled", "savesToICloudDrive"]
    static let managerNumbers: [String: ClosedRange<Double>] = [
        "trackingMode": 0...3, "loggingMode": 0...2, "loggingModeDuringTrip": 0...2,
        "desiredAccuracy": -2...3000, "desiredAccuracyDuringTrip": -2...3000,
        "activityType": 1...6, "activityTypeDuringTrip": 1...6, "cloudFileMode": 0...1,
        "pointsPerBatch": 1...1000, "pointsPerBatchDuringTrip": 1...1000,
        "sendingInterval": -1...3600, "resumesAfterDistance": -1...2000,
        "discardPointsWithinDistance": -1...1000, "discardPointsWithinDistanceDuringTrip": -1...1000,
        "discardPointsOutsideAccuracy": -1...5000, "discardPointsWithinSeconds": 0...600,
        "discardPointsWithinSecondsDuringTrip": 0...600, "stopsAutomaticallyRadius": -1...1000,
        "stopsAutomaticallyAfterSeconds": 1...3600]
    static let preferences: [String: String] = [
        "liveActivity": "WhereWolfLiveActivityEnabled", "liveActivityAppearance": "WhereWolfLiveActivityAppearance",
        "lockScreenCard": "LiveActivityLockScreenCard", "hideWhileAudioPlays": "WhereWolfLiveActivityHideWhileAudioPlays",
        "askToReopenAfterAudio": "WhereWolfLiveActivityAskToReopenAfterAudio", "silentAudio": "WhereWolfSilentAudioEnabled",
        "tripAskToEndWhenStopped": GLTripAskToEndWhenStoppedDefaultsName, "screenLock": GLScreenLockEnabledDefaultsName,
        "uniqueId": GLIncludeUniqueIdDefaultsName, "acceptHTTP": GLConsiderHTTP200SuccessDefaultsName,
        "healthExport": "HealthTripRecorderEnabled", "workoutImportAutomatic": "WorkoutImportAutomatic"]
    static var managerKeys: Set<String> { Set(managerBools).union(managerNumbers.keys) }
    static var keys: Set<String> {
        managerKeys.union(preferences.keys).union(secrets).union(deviceOnly)
            .union(["historyRetentionHours", "wifiPlaces", "tripModes", "advancedTracking", "sendOnlyOnWifi", "workoutImportDays"])
    }
    static var syncKeys: Set<String> { keys.subtracting(secrets).subtracting(deviceOnly) }
    static let labels = ["serverURL": "Server URL", "serverToken": "Server Token", "customHTTPHeaders": "Custom HTTP Headers",
        "wifiPlaces": "Wi-Fi Places", "tripModes": "Trip Modes", "historyRetentionHours": "History Retention",
        "advancedTracking": "Advanced Tracking", "acceptHTTP": "Accept Any Successful HTTP Response",
        "deviceId": "Device ID", "sendOnlyOnWifi": "Send Only on Wi-Fi"]
    static func title(_ key: String) -> String {
        if let label = labels[key] { return label }
        let spaced = key.replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "([a-z])([A-Z])", with: "$1 $2", options: .regularExpression)
        return spaced.prefix(1).uppercased() + spaced.dropFirst()
    }
    static func equal(_ a: Any?, _ b: Any?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        return (a as? NSObject)?.isEqual(b) == true
    }
    static func describe(_ value: Any?, key: String) -> String {
        guard let value else { return "Not set" }
        if secrets.contains(key) { return "Hidden" }
        if let array = value as? [Any] { return "\(array.count) entries" }
        if let dict = value as? [String: Any] { return "\(dict.count) options" }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue ? "On" : "Off" }
            return number.stringValue
        }
        return String(describing: value)
    }
    static func validHeaders(_ input: [String: Any]) -> [String: String]? {
        let allowed = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ")
        var result: [String: String] = [:]
        var names = Set<String>()
        for (key, raw) in input {
            guard let value = raw as? String, !key.isEmpty, key.count <= 256, value.utf8.count <= 8192,
                  key.unicodeScalars.allSatisfy(allowed.contains),
                  !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
                  !["host", "content-length", "connection", "transfer-encoding", "authorization"].contains(key.lowercased()),
                  names.insert(key.lowercased()).inserted else { return nil }
            result[key] = value
        }
        return result
    }
    static func validate(_ input: [String: Any]) throws -> [String: Any] {
        var values = input
        if let legacy = values.removeValue(forKey: "wifiZones") {
            guard let zones = legacy as? [[String: Any]],
                  let places = GLManager.places(fromLegacyWifiZones: zones) else { throw SettingsBackupError.invalid("wifiPlaces") }
            if values["wifiPlaces"] == nil { values["wifiPlaces"] = places }
        }
        var result: [String: Any] = [:]
        for (key, value) in values where keys.contains(key) {
            func require(_ valid: Bool) throws { if !valid { throw SettingsBackupError.invalid(key) } }
            if managerBools.contains(key) || (preferences[key] != nil && key != "liveActivityAppearance") || key == "sendOnlyOnWifi" {
                guard let number = value as? NSNumber else { throw SettingsBackupError.invalid(key) }
                try require(number.doubleValue == 0 || number.doubleValue == 1)
                result[key] = number.boolValue
            } else if let range = managerNumbers[key] {
                guard let number = value as? NSNumber else { throw SettingsBackupError.invalid(key) }
                let n = number.doubleValue
                try require(CFGetTypeID(number) != CFBooleanGetTypeID() && n.isFinite && range.contains(n) && n.rounded() == n)
                if key.hasPrefix("desiredAccuracy") { try require(n == -2 || n == -1 || n >= 5) }
                if key.hasPrefix("activityType") { try require(GLManagerBridge.activityTypes.contains { Double($0.rawValue) == n }) }
                result[key] = number
            } else {
                switch key {
                case "serverURL":
                    guard let text = value as? String else { throw SettingsBackupError.invalid(key) }
                    try require(text.isEmpty || (text.utf8.count <= 8192 && GLManager.isValidEndpoint(text)))
                    result[key] = text
                case "serverToken", "deviceId":
                    guard let text = value as? String else { throw SettingsBackupError.invalid(key) }
                    try require(text.utf8.count <= 8192 && !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains))
                    result[key] = text
                case "liveActivityAppearance":
                    guard let text = value as? String else { throw SettingsBackupError.invalid(key) }
                    try require(["blank", "minimal", "status"].contains(text)); result[key] = text
                case "historyRetentionHours", "workoutImportDays":
                    guard let n = value as? NSNumber else { throw SettingsBackupError.invalid(key) }
                    let range = key == "historyRetentionHours" ? 24...168 : 1...30
                    try require(CFGetTypeID(n) != CFBooleanGetTypeID() && n.doubleValue.isFinite && n.doubleValue.rounded() == n.doubleValue && range.contains(n.intValue))
                    if key == "workoutImportDays" { try require([1, 7, 30].contains(n.intValue)) }
                    result[key] = n
                case "customHTTPHeaders":
                    guard let dict = value as? [String: Any], let valid = validHeaders(dict) else { throw SettingsBackupError.invalid(key) }
                    result[key] = valid
                case "wifiPlaces":
                    guard let places = value as? [[String: Any]], let valid = GLManager.validatedWifiPlaces(places) else { throw SettingsBackupError.invalid(key) }
                    result[key] = valid
                case "tripModes":
                    guard let entries = value as? [[String: Any]] else { throw SettingsBackupError.invalid(key) }
                    let data = try JSONSerialization.data(withJSONObject: entries)
                    guard data.count <= 200_000, let modes = try? JSONDecoder().decode([TripMode].self, from: data), modes.count <= 256,
                          let valid = TripModeStore.normalized(modes) else { throw SettingsBackupError.invalid(key) }
                    result[key] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(valid))
                case "advancedTracking":
                    guard let input = value as? [String: Any] else { throw SettingsBackupError.invalid(key) }
                    let defaults = GLManager.normalizedTrackingOptions([:]) as? [String: NSNumber] ?? [:]
                    var known: [String: NSNumber] = [:]
                    for (name, raw) in input where defaults[name] != nil {
                        guard let n = raw as? NSNumber, n.doubleValue.isFinite else { throw SettingsBackupError.invalid(key) }
                        known[name] = n
                    }
                    let normalized = GLManager.normalizedTrackingOptions(known) as? [String: NSNumber] ?? [:]
                    for (name, n) in known { try require(normalized[name]?.doubleValue == n.doubleValue) }
                    result[key] = normalized
                default: break
                }
            }
        }
        return result
    }
}

enum SettingsBackup {
    static func encode(_ values: [String: Any], credentials: Bool, appVersion: String) throws -> Data {
        var values = try SettingsSchema.validate(values)
        if !credentials { for key in SettingsSchema.secrets { values.removeValue(forKey: key) } }
        return try JSONSerialization.data(withJSONObject: ["schemaVersion": SettingsSchema.version,
            "appVersion": appVersion, "settings": values], options: [.prettyPrinted, .sortedKeys])
    }
    static func preview(_ data: Data, current: [String: Any]) throws -> SettingsImport {
        guard data.count <= 1_000_000,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let schema = object["schemaVersion"] as? NSNumber, CFGetTypeID(schema) != CFBooleanGetTypeID(),
              schema.doubleValue.isFinite, schema.doubleValue.rounded() == schema.doubleValue, (1...1_000_000).contains(schema.intValue),
              let input = object["settings"] as? [String: Any] else { throw SettingsBackupError.invalid("file") }
        let values = try SettingsSchema.validate(input)
        var changes: [SettingsImport.Change] = []
        for key in values.keys.sorted() where !SettingsSchema.equal(current[key], values[key]) {
            if key == "advancedTracking", let options = values[key] as? [String: Any] {
                let previous = current[key] as? [String: Any] ?? [:]
                for name in options.keys.sorted() where !SettingsSchema.equal(previous[name], options[name]) {
                    changes.append(SettingsImport.Change(id: key + "." + name, title: "Advanced: " + SettingsSchema.title(name),
                        before: SettingsSchema.describe(previous[name], key: name), after: SettingsSchema.describe(options[name], key: name)))
                }
            } else {
                changes.append(SettingsImport.Change(id: key, title: SettingsSchema.title(key),
                    before: SettingsSchema.describe(current[key], key: key), after: SettingsSchema.describe(values[key], key: key)))
            }
        }
        return SettingsImport(values: values, changes: changes, newerSchema: schema.intValue > SettingsSchema.version,
            ignoredKeys: input.keys.filter { !SettingsSchema.keys.contains($0) && $0 != "wifiZones" }.sorted())
    }
}

extension GLManagerBridge {
    @MainActor func settingsSnapshot() -> [String: Any] {
        let gl = GLManager.shared()!
        let defaults = UserDefaults.standard
        var result: [String: Any] = [:]
        for key in SettingsSchema.managerKeys { result[key] = gl.value(forKey: key) }
        for (key, preference) in SettingsSchema.preferences {
            result[key] = key == "liveActivityAppearance" ? (defaults.string(forKey: preference) ?? "blank") : defaults.bool(forKey: preference) as Any
        }
        result["serverURL"] = gl.apiEndpointURL() ?? ""
        result["serverToken"] = gl.apiAccessToken() ?? ""
        result["deviceId"] = gl.deviceId() ?? ""
        result["customHTTPHeaders"] = gl.customHTTPHeaders ?? [:]
        result["wifiPlaces"] = gl.wifiPlaces ?? []
        result["tripModes"] = (try? JSONSerialization.jsonObject(with: JSONEncoder().encode(TripModeStore.modes))) ?? []
        result["advancedTracking"] = gl.advancedTrackingOptions
        result["sendOnlyOnWifi"] = sendOnlyOnWifi
        result["historyRetentionHours"] = HistoryRetention.hours
        result["workoutImportDays"] = workoutImporter.days
        return result
    }

    @MainActor func applySettings(_ input: [String: Any]) throws {
        let values = try SettingsSchema.validate(input)
        let gl = GLManager.shared()!
        guard !gl.tripInProgress() else { throw SettingsBackupError.activeTrip }
        if values["serverURL"] != nil || values["serverToken"] != nil {
            guard GLServerCredentials.saveEndpoint(values["serverURL"] as? String ?? gl.apiEndpointURL() ?? "",
                token: values["serverToken"] as? String ?? gl.apiAccessToken() ?? "") else { throw SettingsBackupError.credentialStorage }
        }
        gl.performSettingsBatch {
            for key in SettingsSchema.managerKeys.sorted() {
                if let value = values[key] { gl.setValue(value, forKey: key) }
            }
            for (key, preference) in SettingsSchema.preferences {
                if let value = values[key] { UserDefaults.standard.set(value, forKey: preference) }
            }
            if values["serverURL"] != nil || values["serverToken"] != nil { gl.reloadServerCredentials() }
            if let headers = values["customHTTPHeaders"] as? [String: String] { gl.customHTTPHeaders = headers }
            if let id = values["deviceId"] as? String { gl.saveNewDeviceId(id) }
            if let zones = values["wifiPlaces"] as? [[String: Any]] { gl.replaceWifiPlaces(zones) }
            if let options = values["advancedTracking"] as? [String: NSNumber] { gl.advancedTrackingOptions = options }
            if let hours = values["historyRetentionHours"] as? Int { self.historyRetentionHours = Double(hours) }
            if let enabled = values["sendOnlyOnWifi"] as? Bool { self.sendOnlyOnWifi = enabled }
            if let days = values["workoutImportDays"] as? Int { self.setWorkoutImportDays(days) }
            if let enabled = values["workoutImportAutomatic"] as? Bool { self.setAutomaticWorkoutImport(enabled) }
            if let modes = values["tripModes"], let data = try? JSONSerialization.data(withJSONObject: modes),
               let decoded = try? JSONDecoder().decode([TripMode].self, from: data) { _ = self.saveTripModes(decoded) }
        }
        UIApplication.shared.isIdleTimerDisabled = false
        refresh()
    }
}
