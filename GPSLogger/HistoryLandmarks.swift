import Foundation
import CoreLocation

// Eleven immutable prefix sums cover the dial. Building them with the landmarks keeps powers and
// collection walks off the gesture path; a frame interpolates two scalars, or binary-searches them.
final class HistoryRulerAxis {
    static let weightSteps = 10
    let count: Int
    let interval: TimeInterval?
    private let cumulative: [[Double]]

    init(timestamps: [Date]) {
        count = timestamps.count
        let span = timestamps.last.flatMap { last in timestamps.first.map { last.timeIntervalSince($0) } } ?? 0
        let mean = count > 1 ? span / Double(count - 1) : 0
        interval = mean.isFinite && mean > 0 ? mean : nil
        guard count > 1, let interval else { cumulative = []; return }
        let intervals = zip(timestamps, timestamps.dropFirst()).map { first, last in
            let value = last.timeIntervalSince(first)
            return value.isFinite && value >= 0 ? max(0.000_001, value) / interval : 1
        }
        cumulative = (0...Self.weightSteps).map { step in
            if step == 0 { return (0..<timestamps.count).map(Double.init) }
            let weight = Double(step) / Double(Self.weightSteps)
            var sum = 0.0
            var prefix = [0.0]
            prefix.reserveCapacity(timestamps.count)
            for interval in intervals { sum += pow(interval, weight); prefix.append(sum) }
            let normalization = Double(timestamps.count - 1) / sum
            for index in prefix.indices { prefix[index] *= normalization }
            prefix[prefix.count - 1] = Double(timestamps.count - 1)
            return prefix
        }
    }

    // The approved sketch's beta is 1-w. Keep its smoothstep in log time, without quantizing gestures.
    static func weight(secondsPerBar: TimeInterval) -> Double {
        guard secondsPerBar > 300 else { return 0 }
        let t = min(1, log(secondsPerBar / 300) / log(86_400.0 / 300))
        return t * t * (3 - 2 * t)
    }

    func mapping(pointsPerBar: Double, pointCount: Int, interval: TimeInterval? = nil) -> Mapping {
        let interval = interval ?? self.interval ?? 0
        let weight = Self.weight(secondsPerBar: interval * pointsPerBar)
        // Even a sparse archive's Every point remains literal. Open its dial smoothly over the first
        // octave when the average interval already exceeds five minutes; ordinary phone history uses 1.
        let opening = interval > 300 ? min(1, max(0, log(max(1, pointsPerBar)) / log(2))) : 1
        return mapping(weight: weight * opening * opening * (3 - 2 * opening), pointCount: pointCount)
    }

    func mapping(weight: Double, pointCount: Int) -> Mapping {
        Mapping(axis: self, weight: weight, pointCount: pointCount)
    }

    struct Mapping: Equatable {
        let axis: HistoryRulerAxis?
        let weight: Double
        let pointCount: Int
        private let lower: Int
        private let upper: Int
        private let fraction: Double

        init(axis: HistoryRulerAxis? = nil, weight: Double = 0, pointCount: Int) {
            self.axis = axis
            self.weight = axis?.cumulative.isEmpty == false && weight.isFinite ? min(1, max(0, weight)) : 0
            self.pointCount = max(0, pointCount)
            let dial = self.weight * Double(HistoryRulerAxis.weightSteps)
            lower = Int(floor(dial))
            upper = min(HistoryRulerAxis.weightSteps, lower + 1)
            fraction = dial - Double(lower)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.weight == rhs.weight && lhs.pointCount == rhs.pointCount && (lhs.weight == 0 || lhs.axis === rhs.axis)
        }

        private func rawPrefix(at index: Int) -> Double {
            guard weight > 0, let axis, index < axis.count else { return Double(index) }
            let a = axis.cumulative[lower][index]
            return a + (axis.cumulative[upper][index] - a) * fraction
        }

        private func prefix(at index: Int) -> Double {
            let last = min(pointCount, axis?.count ?? 0) - 1
            if let axis, last > 0, pointCount < axis.count {
                return rawPrefix(at: index) * Double(last) / rawPrefix(at: last)
            }
            return rawPrefix(at: index)
        }

        func coordinate(at index: Double) -> Double {
            // Extend pending appends and the last point-to-Live interval uniformly. Live is always count.
            guard weight > 0, let axis, index > 0, index < Double(min(pointCount, axis.count) - 1) else { return index }
            let lo = Int(floor(index)), t = index - floor(index)
            return prefix(at: lo) + (prefix(at: lo + 1) - prefix(at: lo)) * t
        }

