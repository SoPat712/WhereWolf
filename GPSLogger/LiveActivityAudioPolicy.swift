import CoreLocation

struct LiveActivityAudioPolicy {
    enum Kind: CaseIterable {
        case status, minimal, blank, trip

        var isTrip: Bool { self == .trip }
    }

    enum Scene { case foreground, inactive, background }
    enum Action { case keep, hide, restore, waitForForeground }
    private enum Attempt { case ready, background, foreground }

    private(set) var isHiding = false
    private var audioSince: TimeInterval?
    private var lastSample = -TimeInterval.infinity
    private var pending: [Bool: Attempt] = [:]

    func shouldSampleLocation(at time: TimeInterval) -> Bool { time - lastSample >= 15 }

    mutating func sample(enabled: Bool, otherAudioPlaying: Bool,
                         authorization: CLAuthorizationStatus, at time: TimeInterval) {
        lastSample = time
        guard enabled, authorization == .authorizedAlways, otherAudioPlaying else {
            audioSince = nil
            isHiding = false
            return
        }
        // Separate readings 15 seconds apart ignore brief prompts without scheduling a wakeup.
        if let audioSince {
            if time - audioSince >= 15 { isHiding = true }
        } else {
            audioSince = time
        }
    }

    mutating func action(for kind: Kind, eligible: Bool, hasActivity: Bool, scene: Scene) -> Action {
        guard eligible else {
            pending.removeValue(forKey: kind.isTrip)
            return .keep
        }
        if isHiding {
            if hasActivity { pending[kind.isTrip] = .ready }
            return .hide
        }
        guard let attempt = pending[kind.isTrip] else { return .keep }
        if hasActivity {
            restored(kind)
            return .keep
        }
        if scene == .foreground, attempt != .foreground {
            return .restore
        }
        if scene == .background, attempt == .ready {
            return .restore
        }
        return .waitForForeground
    }

    mutating func willRequest(_ kind: Kind, scene: Scene) {
        pending[kind.isTrip] = scene == .foreground ? .foreground : .background
    }

    mutating func restored(_ kind: Kind) { pending.removeValue(forKey: kind.isTrip) }

    mutating func foregroundOrRetry() {
        for kind in pending.keys { pending[kind] = .ready }
    }
}
