//
//  TripModes.swift
//  Where
//
//  The editable trip-mode catalog. Mode IDs are stable app identifiers; a server receives the
//  configured server value, or the ID when no value was configured.
//

import Foundation
import UIKit

struct TripMode: Codable, Equatable, Identifiable {
    let id: String
    var name: String
    // An SF Symbol name, or one of the app-owned symbols in TripModes.xcassets.
    var symbol: String
    // The Tracker map zooms in closer for slower modes.
    var closeZoom: Bool
    // Other names Siri and Shortcuts accept for this mode.
    var synonyms: [String] = []
    // A key in HealthWorkout.all, or nil when this mode is not saved as a workout.
    var healthWorkout: String? = nil
    // The value sent as trip_mode and as the trip's mode, or nil to send the ID.
    var serverValue: String? = nil

    static let defaults: [TripMode] = [
        // On foot
        TripMode(id: "walk", name: "Walk", symbol: "where.walk", closeZoom: true, synonyms: ["Walking"], healthWorkout: "walking"),
        TripMode(id: "run", name: "Run", symbol: "where.run", closeZoom: true, synonyms: ["Running", "Jog"], healthWorkout: "running"),
        TripMode(id: "hike", name: "Hike", symbol: "where.hike", closeZoom: true, synonyms: ["Hiking"], healthWorkout: "hiking"),
        // Small wheels
        TripMode(id: "bicycle", name: "Bicycle", symbol: "where.bicycle", closeZoom: true, synonyms: ["Bike", "Cycling", "Cycle"], healthWorkout: "cycling"),
        TripMode(id: "ebike", name: "E-Bike", symbol: "where.ebike", closeZoom: true, synonyms: ["Ebike", "Electric Bike", "Electric Bicycle"]),
        TripMode(id: "scooter", name: "Scooter", symbol: "where.scooter", closeZoom: true),
        TripMode(id: "skate", name: "Skate", symbol: "where.skate", closeZoom: true, synonyms: ["Skating", "Ice Skating", "Roller Skating"], healthWorkout: "skating"),
        // Snow
        TripMode(id: "ski", name: "Ski", symbol: "where.ski", closeZoom: true, synonyms: ["Skiing"], healthWorkout: "downhillSkiing"),
        TripMode(id: "snowboard", name: "Snowboard", symbol: "where.snowboard", closeZoom: true, synonyms: ["Snowboarding"], healthWorkout: "snowboarding"),
        TripMode(id: "sleigh", name: "Sleigh", symbol: "where.sleigh", closeZoom: false),
        // Road
        TripMode(id: "car", name: "Car", symbol: "where.car", closeZoom: false, synonyms: ["Drive", "Driving"]),
        TripMode(id: "taxi", name: "Taxi", symbol: "where.taxi", closeZoom: false),
        TripMode(id: "bus", name: "Bus", symbol: "where.bus", closeZoom: false),
        // Rail and cable
        TripMode(id: "tram", name: "Tram", symbol: "where.tram", closeZoom: false, synonyms: ["Streetcar", "Light Rail"]),
        TripMode(id: "metro", name: "Metro", symbol: "where.metro", closeZoom: false, synonyms: ["Subway", "Underground"]),
        TripMode(id: "train", name: "Train", symbol: "where.train", closeZoom: false, synonyms: ["Rail"]),
        TripMode(id: "monorail", name: "Monorail", symbol: "where.monorail", closeZoom: false),
        TripMode(id: "gondola", name: "Gondola", symbol: "where.gondola", closeZoom: false, synonyms: ["Cable Car"]),
        TripMode(id: "funicular", name: "Funicular", symbol: "where.funicular", closeZoom: false, synonyms: ["Incline", "Cliff Railway"]),
        // Water and air
        TripMode(id: "boat", name: "Boat", symbol: "where.boat", closeZoom: false, synonyms: ["Ferry", "Sailing"]),
        TripMode(id: "plane", name: "Plane", symbol: "where.plane", closeZoom: false, synonyms: ["Flight", "Flying"]),
    ]

