//
//  SharedTripState.swift
//  WhereWolf
//
//  A snapshot of the app's state for the widgets and controls. They run in the extension's
//  process and can't read the app's settings, so the app writes this to the App Group and the
//  extension reads it. Compiled into both targets.
//

import Foundation

struct SharedTripState: Codable, Equatable {
    static var appGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "WhereWolfAppGroup") as? String ?? "group.me.joshpatra.WhereWolf"
    }
    private static let defaultsKey = "SharedTripState"

    var trackingEnabled = false
    // Set while a trip is in progress
    var tripStart: Date?
    var tripMode = TripModeStore.defaultModeID
    // Meters, as of updatedAt
    var tripDistance: Double = 0
    var queueCount = 0
    var lastSentDate: Date?
    // The title of the last send error, or nil if the last send succeeded
    var lastSendError: String?
    var todayDistance: Double = 0
    var todayPoints = 0
    var todayStart: Date?
    var lastFixDate: Date?
    var updatedAt = Date()

    var tripInProgress: Bool { tripStart != nil }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case trackingEnabled, tripStart, tripMode, tripDistance, queueCount, lastSentDate
        case lastSendError, todayDistance, todayPoints, todayStart, lastFixDate, updatedAt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        trackingEnabled = try values.decodeIfPresent(Bool.self, forKey: .trackingEnabled) ?? false
        tripStart = try values.decodeIfPresent(Date.self, forKey: .tripStart)
        tripMode = try values.decodeIfPresent(String.self, forKey: .tripMode) ?? TripModeStore.defaultModeID
        tripDistance = try values.decodeIfPresent(Double.self, forKey: .tripDistance) ?? 0
        queueCount = try values.decodeIfPresent(Int.self, forKey: .queueCount) ?? 0
        lastSentDate = try values.decodeIfPresent(Date.self, forKey: .lastSentDate)
        lastSendError = try values.decodeIfPresent(String.self, forKey: .lastSendError)
        todayDistance = try values.decodeIfPresent(Double.self, forKey: .todayDistance) ?? 0
        todayPoints = try values.decodeIfPresent(Int.self, forKey: .todayPoints) ?? 0
        todayStart = try values.decodeIfPresent(Date.self, forKey: .todayStart)
        lastFixDate = try values.decodeIfPresent(Date.self, forKey: .lastFixDate)
        updatedAt = try values.decodeIfPresent(Date.self, forKey: .updatedAt) ?? .distantPast
    }

    func forToday(at date: Date, calendar: Calendar = .current) -> SharedTripState {
        var state = self
        let day = TodayWindow(containing: date, calendar: calendar)
        if todayStart != day.start {
            state.todayDistance = 0
            state.todayPoints = 0
            state.todayStart = day.start
        }
        return state
    }

    static let isSharedStorageAvailable = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil

    private static var defaults: UserDefaults? {
        isSharedStorageAvailable ? UserDefaults(suiteName: appGroup) : nil
    }

    static func read() -> SharedTripState {
        guard let data = defaults?.data(forKey: defaultsKey),
              let state = try? JSONDecoder().decode(SharedTripState.self, from: data) else {
            return SharedTripState()
        }
        return state
    }

    func write() {
        if let data = try? JSONEncoder().encode(self) {
            SharedTripState.defaults?.set(data, forKey: SharedTripState.defaultsKey)
        }
    }
}
