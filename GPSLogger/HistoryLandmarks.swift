import Foundation
import CoreLocation

struct HistoryStop: Identifiable, Equatable {
    let id: Int
    let end: Int
    let arrival: Date
    let departure: Date
    let name: String?
    let symbol: String
    let color: String

    let label: String
    var accessibility: String {
        "\(name ?? "Stop"), arrived \(arrival.formatted(date: .omitted, time: .shortened))"
    }
    var title: String { name ?? "Stop" }

    init(id: Int, end: Int, arrival: Date, departure: Date, name: String?, symbol: String, color: String) {
        self.id = id
        self.end = end
        self.arrival = arrival
        self.departure = departure
        self.name = name
        self.symbol = symbol
        self.color = color
        label = name ?? "Stop · \(max(1, Int(departure.timeIntervalSince(arrival) / 60))) min"
    }
}

// A silence of at least Coverage's gap length between two stored fixes outside a stop. A phone that logs
// only when it moves goes quiet while parked, so a stop explains its own silences.
struct HistoryGap: Equatable {
    let index: Int
    let duration: TimeInterval
    var label: String { "No data · \(ReplayActivity.format(duration))" }
}

struct HistoryStopBoundary: Equatable {
    let index: Int
    let stop: HistoryStop
    let isArrival: Bool
    let event: String
    var accessibility: String {
        let clock = time.formatted(date: .omitted, time: .shortened)
        return isArrival ? "\(stop.title), arrived \(clock)" : "left \(stop.title) \(clock)"
    }
    var time: Date { isArrival ? stop.arrival : stop.departure }

    func clamped(to pointCount: Int) -> HistoryStopBoundary? {
        guard pointCount > 0 else { return nil }
        let index = min(pointCount - 1, max(0, index))
        return index == self.index ? self : HistoryStopBoundary(index: index, stop: stop, isArrival: isArrival)
    }

    init(index: Int, stop: HistoryStop, isArrival: Bool) {
        self.index = index
        self.stop = stop
        self.isArrival = isArrival
        if let name = stop.name { event = isArrival ? "Arrived at \(name)" : "Left \(name)" }
        else { event = isArrival ? "Arrived at a stop" : "Left a stop" }
    }
}

struct HistoryTimeMark: Hashable {
    enum Style: Hashable { case weekday, minute, hour }
    let index: Int
    let time: Date
    let style: Style
}

struct HistoryJourneyRow: Identifiable, Equatable {
    let start: Int
    let end: Int
    var id: String { "\(start)-\(end)-\(isStop)" }
    let startTime: Date
    let endTime: Date
    let title: String
    let symbol: String
    let color: String
    let distance: Double?
    let isStop: Bool

    var timeRange: String {
        "\(startTime.formatted(date: .omitted, time: .shortened)) – \(endTime.formatted(date: .omitted, time: .shortened))"
    }
    func detail(metric: Bool) -> String {
        guard let distance else { return timeRange }
        return "\(timeRange) · \(ReplayStatus.distanceText(distance, metric: metric))"
    }
    func contains(_ position: Double) -> Bool { position >= Double(start) && position <= Double(end) }
    func viewingText(at position: Double) -> String? { contains(position) ? "Viewing" : nil }
}

struct HistoryJourneyDay: Identifiable {
    let id: Date
    let rows: [HistoryJourneyRow]
}

// Immutable point-index metadata shared by UIKit drawing, navigation and the Go To sheet.
// Only the bounded, main-actor text cache mutates after publication.
final class HistoryLandmarks {
    static let timeMinutes = [1, 5, 15, 60, 360]
    let timestamps: [Date]
    let stops: [HistoryStop]
    let boundaries: [HistoryStopBoundary]
    let gaps: [HistoryGap]
    let rulerSpacing: HistoryRulerSpacing
    let days: [HistoryTimeMark]
    let timeMarks: [[HistoryTimeMark]]
    let journey: [HistoryJourneyDay]
    private let calendar: Calendar
    private let locale: Locale
    @MainActor private var textCache: [HistoryTimeMark: String] = [:]
    @MainActor private var formatters: [HistoryTimeMark.Style: DateFormatter] = [:]
    @MainActor var cachedMarkTextCount: Int { textCache.count }

