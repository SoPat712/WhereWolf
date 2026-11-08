import SwiftUI
import MapKit
import UIKit

@Observable
@MainActor
final class HistoryPlaybackModel {
    private(set) var points: [RecordedLocation] = [] {
        didSet { setRulerStep(rulerStep) }
    }
    private(set) var landmarks = HistoryLandmarks(points: [], timeline: ReplayTimeline(points: []), places: [])
    private(set) var selectedIndex: Int?
    private(set) var payload: RecordedPayload?
    private(set) var isPlaying = false
    private(set) var playbackTime: TimeInterval?
    private(set) var renderPose: ReplayPose?
    private(set) var rulerTime: Date?
    private(set) var rulerPosition: Double?
    private(set) var rulerInteractionRevision = 0
    private(set) var isRulerInteracting = false
    private(set) var rulerHold: ReplayRulerHold?
    private(set) var rulerHoldCancelled = false
    private(set) var rulerStep = 1.0
    @ObservationIgnored let rulerScaleChannel = RulerScaleChannel()
    private var rulerWidth: CGFloat = 350
    private(set) var consumerActive = false
    private(set) var retentionRevision = 0
    var isBrowsing = false
    var playbackRate = 1.0

    var rulerDetents: HistoryRulerCoarseDrag.Detents {
        .init(tickCount: points.isEmpty ? 48 : points.count, rulerWidth: rulerWidth)
    }

    var rulerZoom: ReplayRulerHold? {
        guard rulerStep > 1 else { return nil }
        return rulerDetents.zoom(step: rulerStep, width: rulerWidth)
    }

    func setRulerWidth(_ width: CGFloat) {
        guard width > 0, width != rulerWidth else { return }
        rulerWidth = width
        setRulerStep(rulerStep)
    }

