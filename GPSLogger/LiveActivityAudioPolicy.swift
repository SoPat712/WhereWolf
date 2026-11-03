import CoreLocation

struct LiveActivityAudioPolicy {
    static let confirmationInterval: TimeInterval = 15

    enum Kind: CaseIterable {
        case status, minimal, blank, trip

        var isTrip: Bool { self == .trip }
    }

    enum Scene { case foreground, inactive, background }
    enum Action { case keep, hide, restore, waitForForeground }
    private enum Attempt { case ready, background, foreground }

    private(set) var isHiding = false
    private(set) var confirmationDeadline: TimeInterval?
    private var lastSample = -TimeInterval.infinity
    private var pending: [Bool: Attempt] = [:]

    var hasPendingRestore: Bool { !pending.isEmpty }

    func hasPendingRestore(for kind: Kind) -> Bool { pending[kind.isTrip] != nil }

    func shouldSampleLocation(at time: TimeInterval) -> Bool { time - lastSample >= Self.confirmationInterval }

    mutating func sample(enabled: Bool, otherAudioPlaying: Bool,
                         authorization: CLAuthorizationStatus, at time: TimeInterval) {
        lastSample = time
        guard enabled, authorization == .authorizedAlways else {
            confirmationDeadline = nil
            isHiding = false
            return
        }
        guard otherAudioPlaying != isHiding else {
            confirmationDeadline = nil
            return
        }
        if let confirmationDeadline {
            guard time >= confirmationDeadline else { return }
            isHiding = otherAudioPlaying
            self.confirmationDeadline = nil
            return
        }
        confirmationDeadline = time + Self.confirmationInterval
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