    typealias Builder = ([RecordedLocation], ReplayTimeline, [WifiPlace], Calendar, Locale,
                         @escaping (HistoryLandmarks) -> Void) -> Void
    private static let buildQueue = DispatchQueue(label: "me.joshpatra.WhereWolf.history-landmarks", qos: .utility)

    static func build(points: [RecordedLocation], timeline: ReplayTimeline, places: [WifiPlace],
                      calendar: Calendar, locale: Locale, completion: @escaping (HistoryLandmarks) -> Void) {
        buildQueue.async {
            let landmarks = HistoryLandmarks(points: points, timeline: timeline, places: places,
                                              calendar: calendar, locale: locale)
            DispatchQueue.main.async { completion(landmarks) }
        }
    }

    init(points: [RecordedLocation], timeline: ReplayTimeline, places: [WifiPlace],
         calendar: Calendar = .current, locale: Locale = .current,
         matchDistance: Double = GLWifiPlaceMatchDistance) {
        self.calendar = calendar
        self.locale = locale
        let timestamps = points.map(\.timestamp)
        self.timestamps = timestamps
        let stops = timeline.stays.map { stay in
            let first = points[stay.start]
            // Unwrap longitude about the first fix so a stay at the dateline has a local center.
            let latitudes = points[stay.start...stay.end].map(\.latitude)
            let longitudes = points[stay.start...stay.end].map { point -> Double in
                let delta = point.longitude - first.longitude
                return first.longitude + delta - (delta / 360).rounded() * 360
            }
            var longitude = (longitudes.min()! + longitudes.max()!) / 2
            longitude -= floor((longitude + 180) / 360) * 360
            let center = CLLocation(latitude: (latitudes.min()! + latitudes.max()!) / 2, longitude: longitude)
            let nearest = places.map { place in
                (place, center.distance(from: CLLocation(latitude: place.latitude, longitude: place.longitude)))
            }.filter { $0.1 <= matchDistance }.min { $0.1 < $1.1 }?.0
            return HistoryStop(id: stay.start, end: stay.end, arrival: points[stay.start].timestamp,
                               departure: points[stay.end].timestamp, name: nearest?.name,
                               symbol: nearest?.symbol ?? "mappin", color: nearest?.color ?? "gray")
        }
        self.stops = stops
        boundaries = stops.flatMap { stop in
            [HistoryStopBoundary(index: stop.id, stop: stop, isArrival: true),
             HistoryStopBoundary(index: stop.end, stop: stop, isArrival: false)]
        }.sorted { $0.index == $1.index ? !$0.isArrival && $1.isArrival : $0.index < $1.index }
        gaps = timestamps.indices.dropFirst().compactMap { index in
            let duration = timestamps[index].timeIntervalSince(timestamps[index - 1])
            guard duration >= CoverageReport.gapThreshold else { return nil }
            let stop = Self.lowerBound(stops.count) { stops[$0].end >= index }
            if stops.indices.contains(stop), stops[stop].id < index { return nil }
            return HistoryGap(index: index, duration: duration)
        }
        rulerSpacing = HistoryRulerSpacing(timestamps: timestamps, stops: stops)
        let marks = Self.marks(timestamps: timestamps, calendar: calendar)
        days = marks.days
        timeMarks = marks.levels
        journey = Self.journey(points: points, timeline: timeline, stops: stops, calendar: calendar)
    }

    @MainActor func text(for mark: HistoryTimeMark) -> String {
        if let text = textCache[mark] { return text }
        let formatter: DateFormatter
        if let cached = formatters[mark.style] { formatter = cached }
        else {
            formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            switch mark.style {
            case .weekday: formatter.dateFormat = "EEE"
            case .minute: formatter.dateStyle = .none; formatter.timeStyle = .short
            case .hour: formatter.setLocalizedDateFormatFromTemplate("j")
            }
            formatters[mark.style] = formatter
        }
        let text = formatter.string(from: mark.time)
        if textCache.count >= 128 { textCache.removeAll(keepingCapacity: true) }
        textCache[mark] = text
        return text
    }

