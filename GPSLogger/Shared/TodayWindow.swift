import Foundation

struct TodayWindow: Equatable {
    let start: Date
    let end: Date
    let timeZoneIdentifier: String

    init(containing date: Date, calendar: Calendar = .current) {
        start = calendar.startOfDay(for: date)
        end = calendar.date(byAdding: .day, value: 1, to: start)!
        timeZoneIdentifier = calendar.timeZone.identifier
    }

    func contains(_ date: Date) -> Bool {
        date >= start && date < end
    }
}
