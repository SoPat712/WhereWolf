import SwiftUI
import MapKit
import UIKit

struct ReplayCoordinate: Equatable {
    let latitude: Double
    let longitude: Double

    init(_ coordinate: CLLocationCoordinate2D) {
        latitude = coordinate.latitude
        longitude = coordinate.longitude
    }

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    func interpolated(to other: ReplayCoordinate, fraction: Double) -> ReplayCoordinate {
        let start = MKMapPoint(coordinate)
        let end = MKMapPoint(other.coordinate)
        let worldWidth = MKMapRect.world.size.width
        var deltaX = end.x - start.x
        if deltaX > worldWidth / 2 { deltaX -= worldWidth }
        if deltaX < -worldWidth / 2 { deltaX += worldWidth }
        var x = start.x + deltaX * fraction
        if x < 0 { x += worldWidth }
        if x >= worldWidth { x -= worldWidth }
        return ReplayCoordinate(MKMapPoint(x: x, y: start.y + (end.y - start.y) * fraction).coordinate)
    }
}

struct ReplayPose: Equatable {
    let position: Double
    let coordinate: ReplayCoordinate
}

enum ReplayPacing {
    static let rates: [Double] = [0.25, 0.5, 1, 2, 5, 10, 25, 50]

    static func segmentDuration(recordedInterval: TimeInterval, rate: Double) -> TimeInterval {
        let interval = recordedInterval.isFinite && recordedInterval > 0 ? recordedInterval / 15 : 2
        let speed = rate.isFinite && rate > 0 ? min(50, max(0.25, rate)) : 1
        // Bound the base pace before scaling so faster settings also speed up dense recordings.
        return min(16, max(0.2, interval)) / speed
    }

    static func label(for rate: Double) -> String {
        rate.formatted(.number.precision(.fractionLength(0...2))) + "×"
    }
}

enum ReplayCameraFocus: Equatable {
    case point
    case trail

    static func nearest(current: Double, point: Double, trail: Double) -> Self {
        guard current.isFinite, point.isFinite, trail.isFinite,
              current > 0, point > 0, trail > 0 else { return .point }
        return abs(log(current / trail)) < abs(log(current / point)) ? .trail : .point
    }
}

final class ReplayRouteGeometry {
    let coordinates: [CLLocationCoordinate2D]
    private let directions: [CGVector?]

    init(points: [RecordedLocation]) {
        coordinates = points.map(\.coordinate)
        var directions = [CGVector?](repeating: nil, count: coordinates.count)
        let world = MKMapRect.world.width
        for index in coordinates.indices.dropFirst() {
            let start = MKMapPoint(coordinates[index - 1])
            let end = MKMapPoint(coordinates[index])
            var dx = end.x - start.x
            dx -= (dx / world).rounded() * world
            let dy = end.y - start.y
            let length = hypot(dx, dy)
            if length > 0.001 {
                directions[index - 1] = CGVector(dx: dx / length, dy: dy / length)
            }
        }
        // Stationary fixes retain the previous direction; leading duplicates use the first movement.
        var previous = directions.lazy.compactMap { $0 }.first
        for index in directions.indices {
            if let direction = directions[index] { previous = direction }
            else { directions[index] = previous }
        }
        self.directions = directions
    }

    func direction(at position: Double) -> CGVector? {
        guard position.isFinite, !directions.isEmpty else { return nil }
        let index = Int(min(Double(directions.count - 1), max(0, position)))
        return directions[index]
    }
}

@Observable
@MainActor
final class HistoryPlaybackModel {
    private(set) var points: [RecordedLocation] = []
    private(set) var selectedIndex: Int?
    private(set) var payload: RecordedPayload?
    private(set) var isPlaying = false
    private(set) var playbackTime: TimeInterval?
    private(set) var renderPose: ReplayPose?
    private(set) var rulerTime: Date?
    private(set) var rulerPosition: Double?
    private(set) var rulerInteractionRevision = 0
    private(set) var isRulerInteracting = false
    private(set) var consumerActive = false
    private(set) var retentionRevision = 0
    var isBrowsing = false
    var playbackRate = 1.0

    var retentionInterval: TimeInterval {
        _ = retentionRevision
        let value = retentionDurationProvider()
        let minimum = TimeInterval(HistoryRetention.minimumHours) * 60 * 60
        let maximum = TimeInterval(HistoryRetention.maximumHours) * 60 * 60
        return value.isFinite ? min(maximum, max(minimum, value)) : HistoryRetention.duration
    }

    private var playbackFraction = 0.0
    @ObservationIgnored private var displayLink: CADisplayLink?
    @ObservationIgnored private var lastAdvance = 0.0
    @ObservationIgnored private var lastLoadedID: Int64 = 0
    @ObservationIgnored private var loading = false
    @ObservationIgnored private var needsReload = false
    @ObservationIgnored private var needsFullSnapshot = false
    @ObservationIgnored private var expiring = false
    @ObservationIgnored private var lastExpiration = Date.distantPast
    @ObservationIgnored private let pointLoader: (Int64, @escaping ([RecordedLocation]) -> Void) -> Void
    @ObservationIgnored private let payloadLoader: ([Int64], @escaping ([Int64: RecordedPayload]) -> Void) -> Void
    @ObservationIgnored private let retentionDurationProvider: () -> TimeInterval
    @ObservationIgnored private var payloadCache: [Int64: RecordedPayload] = [:]
    @ObservationIgnored private var payloadLoading = false
    @ObservationIgnored private var needsPayloadReload = false
    @ObservationIgnored private var lastPrefetchIndex: Int?
    private var pointsRevision = 0
    private var payloadRevision = 0
    @ObservationIgnored private var routeCache: (revision: Int, geometry: ReplayRouteGeometry)?

    init(pointLoader: @escaping (Int64, @escaping ([RecordedLocation]) -> Void) -> Void = {
        RecentLocationHistory.shared.load(after: $0, completion: $1)
    }, payloadLoader: @escaping ([Int64], @escaping ([Int64: RecordedPayload]) -> Void) -> Void = {
        RecentLocationHistory.shared.loadPayloads(ids: $0, completion: $1)
    }, retentionDuration: @escaping () -> TimeInterval = { HistoryRetention.duration }) {
        self.pointLoader = pointLoader
        self.payloadLoader = payloadLoader
        self.retentionDurationProvider = retentionDuration
    }

    var selectedPoint: RecordedLocation? {
        guard let selectedIndex, points.indices.contains(selectedIndex) else { return nil }
        return points[selectedIndex]
    }

    var playbackCoordinate: ReplayCoordinate? { renderPose?.coordinate }

    var cameraCenter: ReplayCoordinate? { renderPose?.coordinate }

