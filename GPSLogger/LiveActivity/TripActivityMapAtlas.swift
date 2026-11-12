import Darwin
import ImageIO
import MapKit
import UIKit

struct TripActivityMapAtlasLevel: Codable {
    let level: Int
    let x: Double
    let y: Double
    let width: Double
    let height: Double
    let centerX: Double
    let centerY: Double
    let createdAt: Date
    let file: String

    init(level: Int, frame: TripActivityMapFrame, center: MKMapPoint, createdAt: Date,
         file: String = UUID().uuidString + ".jpg") {
        self.level = level
        x = frame.rect.minX
        y = frame.rect.minY
        width = frame.rect.size.width
        height = frame.rect.size.height
        centerX = center.x
        centerY = center.y
        self.createdAt = createdAt
        self.file = file
    }

    var frame: TripActivityMapFrame? { TripActivityMapFrame(rect: MKMapRect(x: x, y: y, width: width, height: height)) }
    var center: MKMapPoint { MKMapPoint(x: centerX, y: centerY) }
}

enum TripActivityMapAtlasPolicy {
    static let sides: [Double] = [8_000, 24_000, 72_000, 216_000, 648_000]
    static let size = CGSize(width: 1_024, height: 1_024)
    static let pixels = 2_048.0
    static let maximumAge: TimeInterval = 30 * 24 * 60 * 60
    static let rebuildInterval: TimeInterval = 10 * 60

    static func valid(_ point: MKMapPoint) -> Bool {
        point.x.isFinite && point.y.isFinite && point.y >= 0 && point.y <= MKMapRect.world.size.height
    }

    static func frame(level: Int, anchor: MKMapPoint) -> TripActivityMapFrame? {
        guard sides.indices.contains(level), valid(anchor) else { return nil }
        let side = sides[level] * MKMapPointsPerMeterAtLatitude(anchor.coordinate.latitude)
        return TripActivityMapFrame(rect: MKMapRect(x: anchor.x - side / 2, y: anchor.y - side / 2, width: side, height: side))
    }

    static func shouldRebuild(level: Int, existing: TripActivityMapAtlasLevel?, anchor: MKMapPoint,
                              now: Date, lastAttempt: Date?, enabled: Bool) -> Bool {
        guard enabled, sides.indices.contains(level), valid(anchor) else { return false }
        guard let existing else { return true }
        let last = max(existing.createdAt, lastAttempt ?? .distantPast)
        guard now.timeIntervalSince(last) >= rebuildInterval else { return false }
        return now.timeIntervalSince(existing.createdAt) > maximumAge || distance(from: existing.center, to: anchor) > sides[level] / 4
    }

    static func distance(from center: MKMapPoint, to point: MKMapPoint) -> Double {
        let world = MKMapRect.world.size.width
        let dx = point.x - center.x
        let wrappedX = dx - (dx / world).rounded() * world
        return hypot(wrappedX, point.y - center.y) / MKMapPointsPerMeterAtLatitude(center.coordinate.latitude)
    }

    static func finest(containing frame: TripActivityMapFrame, levels: [TripActivityMapAtlasLevel]) -> TripActivityMapAtlasCrop? {
        levels.sorted { $0.level < $1.level }.lazy.compactMap { TripActivityMapAtlasCrop(level: $0, requested: frame) }.first
    }

    static func crops(for frames: [TripActivityMap.Presentation: TripActivityMapFrame],
                      levels: [TripActivityMapAtlasLevel]) -> [TripActivityMap.Presentation: TripActivityMapAtlasCrop]? {
        guard !frames.isEmpty else { return nil }
        var crops: [TripActivityMap.Presentation: TripActivityMapAtlasCrop] = [:]
        for (presentation, frame) in frames {
            guard let crop = finest(containing: frame, levels: levels) else { return nil }
            crops[presentation] = crop
        }
        return crops
    }
}

struct TripActivityMapAtlasCrop {
    let level: TripActivityMapAtlasLevel
    let pixels: CGRect
    let frame: TripActivityMapFrame

