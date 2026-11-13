import Foundation
import Observation

struct ServerPendingQueue: Equatable, Sendable {
    let count: Int
    let importedCount: Int
    let oldest: Date?
    let newest: Date?

    static let empty = Self(count: 0, importedCount: 0, oldest: nil, newest: nil)
    var pointCount: Int { count - importedCount }

    init(count: Int, importedCount: Int, oldest: Date?, newest: Date?) {
        self.count = max(0, count)
        self.importedCount = min(max(0, importedCount), max(0, count))
        self.oldest = oldest
        self.newest = newest
    }

    @MainActor static func load() async -> Self? {
        await withCheckedContinuation { continuation in
            GLManager.shared().loadPendingServerQueueSummary { metadata in
                guard let metadata, let count = metadata["count"]?.intValue,
                      let imported = metadata["importedCount"]?.intValue else {
                    continuation.resume(returning: nil)
                    return
                }
                func date(_ key: String) -> Date? {
                    guard let seconds = metadata[key]?.doubleValue, seconds.isFinite else { return nil }
                    return Date(timeIntervalSince1970: seconds)
                }
                continuation.resume(returning: Self(count: count, importedCount: imported,
                                                     oldest: date("oldest"), newest: date("newest")))
            }
        }
    }

    func countText(locale: Locale = .current) -> String {
        if pointCount == 0 && importedCount > 0 {
            return "\(number(importedCount, locale)) imported workout \(importedCount == 1 ? "point" : "points") waiting"
        }
        return "\(number(pointCount, locale)) \(pointCount == 1 ? "point" : "points") waiting"
    }

    func importedText(locale: Locale = .current) -> String? {
        guard pointCount > 0, importedCount > 0 else { return nil }
        return "and \(number(importedCount, locale)) imported workout \(importedCount == 1 ? "point" : "points")"
    }

    func rangeText(locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        guard let oldest, let newest else { return "Recorded dates unavailable" }
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("yMMMdjmmssz")
        let first = formatter.string(from: oldest)
        if oldest == newest { return "Recorded \(first)" }
        return "Recorded \(first) – \(formatter.string(from: newest))"
    }

    private func number(_ count: Int, _ locale: Locale) -> String {
        let formatter = NumberFormatter()
        formatter.locale = locale
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: count)) ?? String(count)
    }
}

@MainActor @Observable
final class ServerChangeConfirmation {
    private(set) var pending: ServerPendingQueue?
    private(set) var host = ""
    private(set) var busy = false
    private(set) var error: String?
    private var generation = UUID()
    private var save: (@MainActor () async -> Bool)?
    private var continuation: CheckedContinuation<Bool?, Never>?

    // nil means Back/cancellation; false means a read or save failure. Keep the captured
    // draft until confirmation, so a form refresh cannot silently change the destination.
    func request(_ values: ServerQRValues, current: ServerQRValues,
                 load: @MainActor () async -> ServerPendingQueue? = { await ServerPendingQueue.load() },
                 save: @escaping @MainActor () async -> Bool) async -> Bool? {
        guard !busy, pending == nil, !Task.isCancelled else { return nil }
        error = nil
        busy = true
        generation = UUID()
        let generation = self.generation
        if values.changesServer(from: current) {
            let summary = await load()
            guard self.generation == generation else { return nil }
            guard !Task.isCancelled else { busy = false; return nil }
            guard let summary else {
                busy = false
                error = "Couldn’t read the points waiting on this iPhone. Try again."
                return false
            }
            if summary.count > 0 {
                host = values.host
                pending = summary
                busy = false
                self.save = save
                return await withCheckedContinuation { continuation = $0 }
            }
        }
        let saved = await save()
        guard self.generation == generation else { return nil }
        busy = false
        if !saved { error = "Couldn’t save the server credential. Unlock this iPhone and try again." }
        return saved
    }

    func confirm() async {
        guard !busy, pending != nil, let save else { return }
        busy = true
        error = nil
        let generation = self.generation
        let saved = await save()
        guard self.generation == generation else { return }
        busy = false
        guard saved else {
            error = "Couldn’t save the server credential. Unlock this iPhone and try again."
            return
        }
        finish(true)
    }

    func back() {
        guard !busy else { return }
        cancel()
    }

    func cancel() {
        generation = UUID()
        busy = false
        error = nil
        finish(nil)
    }

    func clearError() { error = nil }

    private func finish(_ result: Bool?) {
        pending = nil
        save = nil
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(returning: result)
    }
}