    var playbackAccuracy: CLLocationAccuracy? {
        _ = payloadRevision
        guard let pose = renderPose, !points.isEmpty else { return nil }
        let index = min(points.count - 1, max(0, Int(pose.position)))
        func accuracy(at index: Int) -> Double? {
            guard points.indices.contains(index), let value = payloadCache[points[index].id]?.accuracy,
                  value.isFinite, value >= 0 else { return nil }
            return value
        }
        guard let current = accuracy(at: index) else { return nil }
        guard let next = accuracy(at: index + 1) else { return current }
        let fraction = min(1, max(0, pose.position - Double(index)))
        return current + (next - current) * fraction
    }

    var routeGeometry: ReplayRouteGeometry? {
        guard isBrowsing, selectedIndex != nil else { return nil }
        if let routeCache, routeCache.revision == pointsRevision {
            return routeCache.geometry
        }
        let geometry = ReplayRouteGeometry(points: points)
        routeCache = (pointsRevision, geometry)
        return geometry
    }

    var playbackIndex: Double {
        if let rulerPosition { return min(Double(max(0, points.count - 1)), max(0, Double(points.count) - rulerPosition)) }
        guard let selectedIndex else { return 0 }
        return Double(selectedIndex) + playbackFraction
    }

    func setConsumerActive(_ active: Bool) {
        guard active != consumerActive else { return }
        consumerActive = active
        if active { reload() } else {
            interruptRuler()
            pause()
        }
    }

    func reload() {
        guard consumerActive else {
            needsReload = true
            return
        }
        guard !isRulerInteracting, !isPlaying else {
            needsReload = true
            return
        }
        if loading {
            needsReload = true
            return
        }
        let fullSnapshot = needsFullSnapshot
        needsFullSnapshot = false
        needsReload = false
        loading = true
        pointLoader(fullSnapshot ? 0 : lastLoadedID) { [weak self] incoming in
            guard let self else { return }
            guard self.consumerActive else {
                self.loading = false
                self.needsReload = true
                self.needsFullSnapshot = self.needsFullSnapshot || fullSnapshot
                return
            }
            guard !self.isRulerInteracting, !self.isPlaying else {
                self.loading = false
                self.needsReload = true
                self.needsFullSnapshot = self.needsFullSnapshot || fullSnapshot
                return
            }
            self.expireOldPoints()
            let selectedID = self.selectedPoint?.id
            let cutoff = Date().addingTimeInterval(-self.retentionInterval)
            let ordered = self.unique(incoming.filter { $0.timestamp >= cutoff })
            self.lastLoadedID = max(self.lastLoadedID, incoming.map(\.id).max() ?? 0)
            if fullSnapshot {
                self.points = self.unique(ordered + self.points)
                self.lastPrefetchIndex = nil
                if let selectedID { self.selectedIndex = self.points.firstIndex { $0.id == selectedID } }
                else { self.selectedIndex = nil }
                let retained = Set(self.points.map(\.id))
                self.payloadCache = self.payloadCache.filter { retained.contains($0.key) }
                if self.selectedIndex == nil { self.payload = nil }
                else { self.loadSelectedPayload() }
            } else {
                self.appendIncremental(ordered, selectedID: selectedID)
            }
            if fullSnapshot || !ordered.isEmpty {
                self.pointsRevision &+= 1
                self.rebasePlaybackPosition()
                if fullSnapshot, self.rulerPosition != nil, let pose = self.renderPose {
                    self.rulerPosition = Double(self.points.count) - pose.position
                }
            }
            if self.isBrowsing && self.selectedIndex == nil && !self.points.isEmpty {
                self.selectNearest(to: self.rulerTime ?? self.points.last!.timestamp)
            }
            self.prefetchPayloads(around: self.selectedIndex ?? max(0, self.points.count - 1))
            self.loading = false
            self.flushDeferredReload()
        }
    }

    private func unique(_ incoming: [RecordedLocation]) -> [RecordedLocation] {
        var seen = Set<Int64>()
        var result: [RecordedLocation] = []
        result.reserveCapacity(incoming.count)
        for point in incoming where seen.insert(point.id).inserted { result.append(point) }
        return result.sorted(by: Self.precedes)
    }

    private func appendIncremental(_ incoming: [RecordedLocation], selectedID: Int64?) {
        guard !incoming.isEmpty else { return }
        if points.isEmpty {
            interruptRuler()
            points = incoming
            return
        }
        guard let first = incoming.first, let last = points.last, Self.precedes(first, last) else {
            points.append(contentsOf: incoming)
            if let position = rulerPosition { rulerPosition = position + Double(incoming.count) }
            return
        }
        var merged: [RecordedLocation] = []
        merged.reserveCapacity(points.count + incoming.count)
        var i = 0
        var j = 0
        while i < points.count && j < incoming.count {
            if Self.precedes(incoming[j], points[i]) {
                merged.append(incoming[j]); j += 1
            } else {
                merged.append(points[i]); i += 1
            }
        }
        merged.append(contentsOf: points[i...])
        merged.append(contentsOf: incoming[j...])
        points = merged
        interruptRuler()
        if let selectedID { self.selectedIndex = points.firstIndex { $0.id == selectedID } }
    }

    private func flushDeferredReload() {
        guard consumerActive, !isRulerInteracting, !isPlaying, !loading, !expiring,
              needsReload || needsFullSnapshot else { return }
        needsReload = false
        reload()
    }

    private static func precedes(_ lhs: RecordedLocation, _ rhs: RecordedLocation) -> Bool {
        lhs.timestamp == rhs.timestamp ? lhs.id < rhs.id : lhs.timestamp < rhs.timestamp
    }

    func retentionDidChange() {
        retentionRevision &+= 1
        needsFullSnapshot = true
        needsReload = true
        expireOldPoints(force: true)
        flushDeferredReload()
    }

    func expireOldPoints() {
        expireOldPoints(force: false)
    }

