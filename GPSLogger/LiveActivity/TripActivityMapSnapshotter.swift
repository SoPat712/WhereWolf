import MapKit
import UIKit

struct TripActivityMapImage {
    let frame: TripActivityMapFrame
    let data: Data
}

typealias TripActivityMapSnapshotStarter = @MainActor (TripActivityMapFrame, CGSize, Bool,
    @escaping @MainActor (TripActivityMapImage?) -> Void) -> (() -> Void)

enum TripActivityMapRenderer {
    static func options(frame: TripActivityMapFrame, size: CGSize) -> MKMapSnapshotter.Options {
        let options = MKMapSnapshotter.Options()
        options.mapRect = frame.rect
        options.size = size
        // A flat configuration has no 3D buildings; the older showsBuildings flag is ignored on current iOS.
        let configuration = MKStandardMapConfiguration(elevationStyle: .flat, emphasisStyle: .muted)
        configuration.pointOfInterestFilter = .excludingAll
        options.preferredConfiguration = configuration
        options.traitCollection = UITraitCollection(traitsFrom: [
            UITraitCollection(userInterfaceStyle: .dark), UITraitCollection(displayScale: 2)
        ])
        return options
    }

    static func image(_ snapshot: MKMapSnapshotter.Snapshot,
                      requested: TripActivityMapFrame, size: CGSize, washed: Bool = true) -> TripActivityMapImage? {
        let rect = requested.rect
        let first = MKMapPoint(x: rect.minX + rect.size.width * 0.25, y: rect.minY + rect.size.height * 0.25)
        let last = MKMapPoint(x: rect.minX + rect.size.width * 0.75, y: rect.minY + rect.size.height * 0.75)
        guard let frame = TripActivityMapFrame(first: first, firstPixel: snapshot.point(for: first.coordinate),
            last: last, lastPixel: snapshot.point(for: last.coordinate), size: snapshot.image.size) else { return nil }
        return image(snapshot.image, frame: frame, size: size, washed: washed)
    }

    static func image(_ source: UIImage, frame: TripActivityMapFrame, size: CGSize, washed: Bool) -> TripActivityMapImage? {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let bounds = CGRect(origin: .zero, size: size)
            source.draw(in: bounds)
            if washed {
                context.cgContext.setFillColor(UIColor.black.withAlphaComponent(0.45).cgColor)
                context.cgContext.fill(bounds)
            }
        }
        guard let data = image.jpegData(compressionQuality: washed ? 0.75 : 0.8), !washed || data.count <= 100_000 else { return nil }
        return TripActivityMapImage(frame: frame, data: data)
    }

    @MainActor
    static func start(frame: TripActivityMapFrame, size: CGSize, washed: Bool,
                      completion: @escaping @MainActor (TripActivityMapImage?) -> Void) -> () -> Void {
        let snapshotter = MKMapSnapshotter(options: options(frame: frame, size: size))
        snapshotter.start(with: DispatchQueue.global(qos: .utility)) { snapshot, _ in
            let image = autoreleasepool { snapshot.flatMap { Self.image($0, requested: frame, size: size, washed: washed) } }
            Task { @MainActor in completion(image) }
        }
        return { snapshotter.cancel() }
    }
}

@MainActor
final class TripActivityMapController {
    private let files: TripActivityMapFiles
    private let atlas: TripActivityMapAtlas
    private let isActive: () -> Bool
    private let snapshotStarter: TripActivityMapSnapshotStarter
    private let uptime: () -> TimeInterval
    private let beginBackgroundTask: (@escaping () -> Void) -> UIBackgroundTaskIdentifier
    private let endBackgroundTask: (UIBackgroundTaskIdentifier) -> Void
    private var observers: [NSObjectProtocol] = []
    private var policy = TripActivityMapPolicy()
    private var cancelSnapshot: (() -> Void)?
    private var timeout: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var generation = 0
    private var snapshotRevision = 0
    private var source = TripActivityMapPolicy.Source.none
    private var resignedActive = false
    private var showsOnLockScreen = true
    private var rendering: TripActivityMap.Presentation?
    private var requestedFrames: [TripActivityMap.Presentation: TripActivityMapFrame] = [:]
    private var latestPoints: [MKMapPoint] = []
    private var island: TripActivityMapImage?
    var onChange: (() -> Void)?