        func index(at coordinate: Double) -> Double {
            guard weight > 0, let axis, coordinate > 0,
                  coordinate < Double(min(pointCount, axis.count) - 1) else { return coordinate }
            var lo = 0, hi = min(pointCount, axis.count) - 1
            while hi - lo > 1 {
                let mid = (lo + hi) / 2
                if prefix(at: mid) <= coordinate { lo = mid } else { hi = mid }
            }
            let a = prefix(at: lo), b = prefix(at: hi)
            return Double(lo) + (coordinate - a) / max(Double.leastNormalMagnitude, b - a)
        }

        func reverseCoordinate(at position: Double) -> Double {
            weight == 0 ? position : Double(pointCount) - coordinate(at: Double(pointCount) - position)
        }

        func reversePosition(at coordinate: Double) -> Double {
            weight == 0 ? coordinate : Double(pointCount) - index(at: Double(pointCount) - coordinate)
        }
    }
}

enum HistoryRulerFrame: String, CaseIterable, Hashable {
    case day = "Day", week = "Week", month = "Month", year = "Year", all = "All"

    func interval(containing date: Date, calendar: Calendar) -> DateInterval? {
        switch self {
        case .day: return calendar.dateInterval(of: .day, for: date)
        case .week:
            // The sketch uses Monday weeks, independently of the first weekday in the locale.
            var calendar = calendar
            calendar.firstWeekday = 2
            return calendar.dateInterval(of: .weekOfYear, for: date)
        case .month: return calendar.dateInterval(of: .month, for: date)
        case .year: return calendar.dateInterval(of: .year, for: date)
        case .all: return nil
        }
    }
}

struct HistoryRulerStretch: Equatable {
    var range: ClosedRange<Double>
    let title: String
    var timeRange: ClosedRange<Date>? = nil
    var frame: HistoryRulerFrame? = nil
    var accessibility: String {
        "Fit \(title)" + (timeRange.map { ", \($0.lowerBound.formatted(date: .abbreviated, time: .shortened))" } ?? "")
    }
}

struct HistoryRulerHitTarget: Equatable {
    let frame: CGRect
    let stretch: HistoryRulerStretch
    var priority = 0

    var touchFrame: CGRect {
        frame.insetBy(dx: -max(0, 44 - frame.width) / 2, dy: -max(0, 44 - frame.height) / 2)
    }

    func touchFrame(in bounds: CGRect) -> CGRect {
        var target = touchFrame
        target.origin.x = max(bounds.minX, min(bounds.maxX - target.width, target.minX))
        target.origin.y = max(bounds.minY, min(bounds.maxY - target.height, target.minY))
        return target.intersection(bounds)
    }

    static func pick(at point: CGPoint, in targets: [Self], bounds: CGRect? = nil) -> Self? {
        targets.filter { target in
            (bounds.map { target.touchFrame(in: $0) } ?? target.touchFrame).contains(point)
        }.min {
            if $0.priority != $1.priority { return $0.priority < $1.priority }
            return hypot($0.frame.midX - point.x, $0.frame.midY - point.y)
                < hypot($1.frame.midX - point.x, $1.frame.midY - point.y)
        }
    }
}

enum HistoryRulerFraming {
    struct Fit {
        let step: Double
        let position: Double
        let stretch: HistoryRulerStretch
    }

    static func nearestFrame(to step: Double, fits: [(HistoryRulerFrame, Fit)]) -> HistoryRulerFrame? {
        fits.min { abs(log(max(1, $0.1.step) / max(1, step)))
            < abs(log(max(1, $1.1.step) / max(1, step))) }?.0
    }

    static func index(at time: Date, timestamps: [Date]) -> Double {
        index(at: time, pointCount: timestamps.count, timestampAt: { timestamps[$0] })
    }

    static func index(at time: Date, pointCount: Int, timestampAt: (Int) -> Date) -> Double {
        guard pointCount > 0 else { return 0 }
        let next = HistoryLandmarks.lowerBound(pointCount) { timestampAt($0) >= time }
        guard next > 0 else { return 0 }
        guard next < pointCount else { return Double(pointCount - 1) }
        let duration = timestampAt(next).timeIntervalSince(timestampAt(next - 1))
        return Double(next - 1) + (duration > 0 ? time.timeIntervalSince(timestampAt(next - 1)) / duration : 1)
    }

