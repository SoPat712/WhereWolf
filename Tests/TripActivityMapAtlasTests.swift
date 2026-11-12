import ImageIO
import MapKit
import UIKit
import XCTest
@testable import WhereWolf

@MainActor
final class TripActivityMapAtlasTests: XCTestCase {
    private let anchor = MKMapPoint(CLLocationCoordinate2D(latitude: 45.5152, longitude: -122.6784))
    private let date = Date(timeIntervalSince1970: 1_800_000_000)

    func testAtlasSidesMissingStaleMovedRateLimitedAndDisabled() throws {
        XCTAssertEqual(TripActivityMapAtlasPolicy.sides, [8_000, 24_000, 72_000, 216_000, 648_000])
        for index in TripActivityMapAtlasPolicy.sides.indices {
            let frame = try XCTUnwrap(TripActivityMapAtlasPolicy.frame(level: index, anchor: anchor))
            let side = TripActivityMapAtlasPolicy.sides[index]
            XCTAssertEqual(frame.rect.size.width / MKMapPointsPerMeterAtLatitude(anchor.coordinate.latitude), side, accuracy: 0.001)
            XCTAssertEqual(frame.rect.size.width, frame.rect.size.height)
            let level = TripActivityMapAtlasLevel(level: index, frame: frame, center: anchor, createdAt: date)
            let moved = MKMapPoint(x: anchor.x + frame.rect.size.width * 0.251, y: anchor.y)
            let age = TripActivityMapAtlasPolicy.maximumAge
            XCTAssertTrue(TripActivityMapAtlasPolicy.shouldRebuild(level: index, existing: nil, anchor: anchor,
                now: date, lastAttempt: date, enabled: true))
            XCTAssertFalse(TripActivityMapAtlasPolicy.shouldRebuild(level: index, existing: nil, anchor: anchor,
                now: date, lastAttempt: nil, enabled: false))
            XCTAssertFalse(TripActivityMapAtlasPolicy.shouldRebuild(level: index, existing: level, anchor: anchor,
                now: date.addingTimeInterval(age), lastAttempt: nil, enabled: true))
            XCTAssertTrue(TripActivityMapAtlasPolicy.shouldRebuild(level: index, existing: level, anchor: anchor,
                now: date.addingTimeInterval(age + 1), lastAttempt: nil, enabled: true))
            XCTAssertFalse(TripActivityMapAtlasPolicy.shouldRebuild(level: index, existing: level, anchor: moved,
                now: date.addingTimeInterval(599.99), lastAttempt: nil, enabled: true))
            XCTAssertTrue(TripActivityMapAtlasPolicy.shouldRebuild(level: index, existing: level, anchor: moved,
                now: date.addingTimeInterval(600), lastAttempt: nil, enabled: true))
            XCTAssertFalse(TripActivityMapAtlasPolicy.shouldRebuild(level: index, existing: level, anchor: moved,
                now: date.addingTimeInterval(1_000), lastAttempt: date.addingTimeInterval(500), enabled: true))
            XCTAssertFalse(TripActivityMapAtlasPolicy.shouldRebuild(level: index, existing: level, anchor: moved,
                now: date.addingTimeInterval(age + 1), lastAttempt: nil, enabled: false))
        }
        XCTAssertNil(TripActivityMapAtlasPolicy.frame(level: 0, anchor: MKMapPoint(x: .nan, y: 0)))
    }