    func setRulerStep(_ step: Double) {
        let step = rulerDetents.nearestStep(to: step)
        guard rulerStep != step else { return }
        rulerStep = step
        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: rulerScaleLabel.buttonAccessibility)
        }
    }

    var rulerScaleLabel: HistoryRulerCoarseDrag.ScaleLabel {
        HistoryRulerCoarseDrag.scaleLabel(pointsPerTick: rulerStep, pointCount: points.count,
            timestampAt: { self.points[$0].timestamp }, emptyInterval: retentionInterval / 48)
    }

    var rulerScaleMenu: [HistoryRulerCoarseDrag.MenuEntry] {
        let interval = HistoryRulerCoarseDrag.estimatedInterval(pointCount: points.count,
            timestampAt: { self.points[$0].timestamp }, emptyInterval: retentionInterval / 48)
        return rulerDetents.menuEntries(interval: interval ?? retentionInterval / 48, current: rulerStep)
    }

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
    @ObservationIgnored private let placesProvider: () -> [WifiPlace]
    @ObservationIgnored private let landmarkBuilder: HistoryLandmarks.Builder
    @ObservationIgnored private let landmarkClock: () -> TimeInterval
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var landmarkGeneration = 0
    @ObservationIgnored private var lastLandmarkBuild: TimeInterval?
    @ObservationIgnored private var needsLandmarkRebuild = false
    @ObservationIgnored private var scheduledLandmarkRebuild: DispatchWorkItem?
    @ObservationIgnored private var landmarkPlaces: [WifiPlace] = []
    @ObservationIgnored private var landmarkCalendar: Calendar?
    @ObservationIgnored private var landmarkLocale: Locale?
    @ObservationIgnored private let retentionDurationProvider: () -> TimeInterval
    @ObservationIgnored private var payloadCache: [Int64: RecordedPayload] = [:]
    @ObservationIgnored private var payloadLoading = false
    @ObservationIgnored private var needsPayloadReload = false
    @ObservationIgnored private var lastPrefetchIndex: Int?
    private var pointsRevision = 0
    private var payloadRevision = 0
    @ObservationIgnored private var routeCache: (revision: Int, geometry: ReplayRouteGeometry)?
    @ObservationIgnored private var liveRulerCache: (revision: Int, geometry: LiveRulerGeometry)?
    @ObservationIgnored private var timelineCache: (revision: Int, count: Int, timeline: ReplayTimeline)?

    init(pointLoader: @escaping (Int64, @escaping ([RecordedLocation]) -> Void) -> Void = {
        RecentLocationHistory.shared.load(after: $0, completion: $1)
    }, payloadLoader: @escaping ([Int64], @escaping ([Int64: RecordedPayload]) -> Void) -> Void = {
        RecentLocationHistory.shared.loadPayloads(ids: $0, completion: $1)
    }, retentionDuration: @escaping () -> TimeInterval = { HistoryRetention.duration },
         places: @escaping () -> [WifiPlace] = { (GLManager.shared().wifiPlaces ?? []).compactMap(WifiPlace.init) },
         landmarkBuilder: @escaping HistoryLandmarks.Builder = HistoryLandmarks.build,
         landmarkClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         clock: @escaping () -> Date = Date.init) {
        self.pointLoader = pointLoader
        self.payloadLoader = payloadLoader
        self.retentionDurationProvider = retentionDuration
        self.placesProvider = places
        self.landmarkBuilder = landmarkBuilder
        self.landmarkClock = landmarkClock
        self.clock = clock
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

    var liveRulerGeometry: LiveRulerGeometry {
        if let liveRulerCache, liveRulerCache.revision == pointsRevision {
            return liveRulerCache.geometry
        }
        let geometry = LiveRulerGeometry(points: points)
        liveRulerCache = (pointsRevision, geometry)
        return geometry
    }

    var routeGeometry: ReplayRouteGeometry? {
        guard isBrowsing, selectedIndex != nil else { return nil }
        if let routeCache, routeCache.revision == pointsRevision {
            return routeCache.geometry
        }
        let geometry = ReplayRouteGeometry(points: points, stays: timeline.stays)
        routeCache = (pointsRevision, geometry)
        return geometry
    }

    private var timeline: ReplayTimeline {
        if let timelineCache, timelineCache.revision == pointsRevision, timelineCache.count == points.count {
            return timelineCache.timeline
        }
        let timeline = ReplayTimeline(points: points)
        timelineCache = (pointsRevision, points.count, timeline)
        return timeline
    }

    var replayStatus: ReplayStatus? {
        _ = payloadRevision
        guard isBrowsing, let index = selectedIndex, let point = selectedPoint else { return nil }
        let timeline = timeline
        let activity: ReplayActivity
        if let stay = timeline.stay(containing: index) {
            activity = .stayed(stay.span)
        } else {
            activity = ReplayActivity.resolved(recorded: payloadCache[point.id]?.motion ?? [],
                                               inferred: timeline.inferredActivity(at: index))
        }
        // Playback can outrun payload reads, so nearby readings hold the value steady.
        let altitudes = points[max(0, index - 24)...index].compactMap { payloadCache[$0.id]?.altitude }
        return ReplayStatus(activity: activity,
                            minute: Int(point.timestamp.timeIntervalSince1970 / 60),
                            altitude: altitudes.last,
                            altitudeTrend: ReplayStatus.trend(altitudes),
                            legDistance: timeline.legDistance(at: index))
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
            scheduledLandmarkRebuild?.cancel()
            scheduledLandmarkRebuild = nil
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
            // Expiry shifts every index, so landmarks rebuild at once, but only after the new points are in.
            let expired = self.expireOldPoints(force: false, rebuildingLandmarks: false)
            let selectedID = self.selectedPoint?.id
            let cutoff = self.clock().addingTimeInterval(-self.retentionInterval)
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
            let places = self.placesProvider()
            let contextChanged = places != self.landmarkPlaces
                || self.landmarkCalendar != Calendar.current || self.landmarkLocale != Locale.current
            if fullSnapshot || !ordered.isEmpty || contextChanged || expired {
                self.rebuildLandmarks(places: places, promptly: fullSnapshot || contextChanged || expired)
            }
            self.prefetchPayloads(around: self.selectedIndex ?? max(0, self.points.count - 1))
            self.loading = false
            self.flushDeferredReload()
        }
    }

    private func rebuildLandmarks(places: [WifiPlace]? = nil, promptly: Bool = true) {
        needsLandmarkRebuild = true
        let now = landmarkClock()
        if !promptly, let lastLandmarkBuild {
            let delay = lastLandmarkBuild + 30 - now
            if delay > 0 {
                if scheduledLandmarkRebuild == nil, consumerActive {
                    let work = DispatchWorkItem { [weak self] in
                        guard let self else { return }
                        self.scheduledLandmarkRebuild = nil
                        self.flushLandmarkRebuild()
                    }
                    scheduledLandmarkRebuild = work
                    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
                }
                return
            }
        }
        scheduledLandmarkRebuild?.cancel()
        scheduledLandmarkRebuild = nil
        needsLandmarkRebuild = false
        lastLandmarkBuild = now
        let places = places ?? placesProvider()
        let calendar = Calendar.current
        let locale = Locale.current
        landmarkPlaces = places
        landmarkCalendar = calendar
        landmarkLocale = locale
        landmarkGeneration &+= 1
        let generation = landmarkGeneration
        // Value copies and an immutable timeline belong to this generation even if points change.
        let points = points
        let timeline = timeline
        landmarkBuilder(points, timeline, places, calendar, locale) { [weak self] result in
            guard let self, self.landmarkGeneration == generation else { return }
            self.landmarks = result
        }
    }

    // Go To lists every stretch, so opening it does not wait for the coalesced build.
    func refreshLandmarks() {
        guard needsLandmarkRebuild, consumerActive, !isRulerInteracting, !isPlaying, !loading, !expiring else { return }
        rebuildLandmarks()
    }

    private func flushLandmarkRebuild() {
        guard needsLandmarkRebuild, consumerActive, !isRulerInteracting, !isPlaying, !loading, !expiring else { return }
        rebuildLandmarks(promptly: false)
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
        guard consumerActive, !isRulerInteracting, !isPlaying, !loading, !expiring else { return }
        if needsReload || needsFullSnapshot {
            needsReload = false
            reload()
        } else {
            flushLandmarkRebuild()
        }
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

    @discardableResult
    private func expireOldPoints(force: Bool, rebuildingLandmarks: Bool = true) -> Bool {
        guard force || consumerActive else { return false }
        let now = clock()
        guard force || now.timeIntervalSince(lastExpiration) >= 60 else { return false }
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
        guard points.count != previousCount else { return false }
        pointsRevision &+= 1
        if rebuildingLandmarks { rebuildLandmarks() }
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
        return true
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

    func setRulerHold(_ hold: ReplayRulerHold) {
        rulerHoldCancelled = false
        if rulerHold != hold { rulerHold = hold }
    }

    func endRulerInteraction(cancelled: Bool = true) {
        let wasHolding = rulerHold != nil
        rulerHoldCancelled = cancelled
        rulerHold = nil
        if isRulerInteracting { isRulerInteracting = false }
        if wasHolding { loadSelectedPayload() }
        flushDeferredReload()
    }

    func endRulerInteraction(at position: Double, onLive: () -> Void) {
        if position <= 0 { onLive() }
        endRulerInteraction(cancelled: false)
    }

    func scrub(rulerPosition position: Double, liveEdge: Date) {
        pause()
        if !isBrowsing { isBrowsing = true }
        let position = min(Double(points.isEmpty ? 48 : points.count), max(0, position))
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
            if isPlaying, let stay = timeline.stay(during: index) {
                // Thousands of wandering fixes pass in a second or two; glide so the pin and camera hold steady.
                let progress = (Double(index - stay.start) + fraction) / Double(stay.end - stay.start)
                target = ReplayCoordinate(points[stay.start].coordinate)
                    .interpolated(to: ReplayCoordinate(points[stay.end].coordinate), fraction: progress)
            } else {
                target = start.interpolated(to: ReplayCoordinate(points[index + 1].coordinate), fraction: fraction)
            }
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
        rulerHoldCancelled = true
        rulerHold = nil
        isRulerInteracting = false
        rulerPosition = nil
    }

    func returnToLive() {
        interruptRuler()
        pause()
        rulerStep = 1
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

    func stopBoundary(_ direction: Int) -> HistoryStopBoundary? {
        landmarks.boundary(from: selectedIndex == nil ? Double(points.count) : playbackIndex,
                           direction: direction, pointCount: points.count)
    }

    func jumpToStop(_ direction: Int) {
        guard let target = stopBoundary(direction) else { return }
        scrub(pointAt: target.index)
    }

    func goTo(_ time: Date) {
        guard let index = landmarks.nearestPoint(to: time, pointCount: points.count) else { return }
        scrub(pointAt: index)
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
        let timeline = timeline
        while points.indices.contains(index + 1) {
            let duration = timeline.duration(segment: index, rate: playbackRate)
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
        guard consumerActive, rulerHold == nil, points.indices.contains(index) else { return }
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
            Button { history.jumpToStop(-1) } label: {
                Image(systemName: "backward.end.fill")
                    .font(dynamicTypeSize.isAccessibilitySize ? .system(size: 20, weight: .semibold) : .body)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .glassButtonStyle()
            .buttonBorderShape(.circle)
            .disabled(history.stopBoundary(-1) == nil)
            .accessibilityLabel(history.stopBoundary(-1).map { "Previous stop, \($0.accessibility)" } ?? "Previous stop")

            Button { history.togglePlayback() } label: {
                Image(systemName: history.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .frame(width: 32, height: 32)
            }
            .glassButtonStyle(prominent: true, tint: .blue)
            .buttonBorderShape(.circle)
            .disabled(history.points.count < 2)
            .accessibilityLabel(history.isPlaying ? "Pause" : "Play")

            Button { history.jumpToStop(1) } label: {
                Image(systemName: "forward.end.fill")
                    .font(dynamicTypeSize.isAccessibilitySize ? .system(size: 20, weight: .semibold) : .body)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .glassButtonStyle()
            .buttonBorderShape(.circle)
            .disabled(history.stopBoundary(1) == nil)
            .accessibilityLabel(history.stopBoundary(1).map { "Next stop, \($0.accessibility)" } ?? "Next stop")

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
    @State private var showingGoTo = false
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
        position > 0 && history.isBrowsing
            ? (history.rulerTime ?? Date()).formatted(date: .abbreviated, time: .shortened)
            : "Live"
    }

    private var scaleMenu: some View {
        Menu {
            Section("One bar covers") {
                ForEach(history.rulerScaleMenu) { entry in
                    Button {
                        history.setRulerStep(entry.step)
                    } label: {
                        if entry.selected { Label(entry.title, systemImage: "checkmark") }
                        else { Text(entry.title) }
                    }
                }
            }
        } label: {
            Text(history.rulerScaleLabel.buttonText)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .padding(.horizontal, 7)
                .padding(.vertical, 2)
                .background(.primary.opacity(0.08), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(history.rulerScaleLabel.buttonAccessibility)
        .disabled(history.isRulerInteracting)
    }

    var body: some View {
        VStack(spacing: 0) {
            HistoryRulerSurface(position: position, tickCount: tickCount,
                                step: history.rulerStep, detents: history.rulerDetents,
                                revision: history.rulerInteractionRevision,
                                active: history.consumerActive && scenePhase == .active,
                                reduceMotion: reduceMotion, value: value,
                                points: history.points, landmarks: history.landmarks, retentionInterval: history.retentionInterval,
                                onBegin: {
                liveEdge = Date()
                interactionPointCount = history.points.count
                history.beginRulerInteraction()
                return liveEdge
            }, onMove: { position in
                let appended = history.points.count - interactionPointCount
                history.scrub(rulerPosition: position + Double(appended), liveEdge: liveEdge)
                return history.rulerInteractionRevision
            }, onEnd: { position in
                history.endRulerInteraction(at: position, onLive: onLive)
            }, onCancel: {
                if history.isRulerInteracting { history.endRulerInteraction() }
            }, onHold: { hold in
                history.setRulerHold(hold)
            }, onScale: { step in
                history.setRulerStep(step)
            }, onContinuousScale: { frame in
                history.rulerScaleChannel.send(frame)
            }, onAdjust: { direction in
                let target = min(tickCount, max(0, Int(position.rounded()) + direction))
                if target == 0 { onLive() }
                else if history.points.isEmpty {
                    history.scrub(to: liveEdge.addingTimeInterval(-history.retentionInterval * Double(target) / 48))
                } else {
                    history.scrub(pointAt: history.points.count - target)
                }
            })
            .frame(height: 56)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { history.setRulerWidth($0) }
            HStack {
                if history.isBrowsing && position > 0 {
                    Button {
                        history.pause()
                        showingGoTo = true
                    } label: {
                        HStack(spacing: 4) {
                            Text(value).lineLimit(1).minimumScaleFactor(0.8)
                            Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                        }
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(.primary.opacity(0.08), in: Capsule())
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Go To")
                    .accessibilityValue(value)
                    .disabled(history.points.isEmpty)
                } else {
                    Text(value)
                        .font(.caption2.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.blue)
                        .accessibilityHidden(true)
                }
                if !history.isBrowsing {
                    Text("Pinch for scale; hold to scrub")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                        .accessibilityHidden(true)
                }
                Spacer(minLength: 8)
                scaleMenu
                if history.isBrowsing {
                    Button(action: onLive) {
                        Label("Live", systemImage: "location.fill")
                            .font(.caption2.weight(.semibold))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.blue)
                    .accessibilityLabel("Return to Live")
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
        .sheet(isPresented: $showingGoTo) { HistoryGoToView(history: history) }
    }
}

enum HistoryRulerCoarseDrag {
    struct Detents {
        // Ordered from whole-history coverage toward point-by-point precision.
        let steps: [Double]

        init(tickCount: Int, rulerWidth: CGFloat) {
            let width = max(1, Double(rulerWidth))
            let coarsest = Double(tickCount) * 12 <= width ? 1
                : HistoryRulerCoarseDrag.niceStep(Double(max(1, tickCount)) * 18 / width)
            var steps = [1.0]
            var magnitude = 1.0
            while steps.last! < coarsest {
                for multiplier in [2.0, 5, 10] where steps.last! < coarsest {
                    steps.append(multiplier * magnitude)
                }
                magnitude *= 10
            }
            self.steps = Array(steps.reversed())
        }

        func nearestStep(to target: Double) -> Double {
            steps[index(nearest: target)]
        }

        func index(nearest target: Double) -> Int {
            let value = log(min(steps[0], max(1, target)))
            return steps.indices.min { abs(log(steps[$0]) - value) < abs(log(steps[$1]) - value) }!
        }

        func bracket(at value: Double) -> Bracket {
            let value = min(steps[0], max(1, value))
            if steps.contains(value) { return Bracket(lower: value, upper: value, t: 0) }
            let upperIndex = steps.lastIndex { $0 > value }!
            let lower = steps[upperIndex + 1], upper = steps[upperIndex]
            return Bracket(lower: lower, upper: upper, t: log(value / lower) / log(upper / lower))
        }

        func settleTarget(at value: Double, velocity: Double = 0, pinchScale: Double = 1) -> Int {
            let nearest = index(nearest: value)
            let projection = velocity.isFinite && pinchScale.isFinite && pinchScale > 0
                ? 0.12 * velocity / pinchScale : 0
            let projected = exp(min(log(steps[0]), max(0, log(value) - projection)))
            return min(steps.count - 1, min(nearest + 1, max(nearest - 1, index(nearest: projected))))
        }

        func zoom(step: Double, width: CGFloat) -> ReplayRulerHold {
            let scale = HistoryRulerCoarseDrag.scale(step: step, coarsest: steps[0])
            return ReplayRulerHold(pointsPerBar: step, visibleBars: Double(width / scale.spacing),
                coarseness: HistoryRulerCoarseDrag.coarseness(step: step, coarsest: steps[0]))
        }

        func scale(at index: Int) -> Scale {
            HistoryRulerCoarseDrag.scale(step: steps[min(steps.count - 1, max(0, index))], coarsest: steps[0])
        }

        func menuEntries(interval: TimeInterval, current: Double) -> [MenuEntry] {
            let targets: [(String, Double)] = [
                ("Every point", 1), ("1 minute", 60 / interval), ("5 minutes", 300 / interval),
                ("15 minutes", 900 / interval), ("1 hour", 3_600 / interval),
                ("6 hours", 21_600 / interval), ("Whole history", steps[0])
            ]
            var seen = Set<Double>()
            return targets.compactMap { title, target in
                let step = nearestStep(to: target)
                guard seen.insert(step).inserted else { return nil }
                return MenuEntry(title: title, step: step, selected: step == current)
            }
        }
    }

    struct Bracket {
        let lower: Double
        let upper: Double
        let t: Double

        var alphas: (lower: Double, upper: Double) {
            guard lower != upper else { return (1, 0) }
            let blend = min(1, max(0, (t - 0.25) / 0.5))
            let eased = blend * blend * (3 - 2 * blend)
            return (1 - eased, eased)
        }

        func distance(lower from: Double, upper to: Double) -> Double {
            if t == 0 { return from }
            if t == 1 { return to }
            return exp(log(max(1, from)) + log(max(1, to) / max(1, from)) * t)
        }

        struct Bar {
            let position: Double
            var alpha: Double
            var majorAlpha: Double
        }

        func bars(in range: ClosedRange<Double>) -> [Bar] {
            var bars: [Double: Bar] = [:]
            let alphas = alphas
            for (step, alpha) in [(lower, alphas.lower), (upper, alphas.upper)] where alpha > 0 {
                let first = Int(ceil(max(0, range.lowerBound) / step))
                let last = Int(floor(range.upperBound / step))
                guard first <= last else { continue }
                for tick in first...last {
                    let position = Double(tick) * step
                    let major = tick.isMultiple(of: 5)
                    var bar = bars[position] ?? Bar(position: position, alpha: 0, majorAlpha: 0)
                    bar.alpha = max(bar.alpha, alpha)
                    if major { bar.majorAlpha = max(bar.majorAlpha, alpha) }
                    bars[position] = bar
                }
            }
            return bars.values.sorted { $0.position < $1.position }
        }
    }

    struct ScaleEase {
        let from: Double
        let to: Double
        let start: Double
        static let duration = 0.22

        func progress(at time: Double) -> Double { min(1, max(0, (time - start) / Self.duration)) }

        func value(at time: Double) -> Double {
            let progress = progress(at: time)
            if progress == 0 { return from }
            if progress == 1 { return to }
            let eased = 1 - pow(1 - progress, 3)
            return exp(log(from) + log(to / from) * eased)
        }
    }

    static func continuous(start: Double, pinchScale: Double, coarsest: Double) -> Double {
        guard pinchScale.isFinite, pinchScale > 0 else { return start }
        let direct = start / pinchScale
        if direct >= 1 && direct <= coarsest { return direct }
        let value = log(max(Double.leastNormalMagnitude, start)) - log(pinchScale)
        let boundary = min(log(coarsest), max(0, value))
        return exp(boundary + (value - boundary) * 0.35)
    }

    struct MenuEntry: Identifiable, Equatable {
        var title: String
        var step: Double
        var selected: Bool
        var id: Double { step }
    }

    struct Hold {
        private var lastX: CGFloat

        init(at location: CGPoint) { lastX = location.x }

        mutating func translation(to location: CGPoint) -> CGFloat {
            defer { lastX = location.x }
            return location.x - lastX
        }
    }

    struct Scale: Equatable {
        var pointsPerTick: Double = 1
        var spacing: CGFloat = 12
        var minorHeight: CGFloat = 12
        var majorHeight: CGFloat = 17
        var lineWidth: CGFloat = 1
        var bottom: CGFloat = 21

        func screenOffset(of tick: Double, at position: Double) -> CGFloat {
            CGFloat((position - tick) / pointsPerTick) * spacing
        }

        func contentOffset(at position: Double, tickCount: Int) -> CGFloat {
            CGFloat((Double(tickCount) - position) / pointsPerTick) * spacing
        }

        func position(at contentOffset: CGFloat, tickCount: Int) -> Double {
            Double((self.contentOffset(at: 0, tickCount: tickCount) - contentOffset) / spacing) * pointsPerTick
        }
    }

    struct ScaleLabel: Equatable {
        var text: String
        var accessibility: String
        var everyPoint = false

        var buttonText: String {
            everyPoint ? "Every point" : text.replacingOccurrences(of: "1 bar ", with: "")
                .replacingOccurrences(of: "= ", with: "") + " per bar"
        }

        var buttonAccessibility: String {
            everyPoint ? "Ruler scale, every point"
                : "Ruler scale, " + accessibility.replacingOccurrences(of: "1 bar ", with: "")
                    .replacingOccurrences(of: "equals ", with: "") + " per bar"
        }
    }

    static func niceStep(_ value: Double) -> Double {
        guard value.isFinite, value > 1 else { return 1 }
        let magnitude = pow(10, floor(log10(value)))
        return [1.0, 2, 5, 10].map { $0 * magnitude }.first { $0 >= value }!
    }

    static func coarseness(step: Double, coarsest: Double) -> Double {
        guard coarsest > 1 else { return 0 }
        return min(1, max(0, log(max(1, step)) / log(coarsest)))
    }

    static func scale(step: Double, coarsest: Double) -> Scale {
        let coarseness = CGFloat(coarseness(step: step, coarsest: coarsest))
        return Scale(pointsPerTick: step, spacing: 12 + 6 * coarseness,
                     minorHeight: 12 + 8 * coarseness, majorHeight: 17 + 7 * coarseness,
                     lineWidth: 1 + 0.6 * coarseness, bottom: 21 + 5 * coarseness)
    }

    static func position(after current: Double, translation: CGFloat, tickCount: Int,
                         scale: Scale) -> Double {
        let maximum = max(0, Double(tickCount))
        let delta = Double(translation / scale.spacing) * scale.pointsPerTick
        return min(maximum, max(0, current + delta))
    }

    static func time(at position: Double, pointCount: Int, timestampAt: (Int) -> Date,
                     liveEdge: Date, retentionInterval: TimeInterval) -> Date {
        if position <= 0 { return liveEdge }
        guard pointCount > 0 else {
            return liveEdge.addingTimeInterval(-retentionInterval * position / 48)
        }
        if position < 1 {
            return liveEdge.addingTimeInterval(timestampAt(pointCount - 1).timeIntervalSince(liveEdge) * position)
        }
        let index = min(Double(pointCount - 1), max(0, Double(pointCount) - position))
        let lower = Int(floor(index))
        let start = timestampAt(lower)
        guard lower + 1 < pointCount else { return start }
        return start.addingTimeInterval(timestampAt(lower + 1).timeIntervalSince(start) * (index - Double(lower)))
    }

    // The history's average time per point. Bars are evenly spaced points, so a bar's time swings from
    // seconds on a drive to hours across a stop; the average names the scale and changes only with it.
    static func estimatedInterval(pointCount: Int, timestampAt: (Int) -> Date,
                                  emptyInterval: TimeInterval) -> TimeInterval? {
        guard pointCount > 0 else { return emptyInterval }
        guard pointCount > 1 else { return nil }
        let interval = timestampAt(pointCount - 1).timeIntervalSince(timestampAt(0)) / Double(pointCount - 1)
        return interval.isFinite && interval > 0 ? interval : nil
    }

    static func scaleLabel(pointsPerTick: Double, pointCount: Int, timestampAt: (Int) -> Date,
                           emptyInterval: TimeInterval) -> ScaleLabel {
        if pointCount > 0 && pointsPerTick == 1 {
            return ScaleLabel(text: "1 bar = 1 point", accessibility: "1 bar equals 1 point", everyPoint: true)
        }
        guard let interval = estimatedInterval(pointCount: pointCount, timestampAt: timestampAt,
                                              emptyInterval: emptyInterval) else {
            let points = String(format: "%.0f", pointsPerTick)
            return ScaleLabel(text: "1 bar = \(points) points", accessibility: "1 bar equals \(points) points")
        }
        let duration = interval * pointsPerTick
        guard duration >= 1 else {
            return ScaleLabel(text: "1 bar ≈ <1 s", accessibility: "1 bar about less than 1 second", everyPoint: pointsPerTick == 1)
        }
        let units: [(seconds: Double, short: String, long: String)] = [
            (86_400, "d", "day"), (3_600, "h", "hour"), (60, "min", "minute"), (1, "s", "second")
        ]
        let unit = units.first { duration >= $0.seconds }!
        let amount = duration / unit.seconds
        let rounding = pow(10, floor(log10(amount)) - 1)
        let rounded = (amount / rounding).rounded() * rounding
        let number = rounded == rounded.rounded() ? String(format: "%.0f", rounded) : String(format: "%.1f", rounded)
        let spokenUnit = unit.long + (rounded == 1 ? "" : "s")
        return ScaleLabel(text: "1 bar ≈ \(number) \(unit.short)", accessibility: "1 bar about \(number) \(spokenUnit)",
                          everyPoint: pointsPerTick == 1)
    }
}

struct HistoryRulerSurface: UIViewRepresentable {
    var position: Double
    var tickCount: Int
    var step: Double
    var detents: HistoryRulerCoarseDrag.Detents
    var revision: Int
    var active: Bool
    var reduceMotion: Bool
    var value: String
    var points: [RecordedLocation]
    var landmarks: HistoryLandmarks
    var retentionInterval: TimeInterval
    var onBegin: () -> Date
    var onMove: (Double) -> Int
    var onEnd: (Double) -> Void
    var onCancel: () -> Void
    var onHold: (ReplayRulerHold) -> Void
    var onScale: (Double) -> Void
    var onContinuousScale: (RulerScaleChannel.Frame?) -> Void
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
    var pointCount = 0
    var position: Double = 0
    var scale = HistoryRulerCoarseDrag.Scale()
    var detents = HistoryRulerCoarseDrag.Detents(tickCount: 1, rulerWidth: 350)
    var snappedStop: Int?
    var landmarks: HistoryLandmarks? {
        didSet {
            guard oldValue !== landmarks else { return }
            widths.removeAll(keepingCapacity: true)
            symbols.removeAll(keepingCapacity: true)
            labelLevel = nil
        }
    }
    private let font = UIFont.systemFont(ofSize: 10, weight: .medium)
    private var widths: [String: CGFloat] = [:]
    private var symbols: [Int: UIImage] = [:]
    private var labelLevel: Int?

    private func measure(_ text: String) {
        if widths[text] == nil {
            if widths.count >= 256 { widths.removeAll(keepingCapacity: true) }
            widths[text] = ceil((text as NSString).size(withAttributes: [.font: font]).width)
        }
    }

    private func symbol(for stop: HistoryStop) -> UIImage? {
        if let cached = symbols[stop.id] { return cached }
        let image = UIImage(systemName: stop.symbol,
            withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .semibold))?
            .withTintColor(UIColor(WifiPlace.tint(for: stop.color)), renderingMode: .alwaysOriginal)
        if symbols.count >= 128 { symbols.removeAll(keepingCapacity: true) }
        symbols[stop.id] = image
        return image
    }

    private func x(at index: Int) -> CGFloat {
        let index = min(max(0, pointCount - 1), max(0, index))
        return bounds.midX + scale.screenOffset(of: Double(tickCount - index), at: position)
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let center = bounds.width / 2
        let selected = Double(tickCount) - position
        let halfWindow = Double((bounds.width / 2 + 100) / scale.spacing) * scale.pointsPerTick
        let maximum = Double(max(0, tickCount - 1))
        let lower = min(maximum, max(0, selected - halfWindow))
        let range = lower...min(maximum, max(lower, selected + halfWindow))
        let visibleStops: ArraySlice<HistoryStop> = pointCount > 0 ? (landmarks?.visibleStops(in: range) ?? []) : []
        for stop in visibleStops {
            let left = x(at: stop.id), right = x(at: stop.end)
            let frame = CGRect(x: max(-8, left - 3), y: 18,
                               width: max(4, min(bounds.width + 8, right + 3) - max(-8, left - 3)),
                               height: bounds.height - 20)
            UIColor(WifiPlace.tint(for: stop.color)).withAlphaComponent(snappedStop == stop.id ? 0.85 : 0.16).setFill()
            UIBezierPath(roundedRect: frame, cornerRadius: 7).fill()
        }
        let visibleGaps: ArraySlice<HistoryGap> = pointCount > 0 ? (landmarks?.visibleGaps(in: range) ?? []) : []
        for gap in visibleGaps where gap.index < pointCount {
            let left = x(at: gap.index - 1), right = x(at: gap.index)
            let width = max(4, right - left)
            UIColor.systemRed.withAlphaComponent(0.22).setFill()
            UIBezierPath(roundedRect: CGRect(x: (left + right - width) / 2, y: 18, width: width,
                                             height: bounds.height - 20), cornerRadius: 4).fill()
        }
        let firstBar = min(Double(tickCount), max(0, position - halfWindow))
        let barRange = firstBar...min(Double(tickCount), max(firstBar, position + halfWindow))
        for bar in detents.bracket(at: scale.pointsPerTick).bars(in: barRange) {
            let x = center + scale.screenOffset(of: bar.position, at: position)
            let stop = landmarks?.stop(containing: Double(tickCount) - bar.position, pointCount: pointCount)
            let snapped = stop.map { $0.id == snappedStop } == true
            let color: UIColor = snapped ? .white : .label
            let minorAlpha = stop == nil ? 0.25 : 0.15
            let alpha = snapped ? 0.95 * bar.alpha
                : max(minorAlpha * bar.alpha, 2 * minorAlpha * bar.majorAlpha)
            let major = CGFloat(bar.majorAlpha / bar.alpha)
            let height = scale.minorHeight + (scale.majorHeight - scale.minorHeight) * major
            context.setStrokeColor(color.withAlphaComponent(CGFloat(alpha)).cgColor)
            context.setLineWidth(scale.lineWidth)
            context.move(to: CGPoint(x: x, y: 22 + scale.bottom - height))
            context.addLine(to: CGPoint(x: x, y: 22 + scale.bottom))
            context.strokePath()
        }
        drawLabels(in: range, stops: visibleStops, gaps: visibleGaps, context: context)
        context.setShadow(offset: .zero, blur: 3, color: UIColor.systemBlue.withAlphaComponent(0.35).cgColor)
        UIColor.systemBlue.setFill()
        UIBezierPath(roundedRect: CGRect(x: center - 2, y: 17, width: 4, height: 34), cornerRadius: 2).fill()
    }

    private func drawLabels(in range: ClosedRange<Double>, stops: ArraySlice<HistoryStop>, gaps: ArraySlice<HistoryGap>,
                            context: CGContext) {
        guard let landmarks, pointCount > 0 else { return }
        struct Label {
            let text: String
            let symbol: UIImage?
            let color: UIColor
            let hairline: CGFloat?
        }
        var labels: [Label] = []
        var candidates: [HistoryRulerLabelLayout.Candidate] = []
        func add(_ text: String, at x: CGFloat, priority: HistoryRulerLabelLayout.Priority,
                 symbol: UIImage? = nil, symbolAt symbolX: CGFloat? = nil, color: UIColor = .secondaryLabel,
                 hairline: CGFloat? = nil) {
            measure(text)
            let width = (widths[text] ?? 0) + (symbol == nil ? 0 : 14)
            let frame = CGRect(x: x, y: 0, width: width, height: 16)
            guard frame.maxX >= 0, frame.minX <= bounds.width else { return }
            candidates.append(.init(id: labels.count, priority: priority, frame: frame,
                                    symbolFrame: symbol.map { _ in CGRect(x: symbolX ?? x, y: 0, width: 14, height: 16) }))
            labels.append(Label(text: text, symbol: symbol, color: color, hairline: hairline))
        }
        for day in HistoryLandmarks.visibleMarks(landmarks.days, in: range) {
            let x = x(at: day.index)
            context.setStrokeColor(UIColor.separator.cgColor)
            context.setLineWidth(0.5)
            context.move(to: CGPoint(x: x, y: 0))
            context.addLine(to: CGPoint(x: x, y: bounds.height))
            context.strokePath()
            add(landmarks.text(for: day), at: x + 3, priority: .day)
        }
        // Fixes are evenly spaced, so a long stop with few fixes can be narrower than its label.
        // The label still centers on it; the layout falls back to the symbol where labels collide.
        for stop in stops {
            let left = max(0, x(at: stop.id)), right = min(bounds.width, x(at: stop.end))
            guard right >= left else { continue }
            measure(stop.label)
            let width = (widths[stop.label] ?? 0) + 14
            let start = max(0, min(bounds.width - width, (left + right - width) / 2))
            add(stop.label, at: start, priority: .stop, symbol: symbol(for: stop),
                symbolAt: max(0, min(bounds.width - 14, (left + right) / 2 - 7)),
                color: UIColor(WifiPlace.tint(for: stop.color)))
        }
        for gap in gaps where gap.index < pointCount {
            let center = (x(at: gap.index - 1) + x(at: gap.index)) / 2
            measure(gap.label)
            let width = widths[gap.label] ?? 0
            add(gap.label, at: max(0, min(bounds.width - width, center - width / 2)), priority: .gap, color: .systemRed)
        }
        let proposed = landmarks.timeLevel(in: range, pointsPerBar: scale.pointsPerTick, spacing: Double(scale.spacing))
        // Require a little extra room before restoring a finer label interval.
        if let previous = labelLevel, proposed < previous {
            let finer = landmarks.timeLevel(in: range, pointsPerBar: scale.pointsPerTick * 1.08,
                                            spacing: Double(scale.spacing))
            if finer < previous { labelLevel = finer }
        } else { labelLevel = proposed }
        let level = labelLevel ?? proposed
        var lastTimeX = -CGFloat.infinity
        for mark in HistoryLandmarks.visibleMarks(landmarks.timeMarks[level], in: range) {
            let x = x(at: mark.index)
            guard x - lastTimeX >= 60 else { continue }
            lastTimeX = x
            add(landmarks.text(for: mark), at: x + 3, priority: .time, hairline: x)
        }
        for placement in HistoryRulerLabelLayout.resolve(candidates) {
            let label = labels[placement.id]
            if let x = label.hairline {
                context.setStrokeColor(UIColor.tertiaryLabel.cgColor)
                context.setLineWidth(0.5)
                context.move(to: CGPoint(x: x, y: 13))
                context.addLine(to: CGPoint(x: x, y: 24))
                context.strokePath()
            }
            var frame = placement.frame
            if let symbol = label.symbol {
                symbol.draw(in: CGRect(x: frame.minX, y: 2, width: 11, height: 11))
                frame.origin.x += 14
                frame.size.width = max(0, frame.width - 14)
            }
            if !placement.symbolOnly {
                (label.text as NSString).draw(in: frame, withAttributes: [.font: font, .foregroundColor: label.color])
            }
        }
    }
}

private final class HistoryRulerCoarseBubble: UIView {
    let captionLabel = UILabel()
    let valueLabel = UILabel()
    private let eventLabel = UILabel()
    private var event: HistoryStopBoundary?
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
        captionLabel.textAlignment = .center
        captionLabel.adjustsFontForContentSizeCategory = true
        valueLabel.font = .preferredFont(forTextStyle: .subheadline)
        valueLabel.textColor = .label
        valueLabel.adjustsFontForContentSizeCategory = true
        valueLabel.lineBreakMode = .byTruncatingTail
        valueLabel.minimumScaleFactor = 0.75
        valueLabel.adjustsFontSizeToFitWidth = true
        valueLabel.textAlignment = .center
        captionLabel.adjustsFontSizeToFitWidth = true
        captionLabel.minimumScaleFactor = 0.75
        eventLabel.font = .preferredFont(forTextStyle: .caption1)
        eventLabel.textAlignment = .center
        eventLabel.adjustsFontForContentSizeCategory = true
        eventLabel.adjustsFontSizeToFitWidth = true
        eventLabel.minimumScaleFactor = 0.7
        eventLabel.isHidden = true
        for label in [captionLabel, valueLabel, eventLabel] {
            label.isAccessibilityElement = false
            material.contentView.addSubview(label)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layoutSubviews() {
        super.layoutSubviews()
        material.frame = bounds
        let inset: CGFloat = 12
        let valueHeight = ceil(valueLabel.font.lineHeight)
        valueLabel.frame = CGRect(x: inset, y: 7, width: bounds.width - inset * 2, height: valueHeight)
        let eventHeight = event == nil ? 0 : ceil(eventLabel.font.lineHeight) + 3
        eventLabel.frame = CGRect(x: inset, y: valueHeight + 10, width: bounds.width - inset * 2,
                                 height: max(0, eventHeight - 3))
        captionLabel.frame = CGRect(x: inset, y: valueHeight + 10 + eventHeight, width: bounds.width - inset * 2,
                                   height: ceil(captionLabel.font.lineHeight))
        layer.shadowPath = UIBezierPath(roundedRect: bounds, cornerRadius: layer.cornerRadius).cgPath
    }

    func setEvent(_ event: HistoryStopBoundary?) {
        guard self.event != event else { return }
        self.event = event
        eventLabel.isHidden = event == nil
        if let event {
            let color = UIColor(WifiPlace.tint(for: event.stop.color))
            let attachment = NSTextAttachment()
            attachment.image = UIImage(systemName: event.stop.symbol,
                withConfiguration: UIImage.SymbolConfiguration(pointSize: eventLabel.font.pointSize))?
                .withTintColor(color, renderingMode: .alwaysOriginal)
            let text = NSMutableAttributedString(attachment: attachment)
            text.append(NSAttributedString(string: " \(event.event)", attributes: [.foregroundColor: color]))
            eventLabel.attributedText = text
        } else { eventLabel.attributedText = nil }
        setNeedsLayout()
    }

    var preferredHeight: CGFloat {
        ceil(captionLabel.font.lineHeight + valueLabel.font.lineHeight) + 17
            + (event == nil ? 0 : ceil(eventLabel.font.lineHeight) + 3)
    }

    override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
        super.traitCollectionDidChange(previousTraitCollection)
        setNeedsLayout()
    }
}

final class HistoryRulerContainer: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let scrollView = HistoryRulerScrollView()
    private let contentView = UIView()
    private let ticks = HistoryRulerTicks()
    private let coarsePress: UILongPressGestureRecognizer
    private let pinch: UIPinchGestureRecognizer
    private let coarseBubble = HistoryRulerCoarseBubble(frame: .zero)
    private let normalAccessibilityHint = "Older points are on the left. Drag right to browse them, or left toward Live. Pinch to change the scale; hold to scrub."
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private let boundaryFeedback = UIImpactFeedbackGenerator(style: .soft)
    private let coarseFeedback = UIImpactFeedbackGenerator(style: .light)
    private var configuration: HistoryRulerSurface?
    private var appliedRevision = 0
    private var suppressScroll = false
    private var dragging = false
    private var decelerating = false
    private var coastsToLive = false
    private var coarseDragging = false
    private var pinching = false
    private var pinchStartStep = 1.0
    private var coarseGestureCancelled = false
    private var hold = HistoryRulerCoarseDrag.Hold(at: .zero)
    private var coarseLevel = 0
    private var stopSnap = HistoryStopSnap()
    private var coarseDetents = HistoryRulerCoarseDrag.Detents(tickCount: 1, rulerWidth: 350)
    private var interactionLiveEdge = Date()
    private weak var drawerSheet: UIView?
    private var scaleLink: CADisplayLink?
    private var scaleTo = HistoryRulerCoarseDrag.Scale()
    private(set) var scaleEase: HistoryRulerCoarseDrag.ScaleEase?
    struct LiveScroll {
        let from: Double
        let start: Double
        static let duration = 0.45
    }
    private(set) var liveScroll: LiveScroll?
    private var liveLink: CADisplayLink?
    private var pendingScaleCommit: Int?
    private var reportsContinuousScale = false
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

    private var maximumOffset: CGFloat { ticks.scale.contentOffset(at: 0, tickCount: ticks.tickCount) }
    // UIScrollView rounds offsets to pixels. Reading a rounded offset back would move an anchored
    // position a little on every scale frame, and could leave Live after a pinch there.
    private var exactPosition: (offset: CGFloat, scale: HistoryRulerCoarseDrag.Scale, tickCount: Int, value: Double)?
    private var position: Double {
        if let exact = exactPosition, exact.offset == scrollView.contentOffset.x,
           exact.scale == ticks.scale, exact.tickCount == ticks.tickCount { return exact.value }
        return ticks.scale.position(at: scrollView.contentOffset.x, tickCount: ticks.tickCount)
    }

    private func setExactPosition(_ value: Double) {
        exactPosition = (scrollView.contentOffset.x, ticks.scale, ticks.tickCount, value)
    }
    private var pixel: CGFloat { 1 / max(1, traitCollection.displayScale) }
    // Momentum and bounces settle on whole pixels, and a coarse scale's Live edge usually falls between two.
    private var scrolledPosition: Double {
        guard maximumOffset - scrollView.contentOffset.x >= pixel else { return 0 }
        return min(Double(ticks.tickCount), max(0, position))
    }
    private var motionPosition: Double { position / ticks.scale.pointsPerTick * Double(ticks.scale.spacing) }
    private var held: Bool { coarseDragging || pinching }
    private var moving: Bool { dragging || decelerating || held || liveScroll != nil }
    private var coarseBubbleVisible: Bool { coarseBubble.superview != nil }

    private var currentValue: String {
        guard moving, let configuration else { return configuration?.value ?? "" }
        if position <= 0 { return "Live" }
        let time = HistoryRulerCoarseDrag.time(at: position, pointCount: configuration.points.count,
                                              timestampAt: { configuration.points[$0].timestamp },
                                              liveEdge: interactionLiveEdge,
                                              retentionInterval: configuration.retentionInterval)
        return time.formatted(date: .abbreviated, time: .shortened)
    }

    private var scaleLabel: HistoryRulerCoarseDrag.ScaleLabel {
        guard let configuration else { return .init(text: "", accessibility: "") }
        return HistoryRulerCoarseDrag.scaleLabel(
            pointsPerTick: pinching ? coarseDetents.nearestStep(to: ticks.scale.pointsPerTick) : ticks.scale.pointsPerTick,
            pointCount: configuration.points.count, timestampAt: { configuration.points[$0].timestamp },
            emptyInterval: configuration.retentionInterval / 48)
    }

    init() {
        coarsePress = UILongPressGestureRecognizer()
        pinch = UIPinchGestureRecognizer()
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
        scrollView.panGestureRecognizer.maximumNumberOfTouches = 1
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.scrollsToTop = false
        scrollView.delegate = self
        scrollView.isAccessibilityElement = true
        scrollView.accessibilityLabel = "Location history ruler"
        scrollView.accessibilityHint = normalAccessibilityHint
        scrollView.accessibilityTraits = .adjustable
        scrollView.onAdjust = { [weak self] direction in
            guard let self else { return }
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
        coarsePress.delegate = self
        coarsePress.addTarget(self, action: #selector(coarsePressChanged(_:)))
        addGestureRecognizer(coarsePress)
        pinch.delegate = self
        pinch.addTarget(self, action: #selector(pinchChanged(_:)))
        addGestureRecognizer(pinch)
        scrollView.accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Finer Scale", target: self, selector: #selector(finerScale)),
            UIAccessibilityCustomAction(name: "Coarser Scale", target: self, selector: #selector(coarserScale))
        ]
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
        let scaleChanged = self.configuration.map {
            $0.detents.steps != configuration.detents.steps || $0.tickCount != configuration.tickCount
                || $0.step != configuration.step || $0.retentionInterval != configuration.retentionInterval
        } ?? false
        let completingStep = pendingScaleCommit.map { coarseDetents.steps[$0] }
            ?? (pinching ? coarseDetents.nearestStep(to: ticks.scale.pointsPerTick) : nil)
        let externalStep = self.configuration.map { $0.step != configuration.step } ?? false
        // Only a pinch or its settle depends on the previous ladder; scrolling and momentum continue.
        if interrupted || (scaleChanged && (pinching || pendingScaleCommit != nil)) { cancelMotion() }
        // Live flies the ruler back at the scale it shows, then eases to the new one.
        let shownIndex = Double(ticks.tickCount) - position
        let returnsToLive = configuration.position == 0 && (self.configuration?.position ?? 0) > 0 && !moving
            && position > 0 && configuration.active && !configuration.reduceMotion && window != nil
        if let completingStep, externalStep, completingStep != configuration.step {
            // An incoming menu choice follows the interrupted gesture's commit.
            configuration.onScale(configuration.step)
        }
        self.configuration = configuration
        ticks.landmarks = configuration.landmarks
        ticks.pointCount = configuration.points.count
        appliedRevision = configuration.revision
        if !moving { ticks.tickCount = configuration.tickCount }
        coarseDetents = configuration.detents
        ticks.detents = coarseDetents
        if !pinching && pendingScaleCommit == nil && !returnsToLive && liveScroll == nil {
            let step = (interrupted || scaleChanged) && !externalStep ? completingStep ?? configuration.step : configuration.step
            coarseLevel = coarseDetents.index(nearest: step)
            let scale = coarseDetents.scale(at: coarseLevel)
            if scale != scaleTo { setScale(scale, animated: configuration.active && !configuration.reduceMotion) }
        }
        scrollView.isScrollEnabled = configuration.active && !held
        if configuration.active && !wasActive { coarseGestureCancelled = false }
        coarsePress.isEnabled = configuration.active && !pinching
        pinch.isEnabled = configuration.active
        if configuration.reduceMotion, scaleEase != nil { finishScale() }
        scrollView.decelerationRate = configuration.reduceMotion ? .fast : .normal
        if configuration.active && held { updateCoarseBubble() }
        if !configuration.active { removeCoarseBubble() }
        updateAccessibility()
        if returnsToLive {
            updateGeometry(at: Double(ticks.tickCount) - shownIndex)
            startLiveScroll()
        }
        updateGeometry()
        if !moving {
            updateGeometry(at: configuration.position)
        }
        redraw()
    }

    private func startLiveScroll() {
        liveScroll = LiveScroll(from: position, start: ProcessInfo.processInfo.systemUptime)
        let target = HistoryRulerLiveFrameTarget(ruler: self)
        let link = CADisplayLink(target: target, selector: #selector(HistoryRulerLiveFrameTarget.frame(_:)))
        let maximum = Float(window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(60, maximum), maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        liveLink = link
    }

    func advanceLiveScroll(at time: Double) {
        guard let scroll = liveScroll else { return }
        let progress = min(1, max(0, (time - scroll.start) / LiveScroll.duration))
        updateGeometry(at: progress < 1 ? scroll.from * pow(1 - progress, 3) : 0)
        redraw()
        guard progress == 1 else { return }
        stopLiveScroll()
        if let configuration { configure(configuration) }
    }

    private func stopLiveScroll() {
        liveLink?.invalidate()
        liveLink = nil
        liveScroll = nil
    }

    // A touch during the flight keeps the ruler where it is, at the scale it shows.
    private func interruptLiveScroll() {
        guard liveScroll != nil else { return }
        stopLiveScroll()
        if let configuration, configuration.step != ticks.scale.pointsPerTick {
            configuration.onScale(ticks.scale.pointsPerTick)
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateGeometry()
        redraw()
        if held { updateCoarseBubblePosition() }
#if targetEnvironment(simulator)
        motionElement.accessibilityFrameInContainerSpace = bounds
#endif
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil { cancelMotion() }
        else if held { showCoarseBubble() }
    }

    private func updateGeometry(at anchoredPosition: Double? = nil) {
        let anchor = anchoredPosition ?? position
        let contentSize = CGSize(width: bounds.width + maximumOffset, height: bounds.height)
        guard anchoredPosition != nil || scrollView.frame != bounds || scrollView.contentSize != contentSize else { return }
        suppressScroll = true
        ticks.frame = bounds
        scrollView.frame = bounds
        contentView.frame = CGRect(origin: .zero, size: contentSize)
        scrollView.contentSize = contentSize
        let offset = CGPoint(x: ticks.scale.contentOffset(at: anchor, tickCount: ticks.tickCount), y: 0)
        if scrollView.contentOffset != offset { scrollView.setContentOffset(offset, animated: false) }
        setExactPosition(anchor)
        suppressScroll = false
    }

    func cancelMotion(notifying: Bool = true) {
        if pinching && pendingScaleCommit == nil {
            pendingScaleCommit = coarseDetents.index(nearest: ticks.scale.pointsPerTick)
            scaleTo = coarseDetents.scale(at: pendingScaleCommit!)
        }
        finishScale()
        let wasMoving = moving
        let wasHeld = held
        stopLiveScroll()
        coarseDragging = false
        pinching = false
        stopSnap.reset()
        dragging = false
        decelerating = false
        velocity = 0
        if wasHeld {
            coarseGestureCancelled = true
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
        coarsePress.isEnabled = configuration?.active ?? false
        updateAccessibility()
        if wasMoving {
            if notifying { configuration?.onCancel() }
            recordMotion(force: true)
        }
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard !held else { return }
        interruptLiveScroll()
        finishScale()
        if let configuration, ticks.tickCount != configuration.tickCount {
            ticks.tickCount = configuration.tickCount
            updateGeometry()
            redraw()
        }
        dragging = true
        decelerating = false
        coastsToLive = false
        velocity = 0
        lastMotionTime = ProcessInfo.processInfo.systemUptime
        lastMotionPosition = motionPosition
        lastFeedbackPosition = position
        lastBoundary = boundary(at: position)
        selectionFeedback.prepare()
        boundaryFeedback.prepare()
        interactionLiveEdge = configuration?.onBegin() ?? Date()
        recordMotion(force: true)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard !suppressScroll, moving, !held, liveScroll == nil else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let points = motionPosition
        let elapsed = now - lastMotionTime
        if elapsed > 0.001 { velocity = (points - lastMotionPosition) / elapsed }
        lastMotionTime = now
        lastMotionPosition = points
        // Momentum aimed at Live returns there on arrival instead of after its bounce settles.
        if decelerating && coastsToLive && scrolledPosition == 0 {
            stopAtLive()
            return
        }
        redraw()
        let bounded = scrolledPosition
        if let configuration { appliedRevision = configuration.onMove(bounded) }
        feedback(at: bounded, time: now)
        recordMotion()
    }

    func scrollViewWillEndDragging(_ scrollView: UIScrollView, withVelocity velocity: CGPoint,
                                  targetContentOffset: UnsafeMutablePointer<CGPoint>) {
        self.velocity = -Double(velocity.x) * 1_000
        // UIKit clamps the target to the content, so momentum that reaches Live targets its edge.
        coastsToLive = maximumOffset - targetContentOffset.pointee.x < pixel
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        guard dragging, !held else { return }
        dragging = false
        decelerating = decelerate
        recordMotion(force: true)
        if !decelerate { finishMotion() }
        else if coastsToLive && scrolledPosition == 0 { stopAtLive() }
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if decelerating { finishMotion() }
    }

    private func stopAtLive() {
        suppressScroll = true
        scrollView.setContentOffset(CGPoint(x: maximumOffset, y: 0), animated: false)
        setExactPosition(0)
        suppressScroll = false
        redraw()
        finishMotion()
    }

    private func finishMotion() {
        let bounded = scrolledPosition
        if let configuration { appliedRevision = configuration.onMove(bounded) }
        dragging = false
        decelerating = false
        velocity = 0
        configuration?.onEnd(bounded)
        recordMotion(force: true)
    }

    private func redraw() {
        ticks.position = position
        ticks.snappedStop = stopSnap.boundary?.stop.id
        ticks.setNeedsDisplay()
        updateAccessibility()
    }

    private func setScale(_ scale: HistoryRulerCoarseDrag.Scale, animated: Bool) {
        scaleLink?.invalidate()
        scaleLink = nil
        scaleEase = nil
        scaleTo = scale
        guard animated, ticks.scale != scale, window != nil else {
            finishScale()
            return
        }
        scaleEase = .init(from: ticks.scale.pointsPerTick, to: scale.pointsPerTick,
                          start: ProcessInfo.processInfo.systemUptime)
        let target = HistoryRulerScaleFrameTarget(ruler: self)
        let link = CADisplayLink(target: target, selector: #selector(HistoryRulerScaleFrameTarget.frame(_:)))
        let maximum = Float(window?.windowScene?.screen.maximumFramesPerSecond ?? 60)
        link.preferredFrameRateRange = CAFrameRateRange(minimum: min(30, maximum), maximum: maximum, preferred: maximum)
        link.add(to: .main, forMode: .common)
        scaleLink = link
        redraw()
    }

    func advanceScale(at time: Double) {
        guard let ease = scaleEase else { return }
        applyScale(ease.value(at: time))
        if ease.progress(at: time) == 1 { finishScale() }
    }

    private func applyScale(_ value: Double) {
        let anchor = position
        ticks.scale = HistoryRulerCoarseDrag.scale(step: value, coarsest: coarseDetents.steps[0])
        updateGeometry(at: anchor)
        redraw()
        if reportsContinuousScale {
            configuration?.onContinuousScale(.init(pointsPerBar: value, detents: coarseDetents, width: bounds.width))
        }
    }

    private func finishScale() {
        scaleLink?.invalidate()
        scaleLink = nil
        scaleEase = nil
        applyScale(scaleTo.pointsPerTick)
        if let level = pendingScaleCommit {
            pendingScaleCommit = nil
            coarseLevel = level
            configuration?.onScale(coarseDetents.steps[level])
        }
        if reportsContinuousScale {
            reportsContinuousScale = false
            configuration?.onContinuousScale(nil)
        }
    }

    var displayedPointsPerBar: Double { ticks.scale.pointsPerTick }
    var anchoredPosition: Double { position }

    // UIView's own method and the delegate's share this selector; both reach here for the ruler's recognizers.
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        if gestureRecognizer === pinch {
            return configuration?.active == true && !coarseDragging && !coarseGestureCancelled
        }
        if gestureRecognizer === coarsePress {
            return configuration?.active == true && !pinching && !dragging && coarsePress.numberOfTouches == 1
        }
        return super.gestureRecognizerShouldBegin(gestureRecognizer)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        // A second finger can take over a one-finger scroll, but cannot take over a hold.
        (gestureRecognizer === pinch && other === scrollView.panGestureRecognizer)
            || (other === pinch && gestureRecognizer === scrollView.panGestureRecognizer)
    }

    @objc private func finerScale() -> Bool { adjustScale(by: 1) }
    @objc private func coarserScale() -> Bool { adjustScale(by: -1) }

    private func adjustScale(by direction: Int) -> Bool {
        cancelMotion()
        let next = min(coarseDetents.steps.count - 1, max(0, coarseLevel + direction))
        guard next != coarseLevel else { return false }
        changeScale(to: next)
        return true
    }

    private func changeScale(to level: Int) {
        guard level != coarseLevel else { return }
        coarseLevel = level
        let scale = coarseDetents.scale(at: level)
        setScale(scale, animated: configuration?.reduceMotion != true)
        configuration?.onScale(scale.pointsPerTick)
        if held { publishHoldScale(); updateCoarseBubble() }
        coarseFeedback.impactOccurred(intensity: 0.55)
        coarseFeedback.prepare()
    }

    @objc private func pinchChanged(_ pinch: UIPinchGestureRecognizer) {
        switch pinch.state {
        case .began:
            beginPinch()
        case .changed:
            updatePinch(scale: Double(pinch.scale))
        case .ended:
            endPinch(scale: Double(pinch.scale), velocity: Double(pinch.velocity))
        case .cancelled, .failed:
            endPinch(scale: Double(pinch.scale), cancelled: true)
            coarseGestureCancelled = false
        default:
            break
        }
    }

    func beginPinch() {
        guard !held, configuration?.active == true else { return }
        interruptLiveScroll()
        // A pinch interrupts the curve at its displayed value rather than its target.
        let value = ticks.scale.pointsPerTick
        scaleLink?.invalidate()
        scaleLink = nil
        scaleEase = nil
        pendingScaleCommit = nil
        let continuing = reportsContinuousScale
        reportsContinuousScale = false
        scaleTo = ticks.scale
        cancelMotion(notifying: false)
        reportsContinuousScale = true
        pinching = true
        coarseGestureCancelled = true
        pinchStartStep = value
        stopSnap.reset()
        interactionLiveEdge = configuration?.onBegin() ?? Date()
        scrollView.isScrollEnabled = false
        coarsePress.isEnabled = false
        publishHoldScale()
        if !continuing { applyScale(value) }
        showCoarseBubble()
    }

    func updatePinch(scale: Double) {
        guard pinching else { return }
        applyScale(HistoryRulerCoarseDrag.continuous(start: pinchStartStep, pinchScale: scale,
                                                    coarsest: coarseDetents.steps[0]))
        updateCoarseBubble()
    }

    func endPinch(scale: Double, velocity: Double = 0, cancelled: Bool = false) {
        guard pinching else { return }
        if !cancelled { updatePinch(scale: scale) }
        let target = coarseDetents.settleTarget(at: ticks.scale.pointsPerTick,
                                               velocity: cancelled ? 0 : velocity, pinchScale: scale)
        pendingScaleCommit = target
        setScale(coarseDetents.scale(at: target), animated: configuration?.reduceMotion != true)
        endCoarseDrag(cancelled: cancelled)
    }

    @objc private func coarsePressChanged(_ press: UILongPressGestureRecognizer) {
        switch press.state {
        case .began:
            guard !coarseGestureCancelled else { return }
            beginCoarseDrag(at: press.location(ofTouch: 0, in: window))
        case .changed:
            guard coarseDragging else { return }
            let location = press.location(ofTouch: 0, in: window)
            let translation = hold.translation(to: location)
            if translation != 0 { moveCoarse(translation: translation, finger: location.x) }
        case .ended:
            coarseGestureCancelled = false
            if coarseDragging { endCoarseDrag() }
        case .cancelled, .failed:
            if coarseDragging { cancelMotion() }
            coarseGestureCancelled = false
        default:
            break
        }
    }

    private func beginCoarseDrag(at location: CGPoint) {
        guard !held, configuration?.active == true, !dragging else { return }
        interruptLiveScroll()
        finishScale()
        if decelerating { cancelMotion() }
        coarseGestureCancelled = false
        coarseDragging = true
        hold = HistoryRulerCoarseDrag.Hold(at: location)
        stopSnap.reset()
        interactionLiveEdge = configuration?.onBegin() ?? Date()
        publishHoldScale()
        velocity = 0
        lastFeedbackPosition = min(Double(ticks.tickCount), max(0, position))
        lastBoundary = boundary(at: lastFeedbackPosition)
        scrollView.isScrollEnabled = false
        scrollView.panGestureRecognizer.isEnabled = false
        showCoarseBubble()
        updateAccessibility()
        coarseFeedback.prepare()
        coarseFeedback.impactOccurred(intensity: 0.8)
        selectionFeedback.prepare()
        boundaryFeedback.prepare()
        moveCoarse(translation: 0, finger: location.x)
        recordMotion(force: true)
    }

    private func publishHoldScale() {
        let scale = coarseDetents.scale(at: coarseLevel)
        configuration?.onHold(ReplayRulerHold(pointsPerBar: scale.pointsPerTick,
                                             visibleBars: Double(bounds.width / scale.spacing),
                                             coarseness: HistoryRulerCoarseDrag.coarseness(
                                                step: scale.pointsPerTick, coarsest: coarseDetents.steps[0])))
    }

    private func moveCoarse(translation: CGFloat, finger: CGFloat) {
        guard let configuration else { return }
        let previousSnap = stopSnap.boundary
        let target = stopSnap.move(position: min(Double(ticks.tickCount), max(0, position)),
                                   translation: Double(translation), finger: Double(finger),
                                   pointsPerBar: ticks.scale.pointsPerTick, spacing: Double(ticks.scale.spacing),
                                   pointCount: configuration.points.count, landmarks: configuration.landmarks)
        if stopSnap.boundary != nil && stopSnap.boundary != previousSnap {
            selectionFeedback.selectionChanged()
            selectionFeedback.prepare()
            lastFeedbackTime = ProcessInfo.processInfo.systemUptime
        }
        setCoarsePosition(target)
    }

    private func setCoarsePosition(_ target: Double) {
        let bounded = min(Double(ticks.tickCount), max(0, target))
        suppressScroll = true
        scrollView.setContentOffset(CGPoint(x: ticks.scale.contentOffset(at: bounded, tickCount: ticks.tickCount), y: 0), animated: false)
        setExactPosition(bounded)
        suppressScroll = false
        redraw()
        let now = ProcessInfo.processInfo.systemUptime
        if let configuration { appliedRevision = configuration.onMove(bounded) }
        updateCoarseBubble()
        feedback(at: bounded, time: now)
        recordMotion()
    }

    private func endCoarseDrag(cancelled: Bool = false) {
        guard held else { return }
        let bounded = min(Double(ticks.tickCount), max(0, position))
        let wasScrubbing = coarseDragging
        coarseDragging = false
        pinching = false
        stopSnap.reset()
        coarseGestureCancelled = false
        coarsePress.isEnabled = false
        scrollView.isScrollEnabled = configuration?.active ?? false
        scrollView.panGestureRecognizer.isEnabled = configuration?.active ?? false
        removeCoarseBubble()
        updateAccessibility()
        if wasScrubbing, let configuration { appliedRevision = configuration.onMove(bounded) }
        if cancelled { configuration?.onCancel() }
        else { configuration?.onEnd(bounded) }
        coarsePress.isEnabled = configuration?.active ?? false
        recordMotion(force: true)
    }

    private func updateAccessibility() {
        let stop = position > 0 ? configuration?.landmarks.stop(containing: Double(ticks.tickCount) - position, pointCount: configuration?.points.count) : nil
        let value = currentValue + (stop.map { ", \($0.accessibility)" } ?? "")
        scrollView.accessibilityValue = "\(value), \(scaleLabel.accessibility)"
        scrollView.accessibilityHint = held
            ? "Drag sideways to scrub while holding, or pinch to change the scale. Release to stop."
            : normalAccessibilityHint
    }

    private func showCoarseBubble() {
        guard held else { return }
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
        guard held else { return }
        let value = currentValue
        if coarseBubble.valueLabel.text != value { coarseBubble.valueLabel.text = value }
        coarseBubble.setEvent(stopSnap.boundary)
        let scale = scaleLabel.text
        if coarseBubble.captionLabel.text != scale { coarseBubble.captionLabel.text = scale }
        coarseBubble.isHidden = false
        updateAccessibility()
        updateCoarseBubblePosition()
    }

    private func updateCoarseBubblePosition() {
        guard held, let host = coarseBubble.superview else { return }
        var anchor = convert(CGPoint(x: bounds.midX, y: bounds.minY), to: host)
        if drawerSheet?.window !== window { drawerSheet = nil }
        if drawerSheet == nil { drawerSheet = findDrawer(in: host) }
        let hasDrawer = drawerSheet != nil
        if let drawerSheet {
            let layer = drawerSheet.layer.presentation() ?? drawerSheet.layer
            let frame = layer.convert(layer.bounds, to: host.layer.presentation() ?? host.layer)
            anchor = CGPoint(x: frame.midX, y: frame.minY)
        }
        let width = min(260, max(1, host.bounds.width - 24))
        let height = coarseBubble.preferredHeight
        let left = max(12, min(anchor.x - width / 2, host.bounds.width - width - 12))
        let above = anchor.y - height - 8
        let below = convert(CGPoint(x: bounds.midX, y: bounds.maxY), to: host).y + 8
        let desired = hasDrawer || above >= host.safeAreaInsets.top + 8 ? above : below
        let top = max(host.safeAreaInsets.top + 8, min(desired, host.bounds.height - host.safeAreaInsets.bottom - height - 8))
        coarseBubble.frame = CGRect(x: left, y: top, width: width, height: height)
    }

    private func findDrawer(in view: UIView) -> UIView? {
        guard !view.isHidden, view.alpha > 0.01 else { return nil }
        if view.accessibilityIdentifier == MapControlPanelController.sheetIdentifier { return view }
        for child in view.subviews {
            if let drawer = findDrawer(in: child) { return drawer }
        }
        return nil
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
        motionSamples.append([now, motionPosition, velocity,
                              dragging ? 1 : 0, decelerating ? 1 : 0])
        if motionSamples.count > 180 { motionSamples.removeFirst(motionSamples.count - 180) }
#endif
    }

#if targetEnvironment(simulator)
    var motionValue: String {
        let values: [String: Any] = [
            "position": motionPosition, "ticks": position,
            "velocity": velocity, "dragging": dragging, "decelerating": decelerating,
            "coarse": coarseDragging,
            "pinching": pinching,
            "bubbleVisible": coarseBubbleVisible,
            "bubbleGlass": coarseBubble.usesLiquidGlass,
            "bubbleTime": coarseBubbleVisible ? (coarseBubble.valueLabel.text ?? "") : "",
            "pointsPerTick": ticks.scale.pointsPerTick, "tickSpacing": ticks.scale.spacing,
            "level": coarseLevel,
            "bubbleScale": coarseBubbleVisible ? (coarseBubble.captionLabel.text ?? "") : "",
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

@MainActor
private final class HistoryRulerLiveFrameTarget: NSObject {
    private weak var ruler: HistoryRulerContainer?

    init(ruler: HistoryRulerContainer) { self.ruler = ruler }

    @objc func frame(_ link: CADisplayLink) {
        guard let ruler else { link.invalidate(); return }
        ruler.advanceLiveScroll(at: link.timestamp)
    }
}

@MainActor
private final class HistoryRulerScaleFrameTarget: NSObject {
    private weak var ruler: HistoryRulerContainer?

    init(ruler: HistoryRulerContainer) { self.ruler = ruler }

    @objc func frame(_ link: CADisplayLink) {
        guard let ruler else { link.invalidate(); return }
        ruler.advanceScale(at: link.timestamp)
    }
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