    init?(level: TripActivityMapAtlasLevel, requested: TripActivityMapFrame) {
        guard let source = level.frame, source.contains(requested) else { return nil }
        let rect = requested.alignedRect(in: source)
        let count = TripActivityMapAtlasPolicy.pixels
        let left = max(0, floor((rect.minX - source.rect.minX) / source.rect.size.width * count))
        let top = max(0, floor((rect.minY - source.rect.minY) / source.rect.size.height * count))
        let right = min(count, ceil((rect.maxX - source.rect.minX) / source.rect.size.width * count))
        let bottom = min(count, ceil((rect.maxY - source.rect.minY) / source.rect.size.height * count))
        guard right > left, bottom > top,
              let frame = TripActivityMapFrame(rect: MKMapRect(
                x: source.rect.minX + left / count * source.rect.size.width,
                y: source.rect.minY + top / count * source.rect.size.height,
                width: (right - left) / count * source.rect.size.width,
                height: (bottom - top) / count * source.rect.size.height)) else { return nil }
        self.level = level
        pixels = CGRect(x: left, y: top, width: right - left, height: bottom - top)
        self.frame = frame
    }
}

// Used on the atlas's serial queue after initialization. Only the small manifest is read at launch.
final class TripActivityMapAtlasFiles {
    static var defaultDirectory: URL? {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first?
            .appendingPathComponent("TripActivityMapAtlas", isDirectory: true)
    }

    private struct Manifest: Codable {
        var version = 1
        var levels: [TripActivityMapAtlasLevel]
    }

    let directory: URL?
    private(set) var levels: [TripActivityMapAtlasLevel] = []
    private(set) var decodedFile: String?
    private var decodedImage: CGImage?