    private static func marks(timestamps: [Date], calendar: Calendar)
        -> (days: [HistoryTimeMark], levels: [[HistoryTimeMark]]) {
        var days: [HistoryTimeMark] = []
        var levels = [[HistoryTimeMark]](repeating: [], count: timeMinutes.count)
        guard let first = timestamps.first, let last = timestamps.last else { return (days, levels) }
        var day = calendar.startOfDay(for: first)
        var index = 0
        let zone = calendar.timeZone
        while day <= last {
            guard let nextDay = calendar.date(byAdding: .day, value: 1, to: day), nextDay > day else { break }
            var boundary = day
            // One pass over absolute minutes, split at offset changes. Calendar and time-zone
            // lookups happen per day/transition; every level shares the wall-minute arithmetic.
            while boundary < nextDay && boundary <= last {
                let offset = zone.secondsFromGMT(for: boundary)
                let transition = zone.nextDaylightSavingTimeTransition(after: boundary) ?? nextDay
                let end = min(nextDay, transition)
                while boundary < end && boundary <= last {
                    if boundary >= first {
                        while index < timestamps.count && timestamps[index] < boundary { index += 1 }
                        if index < timestamps.count {
                            if boundary == day {
                                days.append(HistoryTimeMark(index: index, time: boundary, style: .weekday))
                            }
                            let absoluteMinute = Int(floor((boundary.timeIntervalSince1970 + Double(offset)) / 60))
                            let wallMinute = (absoluteMinute % 1_440 + 1_440) % 1_440
                            for level in timeMinutes.indices where wallMinute.isMultiple(of: timeMinutes[level]) {
                                levels[level].append(HistoryTimeMark(index: index, time: boundary,
                                    style: timeMinutes[level] >= 60 ? .hour : .minute))
                            }
                        }
                    }
                    boundary = boundary.addingTimeInterval(60)
                }
            }
            day = nextDay
        }
        return (days, levels)
    }

    // A mark sits at its exact time between two fixes, so marks spread across a stop's width.
    func position(of mark: HistoryTimeMark) -> Double {
        let index = mark.index
        guard index > 0, index < timestamps.count, timestamps[index] > mark.time else { return Double(index) }
        let previous = timestamps[index - 1]
        let step = timestamps[index].timeIntervalSince(previous)
        return Double(index - 1) + min(1, max(0, mark.time.timeIntervalSince(previous) / step))
    }

    func stop(containing position: Double, pointCount: Int? = nil) -> HistoryStop? {
        let count = pointCount ?? timestamps.count
        guard position >= 0, position <= Double(count - 1) else { return nil }
        let upper = Self.lowerBound(stops.count) { Double(stops[$0].end) >= position }
        guard stops.indices.contains(upper), Double(stops[upper].id) <= position else { return nil }
        return stops[upper]
    }

    func boundary(from position: Double, direction: Int, pointCount: Int? = nil) -> HistoryStopBoundary? {
        let count = pointCount ?? timestamps.count
        guard direction != 0, count > 0 else { return nil }
        func clampedIndex(_ index: Int) -> Double { Double(min(count - 1, max(0, boundaries[index].index))) }
        let index: Int
        if direction > 0 {
            index = Self.lowerBound(boundaries.count) { clampedIndex($0) > position + 0.000001 }
        } else {
            index = Self.lowerBound(boundaries.count) { clampedIndex($0) >= position - 0.000001 } - 1
        }
        return boundaries.indices.contains(index) ? boundaries[index].clamped(to: count) : nil
    }

    func nearestPoint(to time: Date, pointCount: Int? = nil) -> Int? {
        let count = pointCount ?? timestamps.count
        guard !timestamps.isEmpty, count > 0 else { return nil }
        let next = Self.lowerBound(timestamps.count) { timestamps[$0] >= time }
        let index: Int
        if next == 0 { index = 0 }
        else if next == timestamps.count { index = next - 1 }
        else { index = timestamps[next].timeIntervalSince(time) < time.timeIntervalSince(timestamps[next - 1]) ? next : next - 1 }
        return min(count - 1, max(0, index))
    }

    func viewingRow(at position: Double) -> HistoryJourneyRow? {
        guard position >= 0, position <= Double(timestamps.count - 1) else { return nil }
        // Rows display newest first; search oldest first so the earlier row owns a shared boundary.
        let rows = journey.reversed().flatMap { $0.rows.reversed() }
        if let row = rows.first(where: { $0.isStop && $0.contains(position) })
            ?? rows.first(where: { $0.contains(position) }) { return row }
        // A day split can fall between fixes; the preceding fix owns that fractional segment.
        return rows.first { $0.contains(floor(position)) }
    }

