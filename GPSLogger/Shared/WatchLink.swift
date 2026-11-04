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
    static let fallbackSymbol = "location.fill"

    let id: String
    let name: String
    let symbol: String

    init(id: String, name: String, symbol: String = WatchTripMode.fallbackSymbol) {
        self.id = id
        self.name = name
        self.symbol = symbol.isEmpty ? Self.fallbackSymbol : symbol
    }

    var message: [String: String] { ["id": id, "name": name, "symbol": symbol] }

    init?(message: [String: String]) {
        guard let id = message["id"], let name = message["name"] else { return nil }
        self.init(id: id, name: name, symbol: message["symbol"] ?? Self.fallbackSymbol)
    }
}

struct WatchStatus: Equatable, Sendable {
    // Tags match the Usage Preset picker in Settings. Custom is a result of other settings, not a choice.
    static let customPreset = 0
    static let presets: [(id: Int, name: String)] = [
        (6, "Everyday Detailed"),
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
    var tripSymbol: String?

    var presetName: String {
        Self.presets.first { $0.id == preset }?.name ?? "Custom"
    }

    func isStale(at now: Date) -> Bool {
        guard tracking else { return false }
        guard let lastFix else { return true }
        return now.timeIntervalSince(lastFix) > Self.staleAfter
    }

    var message: [String: Any] {
        var result: [String: Any] = [
            "tracking": tracking, "tripActive": tripActive, "tripDistance": tripDistance,
            "queued": queued, "preset": preset, "metric": metric,
            "modes": modes.map(\.message)
        ]
        if let tripMode { result["tripMode"] = tripMode }
        if let tripSymbol { result["tripSymbol"] = tripSymbol }
        if let tripStart { result["tripStart"] = tripStart.timeIntervalSince1970 }
        if let lastFix { result["lastFix"] = lastFix.timeIntervalSince1970 }
        return result
    }

    init(tracking: Bool, tripActive: Bool, tripMode: String?, tripStart: Date?, tripDistance: Double,
         lastFix: Date?, queued: Int, preset: Int, metric: Bool, modes: [WatchTripMode], tripSymbol: String? = nil) {
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
        self.tripSymbol = tripSymbol
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
        tripSymbol = message["tripSymbol"] as? String
        tripStart = (message["tripStart"] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
        tripDistance = message["tripDistance"] as? Double ?? 0
        lastFix = (message["lastFix"] as? TimeInterval).map(Date.init(timeIntervalSince1970:))
        metric = message["metric"] as? Bool ?? false
        modes = (message["modes"] as? [[String: String]] ?? []).compactMap { WatchTripMode(message: $0) }
    }
}

// Home's state and copy are shared with the phone's tests, without importing watch UI.
struct WatchHomePresentation: Equatable, Sendable {
    enum Hero: Equatable, Sendable {
        case tracking, off, stale, unreachable
    }

    enum RowKind: Hashable, Sendable {
        case refresh, retryUpdates, startTrip, trip, endTrip, sendNow, preset
    }

    struct Row: Equatable, Identifiable, Sendable {
        let id: RowKind
        let title: String
        let subtitle: String?
        let isEnabled: Bool
    }

    let hero: Hero
    let title: String
    let subtitle: String
    let heroLabel: String
    let heroIsEnabled: Bool
    let rows: [Row]

    var heroValue: String { "\(title). \(subtitle)" }

    init(status: WatchStatus?, unreachable: Bool, busy: Bool = false, now: Date) {
        let canControl = status != nil && !unreachable && !busy
        if unreachable || status == nil {
            hero = .unreachable
            title = "Can’t Reach iPhone"
            subtitle = "Bring it closer, or open WhereWolf there."
            heroLabel = "Tracking unavailable"
        } else if status?.tracking == false {
            hero = .off
            title = "Tracking Off"
            subtitle = "Tap to start"
            heroLabel = "Start Tracking"
        } else {
            let stale = status?.isStale(at: now) == true
            hero = stale ? .stale : .tracking
            title = stale ? "No Updates" : "Tracking"
            if let fix = status?.lastFix {
                let age = max(0, now.timeIntervalSince(fix))
                let elapsed = stale || age >= 60 ? "\(Int(age / 60)) min" : "\(Int(age)) s"
                subtitle = "Last fix \(elapsed) ago"
            } else {
                subtitle = "No fix yet"
            }
            heroLabel = "Stop Tracking"
        }
        heroIsEnabled = canControl

        var rows: [Row] = []
        if hero == .unreachable {
            rows.append(Row(id: .refresh, title: "Try Again", subtitle: nil, isEnabled: !busy))
        } else if hero == .stale {
            rows.append(Row(id: .retryUpdates, title: "Retry Updates", subtitle: "Restarts location updates", isEnabled: canControl))
        }
        if status?.tripActive == true {
            rows.append(Row(id: .trip, title: status?.tripMode ?? "Trip", subtitle: nil, isEnabled: !unreachable))
            rows.append(Row(id: .endTrip, title: "End Trip", subtitle: nil, isEnabled: canControl))
        } else {
            rows.append(Row(id: .startTrip, title: "Start Trip",
                            subtitle: status?.tracking == false ? "Tracks just the trip" : nil,
                            isEnabled: canControl && status?.modes.isEmpty == false))
        }
        let waiting = status.map { $0.queued > 0 ? "\($0.queued.formatted()) waiting" : "Nothing waiting" }
        rows.append(Row(id: .sendNow, title: "Send Now", subtitle: waiting,
                        isEnabled: canControl && (status?.queued ?? 0) > 0))
        rows.append(Row(id: .preset, title: "Preset",
                        subtitle: status?.tripActive == true ? "Locked during a trip" : status?.presetName,
                        isEnabled: canControl && status?.tripActive == false))
        self.rows = rows
    }
}