    static func fit(_ stretch: HistoryRulerStretch, axis: HistoryRulerAxis,
                    detents: HistoryRulerCoarseDrag.Detents, width: CGFloat, pointCount: Int? = nil,
                    interval: TimeInterval? = nil) -> Fit {
        let count = pointCount ?? axis.count
        let last = Double(max(0, count - 1))
        let lo = min(last, max(0, stretch.range.lowerBound))
        let hi = min(last, max(lo, stretch.range.upperBound))
        let target = max(1, Double(width) * 0.92)
        func screenWidth(at step: Double) -> Double {
            let mapping = axis.mapping(pointsPerBar: step, pointCount: count, interval: interval)
            let spacing = HistoryRulerCoarseDrag.scale(step: step, coarsest: detents.steps[0]).spacing
            return (mapping.coordinate(at: hi) - mapping.coordinate(at: lo)) / step * Double(spacing)
        }
        // A sparse silence can grow before it shrinks as Blend opens. Search the bounded dial first,
        // then refine its last descending crossing; a binary search from Every point misses that frame.
        let end = log(detents.steps[0])
        let samples = 64
        var best = 0.0, error = abs(log(max(0.000_001, screenWidth(at: 1)) / target))
        var previous = screenWidth(at: 1)
        var crossing: (lower: Double, upper: Double, descending: Bool)?
        for sample in 1...samples {
            let value = end * Double(sample) / Double(samples)
            let width = screenWidth(at: exp(value))
            let nextError = abs(log(max(0.000_001, width) / target))
            if nextError < error { best = value; error = nextError }
            if previous >= target && width <= target {
                crossing = (end * Double(sample - 1) / Double(samples), value, true)
            } else if previous <= target && width >= target && crossing == nil {
                crossing = (end * Double(sample - 1) / Double(samples), value, false)
            }
            previous = width
        }
        if var crossing {
            for _ in 0..<40 {
                let middle = (crossing.lower + crossing.upper) / 2
                let tooWide = screenWidth(at: exp(middle)) > target
                if tooWide == crossing.descending { crossing.lower = middle } else { crossing.upper = middle }
            }
            best = crossing.descending ? crossing.upper : crossing.lower
        }
        let step = exp(best)
        let mapping = axis.mapping(pointsPerBar: step, pointCount: count, interval: interval)
        let midpoint = (mapping.coordinate(at: lo) + mapping.coordinate(at: hi)) / 2
        var stretch = stretch
        stretch.range = lo...hi
        return Fit(step: step, position: Double(count) - mapping.index(at: midpoint), stretch: stretch)
    }
}

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
    var position: Double? = nil
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
    let rulerAxis: HistoryRulerAxis
    let rulerFrames: [HistoryRulerFrame]
    private let rulerDayStretches: [Date: HistoryRulerStretch]
    let stops: [HistoryStop]
    let boundaries: [HistoryStopBoundary]
    let gaps: [HistoryGap]
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
        rulerAxis = HistoryRulerAxis(timestamps: timestamps)
        if let first = timestamps.first, let last = timestamps.last, timestamps.count > 1 {
            let days = (calendar.dateComponents([.day], from: calendar.startOfDay(for: first),
                                               to: calendar.startOfDay(for: last)).day ?? 0) + 1
            rulerFrames = HistoryRulerFrame.allCases.filter { frame in
                guard frame != .all else { return true }
                guard let interval = frame.interval(containing: last, calendar: calendar) else { return false }
                let needed = calendar.dateComponents([.day], from: interval.start, to: interval.end).day ?? 1
                return days >= needed
            }
        } else { rulerFrames = [] }
        let detected = timeline.stays.map { stay in
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
        // A fix that strays out of the box splits one visit in two; show it once. An unnamed pair must touch,
        // so two places across town minutes apart stay separate.
        var stops: [HistoryStop] = []
        for stop in detected {
            if let previous = stops.last, previous.name == stop.name,
               stop.arrival.timeIntervalSince(previous.departure) < CoverageReport.gapThreshold,
               stop.name != nil || stop.id - previous.end <= 1 {
                stops[stops.count - 1] = HistoryStop(id: previous.id, end: stop.end, arrival: previous.arrival,
                    departure: stop.departure, name: previous.name, symbol: previous.symbol, color: previous.color)
            } else {
                stops.append(stop)
            }
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
        let marks = Self.marks(timestamps: timestamps, calendar: calendar)
        days = marks.days
        rulerDayStretches = Dictionary(uniqueKeysWithValues: marks.days.compactMap { mark -> (Date, HistoryRulerStretch)? in
            guard let day = calendar.dateInterval(of: .day, for: mark.time) else { return nil }
            let start = HistoryRulerFraming.index(at: day.start, timestamps: timestamps)
            let end = HistoryRulerFraming.index(at: day.end, timestamps: timestamps)
            let range = start...end
            return (mark.time, HistoryRulerStretch(range: range, title: "Day", timeRange: day.start...day.end, frame: .day))
        })
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
                            let position: Double
                            if index > 0, timestamps[index] > timestamps[index - 1] {
                                position = Double(index - 1) + boundary.timeIntervalSince(timestamps[index - 1])
                                    / timestamps[index].timeIntervalSince(timestamps[index - 1])
                            } else { position = Double(index) }
                            if boundary == day {
                                days.append(HistoryTimeMark(index: index, time: boundary, style: .weekday, position: position))
                            }
                            let absoluteMinute = Int(floor((boundary.timeIntervalSince1970 + Double(offset)) / 60))
                            let wallMinute = (absoluteMinute % 1_440 + 1_440) % 1_440
                            for level in timeMinutes.indices where wallMinute.isMultiple(of: timeMinutes[level]) {
                                levels[level].append(HistoryTimeMark(index: index, time: boundary,
                                    style: timeMinutes[level] >= 60 ? .hour : .minute, position: position))
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

    func stretch(frame: HistoryRulerFrame, at index: Double) -> HistoryRulerStretch? {
        guard timestamps.count > 1 else { return nil }
        let index = min(Double(timestamps.count - 1), max(0, index))
        let lo = Int(floor(index)), hi = min(timestamps.count - 1, lo + 1)
        let time = timestamps[lo].addingTimeInterval(timestamps[hi].timeIntervalSince(timestamps[lo]) * (index - Double(lo)))
        return stretch(frame: frame, at: time)
    }

    func stretch(frame: HistoryRulerFrame, at time: Date) -> HistoryRulerStretch? {
        if frame == .day, let cached = rulerDayStretches[time] { return cached }
        guard let first = timestamps.first, let last = timestamps.last, timestamps.count > 1 else { return nil }
        let interval = frame.interval(containing: time, calendar: calendar) ?? DateInterval(start: first, end: last)
        let start = HistoryRulerFraming.index(at: max(first, interval.start), timestamps: timestamps)
        let end = HistoryRulerFraming.index(at: min(last, interval.end), timestamps: timestamps)
        return HistoryRulerStretch(range: start...end, title: frame.rawValue,
                                   timeRange: interval.start...interval.end, frame: frame)
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

    func markPosition(_ mark: HistoryTimeMark, mapping: HistoryRulerAxis.Mapping?) -> Double {
        let weight = mapping?.weight ?? 0
        guard weight > 0 else { return Double(mark.index) }
        let fractional = mark.position ?? HistoryRulerFraming.index(at: mark.time, timestamps: timestamps)
        return Double(mark.index) + (fractional - Double(mark.index)) * weight
    }

    // Coarsen until every adjacent boundary in the viewport is at least 60 screen points apart.
    func timeLevel(in range: ClosedRange<Double>, pointsPerBar: Double, spacing: Double,
                   mapping: HistoryRulerAxis.Mapping? = nil) -> Int {
        for level in timeMarks.indices {
            let marks = Self.visibleMarks(timeMarks[level], in: range)
            if zip(marks, marks.dropFirst()).allSatisfy({
                let a = markPosition($0.0, mapping: mapping), b = markPosition($0.1, mapping: mapping)
                let distance = mapping.map { $0.coordinate(at: b) - $0.coordinate(at: a) } ?? (b - a)
                return distance * spacing / pointsPerBar >= 60
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
                       spacing: Double, pointCount: Int, landmarks: HistoryLandmarks,
                       mapping: HistoryRulerAxis.Mapping? = nil) -> Double {
        guard pointsPerBar > 1, pointCount > 0 else { reset(); return position + translation * pointsPerBar / spacing }
        boundary = boundary?.clamped(to: pointCount)
        if let boundary {
            guard abs(finger - fingerAtSnap) > 10 else { return Double(pointCount - boundary.index) }
            // Rebase at the current finger: discard the escape distance, then continue 1:1.
            self.boundary = nil
            releasedIndex = boundary.index
            return position
        }
        let mapping = mapping.flatMap { $0.weight > 0 ? $0 : nil }
        let axisPosition = mapping?.reverseCoordinate(at: position) ?? position
        let proposedCoordinate = axisPosition + translation * pointsPerBar / spacing
        let proposed = mapping?.reversePosition(at: proposedCoordinate) ?? proposedCoordinate
        let index = Double(pointCount) - proposed
        func distance(to boundary: Int) -> Double {
            guard let mapping else { return abs(Double(boundary) - index) * spacing / pointsPerBar }
            let coordinate = mapping.reverseCoordinate(at: Double(pointCount - boundary))
            return abs(coordinate - proposedCoordinate) * spacing / pointsPerBar
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