    func window(now: Date) -> ClosedRange<Date>? {
        guard let first = timestamps.first else { return nil }
        return min(first, now)...now
    }

    func visibleGaps(in range: ClosedRange<Double>) -> ArraySlice<HistoryGap> {
        let first = Self.lowerBound(gaps.count) { Double(gaps[$0].index) >= range.lowerBound }
        let end = Self.lowerBound(gaps.count) { Double(gaps[$0].index - 1) > range.upperBound }
        return gaps[first..<max(first, end)]
    }

    func visibleStops(in range: ClosedRange<Double>) -> ArraySlice<HistoryStop> {
        let first = Self.lowerBound(stops.count) { Double(stops[$0].end) >= range.lowerBound }
        let end = Self.lowerBound(stops.count) { Double(stops[$0].id) > range.upperBound }
        return stops[first..<max(first, end)]
    }

    static func visibleMarks(_ marks: [HistoryTimeMark], in range: ClosedRange<Double>) -> ArraySlice<HistoryTimeMark> {
        let first = lowerBound(marks.count) { Double(marks[$0].index) >= range.lowerBound }
        let end = lowerBound(marks.count) { Double(marks[$0].index) > range.upperBound }
        return marks[first..<end]
    }

    // Coarsen until every adjacent boundary in the viewport is at least 60 screen points apart.
    func timeLevel(in range: ClosedRange<Double>, pointsPerBar: Double, spacing: Double) -> Int {
        let map = rulerSpacing.scaled(pointsPerBar)
        for level in timeMarks.indices {
            let marks = Self.visibleMarks(timeMarks[level], in: range)
            if zip(marks, marks.dropFirst()).allSatisfy({
                map.screenDistance(from: position(of: $0.0), to: position(of: $0.1), spacing: spacing) >= 60
            }) { return level }
        }
        return timeMarks.count - 1
    }

    static func lowerBound(_ count: Int, predicate: (Int) -> Bool) -> Int {
        var low = 0, high = count
        while low < high {
            let middle = (low + high) / 2
            if predicate(middle) { high = middle } else { low = middle + 1 }
        }
        return low
    }

    private static func journey(points: [RecordedLocation], timeline: ReplayTimeline,
                                stops: [HistoryStop], calendar: Calendar) -> [HistoryJourneyDay] {
        guard !points.isEmpty else { return [] }
        struct Span {
            let start: Int
            let end: Int
            let stop: HistoryStop?
        }
        var spans: [Span] = []
        var cursor = 0
        for stop in stops {
            if cursor < stop.id { spans.append(Span(start: cursor, end: stop.id, stop: nil)) }
            spans.append(Span(start: stop.id, end: stop.end, stop: stop))
            cursor = stop.end
        }
        if cursor < points.count - 1 || spans.isEmpty {
            spans.append(Span(start: cursor, end: points.count - 1, stop: nil))
        }
        var grouped: [Date: [HistoryJourneyRow]] = [:]
        for span in spans {
            var start = span.start
            while start <= span.end {
                let day = calendar.startOfDay(for: points[start].timestamp)
                let nextDay = calendar.date(byAdding: .day, value: 1, to: day)!
                let next = lowerBound(points.count) { points[$0].timestamp >= nextDay }
                let end = min(span.end, max(start, next - 1))
                let movement = span.stop == nil ? Self.movement(timeline: timeline, range: start...end) : nil
                let distance = span.stop == nil ? timeline.distance(from: start > span.start ? start - 1 : start, through: end) : nil
                grouped[day, default: []].append(HistoryJourneyRow(
                    start: start, end: end, startTime: points[start].timestamp, endTime: points[end].timestamp,
                    title: span.stop?.title ?? movement?.title ?? "Moving",
                    symbol: span.stop?.symbol ?? movement?.symbol ?? ReplayActivity.moving.symbol,
                    color: span.stop?.color ?? movement?.color ?? "gray", distance: distance, isStop: span.stop != nil))
                start = end + 1
            }
        }
        return grouped.keys.sorted(by: >).map { HistoryJourneyDay(id: $0, rows: grouped[$0]!.reversed()) }
    }

