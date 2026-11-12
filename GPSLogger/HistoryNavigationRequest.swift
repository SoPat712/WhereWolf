import Foundation

struct HistoryNavigationRequest: Equatable, Identifiable {
    let id = UUID()
    let date: Date
    let interval: DateInterval?

    static func moment(_ date: Date) -> Self { Self(date: date, interval: nil) }

    static func month(year: Int, month: Int, calendar: Calendar = Calendar(identifier: .gregorian)) -> Self? {
        guard (1970...9998).contains(year), (1...12).contains(month),
              let start = calendar.date(from: DateComponents(year: year, month: month, day: 1)),
              let interval = calendar.dateInterval(of: .month, for: start) else { return nil }
        return Self(date: start, interval: interval)
    }
}
