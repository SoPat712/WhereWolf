import Foundation

enum TripLiveActivityRequestPolicy {
    static let intentTimeout: TimeInterval = 2
    static let relevanceScore: Double = 100
    static let silentSoundName = "TripStartSilence.wav"

    struct IntentStart {
        let tripStart: Date
        let deadline: TimeInterval

        init(tripStart: Date, now: TimeInterval) {
            self.tripStart = tripStart
            deadline = now + TripLiveActivityRequestPolicy.intentTimeout
        }
    }

    enum Decision { case deferRequest, request, requestAndAlert }

    static func decision(tripStart: Date, enabled: Bool, authorized: Bool, requestPending: Bool,
                         isActive: Bool, audioAction: LiveActivityAudioPolicy.Action,
                         intentStart: IntentStart?, now: TimeInterval) -> Decision {
        guard enabled, authorized, audioAction != .hide, audioAction != .waitForForeground else { return .deferRequest }
        guard requestPending || audioAction == .restore else { return .deferRequest }
        let fromIntent = intentStart.map { $0.tripStart == tripStart && now < $0.deadline } ?? false
        guard isActive || audioAction == .restore || fromIntent else { return .deferRequest }
        return fromIntent && !isActive ? .requestAndAlert : .request
    }
}