    private static func movement(timeline: ReplayTimeline,
                                 range: ClosedRange<Int>) -> (title: String, symbol: String, color: String) {
        let choices: [(ReplayActivity, String, String)] = [(.flying, "Flight", "purple"), (.driving, "Drive", "blue"),
                                                          (.cycling, "Cycle", "orange"), (.walking, "Walk", "green"),
                                                          (.moving, "Moving", "gray")]
        var counts = [Int](repeating: 0, count: choices.count)
        var distances = [Double](repeating: 0, count: choices.count)
        for index in range {
            let choice = choices.firstIndex { $0.0 == timeline.inferredActivity(at: index) } ?? choices.count - 1
            counts[choice] += 1
            // Corrected distance, so a stray fix far off a drive, which travels nowhere, cannot make it a flight.
            if index > 0 { distances[choice] += timeline.distance(from: index - 1, through: index) }
        }
        // Name the activity that covered the most ground, but call it a flight once flying covers a quarter.
        let total = distances.reduce(0, +)
        let weights = total > 0 ? distances : counts.map(Double.init)
        let winner = total > 0 && distances[0] * 4 >= total ? 0
            : weights.indices.dropFirst().max { weights[$0] < weights[$1] }!
        return (choices[winner].1, choices[winner].0.symbol, choices[winner].2)
    }
}

// The ruler shows time. Each step between moving fixes is as wide as its duration, in slots of the typical
// interval between them and never under one slot, so a bar covers the same time wherever the phone was
// moving and every fix stays reachable. A stop, or a silence of 5 minutes or more, is one stretch of its
// whole length with no slots of its own. Close up a stretch keeps 4 bars for 5 minutes and 1.5 more for each
// doubling, so even a night at home leaves room on the ruler; zoomed out it counts as 5 minutes times the
// square root of its length in 5-minute units, so stops stay smaller than the drives between them.
final class HistoryRulerSpacing: Equatable {
    static func == (lhs: HistoryRulerSpacing, rhs: HistoryRulerSpacing) -> Bool { lhs === rhs }

    struct Stretch: Equatable {
        let start: Int
        let end: Int
        let startTime: TimeInterval
        let duration: TimeInterval
        let nearBars: Double
        let farSlots: Double

        func bars(pointsPerBar: Double) -> Double { min(nearBars, farSlots / pointsPerBar) }
    }

    static let none = HistoryRulerSpacing()
    // Seconds per slot: the median interval between fixes outside stops.
    let slotDuration: TimeInterval?
    let stretches: [Stretch]
    private let times: [TimeInterval]
    // Slots before each fix from steps that keep their proportion at every scale, then Live's slot.
    private let slotPrefix: [Double]
    private let uniform: Bool

    private init() {
        slotDuration = nil
        stretches = []
        times = []
        slotPrefix = [0]
        uniform = true
    }

    init(timestamps: [Date], stops: [HistoryStop]) {
        let times = timestamps.map(\.timeIntervalSince1970)
        var inStop = [Bool](repeating: false, count: times.count)
        for stop in stops where stop.end > stop.id {
            for index in (stop.id + 1)...stop.end { inStop[index] = true }
        }
        let moving = times.indices.dropFirst().filter { !inStop[$0] }
            .map { times[$0] - times[$0 - 1] }.filter { $0 > 0 }.sorted()
        let slot = moving.isEmpty ? nil : moving[moving.count / 2]
        var stretches = stops.filter { $0.end > $0.id }
            .map { Self.stretch(start: $0.id, end: $0.end, times: times, slot: slot) }
        var prefix = [0.0]
        prefix.reserveCapacity(times.count + 1)
        for index in times.indices.dropFirst() {
            var width = 0.0
            if !inStop[index] {
                if times[index] - times[index - 1] >= 300 {
                    stretches.append(Self.stretch(start: index - 1, end: index, times: times, slot: slot))
                } else {
                    width = max(1, slot.map { (times[index] - times[index - 1]) / $0 } ?? 1)
                }
            }
            prefix.append(prefix.last! + width)
        }
        if !times.isEmpty { prefix.append(prefix.last! + 1) }
        self.times = times
        slotPrefix = prefix
        self.stretches = stretches.sorted { $0.start < $1.start }
        slotDuration = slot
        uniform = stretches.isEmpty && prefix.indices.allSatisfy { prefix[$0] == Double($0) }
    }

