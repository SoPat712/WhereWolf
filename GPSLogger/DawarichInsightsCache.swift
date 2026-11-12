import Foundation
import CryptoKit

actor DawarichInsightsCache {
    static let shared = DawarichInsightsCache()
    static let cleared = Notification.Name("WhereWolfInsightsCacheCleared")
    static let freshness: TimeInterval = 6 * 60 * 60
    static let responseLimit = 8 * 1_024 * 1_024
    static let thumbnailLimit = 4 * 1_024 * 1_024
    static let responseBudget = 32 * 1_024 * 1_024
    static let thumbnailBudget = 64 * 1_024 * 1_024

    struct Entry: Codable {
        let body: Data
        let updated: Date
        var unavailable = false
        func isFresh(at now: Date) -> Bool {
            let age = now.timeIntervalSince(updated)
            return age >= 0 && age < DawarichInsightsCache.freshness
        }
    }
    let directory: URL
    private(set) var generation = UUID()
    private let thumbnailBudget: Int
    private let responseBudget: Int

    init(directory: URL? = nil, thumbnailBudget: Int = DawarichInsightsCache.thumbnailBudget,
         responseBudget: Int = DawarichInsightsCache.responseBudget) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("DawarichInsights", isDirectory: true)
        self.thumbnailBudget = thumbnailBudget
        self.responseBudget = responseBudget
    }

    static func hash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    func read(scope: String, key: String, thumbnail: Bool = false) -> Entry? {
        let url = file(scope: scope, key: key, thumbnail: thumbnail)
        guard let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= (thumbnail ? Self.thumbnailLimit : Self.responseLimit) + 4_096,
              let data = try? Data(contentsOf: url), let entry = try? PropertyListDecoder().decode(Entry.self, from: data) else { return nil }
        return entry
    }

    func write(_ entry: Entry, scope: String, key: String, thumbnail: Bool = false, generation: UUID) {
        guard generation == self.generation,
              entry.body.count <= (thumbnail ? Self.thumbnailLimit : Self.responseLimit) else { return }
        let url = file(scope: scope, key: key, thumbnail: thumbnail)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            try protect(directory)
            let encoder = PropertyListEncoder()
            encoder.outputFormat = .binary
            try encoder.encode(entry).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            try protect(url)
            try trim(thumbnail: thumbnail)
        } catch {
            try? FileManager.default.removeItem(at: url)
        }
    }

    func clear() throws {
        generation = UUID()
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
        NotificationCenter.default.post(name: Self.cleared, object: nil)
    }

    func storageBytes() -> Int64 {
        files().reduce(0) { $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) }
    }

    private func file(scope: String, key: String, thumbnail: Bool) -> URL {
        directory.appendingPathComponent(Self.hash(scope + "\n" + key)).appendingPathExtension(thumbnail ? "thumb" : "response")
    }

    private func protect(_ file: URL) throws {
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: file.path)
        var url = file
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }

    private func files() -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: directory,
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey], options: [.skipsHiddenFiles])) ?? []
    }

    private func trim(thumbnail: Bool) throws {
        let ext = thumbnail ? "thumb" : "response"
        let entries = files().filter { $0.pathExtension == ext }.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var total = entries.reduce(0) { $0 + $1.1 }
        let budget = thumbnail ? thumbnailBudget : responseBudget
        for (url, size, _) in entries where total > budget {
            try FileManager.default.removeItem(at: url)
            total -= size
        }
    }
}