    private func expireOldPoints(force: Bool) {
        guard force || consumerActive else { return }
        let now = Date()
        guard force || now.timeIntervalSince(lastExpiration) >= 60 else { return }
        lastExpiration = now
        expiring = true
        defer {
            expiring = false
            flushDeferredReload()
        }
        let cutoff = now.addingTimeInterval(-retentionInterval)
        let selectedID = selectedPoint?.id
        let previousIndex = selectedIndex
        let previousCount = points.count
        points.removeAll { $0.timestamp < cutoff }
        guard points.count != previousCount else { return }
        pointsRevision &+= 1
        lastPrefetchIndex = nil
        let retained = Set(points.map(\.id))
        payloadCache = payloadCache.filter { retained.contains($0.key) }
        interruptRuler()
        if let playbackTime, let first = points.first,
           playbackTime < first.timestamp.timeIntervalSince1970 {
            pause()
            self.playbackTime = nil
            playbackFraction = 0
        }
        if let selectedID, let previousIndex {
            if let matchingIndex = points.firstIndex(where: { $0.id == selectedID }) {
                self.selectedIndex = matchingIndex
            } else {
                self.selectedIndex = points.isEmpty ? nil : min(previousIndex, points.count - 1)
                rulerTime = selectedPoint?.timestamp
                playbackFraction = 0
                playbackTime = nil
                pause()
            }
            loadSelectedPayload()
        }
        if points.isEmpty {
            pause()
            playbackTime = nil
            playbackFraction = 0
            renderPose = nil
        } else if !isPlaying, let selectedPoint {
            if playbackTime != nil {
                rebasePlaybackPosition()
            } else {
                let coordinate = ReplayCoordinate(selectedPoint.coordinate)
                renderPose = ReplayPose(position: Double(selectedIndex ?? 0), coordinate: coordinate)
            }
        }
    }

    func scrub(to time: Date) {
        interruptRuler()
        let wasBrowsing = isBrowsing
        pause()
        playbackTime = nil
        playbackFraction = 0
        if !isBrowsing { isBrowsing = true }
        rulerTime = time
        guard !points.isEmpty else {
            if !wasBrowsing { reload() }
            return
        }
        selectNearest(to: time)
    }

    func scrub(pointAt index: Int) {
        if !isBrowsing { isBrowsing = true }
        select(index)
    }

    func beginRulerInteraction() {
        if !isRulerInteracting { isRulerInteracting = true }
        stopPlayback()
    }

    func endRulerInteraction() {
        if isRulerInteracting { isRulerInteracting = false }
        flushDeferredReload()
    }

    func scrub(rulerPosition position: Double, liveEdge: Date) {
        pause()
        if !isBrowsing { isBrowsing = true }
        rulerPosition = position
        guard !points.isEmpty else {
            rulerTime = liveEdge.addingTimeInterval(-retentionInterval * position / 48)
            return
        }
        let fractionalIndex = min(Double(points.count - 1), max(0, Double(points.count) - position))
        let index = Int(floor(fractionalIndex))
        let fraction = fractionalIndex - Double(index)
        showPlaybackPosition(index: index, fraction: fraction)
        if position < 1 {
            rulerTime = liveEdge.addingTimeInterval(points[index].timestamp.timeIntervalSince(liveEdge) * position)
        }
    }

    private func rebasePlaybackPosition() {
        guard let selectedIndex, points.indices.contains(selectedIndex) else { return }
        guard let playbackTime else {
            renderPose = ReplayPose(position: Double(selectedIndex),
                                    coordinate: ReplayCoordinate(points[selectedIndex].coordinate))
            return
        }
        if points.indices.contains(selectedIndex + 1),
           points[selectedIndex].timestamp.timeIntervalSince1970 == playbackTime,
           points[selectedIndex + 1].timestamp == points[selectedIndex].timestamp {
            showPlaybackPosition(index: selectedIndex, fraction: playbackFraction)
            return
        }
        let index = index(at: playbackTime)
        let duration = points.indices.contains(index + 1)
            ? points[index + 1].timestamp.timeIntervalSince(points[index].timestamp) : 0
        let fraction = duration > 0
            ? min(1, max(0, (playbackTime - points[index].timestamp.timeIntervalSince1970) / duration)) : 0
        showPlaybackPosition(index: index, fraction: fraction)
    }

    private func showPlaybackPosition(index: Int, fraction: Double) {
        playbackFraction = fraction
        setSelection(index)
        let point = points[index]
        let start = ReplayCoordinate(point.coordinate)
        let target: ReplayCoordinate
        let current: TimeInterval
        if points.indices.contains(index + 1) {
            current = point.timestamp.timeIntervalSince1970
                + points[index + 1].timestamp.timeIntervalSince(point.timestamp) * fraction
            target = start.interpolated(to: ReplayCoordinate(points[index + 1].coordinate), fraction: fraction)
        } else {
            current = point.timestamp.timeIntervalSince1970
            target = start
        }
        playbackTime = current
        rulerTime = Date(timeIntervalSince1970: current)
        renderPose = ReplayPose(position: Double(index) + fraction, coordinate: target)
        if index == points.count - 1 { pause() }
    }

    private func interruptRuler() {
        rulerInteractionRevision &+= 1
        isRulerInteracting = false
        rulerPosition = nil
    }

    func returnToLive() {
        interruptRuler()
        pause()
        isBrowsing = false
        selectedIndex = nil
        payload = nil
        playbackTime = nil
        playbackFraction = 0
        renderPose = nil
        rulerTime = nil
    }

    func select(_ index: Int) {
        interruptRuler()
        pause()
        playbackTime = nil
        playbackFraction = 0
        setSelection(index)
        if let selectedPoint {
            rulerTime = selectedPoint.timestamp
            let coordinate = ReplayCoordinate(selectedPoint.coordinate)
            renderPose = ReplayPose(position: Double(selectedIndex ?? 0), coordinate: coordinate)
        }
    }

    func step(_ direction: Int) {
        select((selectedIndex ?? points.count - 1) + direction)
    }

    func togglePlayback() {
        interruptRuler()
        if isPlaying {
            pause()
            return
        }
        guard consumerActive, points.count > 1 else { return }
        if !isBrowsing { isBrowsing = true }
        if selectedIndex == nil || selectedIndex == points.count - 1 {
            playbackTime = nil
            playbackFraction = 0
            setSelection(0)
            if let first = points.first {
                rulerTime = first.timestamp
                let coordinate = ReplayCoordinate(first.coordinate)
                renderPose = ReplayPose(position: 0, coordinate: coordinate)
            }
        }
        guard let selectedPoint else { return }
        if playbackTime == nil { playbackTime = selectedPoint.timestamp.timeIntervalSince1970 }
        let coordinate = ReplayCoordinate(selectedPoint.coordinate)
        if renderPose == nil {
            renderPose = ReplayPose(position: Double(selectedIndex ?? 0) + playbackFraction, coordinate: coordinate)
        }
        isPlaying = true
        lastAdvance = 0
        startDisplayLink()
    }

    private func stopPlayback() {
        guard isPlaying || displayLink != nil else { return }
        displayLink?.invalidate()
        displayLink = nil
        isPlaying = false
    }

    func pause() {
        stopPlayback()
        flushDeferredReload()
    }

