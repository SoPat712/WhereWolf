import Foundation

struct TrackingTransition: Codable, Equatable {
    enum Kind: String, Codable { case start, stop, pause, resume }
    let date: Date
    let kind: Kind
    var recording: Bool { kind == .start || kind == .resume }
}

struct CoverageSend: Codable, Equatable {
    let date: Date
    let status: Int
    var error: String?
}

struct CoverageLogSnapshot: Codable, Equatable {
    var transitions: [TrackingTransition] = []
    var sends: [CoverageSend] = []
}

// No coordinates or server text. The protection and backup policy match LocationHealth.
@objc(TrackingTransitionLog) final class TrackingTransitionLog: NSObject {
    static let shared = TrackingTransitionLog()
    private let queue = DispatchQueue(label: "me.joshpatra.WhereWolf.coverage-log", qos: .utility)
    private let directory: URL
    private let retention: () -> TimeInterval
    private let clock: () -> Date
    private var cached: CoverageLogSnapshot?
    private var lastPrune = -Double.infinity
    private var lastRetention: TimeInterval = 0
    static let transitionLimit = 2000
    static let sendLimit = 20000

    init(directory: URL? = nil, retention: @escaping () -> TimeInterval = { HistoryRetention.duration }, clock: @escaping () -> Date = { Date() }) {
        self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Coverage", isDirectory: true)
        self.retention = retention; self.clock = clock
        super.init()
    }
    private var file: URL { directory.appendingPathComponent("state.json") }
    static func bounded(_ snapshot: CoverageLogSnapshot, cutoff: Date) -> CoverageLogSnapshot {
        let sorted = snapshot.transitions.filter { $0.date.timeIntervalSince1970.isFinite }.sorted { $0.date < $1.date }
        var transitions = sorted.filter { $0.date >= cutoff }
        if let previous = sorted.last(where: { $0.date < cutoff }) {
            transitions.insert(TrackingTransition(date: cutoff, kind: previous.kind), at: 0)
        }
        transitions = Array(transitions.suffix(transitionLimit))
        let sends = Array(snapshot.sends.filter { $0.date >= cutoff && $0.date.timeIntervalSince1970.isFinite && (0...2).contains($0.status) }.suffix(sendLimit))
        return CoverageLogSnapshot(transitions: transitions, sends: sends)
    }
    private func read() -> CoverageLogSnapshot {
        if let cached { return cached }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= 4_000_000, let data = try? Data(contentsOf: file),
              let value = try? JSONDecoder().decode(CoverageLogSnapshot.self, from: data) else { return CoverageLogSnapshot() }
        return value
    }
    private func write(_ value: CoverageLogSnapshot) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            var excluded = directory
            var resources = URLResourceValues(); resources.isExcludedFromBackup = true
            try excluded.setResourceValues(resources)
            try JSONEncoder().encode(value).write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
            cached = value
        } catch { NSLog("Coverage log could not be saved: %@", error.localizedDescription) }
    }
    private func update(forcePrune: Bool = false, _ edit: @escaping (inout CoverageLogSnapshot) -> Void) {
        queue.async {
            let original = self.read()
            var value = original
            edit(&value)
            let now = self.clock(), retention = self.retention()
            guard forcePrune || value != original || retention != self.lastRetention || now.timeIntervalSince1970 - self.lastPrune >= 3600 else { return }
            value = Self.bounded(value, cutoff: now.addingTimeInterval(-retention))
            self.lastPrune = now.timeIntervalSince1970; self.lastRetention = retention
            if value != original { self.write(value) }
        }
    }
    @objc(recordTracking:paused:) static func recordTracking(_ tracking: Bool, paused: Bool) {
        shared.record(tracking: tracking, paused: paused)
    }
    func record(tracking: Bool, paused: Bool, date: Date? = nil) {
        let date = date ?? clock()
        update { value in
            let last = value.transitions.last
            let kind: TrackingTransition.Kind = !tracking ? .stop : paused ? .pause : (last?.kind == .pause ? .resume : .start)
            if let last, last.recording == (tracking && !paused), (last.kind == .stop) == !tracking { return }
            value.transitions.append(TrackingTransition(date: date, kind: kind))
        }
    }
    @objc(recordSend:) static func recordSend(_ status: Int) {
        shared.update { $0.sends.append(CoverageSend(date: shared.clock(), status: status)) }
    }
    @objc(recordErrorCategory:) static func recordErrorCategory(_ category: String) {
        let safe = ["Certificate Error", "HTTP Error", "Server Error", "iCloud Drive"].contains(category) ? category : "Upload error"
        shared.update { value in
            guard let index = value.sends.indices.last, value.sends[index].status != 0 else { return }
            value.sends[index].error = safe
        }
    }
    @objc static func prune() { shared.update(forcePrune: true) { _ in } }
    func load(completion: @escaping (CoverageLogSnapshot) -> Void) {
        queue.async {
            let original = self.read()
            let value = Self.bounded(original, cutoff: self.clock().addingTimeInterval(-self.retention()))
            if value != original { self.write(value) }
            DispatchQueue.main.async { completion(value) }
        }
    }
}

