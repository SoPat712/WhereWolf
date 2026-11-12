import MapKit
import UIKit

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
                      requested: TripActivityMapFrame, size: CGSize) -> (frame: TripActivityMapFrame, data: Data)? {
        let rect = requested.rect
        let first = MKMapPoint(x: rect.minX + rect.size.width * 0.25, y: rect.minY + rect.size.height * 0.25)
        let last = MKMapPoint(x: rect.minX + rect.size.width * 0.75, y: rect.minY + rect.size.height * 0.75)
        guard let frame = TripActivityMapFrame(first: first, firstPixel: snapshot.point(for: first.coordinate),
            last: last, lastPixel: snapshot.point(for: last.coordinate), size: snapshot.image.size) else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 2
        format.opaque = true
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            let bounds = CGRect(origin: .zero, size: size)
            snapshot.image.draw(in: bounds)
            context.cgContext.setFillColor(UIColor.black.withAlphaComponent(0.45).cgColor)
            context.cgContext.fill(bounds)
        }
        guard let data = image.jpegData(compressionQuality: 0.75), data.count <= 100_000 else { return nil }
        return (frame, data)
    }
}

@MainActor
final class TripActivityMapController {
    private typealias Rendered = (frame: TripActivityMapFrame, data: Data)
    private let files: TripActivityMapFiles
    private var policy = TripActivityMapPolicy()
    private var snapshotter: MKMapSnapshotter?
    private var timeout: Task<Void, Never>?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var generation = 0
    private var showsOnLockScreen = true
    private var rendering: TripActivityMap.Presentation?
    private var requestedFrames: [TripActivityMap.Presentation: TripActivityMapFrame] = [:]
    private var island: Rendered?
    var onChange: (() -> Void)?

    init(files: TripActivityMapFiles = TripActivityMapFiles()) {
        self.files = files
    }

    var needsInitialSnapshot: Bool { files.directory != nil && policy.lastRequest == nil }

    func update(points: [MKMapPoint], enabled: Bool, showsOnLockScreen: Bool) {
        guard enabled, files.directory != nil else { reset(); return }
        let turnedOff = self.showsOnLockScreen && !showsOnLockScreen
        self.showsOnLockScreen = showsOnLockScreen
        if turnedOff {
            files.removeLockScreenImages()
            policy.removeLockScreen()
            if rendering == .lockScreen { finish(generation: generation, lockScreen: nil) }
        }
        guard let islandFrame = TripActivityMapFrame.enclosing(points, size: TripActivityMap.Presentation.island.size),
              let lockFrame = TripActivityMapFrame.enclosing(points, size: TripActivityMap.Presentation.lockScreen.size),
              policy.begin(newest: points.last, now: ProcessInfo.processInfo.systemUptime,
                           enabled: enabled, showsOnLockScreen: showsOnLockScreen) else { return }
        requestedFrames = [.island: islandFrame, .lockScreen: lockFrame]
        generation += 1
        let current = generation
        backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "Trip Activity Maps") { [weak self] in
            Task { @MainActor in self?.fail(generation: current) }
        }
        guard backgroundTask != .invalid else { fail(generation: current); return }
        timeout = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(35)) } catch { return }
            self?.fail(generation: current)
        }
        start(.island, generation: current)
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
        files.removeAll()
    }

    private func start(_ presentation: TripActivityMap.Presentation, generation current: Int) {
        guard let requested = requestedFrames[presentation] else { fail(generation: current); return }
        rendering = presentation
        let size = presentation.size
        let snapshotter = MKMapSnapshotter(options: TripActivityMapRenderer.options(frame: requested, size: size))
        self.snapshotter = snapshotter
        // One MapKit operation at a time; the pair shares its assertion and rate limit.
        snapshotter.start(with: DispatchQueue.global(qos: .utility)) { [weak self] snapshot, _ in
            let result = snapshot.flatMap { TripActivityMapRenderer.image($0, requested: requested, size: size) }
            Task { @MainActor in
                guard let self, self.generation == current, self.rendering == presentation else { return }
                guard let result else { self.fail(generation: current); return }
                if presentation == .island {
                    self.island = result
                    if self.showsOnLockScreen { self.start(.lockScreen, generation: current) }
                    else { self.finish(generation: current, lockScreen: nil) }
                } else {
                    self.finish(generation: current, lockScreen: result)
                }
            }
        }
    }

    private func finish(generation current: Int, lockScreen: Rendered?) {
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
        snapshotter?.cancel()
        snapshotter = nil
        rendering = nil
        requestedFrames = [:]
        island = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }
}
