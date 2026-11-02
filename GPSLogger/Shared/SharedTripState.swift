//
//  SharedTripState.swift
//  Where
//
//  A snapshot of the app's state for the widgets and controls. They run in the extension's
//  process and can't read the app's settings, so the app writes this to the App Group and the
//  extension reads it. Compiled into both targets.
//

import Foundation

struct SharedTripState: Codable, Equatable {
    static var appGroup: String {
        Bundle.main.object(forInfoDictionaryKey: "WhereAppGroup") as? String ?? "group.com.sopat712.where"
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
    var updatedAt = Date()

    var tripInProgress: Bool { tripStart != nil }

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
