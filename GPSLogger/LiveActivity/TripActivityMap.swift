import Foundation

// The geographic frame stays in the app; the extension receives only image-space points.
struct TripActivityMap: Codable, Hashable {
    enum Presentation: String, CaseIterable {
        case island, lockScreen

        var size: CGSize {
            switch self {
            case .island: CGSize(width: 196, height: 78)
            case .lockScreen: CGSize(width: 196, height: 88)
            }
        }
    }

    var token: String
    var routeInMapFrame: TripRouteSketch
    var lockScreenRouteInMapFrame: TripRouteSketch? = nil

    func route(for presentation: Presentation) -> TripRouteSketch? {
        presentation == .island ? routeInMapFrame : lockScreenRouteInMapFrame
    }
}

enum TripActivityMapSettings {
    static let lockScreenKey = "WhereWolfTripMapOnLockScreen"

    static func showsOnLockScreen(defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: lockScreenKey) == nil || defaults.bool(forKey: lockScreenKey)
    }
}

final class TripActivityMapFiles {
    static var sharedDirectory: URL? {
        guard SharedTripState.isSharedStorageAvailable else { return nil }
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: SharedTripState.appGroup)?
            .appendingPathComponent("TripActivityMaps", isDirectory: true)
    }

    let directory: URL?
    private(set) var currentToken: String?
    private(set) var previousToken: String?

    init(directory: URL? = TripActivityMapFiles.sharedDirectory) {
        self.directory = directory
    }

    func url(for token: String, presentation: TripActivityMap.Presentation = .island) -> URL? {
        guard UUID(uuidString: token) != nil else { return nil }
        return directory?.appendingPathComponent(token + "-" + presentation.rawValue + "@2x").appendingPathExtension("jpg")
    }

    func write(_ data: Data, lockScreen: Data? = nil) throws -> String {
        guard var directory else { throw CocoaError(.fileNoSuchFile) }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try directory.setResourceValues(values)
        let token = UUID().uuidString
        let images: [(TripActivityMap.Presentation, Data)] = [(.island, data)] + (lockScreen.map { [(.lockScreen, $0)] } ?? [])
        do {
            for (presentation, image) in images {
                var destination = url(for: token, presentation: presentation)!
                try image.write(to: destination, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
                try destination.setResourceValues(values)
            }
        } catch {
            for presentation in TripActivityMap.Presentation.allCases {
                if let url = url(for: token, presentation: presentation) { try? manager.removeItem(at: url) }
            }
            throw error
        }
        previousToken = currentToken
        currentToken = token
        let keep = Set([currentToken, previousToken].compactMap { $0 }.flatMap { token in
            TripActivityMap.Presentation.allCases.compactMap { url(for: token, presentation: $0)?.lastPathComponent }
        })
        for file in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if !keep.contains(file.lastPathComponent) { try? manager.removeItem(at: file) }
        }
        return token
    }

    func removeLockScreenImages() {
        guard let directory else { return }
        for file in (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if file.lastPathComponent.hasSuffix("-lockScreen@2x.jpg") { try? FileManager.default.removeItem(at: file) }
        }
    }

    func removeAll() {
        if let directory { try? FileManager.default.removeItem(at: directory) }
        currentToken = nil
        previousToken = nil
    }
}