    init(files: TripActivityMapFiles = TripActivityMapFiles(), atlas: TripActivityMapAtlas? = nil,
         isActive: @escaping () -> Bool = { UIApplication.shared.applicationState == .active },
         snapshotStarter: @escaping TripActivityMapSnapshotStarter = TripActivityMapRenderer.start,
         uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         beginBackgroundTask: @escaping (@escaping () -> Void) -> UIBackgroundTaskIdentifier = {
             UIApplication.shared.beginBackgroundTask(withName: "Trip Activity Maps", expirationHandler: $0)
         }, endBackgroundTask: @escaping (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) },
         observeApplication: Bool = true) {
        self.files = files
        self.atlas = atlas ?? TripActivityMapAtlas(isActive: isActive, snapshotStarter: snapshotStarter)
        self.isActive = isActive
        self.snapshotStarter = snapshotStarter
        self.uptime = uptime
        self.beginBackgroundTask = beginBackgroundTask
        self.endBackgroundTask = endBackgroundTask
        self.atlas.onChange = { [weak self] in
            guard let self, !self.latestPoints.isEmpty else { return }
            self.update(points: self.latestPoints, enabled: true, showsOnLockScreen: self.showsOnLockScreen)
        }
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
    }

    deinit {
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        timeout?.cancel()
        cancelSnapshot?()
        if backgroundTask != .invalid { endBackgroundTask(backgroundTask) }
    }

    var needsInitialSnapshot: Bool { files.directory != nil && policy.lastRequest == nil }

    func prepareAtlas(anchor: MKMapPoint?, tripLiveActivityEnabled: Bool, trackingEnabled: Bool) {
        atlas.update(anchor: anchor, tripLiveActivityEnabled: tripLiveActivityEnabled, trackingEnabled: trackingEnabled)
    }

    func update(points: [MKMapPoint], enabled: Bool, showsOnLockScreen: Bool) {
        guard enabled, files.directory != nil else { reset(); return }
        latestPoints = points
        let turnedOff = self.showsOnLockScreen && !showsOnLockScreen
        self.showsOnLockScreen = showsOnLockScreen
        if turnedOff {
            files.removeLockScreenImages()
            policy.removeLockScreen()
            requestedFrames[.lockScreen] = nil
            if rendering == .lockScreen { finish(generation: generation, lockScreen: nil) }
        }
        let frames = frames(for: points)
        guard frames[.island] != nil else { return }
        let source = TripActivityMapPolicy.source(cropWidths: atlas.cropWidths(for: frames), isActive: foregroundAvailable)
        guard policy.begin(newest: points.last, now: uptime(), enabled: enabled,
                           showsOnLockScreen: showsOnLockScreen, source: source) else { return }
        requestedFrames = frames
        self.source = source
        generation += 1
        let current = generation
        backgroundTask = beginBackgroundTask { [weak self] in
            Task { @MainActor in self?.fail(generation: current) }
        }
        guard backgroundTask != .invalid else { fail(generation: current); return }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(35)) } catch { return }
            self?.fail(generation: current)
        }
        if source == .atlas {
            startCrop(generation: current, minimumWidth: foregroundAvailable ? TripActivityMapPolicy.preferredCropWidth : TripActivityMapPolicy.minimumCropWidth)
        } else {
            start(.island, generation: current)
        }
    }

    func map(for points: [MKMapPoint], sketch: (TripActivityMapFrame) -> TripRouteSketch) -> TripActivityMap? {
        guard let frame = policy.usableFrame(for: points, presentation: .island), let token = files.currentToken,
              let url = files.url(for: token), FileManager.default.fileExists(atPath: url.path) else { return nil }
        let lockFrame = showsOnLockScreen ? policy.usableFrame(for: points, presentation: .lockScreen) : nil
        return TripActivityMap(token: token, routeInMapFrame: sketch(frame),
                               lockScreenRouteInMapFrame: lockFrame.map(sketch))
    }

    func reset() {
        generation += 1
        stopRequest()
        policy = TripActivityMapPolicy()
        latestPoints = []
        files.removeAll()
        atlas.dropDecodedImage()
    }

    func applicationDidLeaveActive() {
        resignedActive = true
        atlas.applicationDidLeaveActive()
        if policy.inFlight && source == .snapshot { fallBackToCrop(generation: generation) }
    }

    private func applicationDidBecomeActive() {
        resignedActive = false
        atlas.applicationDidBecomeActive()
        if !latestPoints.isEmpty { update(points: latestPoints, enabled: true, showsOnLockScreen: showsOnLockScreen) }
    }

    private var foregroundAvailable: Bool { !resignedActive && isActive() }

    private func frames(for points: [MKMapPoint]) -> [TripActivityMap.Presentation: TripActivityMapFrame] {
        var frames: [TripActivityMap.Presentation: TripActivityMapFrame] = [:]
        for presentation in TripActivityMap.Presentation.allCases where presentation == .island || showsOnLockScreen {
            frames[presentation] = TripActivityMapFrame.enclosing(points, size: presentation.size)
        }
        return frames
    }

    private func startCrop(generation current: Int, minimumWidth: CGFloat, allowsSnapshot: Bool = true) {
        source = .atlas
        atlas.crop(frames: requestedFrames, minimumWidth: minimumWidth) { [weak self] images in
            guard let self, self.generation == current, self.policy.inFlight, self.source == .atlas else { return }
            guard let images, let island = images[.island] else {
                if allowsSnapshot, self.foregroundAvailable, self.policy.fallBackToSnapshot(now: self.uptime()) {
                    self.source = .snapshot
                    self.start(.island, generation: current)
                } else {
                    self.fail(generation: current)
                }
                return
            }
            self.island = island
            self.finish(generation: current, lockScreen: self.showsOnLockScreen ? images[.lockScreen] : nil)
        }
    }

    private func fallBackToCrop(generation current: Int) {
        guard generation == current, policy.inFlight else { return }
        snapshotRevision += 1
        cancelSnapshot?()
        cancelSnapshot = nil
        rendering = nil
        island = nil
        requestedFrames = frames(for: latestPoints)
        guard let widths = atlas.cropWidths(for: requestedFrames),
              widths.allSatisfy({ $0 >= TripActivityMapPolicy.minimumCropWidth }) else { fail(generation: current); return }
        policy.fellBackToCrop(now: uptime())
        startCrop(generation: current, minimumWidth: TripActivityMapPolicy.minimumCropWidth, allowsSnapshot: false)
    }

    private func start(_ presentation: TripActivityMap.Presentation, generation current: Int) {
        guard foregroundAvailable else { fallBackToCrop(generation: current); return }
        guard let requested = requestedFrames[presentation] else { fail(generation: current); return }
        atlas.setPaused(true)
        rendering = presentation
        snapshotRevision += 1
        let operation = snapshotRevision
        cancelSnapshot = snapshotStarter(requested, presentation.size, true) { [weak self] result in
            guard let self, self.generation == current, self.snapshotRevision == operation, self.rendering == presentation else { return }
            guard self.foregroundAvailable else { self.fallBackToCrop(generation: current); return }
            guard let result else { self.fail(generation: current); return }
            self.cancelSnapshot = nil
            if presentation == .island {
                self.island = result
                if self.showsOnLockScreen { self.start(.lockScreen, generation: current) }
                else { self.finish(generation: current, lockScreen: nil) }
            } else {
                self.finish(generation: current, lockScreen: result)
            }
        }
    }

    private func finish(generation current: Int, lockScreen: TripActivityMapImage?) {
        guard generation == current, policy.inFlight else { return }
        var frames: [TripActivityMap.Presentation: TripActivityMapFrame]?
        if let island, (try? files.write(island.data, lockScreen: lockScreen?.data)) != nil {
            frames = [.island: island.frame]
            if let lockScreen { frames?[.lockScreen] = lockScreen.frame }
        }
        policy.complete(frames: frames)
        stopRequest()
        onChange?()
    }

    private func fail(generation current: Int) {
        guard generation == current, policy.inFlight else { return }
        policy.complete(frames: nil)
        stopRequest()
        onChange?()
    }

    private func stopRequest() {
        timeout?.cancel()
        timeout = nil
        snapshotRevision += 1
        cancelSnapshot?()
        cancelSnapshot = nil
        source = .none
        rendering = nil
        requestedFrames = [:]
        island = nil
        if backgroundTask != .invalid {
            endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
        atlas.setPaused(false)
    }
}
