import Foundation

enum TrackingActivityHandoffPolicy {
    enum TripActivity {
        case absent, active, stale, audioHidden

        var supportsBackgroundLocation: Bool { self == .active || self == .stale }
    }

    enum Decision { case ineligible, stepAside, hideForAudio, waitForAudioRestore, keep, request, waitForForeground }

    static func decision(tripActivity: TripActivity, endingTripActivity: Bool, trackingEligible: Bool,
                         hasTrackingActivity: Bool, isForeground: Bool, audioAction: LiveActivityAudioPolicy.Action,
                         endingTripStart: Date?, intentEnd: TripLiveActivityRequestPolicy.IntentAllowance?,
                         now: TimeInterval) -> Decision {
        guard trackingEligible else { return .ineligible }
        if !endingTripActivity && tripActivity != .absent { return .stepAside }
        if audioAction == .hide { return .hideForAudio }
        if audioAction == .waitForForeground { return .waitForAudioRestore }
        if hasTrackingActivity { return .keep }
        let fromIntent = intentEnd.map {
            endingTripActivity && $0.tripStart == endingTripStart && now < $0.deadline
        } ?? false
        return isForeground || audioAction == .restore || fromIntent ? .request : .waitForForeground
    }
}