    private static func stretch(start: Int, end: Int, times: [TimeInterval], slot: TimeInterval?) -> Stretch {
        let duration = times[end] - times[start]
        let length = max(1, duration / 300)
        let far = slot.map { 300 / $0 * length.squareRoot() } ?? Double(end - start)
        return Stretch(start: start, end: end, startTime: times[start], duration: duration,
                       nearBars: 4 + 1.5 * log2(length), farSlots: max(1, far))
    }

    func scaled(_ pointsPerBar: Double) -> Scaled { Scaled(spacing: self, pointsPerBar: pointsPerBar) }

    // Bars from the oldest fix to Live.
    func totalBars(pointCount: Int, pointsPerBar: Double) -> Double {
        scaled(pointsPerBar).bars(to: Double(pointCount))
    }

    // Before the oldest fix and past Live, a fix is one slot.
    fileprivate func slots(to index: Double) -> Double {
        let count = slotPrefix.count - 1
        guard count > 0, index > 0 else { return index }
        if index >= Double(count) { return slotPrefix[count] + index - Double(count) }
        let lower = Int(index.rounded(.down))
        return slotPrefix[lower] + (slotPrefix[lower + 1] - slotPrefix[lower]) * (index - Double(lower))
    }

    // The newest point index at a slot count; a stretch adds no slots, so its end is where a tick lands.
    fileprivate func index(atSlots value: Double) -> Double {
        let count = slotPrefix.count - 1
        guard count > 0, value > 0 else { return value }
        if value >= slotPrefix[count] { return Double(count) + value - slotPrefix[count] }
        let step = HistoryLandmarks.lowerBound(count) { slotPrefix[$0 + 1] > value }
        let low = slotPrefix[step], high = slotPrefix[step + 1]
        return Double(step) + (high > low ? (value - low) / (high - low) : 0)
    }

    // How far a fractional point index is through a stretch's time.
    fileprivate func fraction(of stretch: Stretch, at index: Double) -> Double {
        guard stretch.duration > 0 else { return index >= Double(stretch.end) ? 1 : 0 }
        let lower = min(times.count - 2, max(0, Int(index.rounded(.down))))
        // Relative to the stretch's start: absolute epoch seconds would cost precision.
        let elapsed = times[lower] - stretch.startTime + (times[lower + 1] - times[lower]) * (index - Double(lower))
        return min(1, max(0, elapsed / stretch.duration))
    }

    // Converts between point indices, counted from the oldest fix, and bars at one scale.
    struct Scaled {
        let pointsPerBar: Double
        private let spacing: HistoryRulerSpacing
        private let widths: [Double]
        private let prefix: [Double]
        var isLinear: Bool { spacing.uniform }

        fileprivate init(spacing: HistoryRulerSpacing, pointsPerBar: Double) {
            let pointsPerBar = pointsPerBar.isFinite ? max(0.000_001, pointsPerBar) : 1
            self.pointsPerBar = pointsPerBar
            self.spacing = spacing
            widths = spacing.stretches.map { $0.bars(pointsPerBar: pointsPerBar) }
            var prefix = [0.0]
            prefix.reserveCapacity(widths.count + 1)
            for width in widths { prefix.append(prefix.last! + width) }
            self.prefix = prefix
        }

        func bars(to index: Double) -> Double {
            guard !isLinear else { return index / pointsPerBar }
            let stretches = spacing.stretches
            let next = HistoryLandmarks.lowerBound(stretches.count) { Double(stretches[$0].end) > index }
            var bars = spacing.slots(to: index) / pointsPerBar + prefix[next]
            if next < stretches.count, Double(stretches[next].start) < index {
                bars += widths[next] * spacing.fraction(of: stretches[next], at: index)
            }
            return bars
        }

        // Bars are linear within each step, so the inverse searches steps and solves within one.
        func index(atBars bars: Double) -> Double {
            guard !isLinear else { return bars * pointsPerBar }
            let count = spacing.slotPrefix.count - 1
            guard count > 0, bars > 0 else { return bars * pointsPerBar }
            let total = self.bars(to: Double(count))
            guard bars < total else { return Double(count) + (bars - total) * pointsPerBar }
            let step = HistoryLandmarks.lowerBound(count) { self.bars(to: Double($0 + 1)) > bars }
            let low = self.bars(to: Double(step)), high = self.bars(to: Double(step + 1))
            return Double(step) + (high > low ? min(1, max(0, (bars - low) / (high - low))) : 0)
        }