    private func startDisplayLink() {
        let target = HistoryPlaybackFrameTarget(model: self)
        let link = CADisplayLink(target: target, selector: #selector(HistoryPlaybackFrameTarget.frame(_:)))
        let screen = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first(where: { $0.activationState == .foregroundActive })?.screen
        let maximum = Float(screen?.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    fileprivate func advancePlaybackFrame(at timestamp: CFTimeInterval) {
        guard isPlaying else { return }
        defer { lastAdvance = timestamp }
        guard lastAdvance > 0 else { return }
        // Resume from a dropped frame instead of jumping through an unseen portion of the trip.
        advancePlayback(by: min(0.1, max(0, timestamp - lastAdvance)))
    }

    func advancePlayback(by elapsed: TimeInterval) {
        guard isPlaying, consumerActive, elapsed.isFinite, elapsed >= 0,
              var index = selectedIndex, points.indices.contains(index) else { return }
        var fraction = playbackFraction
        var remaining = elapsed
        while points.indices.contains(index + 1) {
            let duration = ReplayPacing.segmentDuration(
                recordedInterval: points[index + 1].timestamp.timeIntervalSince(points[index].timestamp),
                rate: playbackRate
            )
            let available = duration * (1 - fraction)
            if remaining < available {
                fraction += remaining / duration
                break
            }
            remaining -= available
            index += 1
            fraction = 0
        }
        showPlaybackPosition(index: index, fraction: fraction)
    }

    private func index(at timestamp: TimeInterval) -> Int {
        var lower = 0
        var upper = points.count
        while lower < upper {
            let middle = (lower + upper) / 2
            if points[middle].timestamp.timeIntervalSince1970 <= timestamp {
                lower = middle + 1
            } else {
                upper = middle
            }
        }
        return max(0, lower - 1)
    }

    private func selectNearest(to time: Date) {
        let previous = index(at: time.timeIntervalSince1970)
        let next = min(previous + 1, points.count - 1)
        let previousDistance = abs(points[previous].timestamp.timeIntervalSince(time))
        let nextDistance = abs(points[next].timestamp.timeIntervalSince(time))
        setSelection(nextDistance < previousDistance ? next : previous)
        if let selectedPoint {
            let coordinate = ReplayCoordinate(selectedPoint.coordinate)
            renderPose = ReplayPose(position: Double(selectedIndex ?? 0), coordinate: coordinate)
        }
    }

    private func setSelection(_ index: Int) {
        guard !points.isEmpty else { return }
        let clamped = min(points.count - 1, max(0, index))
        guard selectedIndex != clamped else { return }
        selectedIndex = clamped
        loadSelectedPayload()
    }

    private func loadSelectedPayload() {
        guard let selectedIndex, let id = selectedPoint?.id else {
            payload = nil
            return
        }
        let cached = payloadCache[id]
        if payload != cached { payload = cached }
        prefetchPayloads(around: selectedIndex)
    }

    private func prefetchPayloads(around index: Int) {
        guard consumerActive, points.indices.contains(index) else { return }
        if payloadCache[points[index].id] != nil, let lastPrefetchIndex, abs(index - lastPrefetchIndex) < 24 { return }
        guard !payloadLoading else {
            needsPayloadReload = true
            return
        }
        let lower = max(0, index - 48)
        let upper = min(points.count, index + 49)
        let ids = points[lower..<upper].map(\.id).filter { payloadCache[$0] == nil }
        lastPrefetchIndex = index
        guard !ids.isEmpty else { return }
        payloadLoading = true
        payloadLoader(ids) { [weak self] values in
            guard let self else { return }
            self.payloadLoading = false
            guard self.consumerActive else {
                self.needsPayloadReload = false
                return
            }
            self.payloadCache.merge(values) { _, incoming in incoming }
            if !values.isEmpty { self.payloadRevision &+= 1 }
            if self.payloadCache.count > 256 {
                let center = self.selectedIndex ?? self.points.count - 1
                let end = min(self.points.count, center + 129)
                let start = max(0, end - 256)
                let keep = Set(self.points[start..<end].map(\.id))
                self.payloadCache = self.payloadCache.filter { keep.contains($0.key) }
            }
            if let id = self.selectedPoint?.id, let value = self.payloadCache[id], self.payload != value {
                self.payload = value
            }
            if self.needsPayloadReload {
                self.needsPayloadReload = false
                self.prefetchPayloads(around: self.selectedIndex ?? max(0, self.points.count - 1))
            }
        }
    }
}

@MainActor
private final class HistoryPlaybackFrameTarget: NSObject {
    private weak var model: HistoryPlaybackModel?

    init(model: HistoryPlaybackModel) { self.model = model }

    @objc func frame(_ link: CADisplayLink) {
        guard let model else { link.invalidate(); return }
        model.advancePlaybackFrame(at: link.timestamp)
    }
}

struct HistoryPlaybackView: View {
    var history: HistoryPlaybackModel
    @State private var showingRecord = false
    @State private var showingDetails = false
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .caption) private var detailIconSize: CGFloat = 18

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if history.points.isEmpty {
                Label("No recent locations", systemImage: "location.slash")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            } else {
                playbackControls.padding(.horizontal, 16)
                if showingDetails { pointDetails.drawerCard() }
            }
        }
        .sheet(isPresented: $showingRecord) { recordSheet }
    }