    init(directory: URL? = TripActivityMapAtlasFiles.defaultDirectory) {
        self.directory = directory
        guard let directory, let data = try? Data(contentsOf: directory.appendingPathComponent("manifest.json")),
              let manifest = try? JSONDecoder().decode(Manifest.self, from: data), manifest.version == 1 else { return }
        var seen = Set<Int>()
        levels = manifest.levels.filter {
            TripActivityMapAtlasPolicy.sides.indices.contains($0.level) && $0.frame != nil &&
            TripActivityMapAtlasPolicy.valid($0.center) && $0.createdAt.timeIntervalSinceReferenceDate.isFinite &&
            $0.file.hasSuffix(".jpg") && UUID(uuidString: String($0.file.dropLast(4))) != nil &&
            FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.file).path) && seen.insert($0.level).inserted
        }.sorted { $0.level < $1.level }
    }

    @discardableResult
    func write(_ image: TripActivityMapImage, level: Int, center: MKMapPoint, now: Date) throws -> [TripActivityMapAtlasLevel] {
        guard let directory else { throw CocoaError(.fileNoSuchFile) }
        let manager = FileManager.default
        try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                    attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
        try excludeFromBackup(directory)
        let level = TripActivityMapAtlasLevel(level: level, frame: image.frame, center: center, createdAt: now)
        let destination = directory.appendingPathComponent(level.file)
        let staging = directory.appendingPathComponent(UUID().uuidString + ".json")
        let updated = (levels.filter { $0.level != level.level } + [level]).sorted { $0.level < $1.level }
        do {
            try writeProtected(image.data, to: destination)
            try writeProtected(JSONEncoder().encode(Manifest(levels: updated)), to: staging)
            // The manifest is the commit point; a crash can leave an orphan JPEG, never a half-replaced level.
            guard rename(staging.path, directory.appendingPathComponent("manifest.json").path) == 0 else {
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        } catch {
            try? manager.removeItem(at: staging)
            try? manager.removeItem(at: destination)
            throw error
        }
        levels = updated
        let keep = Set(updated.map(\.file) + ["manifest.json"])
        for file in (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [] {
            if !keep.contains(file.lastPathComponent) {
                if decodedFile == file.lastPathComponent { dropDecodedImage() }
                try? manager.removeItem(at: file)
            }
        }
        return updated
    }

    func crop(frames: [TripActivityMap.Presentation: TripActivityMapFrame], minimumWidth: CGFloat)
        -> [TripActivityMap.Presentation: TripActivityMapImage]? {
        guard let crops = TripActivityMapAtlasPolicy.crops(for: frames, levels: levels),
              crops.values.allSatisfy({ $0.pixels.width >= minimumWidth }) else { return nil }
        var images: [TripActivityMap.Presentation: TripActivityMapImage] = [:]
        for presentation in TripActivityMap.Presentation.allCases {
            guard let crop = crops[presentation] else { continue }
            let image: TripActivityMapImage? = autoreleasepool {
                guard let decoded = decode(crop.level), let pixels = decoded.cropping(to: crop.pixels) else { return nil }
                return TripActivityMapRenderer.image(UIImage(cgImage: pixels), frame: crop.frame, size: presentation.size, washed: true)
            }
            guard let image else { return nil }
            images[presentation] = image
        }
        return images
    }

    func dropDecodedImage() {
        decodedImage = nil
        decodedFile = nil
    }

    func removeAll() {
        dropDecodedImage()
        levels = []
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func decode(_ level: TripActivityMapAtlasLevel) -> CGImage? {
        if decodedFile == level.file { return decodedImage }
        dropDecodedImage()
        guard let directory,
              let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(level.file) as CFURL,
                  [kCGImageSourceShouldCache: false] as CFDictionary),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width == Int(TripActivityMapAtlasPolicy.pixels), height == width,
              let image = CGImageSourceCreateImageAtIndex(source, 0,
                  [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { return nil }
        decodedImage = image
        decodedFile = level.file
        return image
    }

    private func writeProtected(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        try excludeFromBackup(url)
    }

    private func excludeFromBackup(_ url: URL) throws {
        var url = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try url.setResourceValues(values)
    }
}

@MainActor
final class TripActivityMapAtlas {
    private let files: TripActivityMapAtlasFiles
    private let queue = DispatchQueue(label: "me.joshpatra.WhereWolf.trip-map-atlas", qos: .utility)
    private let isActive: () -> Bool
    private let snapshotStarter: TripActivityMapSnapshotStarter
    private let now: () -> Date
    private var observers: [NSObjectProtocol] = []
    private var anchor: MKMapPoint?
    private var enabled = false
    private var settingEnabled: Bool?
    private var paused = false
    private var resignedActive = false
    private var building = false
    private var buildingAnchor: MKMapPoint?
    private var buildingLevel: Int?
    private var generation = 0
    private var storageGeneration = 0
    private var cancelSnapshot: (() -> Void)?
    private var timeout: Task<Void, Never>?
    private var lastAttempt: [Int: Date] = [:]
    private(set) var levels: [TripActivityMapAtlasLevel]
    var onChange: (() -> Void)?

    init(files: TripActivityMapAtlasFiles = TripActivityMapAtlasFiles(),
         isActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active },
         snapshotStarter: @escaping TripActivityMapSnapshotStarter = TripActivityMapRenderer.start,
         now: @escaping () -> Date = Date.init, observeApplication: Bool = true) {
        self.files = files
        self.isActive = isActive
        self.snapshotStarter = snapshotStarter
        self.now = now
        levels = files.levels
        guard observeApplication else { return }
        let center = NotificationCenter.default
        for name in [UIApplication.willResignActiveNotification, UIApplication.didEnterBackgroundNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.applicationDidLeaveActive() }
            })
        }
        observers.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.applicationDidBecomeActive() }
        })
        observers.append(center.addObserver(forName: UIApplication.didReceiveMemoryWarningNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.dropDecodedImage() }
        })
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        timeout?.cancel()
        cancelSnapshot?()
    }

    func update(anchor: MKMapPoint?, tripLiveActivityEnabled: Bool, trackingEnabled: Bool,
                sharedStorageAvailable: Bool = SharedTripState.isSharedStorageAvailable) {
        self.anchor = anchor.flatMap { TripActivityMapAtlasPolicy.valid($0) ? $0 : nil }
        if let buildingAnchor, let buildingLevel, let anchor = self.anchor,
           TripActivityMapAtlasPolicy.distance(from: buildingAnchor, to: anchor) > TripActivityMapAtlasPolicy.sides[buildingLevel] / 4 {
            cancelBuild()
        }
        enabled = tripLiveActivityEnabled && trackingEnabled && sharedStorageAvailable && files.directory != nil
        if !tripLiveActivityEnabled {
            cancelBuild()
            if settingEnabled != false {
                storageGeneration += 1
                levels = []
                lastAttempt = [:]
                queue.async { [files] in files.removeAll() }
            }
        }
        settingEnabled = tripLiveActivityEnabled
        guard enabled, self.anchor != nil else { cancelBuild(); return }
        if isActive(), !resignedActive, let directory = files.directory {
            levels.removeAll { !FileManager.default.fileExists(atPath: directory.appendingPathComponent($0.file).path) }
        }
        buildNext(skipping: [])
    }

    func cropWidths(for frames: [TripActivityMap.Presentation: TripActivityMapFrame]) -> [CGFloat]? {
        TripActivityMapAtlasPolicy.crops(for: frames, levels: levels).map { $0.values.map(\.pixels.width) }
    }

    func crop(frames: [TripActivityMap.Presentation: TripActivityMapFrame], minimumWidth: CGFloat,
              completion: @escaping ([TripActivityMap.Presentation: TripActivityMapImage]?) -> Void) {
        queue.async { [files] in
            let images = files.crop(frames: frames, minimumWidth: minimumWidth)
            Task { @MainActor in completion(images) }
        }
    }

    func setPaused(_ paused: Bool) {
        guard self.paused != paused else { return }
        self.paused = paused
        if paused { cancelBuild() } else { buildNext(skipping: []) }
    }

    func applicationDidLeaveActive() {
        resignedActive = true
        cancelBuild()
    }

    func applicationDidBecomeActive() {
        resignedActive = false
        buildNext(skipping: [])
    }

    func dropDecodedImage() { queue.async { [files] in files.dropDecodedImage() } }

    func removeAll() {
        cancelBuild()
        enabled = false
        storageGeneration += 1
        levels = []
        queue.async { [files] in files.removeAll() }
    }

    private func buildNext(skipping: Set<Int>) {
        guard enabled, !paused, !resignedActive, isActive(), !building, let anchor else { return }
        let date = now()
        guard let level = TripActivityMapAtlasPolicy.sides.indices.first(where: { index in
            !skipping.contains(index) && TripActivityMapAtlasPolicy.shouldRebuild(level: index,
                existing: levels.first { $0.level == index }, anchor: anchor, now: date,
                lastAttempt: lastAttempt[index], enabled: enabled)
        }), let frame = TripActivityMapAtlasPolicy.frame(level: level, anchor: anchor) else { return }
        building = true
        buildingAnchor = anchor
        buildingLevel = level
        generation += 1
        let current = generation
        let storage = storageGeneration
        let skipped = skipping.union([level])
        lastAttempt[level] = date
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(35)) } catch { return }
            guard let self, self.generation == current else { return }
            self.cancelBuild()
            self.buildNext(skipping: skipped)
        }
        cancelSnapshot = snapshotStarter(frame, TripActivityMapAtlasPolicy.size, false) { [weak self] image in
            guard let self, self.generation == current else { return }
            self.timeout?.cancel()
            self.timeout = nil
            self.cancelSnapshot = nil
            guard self.isActive(), !self.resignedActive, let image else {
                self.building = false
                self.buildingAnchor = nil
                self.buildingLevel = nil
                self.buildNext(skipping: skipped)
                return
            }
            self.queue.async { [weak self, files = self.files] in
                let updated = try? files.write(image, level: level, center: anchor, now: date)
                Task { @MainActor in
                    guard let self, self.storageGeneration == storage else { return }
                    if let updated { self.levels = updated }
                    if self.generation == current {
                        self.building = false
                        self.buildingAnchor = nil
                        self.buildingLevel = nil
                        self.buildNext(skipping: skipped)
                    }
                    if updated != nil { self.onChange?() }
                }
            }
        }
    }

    private func cancelBuild() {
        generation += 1
        timeout?.cancel()
        timeout = nil
        cancelSnapshot?()
        cancelSnapshot = nil
        building = false
        buildingAnchor = nil
        buildingLevel = nil
    }
}