    func testFinestLevelMustContainWholeActualRequestedFrame() throws {
        let levels = try (0..<3).map { index in
            let frame = try XCTUnwrap(TripActivityMapAtlasPolicy.frame(level: index, anchor: anchor))
            return TripActivityMapAtlasLevel(level: index, frame: frame, center: anchor, createdAt: date)
        }
        let small = try centeredFrame(side: 7_000)
        let medium = try centeredFrame(side: 9_000)
        let large = try centeredFrame(side: 80_000)
        XCTAssertEqual(TripActivityMapAtlasPolicy.finest(containing: small, levels: Array(levels.reversed()))?.level.level, 0)
        XCTAssertEqual(TripActivityMapAtlasPolicy.finest(containing: medium, levels: levels)?.level.level, 1)
        XCTAssertNil(TripActivityMapAtlasPolicy.finest(containing: large, levels: levels))
        let crossing = try XCTUnwrap(TripActivityMapFrame(rect: MKMapRect(x: levels[0].frame!.rect.maxX - 1,
            y: anchor.y, width: 2, height: 2)))
        XCTAssertEqual(TripActivityMapAtlasPolicy.finest(containing: crossing, levels: levels)?.level.level, 1)
    }

    func testIntegralCropFrameAlignsRoutePixelsAcrossDateLine() throws {
        let world = MKMapRect.world.size.width
        for x in [anchor.x, world - 1_000] {
            let source = try XCTUnwrap(TripActivityMapFrame(rect: MKMapRect(x: x, y: anchor.y, width: 9_123, height: 9_123)))
            let level = TripActivityMapAtlasLevel(level: 0, frame: source,
                center: MKMapPoint(x: source.rect.midX, y: source.rect.midY), createdAt: date)
            let requested = try XCTUnwrap(TripActivityMapFrame(rect: MKMapRect(
                x: x + 1_001.3, y: anchor.y + 2_003.7, width: 3_003.1, height: 1_201.6)))
            let crop = try XCTUnwrap(TripActivityMapAtlasCrop(level: level, requested: requested))
            XCTAssertEqual(crop.pixels, crop.pixels.integral)
            XCTAssertTrue(crop.frame.contains(requested))
            let point = MKMapPoint(x: requested.rect.midX - (x > world / 2 ? world : 0), y: requested.rect.midY)
            let originalPixel = source.normalized(point)
            let position = crop.frame.normalized(point)
            XCTAssertEqual(position.x, (originalPixel.x * 2_048 - crop.pixels.minX) / crop.pixels.width, accuracy: 0.000000001)
            XCTAssertEqual(position.y, (originalPixel.y * 2_048 - crop.pixels.minY) / crop.pixels.height, accuracy: 0.000000001)
            XCTAssertLessThan(requested.rect.minX - crop.frame.rect.minX, source.rect.size.width / 2_048 + 0.000001)
        }
    }

    func testCropThresholdsAndFallbackOrderRequireEveryNeededPresentation() {
        for active in [false, true] {
            XCTAssertEqual(TripActivityMapPolicy.source(cropWidths: [300, 300], isActive: active), .atlas)
            XCTAssertEqual(TripActivityMapPolicy.source(cropWidths: [301], isActive: active), .atlas)
        }
        XCTAssertEqual(TripActivityMapPolicy.source(cropWidths: [300, 299.99], isActive: true), .snapshot)
        XCTAssertEqual(TripActivityMapPolicy.source(cropWidths: [300, 299.99], isActive: false), .atlas)
        XCTAssertEqual(TripActivityMapPolicy.source(cropWidths: [120, 120], isActive: false), .atlas)
        XCTAssertEqual(TripActivityMapPolicy.source(cropWidths: [300, 119.99], isActive: false), .none)
        XCTAssertEqual(TripActivityMapPolicy.source(cropWidths: [300, 119.99], isActive: true), .snapshot)
        XCTAssertEqual(TripActivityMapPolicy.source(cropWidths: nil, isActive: false), .none)
        XCTAssertEqual(TripActivityMapPolicy.source(cropWidths: nil, isActive: true), .snapshot)
        XCTAssertEqual(TripActivityMapPolicy.source(cropWidths: [], isActive: false), .none)
    }