    private var playbackControls: some View {
        HStack(spacing: 8) {
            Button { history.step(-1) } label: {
                Image(systemName: "backward.end.fill")
                    .font(dynamicTypeSize.isAccessibilitySize ? .system(size: 20, weight: .semibold) : .body)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .glassButtonStyle()
            .buttonBorderShape(.circle)
            .disabled((history.selectedIndex ?? 0) == 0)
            .accessibilityLabel("Previous point")

            Button { history.togglePlayback() } label: {
                Image(systemName: history.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .glassButtonStyle(prominent: true, tint: .blue)
            .buttonBorderShape(.circle)
            .disabled(history.points.count < 2)
            .accessibilityLabel(history.isPlaying ? "Pause" : "Play")

            Button { history.step(1) } label: {
                Image(systemName: "forward.end.fill")
                    .font(dynamicTypeSize.isAccessibilitySize ? .system(size: 20, weight: .semibold) : .body)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .glassButtonStyle()
            .buttonBorderShape(.circle)
            .disabled((history.selectedIndex ?? 0) >= history.points.count - 1)
            .accessibilityLabel("Next point")

            Menu {
                ForEach(ReplayPacing.rates, id: \.self) { rate in
                    Button("\(ReplayPacing.label(for: rate)) replay speed") {
                        history.playbackRate = rate
                    }
                }
            } label: {
                Text(ReplayPacing.label(for: history.playbackRate))
                    .font((dynamicTypeSize.isAccessibilitySize ? Font.system(size: 17, weight: .semibold)
                           : Font.subheadline.weight(.semibold)).monospacedDigit())
                    .frame(minWidth: 40, minHeight: 32)
            }
            .glassButtonStyle()
            .accessibilityLabel("Playback speed")
            .accessibilityValue("\(ReplayPacing.label(for: history.playbackRate)) replay speed")
            Spacer(minLength: 0)
            DrawerDetailsButton(expanded: $showingDetails, subject: "point")
        }
        .controlSize(.small)
        .frame(minHeight: 44)
    }

    private var pointDetails: some View {
        VStack(alignment: .leading, spacing: 10) {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: 6) {
                    pointTitle
                    pointTimestamp
                }
            } else {
                HStack(alignment: .firstTextBaseline) {
                    pointTitle
                    Spacer()
                    pointTimestamp
                }
            }
            if let point = history.selectedPoint {
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Location", systemImage: "location.fill")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(String(format: "%.7f\n%.7f", point.latitude, point.longitude))
                            .font(.caption.monospacedDigit())
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else {
                    detail("Location", value: String(format: "%.7f, %.7f", point.latitude, point.longitude),
                           symbol: "location.fill")
                }
                if dynamicTypeSize.isAccessibilitySize {
                    VStack(spacing: 10) { metricDetails }
                } else {
                    LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading),
                                        GridItem(.flexible(), alignment: .leading)],
                              alignment: .leading, spacing: 10) {
                        metricDetails
                    }
                }
                detail("Device", value: history.payload.map { $0.device ?? "Not in record" } ?? "—", symbol: "iphone")
                Button {
                    history.pause()
                    showingRecord = true
                } label: {
                    HStack {
                        Label("View upload record", systemImage: "curlybraces")
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption.weight(.semibold))
                    }
                    .font(.subheadline.weight(.medium))
                    .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
                .disabled(history.payload == nil)
            }
        }
    }

    private var pointTitle: some View {
        Text(history.playbackIndex > Double(history.selectedIndex ?? 0) + 0.001
             ? "Last logged point \((history.selectedIndex ?? 0) + 1)"
             : "Point \((history.selectedIndex ?? 0) + 1)")
            .font(.subheadline.weight(.semibold))
            .fixedSize(horizontal: false, vertical: true)
    }

    private var pointTimestamp: some View {
        Text(history.selectedPoint?.timestamp.formatted(date: .abbreviated, time: .standard) ?? "")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private var metricDetails: some View {
        detail("Accuracy", value: history.payload?.accuracy.map { String(format: "±%.0f m", $0) } ?? "—",
               symbol: "scope")
        detail("Speed", value: history.payload?.speed.map { String(format: "%.2f m/s", $0) } ?? "—",
               symbol: "speedometer")
        detail("Altitude", value: history.payload?.altitude.map { String(format: "%.1f m", $0) } ?? "—",
               symbol: "mountain.2")
        detail("Battery", value: history.payload?.battery ?? "—", symbol: "battery.100")
    }

    private func detail(_ title: String, value: String, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: dynamicTypeSize.isAccessibilitySize ? detailIconSize * 1.35 : detailIconSize,
                       height: detailIconSize)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(value)
                    .font(.caption.monospacedDigit())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var recordSheet: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("This is the record prepared for the upload queue. Delivery may still be pending.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    Text(history.payload?.json ?? "")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding()
            }
            .navigationTitle(history.payload?.format ?? "Upload record")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { showingRecord = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

struct HistoryRuler: View {
    var history: HistoryPlaybackModel
    var onLive: () -> Void

    @State private var liveEdge = Date()
    @State private var interactionPointCount = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    private var tickCount: Int { history.points.isEmpty ? 48 : history.points.count }

    private var position: Double {
        if let position = history.rulerPosition { return position }
        guard history.isBrowsing else { return 0 }
        if history.points.isEmpty {
            guard let time = history.rulerTime else { return 0 }
            return min(48, max(0, liveEdge.timeIntervalSince(time) / history.retentionInterval * 48))
        }
        return Double(history.points.count) - history.playbackIndex
    }

    private var value: String {
        history.isBrowsing
            ? (history.rulerTime ?? Date()).formatted(date: .abbreviated, time: .shortened)
            : "Live"
    }

    var body: some View {
        VStack(spacing: 0) {
            HistoryRulerSurface(position: position, tickCount: tickCount,
                                revision: history.rulerInteractionRevision,
                                active: history.consumerActive && scenePhase == .active,
                                reduceMotion: reduceMotion, value: value,
                                onBegin: {
                liveEdge = Date()
                interactionPointCount = history.points.count
                history.beginRulerInteraction()
            }, onMove: { position in
                if position <= 0 {
                    if history.isBrowsing { onLive() }
                    if !history.isRulerInteracting { history.beginRulerInteraction() }
                } else {
                    let appended = history.points.count - interactionPointCount
                    history.scrub(rulerPosition: position + Double(appended), liveEdge: liveEdge)
                }
                return history.rulerInteractionRevision
            }, onEnd: {
                if history.isRulerInteracting { history.endRulerInteraction() }
            }, onAdjust: { direction in
                let target = min(tickCount, max(0, Int(position.rounded()) + direction))
                if target == 0 { onLive() }
                else if history.points.isEmpty {
                    history.scrub(to: liveEdge.addingTimeInterval(-history.retentionInterval * Double(target) / 48))
                } else {
                    history.scrub(pointAt: history.points.count - target)
                }
            })
            .frame(height: 44)
            HStack {
                Text(history.isBrowsing ? value : "LIVE")
                    .font(.caption2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(history.isBrowsing ? Color.primary : Color.blue)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .accessibilityHidden(true)
                Spacer(minLength: 8)
                if history.isBrowsing {
                    Button(action: onLive) {
                        Label("Live", systemImage: "location.fill")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .accessibilityLabel("Return to Live")
                } else {
                    Text("Hold to scroll faster")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityHidden(true)
                }
            }
            .frame(height: 18)
            .padding(.horizontal, 8)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .glassPanel(cornerRadius: 22, interactive: true)
        .padding(.horizontal, 16)
        .onAppear { liveEdge = Date() }
    }
}

enum HistoryRulerCoarseDrag {
    static let minimumGain = 24.0
    static let maximumGain = 16_384.0

    // Scale a full-width drag to the loaded timeline, while keeping short histories usable.
    static func gain(tickCount: Int, rulerWidth: CGFloat, spacing: CGFloat = 12) -> Double {
        let spacing = max(0.001, Double(spacing))
        let width = max(1, Double(rulerWidth))
        let span = max(0, Double(tickCount)) * spacing / width
        return min(maximumGain, max(minimumGain, span * 3))
    }

    static func position(after current: Double, translation: CGFloat, tickCount: Int,
                         rulerWidth: CGFloat, spacing: CGFloat = 12) -> Double {
        let maximum = max(0, Double(tickCount))
        let spacing = max(0.001, Double(spacing))
        let delta = Double(translation) / spacing
            * gain(tickCount: tickCount, rulerWidth: rulerWidth, spacing: CGFloat(spacing))
        return min(maximum, max(0, current + delta))
    }
}

private struct HistoryRulerSurface: UIViewRepresentable {
    var position: Double
    var tickCount: Int
    var revision: Int
    var active: Bool
    var reduceMotion: Bool
    var value: String
    var onBegin: () -> Void
    var onMove: (Double) -> Int
    var onEnd: () -> Void
    var onAdjust: (Int) -> Void

    func makeUIView(context: Context) -> HistoryRulerContainer {
        HistoryRulerContainer()
    }

    func updateUIView(_ view: HistoryRulerContainer, context: Context) {
        view.configure(self)
    }

    static func dismantleUIView(_ view: HistoryRulerContainer, coordinator: ()) {
        view.cancelMotion()
    }
}

private final class HistoryRulerScrollView: UIScrollView {
    var onAdjust: ((Int) -> Void)?

    override func accessibilityIncrement() { onAdjust?(1) }
    override func accessibilityDecrement() { onAdjust?(-1) }
}

private final class HistoryRulerTicks: UIView {
    var tickCount = 0
    var position: Double = 0
    static let spacing: CGFloat = 12

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let center = bounds.width / 2
        let radius = Int(ceil(bounds.width / Self.spacing / 2)) + 1
        let first = max(0, Int(position) - radius)
        let last = min(tickCount, Int(position) + radius)
        if first <= last {
            for tick in first...last {
                let x = center + CGFloat(position - Double(tick)) * Self.spacing
                let major = tick == 0 || tick.isMultiple(of: 5)
                context.setStrokeColor(UIColor.label.withAlphaComponent(major ? 0.5 : 0.25).cgColor)
                context.setLineWidth(1)
                context.move(to: CGPoint(x: x, y: major ? 4 : 9))
                context.addLine(to: CGPoint(x: x, y: 21))
                context.strokePath()
            }
        }
        context.setShadow(offset: .zero, blur: 3, color: UIColor.systemBlue.withAlphaComponent(0.35).cgColor)
        UIColor.systemBlue.setFill()
        UIBezierPath(roundedRect: CGRect(x: center - 2, y: 0, width: 4, height: 26), cornerRadius: 2).fill()
    }
}

private final class HistoryRulerCoarseBubble: UIView {
    let captionLabel = UILabel()
    let valueLabel = UILabel()
    private let material: UIVisualEffectView

    var usesLiquidGlass: Bool {
        if #available(iOS 26.0, *) { return material.effect is UIGlassEffect }
        return false
    }

    override init(frame: CGRect) {
        if #available(iOS 26.0, *) {
            material = UIVisualEffectView(effect: UIGlassEffect(style: .regular))
        } else {
            material = UIVisualEffectView(effect: UIBlurEffect(style: .systemThinMaterial))
        }
        super.init(frame: frame)
        isOpaque = false
        isUserInteractionEnabled = false
        backgroundColor = .clear
        layer.cornerRadius = 12
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.16
        layer.shadowRadius = 8
        layer.shadowOffset = CGSize(width: 0, height: 3)
        accessibilityElementsHidden = true
        isAccessibilityElement = false
        material.clipsToBounds = true
        material.layer.cornerCurve = .continuous
        material.layer.cornerRadius = 12
        addSubview(material)

        let captionFont = UIFont.preferredFont(forTextStyle: .caption2)
        captionLabel.font = UIFont(descriptor: captionFont.fontDescriptor.withSymbolicTraits(.traitBold)
                                  ?? captionFont.fontDescriptor, size: 0)
        captionLabel.textColor = .label
        captionLabel.text = "COARSE SCROLL"
        captionLabel.adjustsFontForContentSizeCategory = true
        valueLabel.font = .preferredFont(forTextStyle: .subheadline)
        valueLabel.textColor = .label
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.minimumScaleFactor = 0.75
        valueLabel.adjustsFontSizeToFitWidth = true
        for label in [captionLabel, valueLabel] {
            label.isAccessibilityElement = false
            material.contentView.addSubview(label)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        material.frame = bounds
        let inset: CGFloat = 12
        let captionHeight = ceil(captionLabel.font.lineHeight)
        captionLabel.frame = CGRect(x: inset, y: 7, width: bounds.width - inset * 2, height: captionHeight)
        valueLabel.frame = CGRect(x: inset, y: captionHeight + 10, width: bounds.width - inset * 2,
                                 height: ceil(valueLabel.font.lineHeight))
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }

    var preferredHeight: CGFloat { ceil(captionLabel.font.lineHeight + valueLabel.font.lineHeight) + 17 }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsLayout()
    }
}

private final class HistoryRulerContainer: UIView, UIScrollViewDelegate {
    private let scrollView = HistoryRulerScrollView()
    private let contentView = UIView()
    private let ticks = HistoryRulerTicks()
    private let coarsePress: UILongPressGestureRecognizer
    private let coarseBubble = HistoryRulerCoarseBubble(frame: .zero)
    private let normalAccessibilityHint = "Older points are on the left. Drag right to browse them, or left toward Live. Hold briefly, then drag for coarse scrolling."
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let boundaryFeedback = UIImpactFeedbackGenerator(style: .soft)
    private let coarseFeedback = UIImpactFeedbackGenerator(style: .light)
    private var configuration: HistoryRulerSurface?
    private var appliedRevision = 0
    private var suppressScroll = false
    private var dragging = false
    private var decelerating = false
    private var coarseDragging = false
    private var coarseGestureCancelled = false
    private var coarseLastX: CGFloat = 0
    private var lastFeedbackPosition = 0.0
    private var lastBoundary: Int?
    private var lastFeedbackTime = 0.0
    private var lastMotionTime = 0.0
    private var lastMotionPosition = 0.0
    private var velocity = 0.0
#if targetEnvironment(simulator)
    private var motionSamples: [[Double]] = []
    private var lastSampleTime = 0.0
    private lazy var motionElement = HistoryRulerMotionElement(accessibilityContainer: self)
#endif

    private var maximumOffset: CGFloat { CGFloat(ticks.tickCount) * HistoryRulerTicks.spacing }
    private var position: Double { Double((maximumOffset - scrollView.contentOffset.x) / HistoryRulerTicks.spacing) }
    private var moving: Bool { dragging || decelerating || coarseDragging }
    private var coarseGain: Double {
        HistoryRulerCoarseDrag.gain(tickCount: ticks.tickCount, rulerWidth: bounds.width)
    }
    private var coarseBubbleVisible: Bool { coarseBubble.superview != nil }

    init() {
        coarsePress = UILongPressGestureRecognizer()
        super.init(frame: .zero)
        backgroundColor = .clear
        ticks.backgroundColor = .clear
        ticks.isUserInteractionEnabled = false
        addSubview(ticks)
        scrollView.backgroundColor = .clear
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = true
        scrollView.alwaysBounceVertical = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.scrollsToTop = false
        scrollView.delegate = self
        scrollView.isAccessibilityElement = true
        scrollView.accessibilityLabel = "Location history ruler"
        scrollView.accessibilityHint = normalAccessibilityHint
        scrollView.accessibilityTraits = .adjustable
        scrollView.onAdjust = { [weak self] direction in
            guard let self else { return }
            if self.coarseDragging { self.endCoarseDrag() }
            self.cancelMotion()
            self.selectionFeedback.prepare()
            self.configuration?.onAdjust(direction)
            self.selectionFeedback.selectionChanged()
        }
        scrollView.addSubview(contentView)
        addSubview(scrollView)
        coarsePress.minimumPressDuration = 0.35
        coarsePress.allowableMovement = 16
        coarsePress.cancelsTouchesInView = true
        coarsePress.addTarget(self, action: #selector(coarsePressChanged(_:)))
        addGestureRecognizer(coarsePress)
#if targetEnvironment(simulator)
        motionElement.ruler = self
        motionElement.accessibilityLabel = "History ruler motion"
        accessibilityElements = [scrollView, motionElement]
#else
        accessibilityElements = [scrollView]
#endif
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(_ configuration: HistoryRulerSurface) {
        let interrupted = appliedRevision != configuration.revision || !configuration.active
        let wasActive = self.configuration?.active ?? false
        self.configuration = configuration
        if interrupted { cancelMotion() }
        appliedRevision = configuration.revision
        if !moving { ticks.tickCount = configuration.tickCount }
        scrollView.isScrollEnabled = configuration.active && !coarseDragging
        if configuration.active && !wasActive { coarseGestureCancelled = false }
        coarsePress.isEnabled = configuration.active
        scrollView.decelerationRate = configuration.reduceMotion ? .fast : .normal
        if configuration.active && coarseDragging { updateCoarseBubble() }
        if !configuration.active { removeCoarseBubble() }
        updateAccessibility()
        updateGeometry()
        if !moving {
            suppressScroll = true
            scrollView.setContentOffset(CGPoint(x: maximumOffset - CGFloat(configuration.position) * HistoryRulerTicks.spacing,
                                               y: 0), animated: false)
            suppressScroll = false
        }
        redraw()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateGeometry()
        redraw()
        if coarseDragging { updateCoarseBubblePosition() }
#if targetEnvironment(simulator)
        motionElement.accessibilityFrameInContainerSpace = bounds
#endif
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { removeCoarseBubble() }
        else if coarseDragging { showCoarseBubble() }
    }

    private func updateGeometry() {
        let contentSize = CGSize(width: bounds.width + maximumOffset, height: bounds.height)
        guard scrollView.frame != bounds || scrollView.contentSize != contentSize else { return }
        // The offset range stays independent of width while the drawer changes its layout.
        let offset = scrollView.contentOffset
        suppressScroll = true
        ticks.frame = CGRect(x: 0, y: (bounds.height - 28) / 2, width: bounds.width, height: 28)
        scrollView.frame = bounds
        contentView.frame = CGRect(origin: .zero, size: contentSize)
        scrollView.contentSize = contentSize
        if scrollView.contentOffset != offset { scrollView.setContentOffset(offset, animated: false) }
        suppressScroll = false
    }

    func cancelMotion() {
        let wasMoving = moving
        if coarseDragging {
            coarseGestureCancelled = true
            coarseDragging = false
            scrollView.isScrollEnabled = configuration?.active ?? false
            scrollView.panGestureRecognizer.isEnabled = configuration?.active ?? false
            removeCoarseBubble()
            updateAccessibility()
        } else { removeCoarseBubble() }
        suppressScroll = true
        scrollView.setContentOffset(scrollView.contentOffset, animated: false)
        if scrollView.isTracking || scrollView.isDragging {
            scrollView.panGestureRecognizer.isEnabled = false
            scrollView.panGestureRecognizer.isEnabled = true
        }
        suppressScroll = false
        dragging = false
        decelerating = false
        velocity = 0
        if wasMoving {
            configuration?.onEnd()
            recordMotion(force: true)
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard !coarseDragging else { return }
        if let configuration, ticks.tickCount != configuration.tickCount {
            ticks.tickCount = configuration.tickCount
            updateGeometry()
            redraw()
        }
        dragging = true
        decelerating = false
        velocity = 0
        lastMotionTime = ProcessInfo.processInfo.systemUptime
        lastMotionPosition = position * Double(HistoryRulerTicks.spacing)
        lastFeedbackPosition = position
        lastBoundary = boundary(at: position)
        selectionFeedback.prepare()
        boundaryFeedback.prepare()
        configuration?.onBegin()
        recordMotion(force: true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !suppressScroll, moving, !coarseDragging else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let points = position * Double(HistoryRulerTicks.spacing)
        let elapsed = now - lastMotionTime
        if elapsed > 0.001 { velocity = (points - lastMotionPosition) / elapsed }
        lastMotionTime = now
        lastMotionPosition = points
        redraw()
        let bounded = min(Double(ticks.tickCount), max(0, position))
        if let configuration { appliedRevision = configuration.onMove(bounded) }
        feedback(at: bounded, time: now)
        recordMotion()
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                  targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        self.velocity = -Double(velocity.x) * 1_000
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        dragging = false
        decelerating = decelerate
        recordMotion(force: true)
        if !decelerate { finishMotion() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) { finishMotion() }

    private func finishMotion() {
        let bounded = min(Double(ticks.tickCount), max(0, position))
        if let configuration { appliedRevision = configuration.onMove(bounded) }
        dragging = false
        decelerating = false
        velocity = 0
        configuration?.onEnd()
        recordMotion(force: true)
    }

    private func redraw() {
        ticks.position = position
        ticks.setNeedsDisplay()
    }

    @objc private func coarsePressChanged(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began:
            guard !coarseGestureCancelled else { return }
            beginCoarseDrag(at: press.location(in: self))
        case .changed:
            guard coarseDragging else { return }
            let location = press.location(in: self)
            let translation = location.x - coarseLastX
            coarseLastX = location.x
            guard abs(translation) > 0.01 else { return }
            let target = HistoryRulerCoarseDrag.position(
                after: min(Double(ticks.tickCount), max(0, position)),
                translation: translation,
                tickCount: ticks.tickCount,
                rulerWidth: bounds.width)
            setCoarsePosition(target)
        case .ended, .cancelled, .failed:
            coarseGestureCancelled = false
            endCoarseDrag()
        default:
            break
        }
    }

    private func beginCoarseDrag(at location: CGPoint) {
        guard !coarseDragging, configuration?.active == true, !dragging else { return }
        if decelerating { cancelMotion() }
        if let configuration, ticks.tickCount != configuration.tickCount {
            ticks.tickCount = configuration.tickCount
            updateGeometry()
            redraw()
        }
        coarseGestureCancelled = false
        coarseDragging = true
        coarseLastX = location.x
        velocity = 0
        lastFeedbackPosition = min(Double(ticks.tickCount), max(0, position))
        lastBoundary = boundary(at: lastFeedbackPosition)
        scrollView.isScrollEnabled = false
        scrollView.panGestureRecognizer.isEnabled = false
        showCoarseBubble()
        updateAccessibility()
        coarseFeedback.prepare()
        coarseFeedback.impactOccurred(intensity: 0.8)
        configuration?.onBegin()
        recordMotion(force: true)
    }

    private func setCoarsePosition(_ target: Double) {
        let bounded = min(Double(ticks.tickCount), max(0, target))
        suppressScroll = true
        scrollView.setContentOffset(CGPoint(x: maximumOffset - CGFloat(bounded) * HistoryRulerTicks.spacing, y: 0), animated: false)
        suppressScroll = false
        redraw()
        let now = ProcessInfo.processInfo.systemUptime
        if let configuration { appliedRevision = configuration.onMove(bounded) }
        updateCoarseBubble()
        feedback(at: bounded, time: now)
        recordMotion()
    }

    private func endCoarseDrag() {
        guard coarseDragging else { return }
        coarseDragging = false
        coarseGestureCancelled = false
        coarsePress.isEnabled = false
        scrollView.isScrollEnabled = configuration?.active ?? false
        scrollView.panGestureRecognizer.isEnabled = configuration?.active ?? false
        removeCoarseBubble()
        updateAccessibility()
        if let configuration { appliedRevision = configuration.onMove(min(Double(ticks.tickCount), max(0, position))) }
        configuration?.onEnd()
        coarsePress.isEnabled = configuration?.active ?? false
        recordMotion(force: true)
    }

    private func updateAccessibility() {
        let value = configuration?.value ?? ""
        scrollView.accessibilityValue = coarseDragging
            ? (value.isEmpty ? "Coarse mode" : "\(value), coarse mode")
            : value
        scrollView.accessibilityHint = coarseDragging
            ? "Coarse mode is active. Release to stop."
            : normalAccessibilityHint
    }

    private func showCoarseBubble() {
        guard coarseDragging else { return }
        if let window {
            if coarseBubble.superview !== window {
                coarseBubble.removeFromSuperview()
                window.addSubview(coarseBubble)
            }
        } else if coarseBubble.superview !== self {
            coarseBubble.removeFromSuperview()
            addSubview(coarseBubble)
        }
        coarseBubble.isHidden = false
        updateCoarseBubble()
    }

    private func updateCoarseBubble() {
        guard coarseDragging else { return }
        coarseBubble.valueLabel.text = configuration?.value ?? ""
        coarseBubble.isHidden = false
        updateCoarseBubblePosition()
    }

    private func updateCoarseBubblePosition() {
        guard coarseDragging, let host = coarseBubble.superview else { return }
        let anchor = convert(CGPoint(x: bounds.midX, y: bounds.minY), to: host)
        let width = min(260, max(1, host.bounds.width - 24))
        let height = coarseBubble.preferredHeight
        let left = max(12, min(anchor.x - width / 2, host.bounds.width - width - 12))
        let above = anchor.y - height - 8
        let below = convert(CGPoint(x: bounds.midX, y: bounds.maxY), to: host).y + 8
        let desired = above >= host.safeAreaInsets.top + 8 ? above : below
        let top = max(host.safeAreaInsets.top + 8, min(desired, host.bounds.height - host.safeAreaInsets.bottom - height - 8))
        coarseBubble.frame = CGRect(x: left, y: top, width: width, height: height)
    }

    private func removeCoarseBubble() {
        coarseBubble.removeFromSuperview()
        coarseBubble.isHidden = true
    }

    private func boundary(at position: Double) -> Int? {
        if position <= 0 { return 0 }
        if position >= Double(ticks.tickCount) { return ticks.tickCount }
        return nil
    }

    private func feedback(at position: Double, time: Double) {
        let edge = boundary(at: position)
        let crossedTick = position > lastFeedbackPosition
            ? floor(position) > floor(lastFeedbackPosition)
            : ceil(position) < ceil(lastFeedbackPosition)
        if let edge, edge != lastBoundary {
            boundaryFeedback.impactOccurred(intensity: 0.65)
            boundaryFeedback.prepare()
            lastFeedbackTime = time
        } else if crossedTick && time - lastFeedbackTime >= 0.055 {
            selectionFeedback.selectionChanged()
            selectionFeedback.prepare()
            lastFeedbackTime = time
        }
        lastBoundary = edge
        lastFeedbackPosition = position
    }

    private func recordMotion(force: Bool = false) {
#if targetEnvironment(simulator)
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastSampleTime >= 1.0 / 30.0 else { return }
        lastSampleTime = now
        motionSamples.append([now, position * Double(HistoryRulerTicks.spacing), velocity,
                              dragging ? 1 : 0, decelerating ? 1 : 0])
        if motionSamples.count > 180 { motionSamples.removeFirst(motionSamples.count - 180) }
#endif
    }

#if targetEnvironment(simulator)
    var motionValue: String {
        let values: [String: Any] = [
            "position": position * Double(HistoryRulerTicks.spacing), "ticks": position,
            "velocity": velocity, "dragging": dragging, "decelerating": decelerating,
            "coarse": coarseDragging,
            "bubbleVisible": coarseBubbleVisible,
            "bubbleGlass": coarseBubble.usesLiquidGlass,
            "bubbleTime": coarseBubbleVisible ? (coarseBubble.valueLabel.text ?? "") : "",
            "gain": coarseGain,
            "maximum": Double(maximumOffset), "decelerationRate": scrollView.decelerationRate.rawValue,
            "sampleColumns": ["uptime", "position", "velocity", "dragging", "decelerating"],
            "samples": motionSamples
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: values, options: [.sortedKeys]),
              let value = String(data: data, encoding: .utf8) else { return "{}" }
        return value
    }
#endif
}

#if targetEnvironment(simulator)
private final class HistoryRulerMotionElement: UIAccessibilityElement {
    weak var ruler: HistoryRulerContainer?

    override var accessibilityValue: String? {
        get { ruler?.motionValue }
        set {}
    }
}
#endif
