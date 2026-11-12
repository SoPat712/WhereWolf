import Foundation

struct HistoryDaySummary: Identifiable, Equatable {
    enum State: Equatable { case phone, server, notDownloaded }

    let day: Date
    let distance: Double?
    let pointCount: Int
    let state: State
    var id: Date { day }
}

// Cached reads only. Days are starts of day in the display calendar; intervals are half-open.
// firstDay includes uncached history. Return one entry per day; omit known empty days.
// notDownloaded means point detail is unavailable, even when totals are known.
// Distance is corrected meters, or nil when the total is unknown.
protocol HistoryDaySummaryProvider {
    var firstDay: Date? { get }
    func summaries(in interval: DateInterval) -> [HistoryDaySummary]
}

// Built and replaced with HistoryLandmarks on its utility queue. Shares the journey's corrected
// distance, including its cross-midnight attribution; shared stop/movement endpoints count once.
struct PhoneHistoryDaySummaryProvider: HistoryDaySummaryProvider {
    private let days: [HistoryDaySummary]
    var firstDay: Date? { days.first?.day }

    init(timestamps: [Date], journey: [HistoryJourneyDay], calendar: Calendar) {
        days = journey.sorted { $0.id < $1.id }.map { day in
            let end = calendar.date(byAdding: .day, value: 1, to: day.id)!
            let first = HistoryLandmarks.lowerBound(timestamps.count) { timestamps[$0] >= day.id }
            let next = HistoryLandmarks.lowerBound(timestamps.count) { timestamps[$0] >= end }
            return HistoryDaySummary(day: day.id, distance: day.rows.compactMap(\.distance).reduce(0, +),
                                     pointCount: next - first, state: .phone)
        }
    }

    func summaries(in interval: DateInterval) -> [HistoryDaySummary] {
        let first = HistoryLandmarks.lowerBound(days.count) { days[$0].day >= interval.start }
        let end = HistoryLandmarks.lowerBound(days.count) { days[$0].day >= interval.end }
        return Array(days[first..<end])
    }
}

struct CombinedHistoryDaySummaryProvider: HistoryDaySummaryProvider {
    let phone: PhoneHistoryDaySummaryProvider
    let phoneWindow: DateInterval
    let firstServerDay: Date?
    let calendar: Calendar
    private let server: [Date: ServerHistoryDay]
    private let loadedDays: Set<Date>

    init(phone: PhoneHistoryDaySummaryProvider, phoneWindow: DateInterval, snapshot: ServerHistorySnapshot) {
        self.phone = phone
        self.phoneWindow = phoneWindow
        firstServerDay = snapshot.firstDay
        calendar = snapshot.calendar
        server = Dictionary(snapshot.days.map { ($0.day, $0) }, uniquingKeysWith: { _, new in new })
        loadedDays = Set(snapshot.points.keys)
    }

    var firstDay: Date? { [phone.firstDay, firstServerDay].compactMap { $0 }.min() }

    func summaries(in interval: DateInterval) -> [HistoryDaySummary] {
        let local = phone.summaries(in: interval)
        guard let firstServerDay else { return local }
        let localDays = Dictionary(local.map { ($0.day, $0) }, uniquingKeysWith: { _, new in new })
        var values: [HistoryDaySummary] = []
        var day = max(firstServerDay, calendar.startOfDay(for: interval.start))
        while day < interval.end, day <= phoneWindow.end {
            guard let next = calendar.date(byAdding: .day, value: 1, to: day), next > day else { break }
            defer { day = next }
            guard day >= interval.start else { continue }
            // The partial boundary day belongs to the phone too. An empty phone day
            // must not resurrect server totals inside the phone's retention window.
            if next > phoneWindow.start || localDays[day] != nil {
                if let value = localDays[day] { values.append(value) }
            } else if let value = server[day] {
                guard value.pointCount > 0 else { continue }
                values.append(.init(day: day, distance: value.distance, pointCount: value.pointCount,
                                    state: loadedDays.contains(day) ? .server : .notDownloaded))
            } else {
                values.append(.init(day: day, distance: nil, pointCount: 0, state: .notDownloaded))
            }
        }
        // Phone/queued days can precede the server's first recorded day.
        values += local.filter { $0.day < firstServerDay }
        return values.sorted { $0.day < $1.day }
    }
}