    func testCropRefreshUsesFifteenSecondsAndSnapshotRetainsTwoMinutes() throws {
        let frame = try XCTUnwrap(TripActivityMapFrame(rect: MKMapRect(x: 0, y: 0, width: 100, height: 100)))
        let center = MKMapPoint(x: 50, y: 50), edge = MKMapPoint(x: 85, y: 50)
        var policy = TripActivityMapPolicy()
        XCTAssertTrue(policy.begin(newest: center, now: 0, enabled: true, showsOnLockScreen: true))
        policy.complete(frames: [.island: frame, .lockScreen: frame])
        XCTAssertFalse(policy.begin(newest: edge, now: 14.99, enabled: true, showsOnLockScreen: true, source: .atlas))
        XCTAssertTrue(policy.begin(newest: edge, now: 15, enabled: true, showsOnLockScreen: true, source: .atlas))
        policy.complete(frames: nil)
        XCTAssertFalse(policy.begin(newest: center, now: 30, enabled: true, showsOnLockScreen: true, source: .atlas))
        XCTAssertFalse(policy.begin(newest: edge, now: 119.99, enabled: true, showsOnLockScreen: true))
        XCTAssertTrue(policy.begin(newest: edge, now: 120, enabled: true, showsOnLockScreen: true))
    }

