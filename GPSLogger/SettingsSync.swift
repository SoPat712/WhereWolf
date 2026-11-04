import Foundation
import Security
import SwiftUI
import UIKit

protocol SettingsCredentialStore: AnyObject {
    func read(synchronizable: Bool) throws -> Data?
    func write(_ data: Data, synchronizable: Bool) throws
}

final class KeychainSettingsStore: SettingsCredentialStore {
    private var service: String { (Bundle.main.bundleIdentifier ?? "me.joshpatra.WhereWolf") + ".settings" }
    private func query(_ sync: Bool) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: sync ? "synced-settings" : "local-server",
         kSecAttrSynchronizable as String: sync]
    }
    func read(synchronizable: Bool) throws -> Data? {
        var query = query(synchronizable)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
        return result as? Data
    }
    func write(_ data: Data, synchronizable: Bool) throws {
        let query = query(synchronizable)
        var attributes: [String: Any] = [kSecValueData as String: data]
        let updated = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if updated == errSecSuccess { return }
        guard updated == errSecItemNotFound else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(updated)) }
        attributes.merge(query) { _, new in new }
        attributes[kSecAttrAccessible as String] = synchronizable ? kSecAttrAccessibleAfterFirstUnlock : kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }
}

final class MemorySettingsCredentialStore: SettingsCredentialStore {
    var local: Data?
    var cloud: Data?
    func read(synchronizable: Bool) throws -> Data? { synchronizable ? cloud : local }
    func write(_ data: Data, synchronizable: Bool) throws {
        if synchronizable { cloud = data } else { local = data }
    }
}

@objc(GLServerCredentials) final class GLServerCredentials: NSObject {
    static var store: SettingsCredentialStore = KeychainSettingsStore()
    private static var savedStore: SettingsCredentialStore?
    // The Objective-C manager tests already isolate UserDefaults and URLSession.
    @objc static func beginTesting() { savedStore = store; store = MemorySettingsCredentialStore() }
    @objc static func endTesting() { if let savedStore { store = savedStore }; savedStore = nil }

