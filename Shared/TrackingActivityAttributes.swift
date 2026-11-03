import ActivityKit
import Foundation

struct TrackingActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var isTrip: Bool
        var lastSent: Date?
        var appearance: Appearance
        var reminderDeadline: Date?
        // Optional additions also decode activities created before the card was introduced.
        var lastFix: Date? = nil
        var queuedCount: Int? = nil
        var trackingStatus: TrackingStatus? = nil
        var tripModeName: String? = nil
        var tripStart: Date? = nil
        var tripDistance: Double? = nil
        var separateTripActivity: Bool? = nil

        var showsTrip: Bool { isTrip && separateTripActivity != true && tripStart != nil }

        func needsImmediateUpdate(from old: Self) -> Bool {
            appearance != old.appearance || isTrip != old.isTrip || trackingStatus != old.trackingStatus
                || reminderDeadline != old.reminderDeadline || tripStart != old.tripStart
                || separateTripActivity != old.separateTripActivity || tripModeName != old.tripModeName
                || lastSent != old.lastSent || (queuedCount ?? 0) < (old.queuedCount ?? 0)
        }

        func updateDelay(from old: Self, elapsed: TimeInterval) -> TimeInterval? {
            guard self != old else { return nil }
            return needsImmediateUpdate(from: old) ? 0 : max(0, 60 - elapsed)
        }
    }

    enum TrackingStatus: String, Codable { case tracking, paused, stopped }
    enum Appearance: String, Codable, CaseIterable { case status, minimal, blank }
    var startedAt: Date
}

struct TrackingActivityPresentation: Equatable {
    enum Kind { case off, appOnly, widget }
    let enabled: Bool
    let appearance: TrackingActivityAttributes.Appearance
    let lockScreenCard: Bool

    var kind: Kind {
        guard enabled else { return .off }
        return appearance == .blank && !lockScreenCard ? .appOnly : .widget
    }
    var cardVisible: Bool { enabled }
    var cardRequired: Bool { appearance != .blank }
    var cardOn: Bool { enabled && (cardRequired || lockScreenCard) }
    var cardEditable: Bool { enabled && !cardRequired }
    var supportsBackgroundLocation: Bool { kind == .widget }
}
