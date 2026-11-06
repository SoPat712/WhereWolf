import Foundation

struct TodayHistorySummary: Equatable {
    let start: Date
    let distance: Double
    let points: Int
    let lastFixDate: Date?
}

// Owned by the archive queue. Coordinates stay here, never in the widget snapshot.
struct TodayHistoryCache {
    private(set) var day: TodayWindow?
    private(set) var lastArchivedID: Int64 = 0
    private(set) var readThrough = Date.distantPast
    private var pruningRevision = 0
    private var locations: [RecordedLocation] = []
    private var cumulativeDistance: [Double] = []

    var oldestTimestamp: Date? { locations.first?.timestamp }

    mutating func prepare(now: Date, calendar: Calendar, pruningRevision: Int, cutoff: Date) {
        let day = TodayWindow(containing: now, calendar: calendar)
        guard self.day != day || self.pruningRevision != pruningRevision || now < readThrough
                || locations.first.map({ $0.timestamp < cutoff }) == true else { return }
        self = TodayHistoryCache()
        self.day = day
        self.pruningRevision = pruningRevision
    }

    mutating func extend(_ additions: [RecordedLocation], through now: Date) {
        readThrough = now
        guard !additions.isEmpty else { return }
        let sorted = additions.sorted(by: Self.ordered)
        lastArchivedID = max(lastArchivedID, additions.map(\.id).max() ?? 0)
        if let last = locations.last, let first = sorted.first, !Self.ordered(last, first) {
            locations.append(contentsOf: sorted)
            locations.sort(by: Self.ordered)
            cumulativeDistance = []
            appendDistances(from: 0, context: 0)
            return
        }

        let count = locations.count
        // Net speed looks 30 seconds ahead; jump detection looks two fixes ahead. Revisit
        // that unsettled tail, including an isolated last fix even across a long silence.
        let affectedTime = sorted[0].timestamp.addingTimeInterval(-ReplayTimeline.activityWindow)
        let first = min(lowerBound(affectedTime), max(0, count - 2))
        let contextTime = locations.isEmpty ? affectedTime
            : locations[max(0, first - 1)].timestamp.addingTimeInterval(-ReplayTimeline.activityWindow)
        let context = min(lowerBound(contextTime), max(0, first - 3))
        locations.append(contentsOf: sorted)
        cumulativeDistance.removeSubrange(first..<cumulativeDistance.count)
        appendDistances(from: first, context: context)
    }

    func summary(lastFixDate: Date?) -> TodayHistorySummary {
        TodayHistorySummary(start: day!.start, distance: cumulativeDistance.last ?? 0,
                            points: locations.count, lastFixDate: lastFixDate)
    }

    private mutating func appendDistances(from first: Int, context: Int) {
        let increments = ReplayTimeline.distanceIncrements(Array(locations[context...]))
        var distance = cumulativeDistance.last ?? 0
        for index in first..<locations.count {
            distance += increments[index - context]
            cumulativeDistance.append(distance)
        }
    }

    private func lowerBound(_ date: Date) -> Int {
        var lower = 0, upper = locations.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if locations[middle].timestamp < date { lower = middle + 1 }
            else { upper = middle }
        }
        return lower
    }

    private static func ordered(_ lhs: RecordedLocation, _ rhs: RecordedLocation) -> Bool {
        lhs.timestamp == rhs.timestamp ? lhs.id < rhs.id : lhs.timestamp < rhs.timestamp
    }
}