struct CoverageSpan: Identifiable, Equatable {
    enum Kind: String { case recorded, paused, gap, unknown }
    let start: Date
    let end: Date
    let kind: Kind
    var id: Date { start }
    var duration: TimeInterval { end.timeIntervalSince(start) }
}

struct CoverageHour: Identifiable {
    let start: Date
    let points: Int
    var id: Date { start }
}

struct CoverageReport {
    let start: Date
    let end: Date
    let spans: [CoverageSpan]
    let hours: [CoverageHour]
    let pointCount: Int
    let sendsSucceeded: Int
    let sendsFailed: Int
    let lastError: String?
    let queued: Int
    var gaps: [CoverageSpan] { spans.filter { $0.kind == .gap } }
    var longestGap: TimeInterval { gaps.map(\.duration).max() ?? 0 }
    static let gapThreshold: TimeInterval = 600

    static func compute(timestamps: [Date], transitions: [TrackingTransition], sends: [CoverageSend],
                        start: Date, end: Date, queued: Int, calendar: Calendar = .current) -> CoverageReport {
        guard end > start else {
            return CoverageReport(start: start, end: end, spans: [], hours: [], pointCount: 0,
                                  sendsSucceeded: 0, sendsFailed: 0, lastError: nil, queued: queued)
        }
        let allPoints = timestamps.filter { $0.timeIntervalSince1970.isFinite && $0 <= end }.sorted()
        let points = allPoints.filter { $0 >= start }
        func previousFix(at date: Date, since: Date) -> Date? {
            var low = 0, high = allPoints.count
            while low < high {
                let middle = (low + high) / 2
                if allPoints[middle] <= date { low = middle + 1 } else { high = middle }
            }
            guard low > 0, allPoints[low - 1] >= since else { return nil }
            return allPoints[low - 1]
        }
        let events = transitions.filter { $0.date <= end }.sorted { $0.date < $1.date }
        let boundaries = Array(Set([start, end] + events.filter { $0.date > start }.map(\.date))).sorted()
        var spans: [CoverageSpan] = []
        func add(_ kind: CoverageSpan.Kind, _ a: Date, _ b: Date) {
            guard b > a else { return }
            if kind != .gap, let previous = spans.last, previous.kind == kind, previous.end == a {
                spans[spans.count - 1] = CoverageSpan(start: previous.start, end: b, kind: kind)
            } else { spans.append(CoverageSpan(start: a, end: b, kind: kind)) }
        }
        var pointIndex = 0
        var eventIndex = 0
        var state: TrackingTransition?
        for index in 0..<(boundaries.count - 1) {
            let a = boundaries[index], b = boundaries[index + 1]
            while eventIndex < events.count && events[eventIndex].date <= a { state = events[eventIndex]; eventIndex += 1 }
            while pointIndex < points.count && points[pointIndex] < a { pointIndex += 1 }
            guard let state else { add(.unknown, a, b); continue }
            guard state.recording else { add(.paused, a, b); continue }
            var cursor = a
            // Include the last accepted point before a day/window boundary, but never before a resume.
            var lastFix = previousFix(at: a, since: state.date) ?? a
            while pointIndex < points.count && points[pointIndex] < b {
                let point = points[pointIndex]
                if point.timeIntervalSince(lastFix) > gapThreshold {
                    add(.recorded, cursor, max(cursor, lastFix))
                    add(.gap, max(cursor, lastFix), point)
                } else { add(.recorded, cursor, point) }
                cursor = point; lastFix = point; pointIndex += 1
            }
            if b.timeIntervalSince(lastFix) > gapThreshold {
                add(.recorded, cursor, max(cursor, lastFix)); add(.gap, max(cursor, lastFix), b)
            } else { add(.recorded, cursor, b) }
        }
        var hours: [CoverageHour] = []
        var hour = calendar.dateInterval(of: .hour, for: start)?.start ?? start
        var countIndex = 0
        while hour < end {
            let next = calendar.date(byAdding: .hour, value: 1, to: hour) ?? hour.addingTimeInterval(3600)
            let initial = countIndex
            while countIndex < points.count && (points[countIndex] < next || (next >= end && points[countIndex] == end)) { countIndex += 1 }
            hours.append(CoverageHour(start: hour, points: countIndex - initial)); hour = next
        }
        let attempts = sends.filter { $0.date >= start && $0.date <= end }
        let lastFailure = attempts.last { $0.status != 0 }
        return CoverageReport(start: start, end: end, spans: spans, hours: hours, pointCount: points.count,
            sendsSucceeded: attempts.filter { $0.status == 0 }.count, sendsFailed: attempts.filter { $0.status != 0 }.count,
            lastError: lastFailure.map { $0.error ?? ($0.status == 1 ? "Server rejected the upload" : "Network failure") }, queued: max(0, queued))
    }
}