    func testAtlasManifestCommitsReloadsAndProtectsEveryFile() throws {
        let files = TripActivityMapAtlasFiles(directory: temporaryDirectory())
        defer { files.removeAll() }
        let frame = try centeredFrame(side: 8_000)
        let image = try fixtureImage(frame: frame)
        try files.write(image, level: 0, center: anchor, now: date)
        let previous = try XCTUnwrap(files.levels.first?.file)
        try files.write(image, level: 0, center: anchor, now: date.addingTimeInterval(600))
        try files.write(image, level: 1, center: anchor, now: date)
        let directory = try XCTUnwrap(files.directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent(previous).path))
        let entries = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(entries.count, 3)
        for url in [directory] + entries {
            XCTAssertEqual(try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
#if !targetEnvironment(simulator)
            // The simulator reports no data protection class.
            let protection = try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
            XCTAssertEqual((protection as? FileProtectionType)?.rawValue ?? (protection as? String),
                           FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
#endif
        }
        let reloaded = TripActivityMapAtlasFiles(directory: directory)
        XCTAssertEqual(reloaded.levels.map(\.file), files.levels.map(\.file))
        XCTAssertEqual(reloaded.levels.first?.createdAt, date.addingTimeInterval(600))
        let restored = try XCTUnwrap(reloaded.levels.first?.frame)
        XCTAssertEqual(restored.rect.minX, frame.rect.minX)
        XCTAssertEqual(restored.rect.minY, frame.rect.minY)
        XCTAssertEqual(restored.rect.size.width, frame.rect.size.width)
        XCTAssertEqual(restored.rect.size.height, frame.rect.size.height)
        XCTAssertEqual(TripActivityMapAtlasFiles.defaultDirectory?.lastPathComponent, "TripActivityMapAtlas")
        XCTAssertEqual(TripActivityMapAtlasFiles.defaultDirectory?.deletingLastPathComponent().lastPathComponent, "Application Support")
    }

    func testFailedManifestReplacementKeepsPreviousLevel() throws {
        let files = try seededFiles(side: 8_000)
        defer { files.removeAll() }
        let before = try XCTUnwrap(files.levels.first)
        let image = try fixtureImage(frame: XCTUnwrap(before.frame))
        XCTAssertThrowsError(try files.write(image, level: 0, center: MKMapPoint(x: .nan, y: anchor.y), now: date))
        let directory = try XCTUnwrap(files.directory)
        XCTAssertEqual(TripActivityMapAtlasFiles(directory: directory).levels.first?.file, before.file)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: directory.path).count, 2)
    }

    func testCropOutputSizeWashAndOneDecodedLevel() async throws {
        let files = try seededFiles(side: 8_000)
        let wide = try centeredFrame(side: 24_000)
        try files.write(fixtureImage(frame: wide), level: 1, center: anchor, now: date)
        let atlas = TripActivityMapAtlas(files: files, isActive: { false }, observeApplication: false)
        defer { atlas.removeAll() }
        let frames: [TripActivityMap.Presentation: TripActivityMapFrame] = [
            .island: try centeredFrame(side: 4_000), .lockScreen: try centeredFrame(side: 20_000)
        ]
        let cropped = await crop(atlas, frames: frames)
        let images = try XCTUnwrap(cropped)
        for presentation in TripActivityMap.Presentation.allCases {
            let image = try XCTUnwrap(images[presentation])
            XCTAssertLessThanOrEqual(image.data.count, 100_000)
            let decoded = try XCTUnwrap(UIImage(data: image.data)?.cgImage)
            XCTAssertEqual(decoded.width, Int(presentation.size.width * 2))
            XCTAssertEqual(decoded.height, Int(presentation.size.height * 2))
            XCTAssertEqual(try redComponent(image.data), 140, accuracy: 3)
        }
        XCTAssertEqual(try redComponent(Data(contentsOf: files.directory!.appendingPathComponent(files.levels[0].file))), 255, accuracy: 2)
        XCTAssertEqual(files.decodedFile, files.levels.first { $0.level == 1 }?.file)
        atlas.dropDecodedImage()
        _ = await crop(atlas, frames: [:])
        XCTAssertNil(files.decodedFile)
    }

    func testBackgroundCropNeverStartsMapKitAndResetPreservesAtlas() async throws {
        let stored = try seededFiles(side: 8_000)
        let spy = TripMapSnapshotSpy()
        let atlas = TripActivityMapAtlas(files: stored, isActive: { false }, snapshotStarter: spy.start, observeApplication: false)
        let files = TripActivityMapFiles(directory: temporaryDirectory())
        let controller = controller(files: files, atlas: atlas, spy: spy, isActive: { false })
        defer { controller.reset(); atlas.removeAll() }
        let ready = expectation(description: "background crop")
        controller.onChange = { ready.fulfill() }
        controller.update(points: [anchor], enabled: true, showsOnLockScreen: true)
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertNotNil(controller.map(for: [anchor]) { _ in TripRouteSketch(points: []) }?.route(for: .lockScreen))
        XCTAssertTrue(spy.requests.isEmpty)
        XCTAssertNotNil(stored.decodedFile)
        controller.reset()
        _ = await crop(atlas, frames: [:])
        XCTAssertNil(stored.decodedFile)
        XCTAssertTrue(FileManager.default.fileExists(atPath: stored.directory!.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.directory!.path))
    }

    func testBackgroundWithoutUsableAtlasLeavesPlainSketch() throws {
        for side in [Double?.none, 40_000] {
            let stored = try side.map { try seededFiles(side: $0) } ?? TripActivityMapAtlasFiles(directory: temporaryDirectory())
            let spy = TripMapSnapshotSpy()
            let atlas = TripActivityMapAtlas(files: stored, isActive: { false }, snapshotStarter: spy.start, observeApplication: false)
            defer { atlas.removeAll() }
            let files = TripActivityMapFiles(directory: temporaryDirectory())
            let controller = controller(files: files, atlas: atlas, spy: spy, isActive: { false })
            controller.update(points: [anchor], enabled: true, showsOnLockScreen: true)
            XCTAssertNil(controller.map(for: [anchor]) { _ in TripRouteSketch(points: []) })
            XCTAssertTrue(spy.requests.isEmpty)
            XCTAssertNil(files.currentToken)
            controller.reset()
        }
    }

    func testLeavingForegroundCancelsSnapshotAndCropsImmediately() async throws {
        let stored = try seededFiles(side: 16_000)
        let spy = TripMapSnapshotSpy()
        var active = true
        let atlas = TripActivityMapAtlas(files: stored, isActive: { active }, snapshotStarter: spy.start, observeApplication: false)
        let files = TripActivityMapFiles(directory: temporaryDirectory())
        let controller = controller(files: files, atlas: atlas, spy: spy, isActive: { active })
        defer { controller.reset(); atlas.removeAll() }
        let ready = expectation(description: "crop after cancel")
        controller.onChange = { ready.fulfill() }
        controller.update(points: [anchor], enabled: true, showsOnLockScreen: true)
        XCTAssertEqual(spy.requests.count, 1)
        active = false
        controller.applicationDidLeaveActive()
        XCTAssertEqual(spy.cancellations, 1)
        await fulfillment(of: [ready], timeout: 3)
        XCTAssertNotNil(controller.map(for: [anchor]) { _ in TripRouteSketch(points: []) })
        let token = files.currentToken
        let request = try XCTUnwrap(spy.requests.first)
        request.completion(TripActivityMapImage(frame: request.frame, data: Data([7])))
        XCTAssertEqual(files.currentToken, token)
        XCTAssertEqual(spy.requests.count, 1)
    }

    func testForegroundPrefersAtlasAndLockScreenOffNeedsOnlyIsland() async throws {
        for side in [8_000.0, 9_500.0] {
            let stored = try seededFiles(side: side)
            let spy = TripMapSnapshotSpy()
            let atlas = TripActivityMapAtlas(files: stored, isActive: { true }, snapshotStarter: spy.start, observeApplication: false)
            let files = TripActivityMapFiles(directory: temporaryDirectory())
            let controller = controller(files: files, atlas: atlas, spy: spy, isActive: { true })
            defer { controller.reset(); atlas.removeAll() }
            let ready = expectation(description: "preferred crop")
            controller.onChange = { ready.fulfill() }
            controller.update(points: [anchor], enabled: true, showsOnLockScreen: side == 8_000)
            await fulfillment(of: [ready], timeout: 3)
            XCTAssertTrue(spy.requests.isEmpty)
            let map = try XCTUnwrap(controller.map(for: [anchor]) { _ in TripRouteSketch(points: []) })
            XCTAssertEqual(map.route(for: .lockScreen) != nil, side == 8_000)
            if side != 8_000 {
                XCTAssertFalse(FileManager.default.fileExists(atPath: files.url(for: map.token, presentation: .lockScreen)!.path))
            }
        }
    }

    func testUnreadableAtlasFallsBackToSnapshotOnlyWhileActive() async throws {
        for active in [false, true] {
            let stored = try seededFiles(side: 8_000)
            let level = try XCTUnwrap(stored.levels.first)
            try stored.write(TripActivityMapImage(frame: XCTUnwrap(level.frame), data: Data([0])), level: 0, center: anchor, now: date)
            let spy = TripMapSnapshotSpy()
            let atlas = TripActivityMapAtlas(files: stored, isActive: { active }, snapshotStarter: spy.start, observeApplication: false)
            let files = TripActivityMapFiles(directory: temporaryDirectory())
            let controller = controller(files: files, atlas: atlas, spy: spy, isActive: { active })
            defer { controller.reset(); atlas.removeAll() }
            let ready = expectation(description: "unreadable atlas fallback")
            spy.onStart = { ready.fulfill() }
            controller.onChange = { if !active { ready.fulfill() } }
            controller.update(points: [anchor], enabled: true, showsOnLockScreen: true)
            await fulfillment(of: [ready], timeout: 3)
            XCTAssertEqual(spy.requests.count, active ? 1 : 0)
            XCTAssertNil(files.currentToken)
        }
    }

    func testMemoryWarningDropsDecodedAtlas() async throws {
        let files = try seededFiles(side: 8_000)
        let atlas = TripActivityMapAtlas(files: files, isActive: { false })
        defer { atlas.removeAll() }
        let frame = try XCTUnwrap(TripActivityMapFrame.enclosing([anchor], size: TripActivityMap.Presentation.island.size))
        _ = await crop(atlas, frames: [.island: frame])
        XCTAssertNotNil(files.decodedFile)
        NotificationCenter.default.post(name: UIApplication.didReceiveMemoryWarningNotification, object: nil)
        _ = await crop(atlas, frames: [:])
        XCTAssertNil(files.decodedFile)
    }

    func testCropUsesTopLeftPixelOrigin() async throws {
        let files = TripActivityMapAtlasFiles(directory: temporaryDirectory())
        let atlas = TripActivityMapAtlas(files: files, isActive: { false }, observeApplication: false)
        defer { atlas.removeAll() }
        let frame = try centeredFrame(side: 8_000)
        let source = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 4))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 0, y: 4, width: 8, height: 4))
        }
        let image = try XCTUnwrap(TripActivityMapRenderer.image(source, frame: frame, size: TripActivityMapAtlasPolicy.size, washed: false))
        try files.write(image, level: 0, center: anchor, now: date)
        let top = try XCTUnwrap(TripActivityMapFrame(rect: MKMapRect(x: frame.rect.minX, y: frame.rect.minY,
            width: frame.rect.size.width, height: frame.rect.size.height / 4)))
        let cropped = await crop(atlas, frames: [.island: top])
        let data = try XCTUnwrap(cropped?[.island]?.data)
        XCTAssertEqual(try redComponent(data), 140, accuracy: 4)
    }

    func testCancelledAtlasRebuildKeepsExistingLevel() async throws {
        let files = try seededFiles(side: 8_000)
        let before = try XCTUnwrap(files.levels.first)
        let spy = TripMapSnapshotSpy()
        let atlas = TripActivityMapAtlas(files: files, isActive: { true }, snapshotStarter: spy.start,
            now: { self.date.addingTimeInterval(TripActivityMapAtlasPolicy.maximumAge + 1) }, observeApplication: false)
        defer { atlas.removeAll() }
        atlas.update(anchor: anchor, tripLiveActivityEnabled: true, trackingEnabled: true, sharedStorageAvailable: true)
        let request = try XCTUnwrap(spy.requests.first)
        atlas.applicationDidLeaveActive()
        request.completion(TripActivityMapImage(frame: request.frame, data: Data([0])))
        _ = await crop(atlas, frames: [:])
        XCTAssertEqual(spy.cancellations, 1)
        XCTAssertEqual(atlas.levels.first?.file, before.file)
        XCTAssertEqual(TripActivityMapAtlasFiles(directory: files.directory).levels.first?.file, before.file)
    }

    func testAtlasReanchorsMissingBuildAfterForegroundMovement() async throws {
        let files = TripActivityMapAtlasFiles(directory: temporaryDirectory())
        let spy = TripMapSnapshotSpy()
        let atlas = TripActivityMapAtlas(files: files, isActive: { true }, snapshotStarter: spy.start, observeApplication: false)
        defer { atlas.removeAll() }
        atlas.update(anchor: anchor, tripLiveActivityEnabled: true, trackingEnabled: true, sharedStorageAvailable: true)
        let moved = MKMapPoint(x: anchor.x + 3_000 * MKMapPointsPerMeterAtLatitude(anchor.coordinate.latitude), y: anchor.y)
        atlas.update(anchor: moved, tripLiveActivityEnabled: true, trackingEnabled: true, sharedStorageAvailable: true)
        XCTAssertEqual(spy.cancellations, 1)
        XCTAssertEqual(spy.requests.count, 2)
        let request = try XCTUnwrap(spy.requests.last)
        XCTAssertEqual(request.frame.rect.midX, moved.x, accuracy: 0.000001)
    }

    func testMissingAtlasFileBypassesRebuildRateLimit() throws {
        let files = try seededFiles(side: 8_000)
        let spy = TripMapSnapshotSpy()
        let atlas = TripActivityMapAtlas(files: files, isActive: { true }, snapshotStarter: spy.start,
            now: { self.date.addingTimeInterval(1) }, observeApplication: false)
        defer { atlas.removeAll() }
        let level = try XCTUnwrap(files.levels.first)
        try FileManager.default.removeItem(at: files.directory!.appendingPathComponent(level.file))
        atlas.update(anchor: anchor, tripLiveActivityEnabled: true, trackingEnabled: true, sharedStorageAvailable: true)
        let request = try XCTUnwrap(spy.requests.first)
        XCTAssertEqual(request.frame.rect.size.width / MKMapPointsPerMeterAtLatitude(anchor.coordinate.latitude), 8_000, accuracy: 0.001)
    }

    func testAtlasBuildGatesAndCancellationIgnoreLateSnapshot() async throws {
        let files = TripActivityMapAtlasFiles(directory: temporaryDirectory())
        let spy = TripMapSnapshotSpy()
        var active = false
        let atlas = TripActivityMapAtlas(files: files, isActive: { active }, snapshotStarter: spy.start, observeApplication: false)
        defer { atlas.removeAll() }
        atlas.update(anchor: anchor, tripLiveActivityEnabled: true, trackingEnabled: true, sharedStorageAvailable: true)
        active = true
        atlas.update(anchor: anchor, tripLiveActivityEnabled: false, trackingEnabled: true, sharedStorageAvailable: true)
        atlas.update(anchor: anchor, tripLiveActivityEnabled: true, trackingEnabled: false, sharedStorageAvailable: true)
        atlas.update(anchor: anchor, tripLiveActivityEnabled: true, trackingEnabled: true, sharedStorageAvailable: false)
        atlas.update(anchor: nil, tripLiveActivityEnabled: true, trackingEnabled: true, sharedStorageAvailable: true)
        XCTAssertTrue(spy.requests.isEmpty)
        atlas.update(anchor: anchor, tripLiveActivityEnabled: true, trackingEnabled: true, sharedStorageAvailable: true)
        XCTAssertEqual(spy.requests.count, 1)
        let request = try XCTUnwrap(spy.requests.first)
        XCTAssertEqual(request.size, CGSize(width: 1_024, height: 1_024))
        XCTAssertFalse(request.washed)
        atlas.applicationDidLeaveActive()
        XCTAssertEqual(spy.cancellations, 1)
        request.completion(TripActivityMapImage(frame: request.frame, data: Data([1])))
        _ = await crop(atlas, frames: [:])
        XCTAssertTrue(atlas.levels.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.directory!.path))
    }

    func testAtlasBuildsOneLevelAtATimeFinestFirst() async throws {
        let files = TripActivityMapAtlasFiles(directory: temporaryDirectory())
        let spy = TripMapSnapshotSpy()
        let atlas = TripActivityMapAtlas(files: files, isActive: { true }, snapshotStarter: spy.start, now: { self.date }, observeApplication: false)
        defer { atlas.removeAll() }
        let data = try fixtureImage(frame: centeredFrame(side: 8_000)).data
        atlas.update(anchor: anchor, tripLiveActivityEnabled: true, trackingEnabled: true, sharedStorageAvailable: true)
        for index in TripActivityMapAtlasPolicy.sides.indices {
            XCTAssertEqual(spy.requests.count, index + 1)
            let request = try XCTUnwrap(spy.requests.dropFirst(index).first)
            XCTAssertEqual(request.frame.rect.size.width / MKMapPointsPerMeterAtLatitude(anchor.coordinate.latitude),
                           TripActivityMapAtlasPolicy.sides[index], accuracy: 0.001)
            let ready = expectation(description: "level committed")
            atlas.onChange = { ready.fulfill() }
            request.completion(TripActivityMapImage(frame: request.frame, data: data))
            await fulfillment(of: [ready], timeout: 3)
        }
        XCTAssertEqual(atlas.levels.map(\.level), [0, 1, 2, 3, 4])
        XCTAssertEqual(spy.requests.count, 5)
        atlas.update(anchor: anchor, tripLiveActivityEnabled: true, trackingEnabled: true, sharedStorageAvailable: true)
        XCTAssertEqual(spy.requests.count, 5)
    }

    func testTurningOffTripSettingDeletesAtlasWithTrackingOff() async throws {
        let files = try seededFiles(side: 8_000)
        let spy = TripMapSnapshotSpy()
        let atlas = TripActivityMapAtlas(files: files, isActive: { false }, snapshotStarter: spy.start, observeApplication: false)
        defer { atlas.removeAll() }
        atlas.update(anchor: nil, tripLiveActivityEnabled: false, trackingEnabled: false, sharedStorageAvailable: true)
        _ = await crop(atlas, frames: [:])
        XCTAssertFalse(FileManager.default.fileExists(atPath: files.directory!.path))
        XCTAssertTrue(atlas.levels.isEmpty)
        XCTAssertTrue(files.levels.isEmpty)
        XCTAssertTrue(spy.requests.isEmpty)
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    }

    private func centeredFrame(side: Double) throws -> TripActivityMapFrame {
        let width = side * MKMapPointsPerMeterAtLatitude(anchor.coordinate.latitude)
        return try XCTUnwrap(TripActivityMapFrame(rect: MKMapRect(x: anchor.x - width / 2,
            y: anchor.y - width / 2, width: width, height: width)))
    }

    private func fixtureImage(frame: TripActivityMapFrame) throws -> TripActivityMapImage {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 8, height: 8)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        }
        return try XCTUnwrap(TripActivityMapRenderer.image(image, frame: frame, size: TripActivityMapAtlasPolicy.size, washed: false))
    }

    private func seededFiles(side: Double) throws -> TripActivityMapAtlasFiles {
        let files = TripActivityMapAtlasFiles(directory: temporaryDirectory())
        try files.write(fixtureImage(frame: centeredFrame(side: side)), level: 0, center: anchor, now: date)
        return files
    }

    private func crop(_ atlas: TripActivityMapAtlas, frames: [TripActivityMap.Presentation: TripActivityMapFrame]) async
        -> [TripActivityMap.Presentation: TripActivityMapImage]? {
        await withCheckedContinuation { completion in
            atlas.crop(frames: frames, minimumWidth: 120) { completion.resume(returning: $0) }
        }
    }

    private func controller(files: TripActivityMapFiles, atlas: TripActivityMapAtlas, spy: TripMapSnapshotSpy,
                            isActive: @escaping () -> Bool) -> TripActivityMapController {
        TripActivityMapController(files: files, atlas: atlas, isActive: isActive, snapshotStarter: spy.start,
            beginBackgroundTask: { _ in UIBackgroundTaskIdentifier(rawValue: 1) }, endBackgroundTask: { _ in }, observeApplication: false)
    }

    private func redComponent(_ data: Data) throws -> Double {
        let source = try XCTUnwrap(CGImageSourceCreateWithData(data as CFData, nil))
        let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        var bytes = [UInt8](repeating: 0, count: 4)
        try bytes.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return Double(bytes[0])
    }
}

@MainActor
private final class TripMapSnapshotSpy {
    struct Request {
        let frame: TripActivityMapFrame
        let size: CGSize
        let washed: Bool
        let completion: @MainActor (TripActivityMapImage?) -> Void
    }
    var requests: [Request] = []
    var cancellations = 0
    var onStart: (() -> Void)?

    func start(frame: TripActivityMapFrame, size: CGSize, washed: Bool,
               completion: @escaping @MainActor (TripActivityMapImage?) -> Void) -> () -> Void {
        requests.append(Request(frame: frame, size: size, washed: washed, completion: completion))
        onStart?()
        return { [weak self] in self?.cancellations += 1 }
    }
}
