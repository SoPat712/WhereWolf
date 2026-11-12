import Foundation

struct HistoryLoadingDay: Equatable {
    let day: Date
    let range: ClosedRange<Double>
    let state: ServerHistoryDayState
    let pointCount: Int?

    var label: String { state == .loading ? "Loading…" : "Not downloaded" }
}

// Missing days supply time anchors, never invented locations. Only the real points enter map geometry.
final class ServerHistoryRuler {
    let timestamps: [Date]
    let positions: [Int]
    let count: Int
    let sourcePositions: [Int]
    private let sourceIndices: [Int?]
    let loadingDays: [HistoryLoadingDay]
    let detailDays: Set<Date>
    let phoneStart: Date
    let snapshot: ServerHistorySnapshot

    init(points: [RecordedLocation], phoneStart: Date, snapshot: ServerHistorySnapshot, now: Date) {
        self.phoneStart = phoneStart
        self.snapshot = snapshot
        let calendar = snapshot.calendar
        let sourceTimes = Set(points.map(\.timestamp))
        var anchors = Set<Date>()
        var entries = points.enumerated().map { (time: $0.element.timestamp, source: Optional($0.offset)) }
        func anchor(_ date: Date) {
            if !sourceTimes.contains(date), anchors.insert(date).inserted { entries.append((date, nil)) }
        }
        let detailDays = Set(points.map { calendar.startOfDay(for: $0.timestamp) })
        self.detailDays = detailDays
        let summaries = Dictionary(snapshot.days.map { ($0.day, $0) }, uniquingKeysWith: { _, new in new })
        let phone = points.filter { $0.id >= 0 }
        let mean = phone.count > 1 ? phone.last!.timestamp.timeIntervalSince(phone.first!.timestamp) / Double(phone.count - 1) : 60
        let nominal = max(1, mean.isFinite && mean > 0 ? mean : 60)
        var pending: [(Date, Date, ServerHistoryDayState, Int?)] = []
        var reserved: [(start: Date, end: Date, count: Int)] = []
        if var day = snapshot.firstDay {
            let last = min(now, phoneStart)
            while day < last {
                guard let end = calendar.date(byAdding: .day, value: 1, to: day), end > day else { break }
                if snapshot.points[day] == nil {
                    let upper = min(last.addingTimeInterval(-0.001), end.addingTimeInterval(-0.001))
                    if upper > day {
                        anchor(day); anchor(upper)
                        let state: ServerHistoryDayState = summaries[day]?.state == .loading || snapshot.loadingDays.contains(day)
                            ? .loading : .notDownloaded
                        let fraction = upper.timeIntervalSince(day) / end.timeIntervalSince(day)
                        let estimate = summaries[day].map { Double($0.pointCount) * fraction }
                            ?? upper.timeIntervalSince(day) / nominal
                        reserved.append((day, upper, min(100_000_000, max(2, Int(min(100_000_000, estimate))))))
                        pending.append((day, upper, state, summaries[day]?.pointCount))
                    }
                } else if snapshot.points[day]?.isEmpty == true {
                    // A downloaded empty day still occupies time, without a phone "No data" warning.
                    anchor(day)
                    anchor(min(last, end.addingTimeInterval(-0.001)))
                }
                day = end
            }
        }
        entries.sort { $0.time == $1.time ? ($0.source ?? -1) < ($1.source ?? -1) : $0.time < $1.time }
        let ordered = entries.map { $0.time }
        timestamps = ordered
        sourceIndices = entries.map { $0.source }
        var knots = [Int](repeating: 0, count: entries.count)
        var sourcePositions = [Int](repeating: 0, count: points.count)
        var missing = 0
        for index in entries.indices {
            if index > 0 {
                while missing < reserved.count, reserved[missing].end <= entries[index - 1].time { missing += 1 }
                var width = 1
                if missing < reserved.count {
                    let day = reserved[missing]
                    if entries[index - 1].time >= day.start, entries[index].time <= day.end {
                        let fraction = entries[index].time.timeIntervalSince(entries[index - 1].time)
                            / max(0.001, day.end.timeIntervalSince(day.start))
                        width = max(1, Int((Double(day.count - 1) * fraction).rounded()))
                    }
                }
                knots[index] = knots[index - 1] + width
            }
            if let source = entries[index].source { sourcePositions[source] = knots[index] }
        }
        positions = knots
        count = knots.last.map { $0 + 1 } ?? 0
        self.sourcePositions = sourcePositions
        func index(at time: Date) -> Double {
            let sample = HistoryRulerFraming.index(at: time, timestamps: ordered)
            guard !knots.isEmpty else { return 0 }
            let lo = Int(sample), hi = min(knots.count - 1, lo + 1)
            return Double(knots[lo]) + Double(knots[hi] - knots[lo]) * (sample - Double(lo))
        }
        loadingDays = pending.map { day, end, state, count in
            .init(day: day, range: index(at: day)...index(at: end), state: state, pointCount: count)
        }
    }

    func index(forSourcePosition position: Double) -> Double {
        guard !sourcePositions.isEmpty else { return 0 }
        let value = min(Double(sourcePositions.count - 1), max(0, position))
        let lo = Int(value), hi = min(sourcePositions.count - 1, lo + 1)
        return Double(sourcePositions[lo]) + Double(sourcePositions[hi] - sourcePositions[lo]) * (value - Double(lo))
    }

    func sourcePosition(at index: Double) -> Double? {
        guard index >= 0, index < Double(count), !positions.isEmpty else { return nil }
        let hi = min(positions.count - 1, HistoryLandmarks.lowerBound(positions.count) { Double(positions[$0]) >= index })
        if Double(positions[hi]) == index { return sourceIndices[hi].map(Double.init) }
        let lo = max(0, hi - 1)
        guard let first = sourceIndices[lo], let last = sourceIndices[hi] else { return nil }
        let fraction = (index - Double(positions[lo])) / Double(max(1, positions[hi] - positions[lo]))
        return Double(first) + Double(last - first) * fraction
    }

    func index(at time: Date) -> Double {
        guard !positions.isEmpty else { return 0 }
        let sample = HistoryRulerFraming.index(at: time, timestamps: timestamps)
        let lo = Int(sample), hi = min(positions.count - 1, lo + 1)
        return Double(positions[lo]) + Double(positions[hi] - positions[lo]) * (sample - Double(lo))
    }

    func timestamp(at index: Int) -> Date { time(at: Double(index)) ?? .distantPast }

    func time(at index: Double) -> Date? {
        guard !timestamps.isEmpty else { return nil }
        let bounded = min(Double(max(0, count - 1)), max(0, index))
        let hi = min(positions.count - 1, HistoryLandmarks.lowerBound(positions.count) { Double(positions[$0]) >= bounded })
        let lo = max(0, hi - 1)
        let fraction = (bounded - Double(positions[lo])) / Double(max(1, positions[hi] - positions[lo]))
        return timestamps[lo].addingTimeInterval(timestamps[hi].timeIntervalSince(timestamps[lo]) * fraction)
    }

    func loadingDay(at index: Double) -> HistoryLoadingDay? {
        let next = HistoryLandmarks.lowerBound(loadingDays.count) { loadingDays[$0].range.upperBound >= index }
        return next < loadingDays.count && loadingDays[next].range.contains(index) ? loadingDays[next] : nil
    }
}