        // Ticks mark slots, which move with the data as the scale changes and leave stretches clear.
        func slots(to index: Double) -> Double { isLinear ? index : spacing.slots(to: index) }
        func index(atSlots slots: Double) -> Double { isLinear ? slots : spacing.index(atSlots: slots) }

        // Screen points between two point indices.
        func screenDistance(from start: Double, to end: Double, spacing: Double) -> Double {
            isLinear ? (end - start) * spacing / pointsPerBar : (bars(to: end) - bars(to: start)) * spacing
        }

        // The ruler position, counted in fixes back from Live, that a sideways movement reaches.
        func position(_ position: Double, movedBy translation: Double, spacing: Double, pointCount: Int) -> Double {
            guard !isLinear else { return position + translation * pointsPerBar / spacing }
            let count = Double(pointCount)
            return count - index(atBars: bars(to: count - position) - translation / spacing)
        }
    }
}

struct HistoryRulerLabelLayout {
    enum Priority: Int { case day, stop, gap, time }
    struct Candidate {
        let id: Int
        let priority: Priority
        let frame: CGRect
        var symbolFrame: CGRect? = nil
    }
    struct Placement {
        let id: Int
        let frame: CGRect
        let symbolOnly: Bool
    }

    static func resolve(_ candidates: [Candidate]) -> [Placement] {
        var result: [Placement] = []
        for candidate in candidates.sorted(by: {
            $0.priority.rawValue == $1.priority.rawValue ? $0.id < $1.id : $0.priority.rawValue < $1.priority.rawValue
        }) {
            func fits(_ frame: CGRect) -> Bool {
                !result.contains { $0.frame.insetBy(dx: -3, dy: 0).intersects(frame) }
            }
            if fits(candidate.frame) {
                result.append(Placement(id: candidate.id, frame: candidate.frame, symbolOnly: false))
            } else if let frame = candidate.symbolFrame, fits(frame) {
                result.append(Placement(id: candidate.id, frame: frame, symbolOnly: true))
            }
        }
        return result
    }
}

struct HistoryStopSnap {
    private(set) var boundary: HistoryStopBoundary?
    private var fingerAtSnap: Double = 0
    private var releasedIndex: Int?

    mutating func reset() { self = Self() }

    mutating func move(position: Double, translation: Double, finger: Double, pointsPerBar: Double,
                       spacing: Double, pointCount: Int, landmarks: HistoryLandmarks) -> Double {
        let map = landmarks.rulerSpacing.scaled(pointsPerBar)
        let proposed = map.position(position, movedBy: translation, spacing: spacing, pointCount: pointCount)
        guard pointsPerBar > 1, pointCount > 0 else { reset(); return proposed }
        boundary = boundary?.clamped(to: pointCount)
        if let boundary {
            guard abs(finger - fingerAtSnap) > 10 else { return Double(pointCount - boundary.index) }
            // Rebase at the current finger: discard the escape distance, then continue 1:1.
            self.boundary = nil
            releasedIndex = boundary.index
            return position
        }
        let index = Double(pointCount) - proposed
        func distance(to target: Int) -> Double {
            abs(map.screenDistance(from: index, to: Double(target), spacing: spacing))
        }
        if let releasedIndex, distance(to: releasedIndex) > 6 {
            self.releasedIndex = nil
        }
        let next = HistoryLandmarks.lowerBound(landmarks.boundaries.count) {
            Double(min(pointCount - 1, max(0, landmarks.boundaries[$0].index))) >= index
        }
        let nearby = [next - 1, next].filter { landmarks.boundaries.indices.contains($0) }
            .compactMap { landmarks.boundaries[$0].clamped(to: pointCount) }
        if let target = nearby.filter({ $0.index != releasedIndex }).min(by: {
            distance(to: $0.index) < distance(to: $1.index)
        }), distance(to: target.index) <= 6 {
            boundary = target
            fingerAtSnap = finger
            return Double(pointCount - target.index)
        }
        return proposed
    }
}
