import Foundation

// Messages between the phone and watch apps. WatchConnectivity carries property list types only.
enum WatchCommand: Equatable, Sendable {
    case refresh
    case setTracking(Bool)
    case retryUpdates
    case startTrip(mode: String?)
    case endTrip
    case sendNow
    case setPreset(Int)

    var message: [String: Any] {
        switch self {
        case .refresh: return ["command": "refresh"]
        case .setTracking(let enabled): return ["command": "setTracking", "value": enabled]
        case .retryUpdates: return ["command": "retryUpdates"]
        case .startTrip(let mode): return mode.map { ["command": "startTrip", "value": $0] } ?? ["command": "startTrip"]
        case .endTrip: return ["command": "endTrip"]
        case .sendNow: return ["command": "sendNow"]
        case .setPreset(let preset): return ["command": "setPreset", "value": preset]
        }
    }

    init?(message: [String: Any]) {
        switch message["command"] as? String {
        case "refresh": self = .refresh
        case "setTracking":
            guard let enabled = message["value"] as? Bool else { return nil }
            self = .setTracking(enabled)
        case "retryUpdates": self = .retryUpdates
        case "startTrip": self = .startTrip(mode: message["value"] as? String)
        case "endTrip": self = .endTrip
        case "sendNow": self = .sendNow
        case "setPreset":
            guard let preset = message["value"] as? Int,
                  WatchStatus.presets.contains(where: { $0.id == preset }) else { return nil }
            self = .setPreset(preset)
        default: return nil
        }
    }
}

struct WatchTripMode: Equatable, Identifiable, Sendable {
    let id: String
    let name: String
}

struct WatchStatus: Equatable, Sendable {
    // Tags match the Usage Preset picker in Settings. Custom is a result of other settings, not a choice.
    static let customPreset = 0
    static let presets: [(id: Int, name: String)] = [
        (1, "High Resolution"), (2, "Low Power"), (3, "Balanced"), (4, "Walking / Running"), (5, "Driving")
    ]
    // Matches the delay before the phone's missed-update reminder.
    static let staleAfter: TimeInterval = 600

    var tracking: Bool
    var tripActive: Bool
    var tripMode: String?
    var tripStart: Date?
    var tripDistance: Double
    var lastFix: Date?
    var queued: Int
    var preset: Int
    var metric: Bool
    var modes: [WatchTripMode]

    func isStale(at now: Date) -> Bool {
        guard tracking else { return false }
        guard let lastFix else { return true }
        return now.timeIntervalSince(lastFix) > Self.staleAfter
    }

    var message: [String: Any] {
        var result: [String: Any] = [
            "tracking": tracking, "tripActive": tripActive, "tripDistance": tripDistance,
            "queued": queued, "preset": preset, "metric": metric,
            "modes": modes.map { ["id": $0.id, "name": $0.name] }
        ]
        if let tripMode { result["tripMode"] = tripMode }
        if let tripStart { result["tripStart"] = tripStart.timeIntervalSince1970 }
        if let lastFix { result["lastFix"] = lastFix.timeIntervalSince1970 }
        return result
    }

    init(tracking: Bool, tripActive: Bool, tripMode: String?, tripStart: Date?, tripDistance: Double,
         lastFix: Date?, queued: Int, preset: Int, metric: Bool, modes: [WatchTripMode]) {
        self.tracking = tracking
        self.tripActive = tripActive
        self.tripMode = tripMode
        self.tripStart = tripStart
        self.tripDistance = tripDistance
        self.lastFix = lastFix
        self.queued = queued
        self.preset = preset
        self.metric = metric
        self.modes = modes
    }

    init?(message: [String: Any]) {
        guard let tracking = message["tracking"] as? Bool,
              let tripActive = message["tripActive"] as? Bool,
              let queued = message["queued"] as? Int,
              let preset = message["preset"] as? Int else { return nil }
        self.tracking = tracking
        self.tripActive = tripActive
        self.queued = queued
        self.preset = preset
        tripMode = message["tripMode"] as? String
        tripStart = (message["tripStart"] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
        tripDistance = message["tripDistance"] as? Double ?? 0
        lastFix = (message["lastFix"] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
        metric = message["metric"] as? Bool ?? false
        modes = (message["modes"] as? [[String: String]] ?? []).compactMap { mode in
            guard let id = mode["id"], let name = mode["name"] else { return nil }
            return WatchTripMode(id: id, name: name)
        }
    }
}