    private static func values() -> [String: String] {
        var values = (try? store.read(synchronizable: false)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
        let defaults = UserDefaults.standard
        let oldURL = defaults.string(forKey: GLAPIEndpointDefaultsName)
        let oldToken = defaults.string(forKey: GLAPIAccessTokenDefaultsName)
        if oldURL != nil || oldToken != nil {
            values["serverURL"] = oldURL ?? values["serverURL"] ?? ""
            values["serverToken"] = oldToken ?? values["serverToken"] ?? ""
            if let data = try? JSONSerialization.data(withJSONObject: values), (try? store.write(data, synchronizable: false)) != nil {
                defaults.removeObject(forKey: GLAPIEndpointDefaultsName)
                defaults.removeObject(forKey: GLAPIAccessTokenDefaultsName)
            }
        }
        return values
    }
    @objc static func endpoint() -> String { values()["serverURL"] ?? "" }
    @objc static func token() -> String { values()["serverToken"] ?? "" }
    @objc(saveEndpoint:token:) static func saveEndpoint(_ endpoint: String, token: String) -> Bool {
        do {
            let data = try JSONSerialization.data(withJSONObject: ["serverURL": endpoint, "serverToken": token])
            try store.write(data, synchronizable: false)
            UserDefaults.standard.removeObject(forKey: GLAPIEndpointDefaultsName)
            UserDefaults.standard.removeObject(forKey: GLAPIAccessTokenDefaultsName)
            return true
        } catch { return false }
    }
}

protocol SettingsCloudStore: AnyObject {
    var values: [String: Any] { get }
    func set(_ value: Any, forKey key: String)
    func synchronize() -> Bool
}

final class UbiquitousSettingsStore: SettingsCloudStore {
    private lazy var store = NSUbiquitousKeyValueStore.default
    var values: [String: Any] { store.dictionaryRepresentation }
    func set(_ value: Any, forKey key: String) { store.set(value, forKey: key) }
    func synchronize() -> Bool { store.synchronize() }
}

struct SettingsSyncRecord {
    let value: Any
    let modified: TimeInterval
    let writer: String
    var dictionary: [String: Any] { ["value": value, "modified": modified, "writer": writer, "schema": SettingsSchema.version] }
    init(value: Any, modified: TimeInterval, writer: String) { self.value = value; self.modified = modified; self.writer = writer }
    init?(_ raw: Any) {
        guard let dict = raw as? [String: Any], let value = dict["value"], let modified = dict["modified"] as? NSNumber,
              modified.doubleValue.isFinite, modified.doubleValue >= 0,
              let writer = dict["writer"] as? String, writer.count <= 80,
              let schema = dict["schema"] as? Int, schema <= SettingsSchema.version else { return nil }
        self.init(value: value, modified: modified.doubleValue, writer: writer)
    }
    func isNewer(than other: SettingsSyncRecord?) -> Bool {
        guard let other else { return true }
        return modified > other.modified || (modified == other.modified && writer > other.writer)
    }
}

@MainActor @Observable @objc(WhereWolfSettingsSync) final class SettingsSync: NSObject {
    @objc static let shared = SettingsSync()
    static let enabledKey = "WhereWolfSettingsSyncEnabled"
    static let recordsKey = "WhereWolfSettingsModificationTimes"
    static let prefix = "WhereWolf.settings."
    private static var advancedNames: Set<String> { Set((GLManager.normalizedTrackingOptions([:]) as? [String: NSNumber] ?? [:]).keys) }
    private static var advancedKeys: Set<String> { Set(advancedNames.map { "advancedTracking." + $0 }) }
    private static var portableKeys: Set<String> { SettingsSchema.keys.subtracting(["advancedTracking"]).union(advancedKeys) }
    private static var cloudKeys: Set<String> { SettingsSchema.syncKeys.subtracting(["advancedTracking"]).union(advancedKeys) }
    private static func flattened(_ input: [String: Any]) -> [String: Any] {
        var result = input
        if let options = result.removeValue(forKey: "advancedTracking") as? [String: Any] {
            for (name, value) in options where advancedNames.contains(name) { result["advancedTracking." + name] = value }
        }
        return result
    }
    private static func validatedValue(_ value: Any, key: String) throws -> Any? {
        if advancedKeys.contains(key) {
            let name = String(key.dropFirst("advancedTracking.".count))
            let validated = try SettingsSchema.validate(["advancedTracking": [name: value]])
            return (validated["advancedTracking"] as? [String: Any])?[name]
        }
        return try SettingsSchema.validate([key: value])[key]
    }
    private func batchValues(_ input: [String: Any]) -> [String: Any] {
        var result = input
        var options = snapshot()["advancedTracking"] as? [String: Any] ?? [:]
        var changed = false
        for key in Self.advancedKeys {
            if let value = result.removeValue(forKey: key) {
                options[String(key.dropFirst("advancedTracking.".count))] = value; changed = true
            }
        }
        if changed { result["advancedTracking"] = options }
        return result
    }
    private let defaults: UserDefaults
    private let cloud: SettingsCloudStore
    private let secrets: SettingsCredentialStore
    private let snapshot: () -> [String: Any]
    private let apply: ([String: Any]) throws -> Void
    private let canApply: () -> Bool
    private let supported: Bool
    private let clock: () -> Date
    private let writer: String
    private var local: [String: SettingsSyncRecord] = [:]
    private var observers: [NSObjectProtocol] = []
    private var pending: DispatchWorkItem?
    private var started = false
    private var applying = false
    private(set) var status = "Settings stay on this iPhone."
    var enabled: Bool { defaults.bool(forKey: Self.enabledKey) }
    var available: Bool { supported }