    // The SF Symbols used by built-in modes before the app-owned icons were added.
    static let previousSymbols: [String: String] = [
        "walk": "figure.walk",
        "run": "figure.run",
        "hike": "figure.hiking",
        "bicycle": "bicycle",
        "ebike": "bicycle",
        "scooter": "scooter",
        "skate": "figure.skating",
        "ski": "figure.skiing.downhill",
        "snowboard": "figure.snowboarding",
        "sleigh": "snowflake",
        "car": "car.fill",
        "taxi": "car.fill",
        "bus": "bus.fill",
        "tram": "tram.fill",
        "metro": "tram.fill.tunnel",
        "train": "train.side.front.car",
        "monorail": "lightrail.fill",
        "gondola": "cablecar.fill",
        "boat": "sailboat.fill",
        "plane": "airplane",
    ]

    // Built-ins known by versions before Hike, Ski, Snowboard, Skate and Funicular existed.
    static let originalIDs: Set<String> = [
        "walk", "run", "bicycle", "ebike", "car", "taxi", "bus", "tram", "train",
        "metro", "gondola", "monorail", "sleigh", "plane", "boat", "scooter",
    ]
}

@objc(GLTripModeStore) final class TripModeStore: NSObject {
    static let modesKey = "TripModes"
    // The built-in IDs known when the saved list was last written.
    static let builtInIDsKey = "TripModesBuiltInIDs"

    private static let unknownSymbol = "location.fill"
    private static var injectedDefaults: UserDefaults?

    // Tests use an isolated suite so migration and validation never touch app preferences.
    static func setUserDefaults(_ defaults: UserDefaults?) {
        injectedDefaults = defaults
    }

    static func resetUserDefaults() {
        injectedDefaults = nil
    }

    private static let productionDefaults: UserDefaults? = {
        if SharedTripState.isSharedStorageAvailable { return UserDefaults(suiteName: SharedTripState.appGroup) }
        return Bundle.main.bundleURL.pathExtension.lowercased() == "appex" ? nil : .standard
    }()

    static func persistenceDefaults() -> UserDefaults? { injectedDefaults ?? productionDefaults }

    static var modes: [TripMode] {
        guard let defaults = persistenceDefaults(),
              let data = defaults.data(forKey: modesKey),
              let saved = try? JSONDecoder().decode([TripMode].self, from: data),
              !saved.isEmpty else {
            return TripMode.defaults
        }

        // A missing marker is an old list. IDs in the marker were known and intentionally
        // deleted; only defaults introduced later are appended.
        let known = defaults.stringArray(forKey: builtInIDsKey).map(Set.init) ?? TripMode.originalIDs
        let savedIDs = Set(saved.map(\.id))

        // Keep user edits, but replace an old built-in SF Symbol with the app-owned icon.
        let migrated = saved.map { mode in
            guard TripMode.previousSymbols[mode.id] == mode.symbol,
                  let builtIn = TripMode.defaults.first(where: { $0.id == mode.id }) else { return mode }
            var updated = mode
            updated.symbol = builtIn.symbol
            return updated
        }
        let newer = TripMode.defaults.filter { !known.contains($0.id) && !savedIDs.contains($0.id) }
        return migrated + newer
    }

    static func mode(_ id: String?) -> TripMode? {
        guard let id else { return nil }
        return modes.first { $0.id == id }
    }

    @objc static var allModeIDs: [String] {
        modes.map(\.id)
    }

    // The mode used when none has been chosen yet, or the chosen mode was removed.
    @objc static var defaultModeID: String {
        if modes.contains(where: { $0.id == "bicycle" }) { return "bicycle" }
        return modes.first?.id ?? TripMode.defaults[0].id
    }

    @objc(containsModeID:) static func contains(_ id: String?) -> Bool {
        mode(id) != nil
    }

    @objc(nameForModeID:) static func name(_ id: String) -> String {
        mode(id)?.name ?? id
    }

    // A mode removed during a trip keeps sending its ID.
    @objc(serverValueForModeID:) static func serverValue(_ id: String) -> String {
        mode(id)?.serverValue ?? id
    }

    // For remote config, prefer the explicit server value and then the mode ID.
    @objc(modeIDForServerValue:) static func modeID(serverValue value: String) -> String? {
        let modes = self.modes
        return (modes.first { ($0.serverValue ?? $0.id) == value } ?? modes.first { $0.id == value })?.id
    }

    @objc(symbolForModeID:) static func symbol(_ id: String) -> String {
        mode(id)?.symbol ?? unknownSymbol
    }

    @objc(closeZoomForModeID:) static func closeZoom(_ id: String) -> Bool {
        mode(id)?.closeZoom ?? false
    }

    static func healthWorkout(_ id: String) -> String? {
        mode(id)?.healthWorkout
    }
}