    override convenience init() {
        self.init(defaults: .standard, cloud: UbiquitousSettingsStore(), secrets: GLServerCredentials.store,
            snapshot: { GLManagerBridge.shared.settingsSnapshot() },
            apply: { try GLManagerBridge.shared.applySettings($0) },
            canApply: { !GLManager.shared().tripInProgress() },
            supported: (Bundle.main.object(forInfoDictionaryKey: "WhereWolfICloudEnabled") as? NSString)?.boolValue ?? true)
    }
    init(defaults: UserDefaults, cloud: SettingsCloudStore, secrets: SettingsCredentialStore,
         snapshot: @escaping () -> [String: Any], apply: @escaping ([String: Any]) throws -> Void,
         canApply: @escaping () -> Bool = { true }, supported: Bool = true, clock: @escaping () -> Date = { Date() }) {
        self.defaults = defaults; self.cloud = cloud; self.secrets = secrets
        self.snapshot = snapshot; self.apply = apply; self.canApply = canApply; self.clock = clock; self.supported = supported
        let writerKey = "WhereWolfSettingsWriter"
        writer = defaults.string(forKey: writerKey) ?? UUID().uuidString
        super.init()
        defaults.set(writer, forKey: writerKey)
        for (key, raw) in defaults.dictionary(forKey: Self.recordsKey) ?? [:] where Self.portableKeys.contains(key) {
            if let record = SettingsSyncRecord(raw) { local[key] = record }
        }
    }
    @objc func start() {
        guard !started else { return }
        started = true
        observeLocalChanges(initial: true)
        for name in [Notification.Name(GLSettingsChangedNotification), UserDefaults.didChangeNotification,
                     Notification.Name(GLTrackingStateChangedNotification), Notification.Name(GLNewDataNotification),
                     UIApplication.didBecomeActiveNotification, NSUbiquitousKeyValueStore.didChangeExternallyNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] notification in
                MainActor.assumeIsolated {
                    guard let self, !self.applying else { return }
                    if notification.name == NSUbiquitousKeyValueStore.didChangeExternallyNotification,
                       notification.userInfo?[NSUbiquitousKeyValueStoreChangeReasonKey] as? Int == NSUbiquitousKeyValueStoreQuotaViolationChange {
                        self.status = "iCloud storage quota was exceeded. Settings remain saved locally."
                        return
                    }
                    self.pending?.cancel()
                    let work = DispatchWorkItem { [weak self] in self?.synchronize() }
                    self.pending = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
                }
            })
        }
        if enabled && supported { _ = cloud.synchronize() }
        synchronize()
    }
    func setEnabled(_ value: Bool) {
        guard !value || supported else { status = "iCloud settings sync is unavailable in this build."; return }
        defaults.set(value, forKey: Self.enabledKey)
        if value { _ = cloud.synchronize() }
        synchronize()
    }
    private func persist() {
        var safe = local.mapValues(\.dictionary)
        for key in SettingsSchema.secrets where safe[key] != nil { safe[key]?["value"] = "" }
        if !SettingsSchema.equal(defaults.dictionary(forKey: Self.recordsKey), safe) { defaults.set(safe, forKey: Self.recordsKey) }
    }
    func observeLocalChanges(initial: Bool = false) {
        for (key, raw) in Self.flattened(snapshot()) where Self.portableKeys.contains(key) {
            guard let value = try? Self.validatedValue(raw, key: key) else { continue }
            if initial, SettingsSchema.secrets.contains(key), let old = local[key] {
                local[key] = SettingsSyncRecord(value: value, modified: old.modified, writer: old.writer)
                continue
            }
            guard !SettingsSchema.equal(value, local[key]?.value) else { continue }
            local[key] = SettingsSyncRecord(value: value, modified: initial && local[key] == nil ? 0 : clock().timeIntervalSince1970, writer: writer)
        }
        persist()
    }
    func synchronize() {
        guard !applying else { return }
        observeLocalChanges()
        guard supported else { status = "iCloud settings sync is unavailable in this build."; return }
        guard enabled else { status = "Settings stay on this iPhone."; return }
        guard canApply() else { status = "Incoming changes will apply after the current trip ends."; return }
        do {
            var remote: [String: SettingsSyncRecord] = [:]
            let cloudValues = cloud.values
            for key in Self.cloudKeys {
                if let raw = cloudValues[Self.prefix + key], let record = SettingsSyncRecord(raw) { remote[key] = record }
            }
            let secretData = try secrets.read(synchronizable: true)
            let secretValues = secretData.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            for key in SettingsSchema.secrets { if let raw = secretValues[key], let record = SettingsSyncRecord(raw) { remote[key] = record } }
            var changes: [String: Any] = [:]
            var accepted: [String: SettingsSyncRecord] = [:]
            for (key, record) in remote where record.isNewer(than: local[key]) {
                if let value = try Self.validatedValue(record.value, key: key) {
                    changes[key] = value
                    accepted[key] = SettingsSyncRecord(value: value, modified: record.modified, writer: record.writer)
                }
            }
            applying = true
            defer { applying = false }
            if !changes.isEmpty { try apply(batchValues(changes)); local.merge(accepted) { _, remote in remote } }
            persist()
            for key in Self.cloudKeys {
                guard var record = local[key], record.isNewer(than: remote[key]) else { continue }
                if record.modified == 0 && remote[key] == nil {
                    record = SettingsSyncRecord(value: record.value, modified: clock().timeIntervalSince1970, writer: writer)
                    local[key] = record
                }
                cloud.set(record.dictionary, forKey: Self.prefix + key)
            }
            var secretOutput = secretValues
            var secretChanged = false
            for key in SettingsSchema.secrets {
                guard var record = local[key], record.isNewer(than: remote[key]) else { continue }
                if record.modified == 0 && remote[key] == nil {
                    record = SettingsSyncRecord(value: record.value, modified: clock().timeIntervalSince1970, writer: writer)
                    local[key] = record
                }
                secretOutput[key] = record.dictionary; secretChanged = true
            }
            persist()
            if secretChanged { try secrets.write(JSONSerialization.data(withJSONObject: secretOutput), synchronizable: true) }
            status = "iCloud sync is on. Delivery depends on iCloud availability. Server credentials use iCloud Keychain."
        } catch {
            status = "Couldn’t sync settings: \(error.localizedDescription) Settings remain saved locally."
        }
    }
}
